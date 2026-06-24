#!/usr/bin/env bash
# =============================================================================
# cpu_metrics_generic.sh  —  Analisi metriche CPU generica ed adattiva
# =============================================================================
#
# Cerca di profilare al livello più basso consentito dall'hardware (PMU),
# testando preventivamente il supporto degli eventi e attivando un fallback
# software se i contatori hardware non sono disponibili (es. in VM o Docker).
#
# Utilizzo:
#   ./cpu/cpu_metrics_generic.sh --exe /path/to/binary [opzioni]
#
# Opzioni:
#   --exe PATH          Binario da profilare (OBBLIGATORIO)
#   --args "..."        Argomenti da passare al binario
#   --output FILE       File di testo con il report (default: traces/cpu_metrics_generic.txt)
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
hdr()    { echo -e "\n$*"; }

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
[[ -z "${OUTPUT_FILE}" ]] && OUTPUT_FILE="${OUT_DIR}/cpu_metrics_generic.txt"

# -- Validazione eseguibile ----------------------------------------------------─
[[ -n "${EXE}" ]] || die "Specifica l'eseguibile con --exe /path/to/binary"
[[ -x "${EXE}" ]] || die "Binario non trovato o non eseguibile: ${EXE}"

echo ""
echo "  +--------------------------------------------------------─+"
echo "  |       CPU Metrics Generic — Adaptable perf Analysis     |"
# Con questa dicitura indichiamo chiaramente la portabilità
echo "  |    Auto-detects PMU hardware & falls back gracefully    |"
echo "  +--------------------------------------------------------─+"
echo ""

# -- Sblocca contatori hardware (se possibile) ----------------------------------
PARANOIA=$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo "4")
if [[ "${PARANOIA}" -gt 0 ]]; then
  warn "perf_event_paranoid=${PARANOIA} → tentativo di sblocco temporaneo..."
  sudo sysctl -w kernel.perf_event_paranoid=-1 \
    || warn "Sblocco fallito — l'accesso ai contatori hardware potrebbe essere limitato"
fi

# -- Pre-screening degli eventi supportati --------------------------------------
CPU_EVENTS_DESIRED=(
  "cycles"
  "instructions"
  "branches"
  "branch-misses"
  "stalled-cycles-frontend"
  "context-switches"
  "cpu-migrations"
  "page-faults"
)

SUPPORTED_EVENTS=()
step "Verifica compatibilità eventi CPU..."
for ev in "${CPU_EVENTS_DESIRED[@]}"; do
  # Esegui un test non distruttivo rapido
  if "${PERF_BIN}" stat -e "$ev" -- true &>/dev/null; then
    SUPPORTED_EVENTS+=("$ev")
    ok "Evento supportato: $ev"
  else
    warn "Evento NON supportato: $ev (escluso)"
  fi
done

