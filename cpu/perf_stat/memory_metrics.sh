#!/usr/bin/env bash

# Misura: L1-D cache, L1-I cache, LLC (Last Level Cache), dTLB, iTLB miss rate,
#         e stima del working set / pressione sulla gerarchia di memoria.
#
# Utilizzo:
#   ./cpu/perf_stat/memory_metrics.sh --exe /path/to/binary [opzioni]
#
# Opzioni:
#   --exe PATH          Binario da profilare (OBBLIGATORIO)
#   --args "..."        Argomenti da passare al binario
#   --out-dir DIR       Directory di output (default: ./traces/)
#   --output FILE       File di testo con il report (default: traces/memory_metrics.txt)
#   --repeat N          Esegue N volte per la media dei totali (default: 1)
#   --warmup N          Esegue N run di warmup ignorati prima dei repeat (default: 0)
#   --interval MS       Intervallo campionamento in ms per Perfetto (default: 500)
#   --csv               Salva anche un CSV machine-readable
#   --no-perfetto       Non generare il file JSON per Perfetto
#
# Esempio :
#  ./cpu/perf_stat/memory_metrics.sh --exe ../muDock/build/application/muDock
# Nota : usare sudo per vedere branche di thread non appartenenti all'utente corrente (per --per-thread)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# -- Default --
EXE=""
EXE_ARGS=""
OUTPUT_FILE=""
OUT_DIR=""
REPEAT=1
WARMUP=0
INTERVAL_MS=500
SAVE_CSV=0
GEN_PERFETTO=1

# -- Trova perf --
PERF_BIN=""
for candidate in \
  "/usr/lib/linux-tools/$(uname -r)/perf" \
  "$(ls /usr/lib/linux-tools/*/perf 2>/dev/null | sort -V | tail -1)" \
  "perf"; do
  if [[ -x "${candidate}" ]]; then
    PERF_BIN="${candidate}"
    break
  fi
done
[[ -n "${PERF_BIN}" ]] || {
  echo "[ERROR] 'perf' non trovato." >&2
  exit 1
}

# -- Parsing argomenti --
while [[ $# -gt 0 ]]; do
  case "$1" in
  --exe)
    EXE="$2"
    shift
    ;;
  --args)
    EXE_ARGS="$2"
    shift
    ;;
  --output)
    OUTPUT_FILE="$2"
    shift
    ;;
  --out-dir)
    OUT_DIR="$2"
    shift
    ;;
  --repeat)
    REPEAT="$2"
    shift
    ;;
  --warmup)
    WARMUP="$2"
    shift
    ;;
  --interval)
    INTERVAL_MS="$2"
    shift
    ;;
  --csv) SAVE_CSV=1 ;;
  --no-perfetto) GEN_PERFETTO=0 ;;
  -h | --help)
    sed -n '2,30p' "$0" | sed 's/^# \?//'
    exit 0
    ;;
  *) echo "[WARN] Argomento sconosciuto: $1" ;;
  esac
  shift
done

# Set output directory (default: traces/ in cwd)
if [[ -z "${OUT_DIR}" ]]; then
  OUT_DIR="$(pwd)/traces"
fi
mkdir -p "${OUT_DIR}"
[[ -z "${OUTPUT_FILE}" ]] && OUTPUT_FILE="${OUT_DIR}/memory_metrics.txt"

# -- Colori --
step() { echo -e "\n== $* =="; }
ok() { echo "  [OK]  $*"; }
warn() { echo "  [WARN]  $*"; }
info() { echo "  [INFO]  $*"; }
die() {
  echo "  [FAIL]  $*" >&2
  exit 1
}

# -- Validazion
[[ -n "${EXE}" ]] || die "Specifica l'eseguibile con --exe /path/to/binary"
[[ -x "${EXE}" ]] || die "Binario non trovato o non eseguibile: ${EXE}"

