#!/usr/bin/env bash
# =============================================================================
# memory_metrics_generic.sh  —  Analisi metriche memoria/cache generica e adattiva
# =============================================================================
#
# Cerca di profilare la memoria e la gerarchia di cache al livello più basso
# supportato dall'host (contatori PMU hardware), testando preventivamente il
# supporto per ciascun evento e disattivandoli in modo pulito se non disponibili,
# attivando un fallback software per la gestione dei page faults in VM/Docker.
#
# Utilizzo:
#   ./cpu/memory_metrics_generic.sh --exe /path/to/binary [opzioni]
#
# Opzioni:
#   --exe PATH          Binario da profilare (OBBLIGATORIO)
#   --args "..."        Argomenti da passare al binario
#   --output FILE       File di testo con il report (default: traces/memory_metrics_generic.txt)
#   --repeat N          Ripete N volte e fa la media (default: 1)
#   --interval MS       Intervallo campionamento in ms per Perfetto (default: 500)
#   --csv               Salva anche un CSV machine-readable
#   --no-perfetto       Non generare il file JSON per Perfetto
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# -- Default --------------------------------------------------------------------
EXE=""
EXE_ARGS=""
OUTPUT_FILE=""
OUT_DIR=""
REPEAT=1
INTERVAL_MS=500
SAVE_CSV=0
GEN_PERFETTO=1

# -- Colori --------------------------------------------------------------------─
step()   { echo -e "\n== $* =="; }
ok()     { echo "  [OK]  $*"; }
warn()   { echo "  [WARN]  $*"; }
info()   { echo "  [INFO]  $*"; }
die()    { echo "  [FAIL]  $*" >&2; exit 1; }

# -- Trova perf ----------------------------------------------------------------─
PERF_BIN=""
if command -v perf &>/dev/null; then
  PERF_BIN="perf"
else
  for candidate in \
      "/usr/lib/linux-tools/$(uname -r)/perf" \
      "$(ls /usr/lib/linux-tools/*/perf 2>/dev/null | sort -V | tail -1)"; do
    if [[ -x "${candidate}" ]]; then
      PERF_BIN="${candidate}"
      break
    fi
  done
fi
[[ -n "${PERF_BIN}" ]] || die "Strumento 'perf' non trovato nel PATH o in /usr/lib/linux-tools/. Installa linux-tools per abilitare il profiling."

# -- Parsing argomenti ----------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --exe)          EXE="$2";          shift ;;
    --args)         EXE_ARGS="$2";     shift ;;
    --output)       OUTPUT_FILE="$2";  shift ;;
    --out-dir)      OUT_DIR="$2";      shift ;;
    --repeat)       REPEAT="$2";       shift ;;
    --interval)     INTERVAL_MS="$2";  shift ;;
    --csv)          SAVE_CSV=1 ;;
    --no-perfetto)  GEN_PERFETTO=0 ;;
    -h|--help)
      sed -n '2,22p' "$0" | sed 's/^# \?//'
      exit 0 ;;
    *) echo "[WARN] Argomento sconosciuto: $1" ;;
  esac
  shift
done

# Set output directory (default: traces/ in cwd)
if [[ -z "${OUT_DIR}" ]]; then
  OUT_DIR="$(pwd)/traces"
fi
mkdir -p "${OUT_DIR}"
[[ -z "${OUTPUT_FILE}" ]] && OUTPUT_FILE="${OUT_DIR}/memory_metrics_generic.txt"

# -- Validazione eseguibile ----------------------------------------------------─
[[ -n "${EXE}" ]] || die "Specifica l'eseguibile con --exe /path/to/binary"
[[ -x "${EXE}" ]] || die "Binario non trovato o non eseguibile: ${EXE}"

echo ""
echo "  +--------------------------------------------------------─+"
echo "  |     Memory Metrics Generic — Adaptable Cache Analysis   |"
echo "  |     Scans hardware PMU cache events & falls back        |"
echo "  +--------------------------------------------------------─+"
echo ""

# -- Sblocca contatori hardware (se possibile) ----------------------------------
PARANOIA=$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo "4")
if [[ "${PARANOIA}" -gt 0 ]]; then
  warn "perf_event_paranoid=${PARANOIA} → sblocco temporaneo..."
  sudo sysctl -w kernel.perf_event_paranoid=-1 \
    || warn "Sblocco fallito — l'accesso ai contatori hardware potrebbe essere limitato"