# Se non abbiamo eventi hardware critici (es. cycles/instructions), facciamo fallback software
IS_HARDWARE_PMU=1
if [ ${#SUPPORTED_EVENTS[@]} -eq 0 ] || ! ( echo "${SUPPORTED_EVENTS[@]}" | grep -q "cycles" ) || ! ( echo "${SUPPORTED_EVENTS[@]}" | grep -q "instructions" ); then
  warn "Contatori hardware PMU non disponibili (comune in VM/Docker o senza permessi)."
  warn "Abilitazione del fallback software ad alto livello..."
  IS_HARDWARE_PMU=0
  SUPPORTED_EVENTS=(
    "task-clock"
    "context-switches"
    "cpu-migrations"
    "page-faults"
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
PERF_STAT_INTERVAL=$(mktemp /tmp/cpu_metrics_gen_interval_XXXXXX.txt)
PERF_STAT_TOTAL=$(mktemp /tmp/cpu_metrics_gen_total_XXXXXX.txt)
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
# STEP 2/3 — Parsing e generazione report testuale
# ===============================================================================
step "STEP 2/3 — Parsing e generazione report"

RAW_CONTENT=$(cat "${PERF_STAT_TOTAL}")

# Funzione di estrazione sicura per evitare crash con set -e
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

CYCLES=$(extract_val "cycles")
INSTR=$(extract_val "instructions")
BRANCHES=$(extract_val "branches")
BRANCH_MISS=$(extract_val "branch-misses")
STALL_FE=$(extract_val "stalled-cycles-frontend")
TASK_CLOCK=$(extract_val "task-clock")
CTX_SW=$(extract_val "context-switches")
MIGRATIONS=$(extract_val "cpu-migrations")
PAGE_FAULTS=$(extract_val "page-faults")

# Estrazione elapsed time e CPU utilizzate
ELAPSED=$(echo "${RAW_CONTENT}" | grep "seconds time elapsed" | awk '{print $1}' || echo "0")
CPU_USED=$(echo "${RAW_CONTENT}" | grep "CPUs utilized" | awk '{for(i=1;i<=NF;i++) if($i=="CPUs" && $(i+1)=="utilized") print $(i-1)}' || echo "N/A")
[[ -n "${CPU_USED}" ]] || CPU_USED="N/A"

# Calcoli metriche derivate con awk
IPC="N/A"
if [[ "${IS_HARDWARE_PMU}" -eq 1 && $(awk -v c="${CYCLES}" 'BEGIN {print (c>0)?1:0}') -eq 1 ]]; then
  IPC=$(awk -v i="${INSTR}" -v c="${CYCLES}" 'BEGIN { printf "%.3f", i/c }')
fi

BRANCH_MISS_RATE="N/A"
if [[ $(awk -v b="${BRANCHES}" 'BEGIN {print (b>0)?1:0}') -eq 1 ]]; then
  BRANCH_MISS_RATE=$(awk -v bm="${BRANCH_MISS}" -v b="${BRANCHES}" 'BEGIN { printf "%.2f%%", bm/b*100 }')
fi

STALL_RATE="N/A"
if [[ $(awk -v c="${CYCLES}" 'BEGIN {print (c>0)?1:0}') -eq 1 && $(awk -v s="${STALL_FE}" 'BEGIN {print (s>0)?1:0}') -eq 1 ]]; then
  STALL_RATE=$(awk -v sf="${STALL_FE}" -v c="${CYCLES}" 'BEGIN { printf "%.2f%%", sf/c*100 }')
fi

fmt_num() {
  printf "%'d" "$1" 2>/dev/null || echo "$1"
}

# Costruisci il report
{
  echo "+===================================================================+"
  echo "|               CPU METRICS REPORT (PORTABLE)                       |"
  echo "+===================================================================╣"
  printf "|  Eseguibile: %-52s |\n" "${EXE}"
  printf "|  Data:       %-52s |\n" "$(date '+%Y-%m-%d %H:%M:%S')"
  printf "|  Ripetizioni:%-52s |\n" "${REPEAT}"
  printf "|  Profilazione: %-51s |\n" "$( [[ "${IS_HARDWARE_PMU}" -eq 1 ]] && echo "Hardware (PMU)" || echo "Software Fallback" )"
  echo "+===================================================================╣"
  echo "|                                                                  |"
  echo "|   EXECUTION TIME                                                |"
  printf "|    Elapsed time          : %-40s |\n" "${ELAPSED} s"
  printf "|    CPUs utilized         : %-40s |\n" "${CPU_USED}"
  if [[ "${TASK_CLOCK}" != "0" ]]; then
    printf "|    Task-clock (CPU time) : %-40s |\n" "$(awk -v tc="${TASK_CLOCK}" 'BEGIN {printf "%.2f ms", tc}')"
  fi
  echo "|                                                                  |"
  echo "|   INSTRUCTION-LEVEL PARALLELISM                                 |"
  printf "|    IPC  (Instructions/Cycle)  : %-33s |\n" "${IPC}"
  printf "|    Cycles                     : %-33s |\n" "$( [[ "${CYCLES}" != "0" ]] && fmt_num "${CYCLES}" || echo "N/A" )"
  printf "|    Instructions               : %-33s |\n" "$( [[ "${INSTR}" != "0" ]] && fmt_num "${INSTR}" || echo "N/A" )"
  echo "|                                                                  |"
  echo "|   BRANCH PREDICTION                                             |"
  printf "|    Branch instructions        : %-33s |\n" "$( [[ "${BRANCHES}" != "0" ]] && fmt_num "${BRANCHES}" || echo "N/A" )"
  printf "|    Branch mispredictions      : %-33s |\n" "$( [[ "${BRANCH_MISS}" != "0" ]] && fmt_num "${BRANCH_MISS}" || echo "N/A" )"
  printf "|    Branch miss rate           : %-33s |\n" "${BRANCH_MISS_RATE}"
  echo "|                                                                  |"
  echo "|   PIPELINE STALLS                                               |"
  printf "|    Frontend stalled cycles    : %-33s |\n" "$( [[ "${STALL_FE}" != "0" ]] && fmt_num "${STALL_FE}" || echo "N/A" )"
  printf "|    Frontend stall rate        : %-33s |\n" "${STALL_RATE}"
  echo "|                                                                  |"
  echo "|   OS / SCHEDULING (SOFTWARE METRICS)                            |"
  printf "|    Context switches           : %-33s |\n" "$(fmt_num "${CTX_SW:-0}")"
  printf "|    CPU migrations             : %-33s |\n" "$(fmt_num "${MIGRATIONS:-0}")"
  printf "|    Page faults                : %-33s |\n" "$(fmt_num "${PAGE_FAULTS:-0}")"
  echo "|                                                                  |"
  echo "+===================================================================╣"
  echo "|  INTERPRETAZIONE RAPIDA                                          |"
  echo "|                                                                  |"
  echo "|  IPC > 2.0  → buona efficienza pipeline                         |"
  echo "|  IPC < 1.0  → collo di bottiglia (memoria, branch, stall)       |"
  echo "|  Branch miss > 5% → ottimizzare predittori/branch               |"
  echo "|  Frontend stall > 20% → istruzione fetch/decode limitante       |"
  echo "|  (Le metriche PMU hardware sono N/A se si è in fallback)        |"
  echo "|                                                                  |"
  echo "+===================================================================+"
  echo ""
  echo "=================== RAW PERF STAT OUTPUT (TOTALI) =================="
  echo ""
  cat "${PERF_STAT_TOTAL}"
} | tee "${OUTPUT_FILE}"

# Copia raw dei totali e degli intervalli per utilizzi successivi
cp "${PERF_STAT_TOTAL}" "${OUT_DIR}/cpu_metrics_generic_raw.txt"
cp "${PERF_STAT_INTERVAL}" "${OUT_DIR}/cpu_metrics_generic_interval.txt"

# -- CSV opzionale --------------------------------------------------------------
if [[ "${SAVE_CSV}" -eq 1 ]]; then
  CSV_FILE="${OUTPUT_FILE%.txt}.csv"
  {
    echo "metric,value,unit"
    echo "elapsed_seconds,${ELAPSED},s"
    echo "cpus_utilized,${CPU_USED},"
    echo "ipc,${IPC},"
    echo "cycles,${CYCLES},count"
    echo "instructions,${INSTR},count"
    echo "branches,${BRANCHES},count"
    echo "branch_misses,${BRANCH_MISS},count"
    echo "branch_miss_rate,${BRANCH_MISS_RATE},%"
    echo "frontend_stalled_cycles,${STALL_FE},count"
    echo "frontend_stall_rate,${STALL_RATE},%"
    echo "context_switches,${CTX_SW},count"
    echo "cpu_migrations,${MIGRATIONS},count"
    echo "page_faults,${PAGE_FAULTS},count"
  } > "${CSV_FILE}"
  ok "CSV salvato: ${CSV_FILE}"
fi

# -- Genera JSON Perfetto ------------------------------------------------------
if [[ "${GEN_PERFETTO}" -eq 1 ]]; then
  step "STEP 3/3 — Conversione in Perfetto JSON"
  CONVERTER="${SCRIPT_DIR}/../perfetto_converters/stat_to_perfetto.py"
  if [[ -f "${CONVERTER}" ]]; then
    PERFETTO_OUT="${OUTPUT_FILE%.txt}.json"
    python3 "${CONVERTER}" "${OUT_DIR}/cpu_metrics_generic_interval.txt" "${PERFETTO_OUT}" \
      && ok "Perfetto JSON: ${PERFETTO_OUT}  → apri su https://ui.perfetto.dev/" \
      || warn "Conversione Perfetto fallita (verifica stat_to_perfetto.py)"
  else
    warn "stat_to_perfetto.py non trovato in ${SCRIPT_DIR}"
  fi
fi

ok "Report testuale: ${OUTPUT_FILE}"
ok "Raw (totali):    ${OUT_DIR}/cpu_metrics_generic_raw.txt"
ok "Raw (serie):     ${OUT_DIR}/cpu_metrics_generic_interval.txt"