# -- Fallback argomenti per muDock se vuoti --
if [[ -z "${EXE_ARGS}" ]]; then
  if [[ "${EXE}" =~ [Mm]u[Dd]ock ]]; then
    MUDOCK_ROOT=""
    if [[ -d "${SCRIPT_DIR}/../../../muDock" ]]; then
      MUDOCK_ROOT="$(cd "${SCRIPT_DIR}/../../../muDock" && pwd)"
    elif [[ -d "${SCRIPT_DIR}/../.." ]]; then
      MUDOCK_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
    fi
    if [[ -n "${MUDOCK_ROOT}" ]]; then
      PROTEIN_PATH="${MUDOCK_ROOT}/data/1fkb/1fkb_protein.pdb"
      # LIGAND_PATH="${MUDOCK_ROOT}/data/1fkb/1fkb_ligand.mol2"
      LIGAND_PATH="${MUDOCK_ROOT}/data/1fkb/1fkb_ligand.adtmol2"
      if [[ -f "${PROTEIN_PATH}" && -f "${LIGAND_PATH}" ]]; then
        EXE_ARGS="--protein ${PROTEIN_PATH} --ligand ${LIGAND_PATH} --use CPP:CPU:0 --population 100 --generations 100"
      fi
    fi
  fi
fi
[[ "${REPEAT}" =~ ^[0-9]+$ && "${REPEAT}" -ge 1 ]] || die "--repeat deve essere un intero >= 1"
[[ "${WARMUP}" =~ ^[0-9]+$ ]] || die "--warmup deve essere un intero >= 0"
[[ "${INTERVAL_MS}" =~ ^[0-9]+$ && "${INTERVAL_MS}" -ge 10 ]] ||
  die "--interval deve essere un intero >= 10 ms"

echo ""
echo "  +--------------------------------------------------------─+"
echo "  |       Memory Metrics — perf stat Analysis              |"
echo "  |  L1 · LLC · dTLB · iTLB · Page Faults + Perfetto     |"
echo "  +--------------------------------------------------------─+"
echo ""

# -- Sblocca contatori hardware --
PARANOIA=$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo "4")
if [[ "${PARANOIA}" -gt 0 ]]; then
  warn "perf_event_paranoid=${PARANOIA} → sblocco temporaneo..."
  sudo sysctl -w kernel.perf_event_paranoid=-1 ||
    warn "Sblocco fallito — alcuni contatori potrebbero non essere disponibili"
fi