fi

# -- Pre-screening degli eventi di memoria supportati --------------------------─
MEM_EVENTS_DESIRED=(
  "L1-dcache-loads"
  "L1-dcache-load-misses"
  "L1-icache-loads"
  "L1-icache-load-misses"
  "cache-references"
  "cache-misses"
  "dTLB-loads"
  "dTLB-load-misses"
  "iTLB-loads"
  "iTLB-load-misses"
  "page-faults"
  "major-faults"
  "minor-faults"
)

SUPPORTED_EVENTS=()
step "Verifica compatibilità eventi memoria/cache..."
for ev in "${MEM_EVENTS_DESIRED[@]}"; do
  if "${PERF_BIN}" stat -e "$ev" -- true &>/dev/null; then
    SUPPORTED_EVENTS+=("$ev")
    ok "Evento supportato: $ev"
  else
    warn "Evento NON supportato: $ev (escluso)"
  fi
done

# Fallback se non ci sono eventi hardware supportati per cache/references
IS_HARDWARE_PMU=1
if [ ${#SUPPORTED_EVENTS[@]} -eq 0 ] || ! ( echo "${SUPPORTED_EVENTS[@]}" | grep -q -E "cache|TLB" ); then
  warn "Nessun contatore hardware PMU per la memoria/cache disponibile."
  warn "Abilitazione del fallback software ad alto livello (Page Faults)..."
  IS_HARDWARE_PMU=0
  SUPPORTED_EVENTS=(
    "page-faults"
    "major-faults"
    "minor-faults"
  )
fi

EVENTS_STR=$(IFS=,; echo "${SUPPORTED_EVENTS[*]}")
info "Eventi selezionati per il profiling: ${EVENTS_STR}"

# ===============================================================================
# STEP 1/3 — Esecuzione con perf stat
# ===============================================================================
step "STEP 1/3 — Esecuzione con perf stat -I ${INTERVAL_MS}ms"
info "Eseguibile:  ${EXE}"
[[ -n "${EXE_ARGS}" ]] && info "Argomenti:   ${EXE_ARGS}"
info "Campionamento ogni ${INTERVAL_MS}ms"
echo ""

# File temporanei
PERF_STAT_INTERVAL=$(mktemp /tmp/mem_metrics_gen_interval_XXXXXX.txt)
PERF_STAT_TOTAL=$(mktemp /tmp/mem_metrics_gen_total_XXXXXX.txt)
trap 'rm -f "${PERF_STAT_INTERVAL}" "${PERF_STAT_TOTAL}"' EXIT

# Esegui con -I per la serie storica (Perfetto JSON)
# shellcheck disable=SC2086
"${PERF_BIN}" stat \
  -I "${INTERVAL_MS}" \
  -e "${EVENTS_STR}" \
  --output "${PERF_STAT_INTERVAL}" \
  -- "${EXE}" ${EXE_ARGS} \
  2>&1 | tail -3 || true

# Esegui senza -I per i totali (precisione report)
# shellcheck disable=SC2086
"${PERF_BIN}" stat \
  --repeat "${REPEAT}" \
  -e "${EVENTS_STR}" \
  --output "${PERF_STAT_TOTAL}" \
  -- "${EXE}" ${EXE_ARGS} \
  2>&1 | tail -3 || true

ok "Raccolta dati completata"

# ===============================================================================
# STEP 2/3 — Parsing e generazione report
# ===============================================================================
step "STEP 2/3 — Parsing e generazione report"

RAW_CONTENT=$(cat "${PERF_STAT_TOTAL}")

extract_val() {
  local event="$1"
  local val
  val=$(echo "${RAW_CONTENT}" | grep -m1 "${event}" | awk '{gsub(/,/,""); print $1}' || true)
  if [[ -z "${val}" || "${val}" == "<not" || "${val}" == "<not supported>" || "${val}" == "<not counted>" ]]; then
    echo "0"
  else
    if [[ "${val}" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
      echo "${val}"
    else
      echo "0"
    fi
  fi
}

L1D_LOADS=$(extract_val "L1-dcache-loads")
L1D_MISS=$(extract_val "L1-dcache-load-misses")
L1I_LOADS=$(extract_val "L1-icache-loads")
L1I_MISS=$(extract_val "L1-icache-load-misses")
LLC_REFS=$(extract_val "cache-references")
LLC_MISS=$(extract_val "cache-misses")
DTLB_LOADS=$(extract_val "dTLB-loads")
DTLB_MISS=$(extract_val "dTLB-load-misses")
ITLB_LOADS=$(extract_val "iTLB-loads")
ITLB_MISS=$(extract_val "iTLB-load-misses")
PAGE_FAULTS=$(extract_val "page-faults")
MAJOR_FAULTS=$(extract_val "major-faults")
MINOR_FAULTS=$(extract_val "minor-faults")

ELAPSED=$(echo "${RAW_CONTENT}" | grep "seconds time elapsed" | awk '{print $1}' || echo "0")

# Calcola rates in modo sicuro
calc_rate() {
  local miss="$1"
  local total="$2"
  if [[ "${total}" == "0" || "${miss}" == "0" ]]; then
    echo "N/A"
  else
    awk -v miss="${miss}" -v total="${total}" 'BEGIN { printf "%.3f%%", miss/total*100 }'
  fi
}

calc_hits() {
  local miss="$1"
  local total="$2"
  if [[ "${total}" == "0" ]]; then
    echo "N/A"
  else
    awk -v miss="${miss}" -v total="${total}" 'BEGIN { printf "%.3f%%", (1 - miss/total)*100 }'
  fi
}

fmt_num() {
  printf "%'d" "${1:-0}" 2>/dev/null || echo "${1:-0}"
}

fmt_M() {
  if [[ "${1:-0}" == "0" ]]; then
    echo "N/A"
  else
    awk -v n="${1:-0}" 'BEGIN { printf "%.2f M", n/1e6 }'
  fi
}

L1D_MISS_RATE=$(calc_rate "${L1D_MISS}" "${L1D_LOADS}")
L1D_HIT_RATE=$(calc_hits "${L1D_MISS}" "${L1D_LOADS}")
L1I_MISS_RATE=$(calc_rate "${L1I_MISS}" "${L1I_LOADS}")
L1I_HIT_RATE=$(calc_hits "${L1I_MISS}" "${L1I_LOADS}")
LLC_MISS_RATE=$(calc_rate "${LLC_MISS}" "${LLC_REFS}")
LLC_HIT_RATE=$(calc_hits "${LLC_MISS}" "${LLC_REFS}")
DTLB_MISS_RATE=$(calc_rate "${DTLB_MISS}" "${DTLB_LOADS}")
ITLB_MISS_RATE=$(calc_rate "${ITLB_MISS}" "${ITLB_LOADS}")

# Tentativo di recuperare istruzioni totali per calcolo MPKI
INSTR=0
if [[ -f "${OUT_DIR}/cpu_metrics_generic_raw.txt" ]]; then
  INSTR=$(grep -m1 "instructions" "${OUT_DIR}/cpu_metrics_generic_raw.txt" | awk '{gsub(/,/,""); print $1}' || echo "0")
elif [[ -f "${OUT_DIR}/cpu_metrics_raw.txt" ]]; then
  INSTR=$(grep -m1 "instructions" "${OUT_DIR}/cpu_metrics_raw.txt" | awk '{gsub(/,/,""); print $1}' || echo "0")
fi

LLC_MPKI="N/A"
if [[ "${INSTR}" -gt 0 && "${LLC_MISS}" != "0" ]]; then
  LLC_MPKI=$(awk -v miss="${LLC_MISS}" -v instr="${INSTR}" 'BEGIN { printf "%.2f", miss/instr*1000 }')
fi

# Costruisci il report
{
  echo "+===================================================================+"
  echo "|               MEMORY METRICS REPORT (PORTABLE)                    |"
  echo "+===================================================================╣"
  printf "|  Eseguibile: %-52s |\n" "${EXE}"
  printf "|  Data:       %-52s |\n" "$(date '+%Y-%m-%d %H:%M:%S')"
  printf "|  Elapsed:    %-52s |\n" "${ELAPSED} s"
  printf "|  Profilazione: %-51s |\n" "$( [[ "${IS_HARDWARE_PMU}" -eq 1 ]] && echo "Hardware (PMU)" || echo "Software Fallback" )"
  echo "+===================================================================╣"
  echo "|                                                                  |"
  echo "|   L1 DATA CACHE (L1-D)                                         |"
  printf "|    Loads totali     : %-44s |\n" "$( [[ "${L1D_LOADS}" != "0" ]] && echo "$(fmt_M "${L1D_LOADS}") ($(fmt_num "${L1D_LOADS}"))" || echo "N/A" )"
  printf "|    Misses           : %-44s |\n" "$( [[ "${L1D_MISS}" != "0" ]] && echo "$(fmt_M "${L1D_MISS}") ($(fmt_num "${L1D_MISS}"))" || echo "N/A" )"
  printf "|    Miss rate        : %-44s |\n" "${L1D_MISS_RATE}"
  printf "|    Hit rate         : %-44s |\n" "${L1D_HIT_RATE}"
  echo "|                                                                  |"
  echo "|   L1 INSTRUCTION CACHE (L1-I)                                  |"
  printf "|    Loads totali     : %-44s |\n" "$( [[ "${L1I_LOADS}" != "0" ]] && echo "$(fmt_M "${L1I_LOADS}") ($(fmt_num "${L1I_LOADS}"))" || echo "N/A" )"
  printf "|    Misses           : %-44s |\n" "$( [[ "${L1I_MISS}" != "0" ]] && echo "$(fmt_M "${L1I_MISS}") ($(fmt_num "${L1I_MISS}"))" || echo "N/A" )"
  printf "|    Miss rate        : %-44s |\n" "${L1I_MISS_RATE}"
  printf "|    Hit rate         : %-44s |\n" "${L1I_HIT_RATE}"
  echo "|                                                                  |"
  echo "|   LAST LEVEL CACHE (LLC / L3)                                  |"
  printf "|    References totali: %-44s |\n" "$( [[ "${LLC_REFS}" != "0" ]] && echo "$(fmt_M "${LLC_REFS}") ($(fmt_num "${LLC_REFS}"))" || echo "N/A" )"
  printf "|    Misses (→ RAM)   : %-44s |\n" "$( [[ "${LLC_MISS}" != "0" ]] && echo "$(fmt_M "${LLC_MISS}") ($(fmt_num "${LLC_MISS}"))" || echo "N/A" )"
  printf "|    Miss rate        : %-44s |\n" "${LLC_MISS_RATE}"
  printf "|    Hit rate         : %-44s |\n" "${LLC_HIT_RATE}"
  printf "|    MPKI (LLC miss/KI): %-43s |\n" "${LLC_MPKI}"
  echo "|                                                                  |"
  echo "|   dTLB (Data Translation Lookaside Buffer)                     |"
  printf "|    Loads totali     : %-44s |\n" "$( [[ "${DTLB_LOADS}" != "0" ]] && echo "$(fmt_M "${DTLB_LOADS}") ($(fmt_num "${DTLB_LOADS}"))" || echo "N/A" )"
  printf "|    Misses           : %-44s |\n" "$( [[ "${DTLB_MISS}" != "0" ]] && echo "$(fmt_M "${DTLB_MISS}") ($(fmt_num "${DTLB_MISS}"))" || echo "N/A" )"
  printf "|    Miss rate        : %-44s |\n" "${DTLB_MISS_RATE}"
  echo "|                                                                  |"
  echo "|   iTLB (Instruction TLB)                                       |"
  printf "|    Loads totali     : %-44s |\n" "$( [[ "${ITLB_LOADS}" != "0" ]] && echo "$(fmt_M "${ITLB_LOADS}") ($(fmt_num "${ITLB_LOADS}"))" || echo "N/A" )"
  printf "|    Misses           : %-44s |\n" "$( [[ "${ITLB_MISS}" != "0" ]] && echo "$(fmt_M "${ITLB_MISS}") ($(fmt_num "${ITLB_MISS}"))" || echo "N/A" )"
  printf "|    Miss rate        : %-44s |\n" "${ITLB_MISS_RATE}"
  echo "|                                                                  |"
  echo "|   PAGE FAULTS (SOFTWARE METRICS)                                |"
  printf "|    Totali           : %-44s |\n" "$(fmt_num "${PAGE_FAULTS}")"
  printf "|    Major (disk I/O) : %-44s |\n" "$(fmt_num "${MAJOR_FAULTS}")"
  printf "|    Minor (anon/CoW) : %-44s |\n" "$(fmt_num "${MINOR_FAULTS}")"
  echo "|                                                                  |"
  echo "+===================================================================╣"
  echo "|  INTERPRETAZIONE RAPIDA                                          |"
  echo "|                                                                  |"
  echo "|  L1-D miss > 10% → working set non entra in L1                   |"
  echo "|  LLC miss  > 10% → working set non entra in L3, accessi a RAM    |"
  echo "|  MPKI > 10        → applicazione memory-bound                     |"
  echo "|  dTLB miss > 1%  → accessi sparsi su molte pagine                |"
  echo "|  (Le metriche PMU hardware sono N/A se si è in fallback)        |"
  echo "|                                                                  |"
  echo "+===================================================================+"
  echo ""
  echo "=================== RAW PERF STAT OUTPUT (TOTALI) =================="
  echo ""
  cat "${PERF_STAT_TOTAL}"
} | tee "${OUTPUT_FILE}"

# Copia file raw
cp "${PERF_STAT_TOTAL}" "${OUT_DIR}/memory_metrics_generic_raw.txt"
cp "${PERF_STAT_INTERVAL}" "${OUT_DIR}/memory_metrics_generic_interval.txt"

# -- CSV opzionale --------------------------------------------------------------
if [[ "${SAVE_CSV}" -eq 1 ]]; then
  CSV_FILE="${OUTPUT_FILE%.txt}.csv"
  {
    echo "metric,value,unit"
    echo "elapsed_seconds,${ELAPSED},s"
    echo "l1d_loads,${L1D_LOADS:-0},count"
    echo "l1d_misses,${L1D_MISS:-0},count"
    echo "l1d_miss_rate,${L1D_MISS_RATE},%"
    echo "l1d_hit_rate,${L1D_HIT_RATE},%"
    echo "l1i_loads,${L1I_LOADS:-0},count"
    echo "l1i_misses,${L1I_MISS:-0},count"
    echo "l1i_miss_rate,${L1I_MISS_RATE},%"
    echo "l1i_hit_rate,${L1I_HIT_RATE},%"
    echo "llc_references,${LLC_REFS:-0},count"
    echo "llc_misses,${LLC_MISS:-0},count"
    echo "llc_miss_rate,${LLC_MISS_RATE},%"
    echo "llc_hit_rate,${LLC_HIT_RATE},%"
    echo "llc_mpki,${LLC_MPKI},miss/KI"
    echo "dtlb_loads,${DTLB_LOADS:-0},count"
    echo "dtlb_misses,${DTLB_MISS:-0},count"
    echo "dtlb_miss_rate,${DTLB_MISS_RATE},%"
    echo "itlb_loads,${ITLB_LOADS:-0},count"
    echo "itlb_misses,${ITLB_MISS:-0},count"
    echo "itlb_miss_rate,${ITLB_MISS_RATE},%"
    echo "page_faults_total,${PAGE_FAULTS:-0},count"
    echo "page_faults_major,${MAJOR_FAULTS:-0},count"
    echo "page_faults_minor,${MINOR_FAULTS:-0},count"
  } > "${CSV_FILE}"
  ok "CSV salvato: ${CSV_FILE}"
fi

# -- Genera JSON Perfetto ------------------------------------------------------
if [[ "${GEN_PERFETTO}" -eq 1 ]]; then
  step "STEP 3/3 — Conversione in Perfetto JSON"
  CONVERTER="${SCRIPT_DIR}/../perfetto_converters/stat_to_perfetto.py"
  if [[ -f "${CONVERTER}" ]]; then
    PERFETTO_OUT="${OUTPUT_FILE%.txt}.json"
    python3 "${CONVERTER}" "${OUT_DIR}/memory_metrics_generic_interval.txt" "${PERFETTO_OUT}" \
      && ok "Perfetto JSON: ${PERFETTO_OUT}  → apri su https://ui.perfetto.dev/" \
      || warn "Conversione Perfetto fallita (verifica stat_to_perfetto.py)"
  else
    warn "stat_to_perfetto.py non trovato in ${SCRIPT_DIR}"
  fi
fi

ok "Report testuale: ${OUTPUT_FILE}"
ok "Raw (totali):    ${OUT_DIR}/memory_metrics_generic_raw.txt"
ok "Raw (serie):     ${OUT_DIR}/memory_metrics_generic_interval.txt"