# -- Definizione eventi memoria --
# Gruppo 1: L1 Data + L1 Instruction Cache
MEM_EVENTS=(
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

step "STEP 1/3 — Raccolta dati con perf stat"
info "Eseguibile:  ${EXE}"
[[ -n "${EXE_ARGS}" ]] && info "Argomenti:   ${EXE_ARGS}"
info "Repeat:      ${REPEAT}  |  Warmup: ${WARMUP}  |  Intervallo: ${INTERVAL_MS}ms"
echo ""

EVENTS_STR=$(
  IFS=,
  echo "${MEM_EVENTS[*]}"
)

# File temporanei
PERF_STAT_INTERVAL=$(mktemp /tmp/mem_metrics_interval_XXXXXX.txt)
PERF_STAT_TOTAL=$(mktemp /tmp/mem_metrics_total_XXXXXX.txt)
PERF_STAT_PERTHREAD=$(mktemp /tmp/mem_metrics_perthread_XXXXXX.txt)
trap 'rm -f "${PERF_STAT_INTERVAL}" "${PERF_STAT_TOTAL}" "${PERF_STAT_PERTHREAD}"' EXIT

# -- Warmup runs --
if [[ "${WARMUP}" -gt 0 ]]; then
  info "Eseguo ${WARMUP} run di warmup (ignorati nella media)..."
  WARMUP_TMP=$(mktemp /tmp/mem_metrics_warmup_XXXXXX.txt)
  trap 'rm -f "${PERF_STAT_INTERVAL}" "${PERF_STAT_TOTAL}" "${WARMUP_TMP}"' EXIT

  for ((i = 1; i <= WARMUP; i++)); do
    info "  Warmup run ${i}/${WARMUP}..."
    # shellcheck disable=SC2086
    "${PERF_BIN}" stat \
      -e "${EVENTS_STR}" \
      --output "${WARMUP_TMP}" \
      -- "${EXE}" ${EXE_ARGS} \
      2>&1 | tail -1 || true
  done
  rm -f "${WARMUP_TMP}"
  ok "Warmup completato — cache sistema scaldata"
  echo ""
fi

# -- Run con -I per la serie temporale (Perfetto JSON) --
info "Eseguo run con -I ${INTERVAL_MS}ms per la serie temporale Perfetto..."
# shellcheck disable=SC2086
"${PERF_BIN}" stat \
  -I "${INTERVAL_MS}" \
  -e "${EVENTS_STR}" \
  --output "${PERF_STAT_INTERVAL}" \
  -- "${EXE}" ${EXE_ARGS} \
  2>&1 | tail -3

# -- Run senza -I per i totali precisi (media su --repeat) --
info "Eseguo ${REPEAT} run per i totali (media)..."
# shellcheck disable=SC2086
"${PERF_BIN}" stat \
  --repeat "${REPEAT}" \
  -e "${EVENTS_STR}" \
  --output "${PERF_STAT_TOTAL}" \
  -- "${EXE}" ${EXE_ARGS} \
  2>&1 | tail -3

PERF_STAT_RAW="${PERF_STAT_TOTAL}"

# -- Run per-thread: breakdown dei contatori cache per singolo thread --
info "Eseguo run --per-thread per il breakdown per thread..."

# Se siamo root (sudo), aggiungiamo -a per consentire --per-thread
PER_THREAD_OPTS="--per-thread"
if [[ "${EUID}" -eq 0 ]]; then
  PER_THREAD_OPTS="--per-thread -a"
fi

# shellcheck disable=SC2086
"${PERF_BIN}" stat \
  ${PER_THREAD_OPTS} \
  -e "${EVENTS_STR}" \
  --output "${PERF_STAT_PERTHREAD}" \
  -- "${EXE}" ${EXE_ARGS} \
  2>&1 | tail -3 || true

ok "Raccolta completata"

# -- Parsing --
step "STEP 2/2 — Parsing e generazione report"

RAW_CONTENT=$(cat "${PERF_STAT_RAW}")

extract_val() {
  local event="$1"
  local val
  val=$(echo "${RAW_CONTENT}" | grep -m1 "${event}" | awk '{gsub(/,/,""); print $1}' || echo "0")
  if [[ ! "${val}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    val="0"
  fi
  echo "${val}"
}

# Estrai tutti i valori
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

# Calcola miss rate con awk (gestisce divisione per 0)
calc_rate() {
  awk -v miss="$1" -v total="$2" \
    'BEGIN { if (total>0) printf "%.3f%%", miss/total*100; else print "N/A" }'
}
calc_hits() {
  awk -v miss="$1" -v total="$2" \
    'BEGIN { if (total>0) printf "%.3f%%", (1 - miss/total)*100; else print "N/A" }'
}
fmt_num() {
  printf "%'d" "${1:-0}" 2>/dev/null || echo "${1:-0}"
}
fmt_M() {
  awk -v n="${1:-0}" 'BEGIN { printf "%.2f M", n/1e6 }'
}

# Metriche derivate
L1D_MISS_RATE=$(calc_rate "${L1D_MISS}" "${L1D_LOADS}")
L1D_HIT_RATE=$(calc_hits "${L1D_MISS}" "${L1D_LOADS}")
L1I_MISS_RATE=$(calc_rate "${L1I_MISS}" "${L1I_LOADS}")
L1I_HIT_RATE=$(calc_hits "${L1I_MISS}" "${L1I_LOADS}")
LLC_MISS_RATE=$(calc_rate "${LLC_MISS}" "${LLC_REFS}")
LLC_HIT_RATE=$(calc_hits "${LLC_MISS}" "${LLC_REFS}")
DTLB_MISS_RATE=$(calc_rate "${DTLB_MISS}" "${DTLB_LOADS}")
ITLB_MISS_RATE=$(calc_rate "${ITLB_MISS}" "${ITLB_LOADS}")

# Nota: MPKI = Misses Per Kilo-Instructions (richiede istruzioni da cpu_metrics)
INSTR=0
if [[ -f "${OUT_DIR}/cpu_metrics_raw.txt" ]]; then
  INSTR=$(grep -m1 "instructions" "${OUT_DIR}/cpu_metrics_raw.txt" | awk '{gsub(/,/,""); print $1}' || echo "0")
elif [[ -f "cpu_metrics_raw.txt" ]]; then
  INSTR=$(grep -m1 "instructions" cpu_metrics_raw.txt | awk '{gsub(/,/,""); print $1}' || echo "0")
fi

LLC_MPKI="N/A"
if [[ "${INSTR}" -gt 0 ]]; then
  LLC_MPKI=$(awk -v miss="${LLC_MISS}" -v instr="${INSTR}" \
    'BEGIN { printf "%.2f", miss/instr*1000 }')
fi

{
  echo "+===================================================================+"
  echo "|                 MEMORY METRICS REPORT                           |"
  echo "+===================================================================╣"
  printf "|  Eseguibile: %-52s |\n" "${EXE}"
  printf "|  Data:       %-52s |\n" "$(date '+%Y-%m-%d %H:%M:%S')"
  printf "|  Elapsed:    %-52s |\n" "${ELAPSED} s"
  printf "|  Repeat:     %-52s |\n" "${REPEAT}  (warmup: ${WARMUP})"
  echo "+===================================================================╣"
  echo "|                                                                  |"
  echo "|   L1 DATA CACHE (L1-D)                                         |"
  printf "|    Loads totali     : %-44s |\n" "$(fmt_M "${L1D_LOADS}") ($(fmt_num "${L1D_LOADS}"))"
  printf "|    Misses           : %-44s |\n" "$(fmt_M "${L1D_MISS}") ($(fmt_num "${L1D_MISS}"))"
  printf "|    Miss rate        : %-44s |\n" "${L1D_MISS_RATE}"
  printf "|    Hit rate         : %-44s |\n" "${L1D_HIT_RATE}"
  echo "|                                                                  |"
  echo "|   L1 INSTRUCTION CACHE (L1-I)                                  |"
  printf "|    Loads totali     : %-44s |\n" "$(fmt_M "${L1I_LOADS}") ($(fmt_num "${L1I_LOADS}"))"
  printf "|    Misses           : %-44s |\n" "$(fmt_M "${L1I_MISS}") ($(fmt_num "${L1I_MISS}"))"
  printf "|    Miss rate        : %-44s |\n" "${L1I_MISS_RATE}"
  printf "|    Hit rate         : %-44s |\n" "${L1I_HIT_RATE}"
  echo "|                                                                  |"
  echo "|   LAST LEVEL CACHE (LLC / L3)                                  |"
  printf "|    References totali: %-44s |\n" "$(fmt_M "${LLC_REFS}") ($(fmt_num "${LLC_REFS}"))"
  printf "|    Misses (→ RAM)   : %-44s |\n" "$(fmt_M "${LLC_MISS}") ($(fmt_num "${LLC_MISS}"))"
  printf "|    Miss rate        : %-44s |\n" "${LLC_MISS_RATE}"
  printf "|    Hit rate         : %-44s |\n" "${LLC_HIT_RATE}"
  printf "|    MPKI (LLC miss/KI): %-43s |\n" "${LLC_MPKI}"
  echo "|                                                                  |"
  echo "|   dTLB (Data Translation Lookaside Buffer)                     |"
  printf "|    Loads totali     : %-44s |\n" "$(fmt_M "${DTLB_LOADS}") ($(fmt_num "${DTLB_LOADS}"))"
  printf "|    Misses           : %-44s |\n" "$(fmt_M "${DTLB_MISS}") ($(fmt_num "${DTLB_MISS}"))"
  printf "|    Miss rate        : %-44s |\n" "${DTLB_MISS_RATE}"
  echo "|                                                                  |"
  echo "|   iTLB (Instruction TLB)                                       |"
  printf "|    Loads totali     : %-44s |\n" "$(fmt_M "${ITLB_LOADS}") ($(fmt_num "${ITLB_LOADS}"))"
  printf "|    Misses           : %-44s |\n" "$(fmt_M "${ITLB_MISS}") ($(fmt_num "${ITLB_MISS}"))"
  printf "|    Miss rate        : %-44s |\n" "${ITLB_MISS_RATE}"
  echo "|                                                                  |"
  echo "|   PAGE FAULTS                                                   |"
  printf "|    Totali           : %-44s |\n" "$(fmt_num "${PAGE_FAULTS}")"
  printf "|    Major (disk I/O) : %-44s |\n" "$(fmt_num "${MAJOR_FAULTS}")"
  printf "|    Minor (anon/CoW) : %-44s |\n" "$(fmt_num "${MINOR_FAULTS}")"
  echo "|                                                                  |"
  echo "+===================================================================╣"
  echo "|  RAW perf stat (totali) → memory_metrics_raw.txt                |"
  [[ "${GEN_PERFETTO}" -eq 1 ]] &&
    echo "|  Perfetto JSON          → memory_metrics.json                   |"
  echo "+===================================================================+"
  echo ""
  echo "=================== RAW PERF STAT OUTPUT (TOTALI) =================="
  echo ""
  cat "${PERF_STAT_RAW}"
} | tee "${OUTPUT_FILE}"

ok "Report testuale: ${OUTPUT_FILE}"

# Copia raw (totali)
cp "${PERF_STAT_RAW}" "${OUT_DIR}/memory_metrics_raw.txt"
# Copia raw con intervalli
cp "${PERF_STAT_INTERVAL}" "${OUT_DIR}/memory_metrics_interval.txt"
# Copia per-thread
cp "${PERF_STAT_PERTHREAD}" "${OUT_DIR}/memory_metrics_per_thread.txt"

# Mostra estratto per-thread a schermo
echo ""
echo "  === BREAKDOWN PER THREAD (LLC-loads, LLC-load-misses) ==="
grep -E "(muDock|omp|thread|Thread)" "${OUT_DIR}/memory_metrics_per_thread.txt" 2>/dev/null | head -30 || true
echo "  (file completo: ${OUT_DIR}/memory_metrics_per_thread.txt)"

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
  } >"${CSV_FILE}"
  ok "CSV salvato: ${CSV_FILE}"
fi

# -- Genera JSON Perfetto ------------------------------------------------------
if [[ "${GEN_PERFETTO}" -eq 1 ]]; then
  step "STEP 3/3 — Conversione in Perfetto JSON"
  CONVERTER="${SCRIPT_DIR}/../perfetto_converters/stat_to_perfetto.py"
  if [[ -f "${CONVERTER}" ]]; then
    PERFETTO_OUT="${OUTPUT_FILE%.txt}.json"
    python3 "${CONVERTER}" "${OUT_DIR}/memory_metrics_interval.txt" "${PERFETTO_OUT}" &&
      ok "Perfetto JSON: ${PERFETTO_OUT}  → aprilo su https://ui.perfetto.dev/" ||
      warn "Conversione Perfetto fallita (controlla stat_to_perfetto.py)"
  else
    warn "stat_to_perfetto.py non trovato in ${SCRIPT_DIR}"
  fi
fi

ok "Report testuale: ${OUTPUT_FILE}"
ok "Raw (totali):    ${OUT_DIR}/memory_metrics_raw.txt"
ok "Raw (serie):     ${OUT_DIR}/memory_metrics_interval.txt"
