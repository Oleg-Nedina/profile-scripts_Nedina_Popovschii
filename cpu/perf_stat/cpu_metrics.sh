#!/usr/bin/env bash
# =============================================================================
#
# Misura: IPC, cicli, istruzioni, branch prediction, frontend stalls,
#         CPU utilization, context switch, CPU clock.
#
# Utilizzo:
#   ./cpu/perf_stat/cpu_metrics.sh --exe /path/to/binary [opzioni]
#
# Opzioni:
#   --exe PATH          Binario da profilare (OBBLIGATORIO)
#   --args "..."        Argomenti da passare al binario
#   --out-dir DIR       Directory di output (default: ./traces/)
#   --output FILE       File di testo con il report (default: traces/cpu_metrics.txt)
#   --repeat N          Esegue N volte per la media dei totali (default: 1)
#   --warmup N          Esegue N run di warmup ignorati prima dei repeat (default: 0)
#   --interval MS       Intervallo campionamento in ms per Perfetto (default: 500)
#   --csv               Salva anche un CSV machine-readable
#   --no-perfetto       Non generare il file JSON per Perfetto
# Esempio:
#  ./cpu/perf_stat/cpu_metrics.sh --exe ../muDock/build/application/muDock
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# -- Default --
EXE=""
EXE_ARGS=""
OUTPUT_FILE=""
OUT_DIR=""
REPEAT=2
WARMUP=1
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

# -- Output directory --
if [[ -z "${OUT_DIR}" ]]; then
  OUT_DIR="$(pwd)/traces"
fi
mkdir -p "${OUT_DIR}"
[[ -z "${OUTPUT_FILE}" ]] && OUTPUT_FILE="${OUT_DIR}/cpu_metrics.txt"

step() { echo -e "\n== $* =="; }
ok() { echo "  [OK]  $*"; }
warn() { echo "  [WARN]  $*"; }
info() { echo "  [INFO]  $*"; }
die() {
  echo "  [FAIL]  $*" >&2
  exit 1
}

[[ -n "${EXE}" ]] || die "Specifica l'eseguibile con --exe /path/to/binary"
[[ -x "${EXE}" ]] || die "Binario non trovato o non eseguibile: ${EXE}"

# -- Fallback argomenti --
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

# Validazione valori numerici
[[ "${REPEAT}" =~ ^[0-9]+$ && "${REPEAT}" -ge 1 ]] || die "--repeat deve essere un intero >= 1"
[[ "${WARMUP}" =~ ^[0-9]+$ ]] || die "--warmup deve essere un intero >= 0"
[[ "${INTERVAL_MS}" =~ ^[0-9]+$ && "${INTERVAL_MS}" -ge 10 ]] ||
  die "--interval deve essere un intero >= 10 ms"

echo ""
echo "  +--------------------------------------------------------─+"
echo "  |           CPU Metrics — perf stat Analysis             |"
echo "  |  IPC · Branch · Stalls · Utilization + Perfetto JSON  |"
echo "  +--------------------------------------------------------─+"
echo ""

# -- Sblocca contatori hardware --
PARANOIA=$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo "4")
if [[ "${PARANOIA}" -gt 0 ]]; then
  warn "perf_event_paranoid=${PARANOIA} → sblocco temporaneo..."
  sudo sysctl -w kernel.perf_event_paranoid=-1 ||
    warn "Sblocco fallito — alcuni contatori potrebbero non essere disponibili"
fi

# -- Definizione eventi CPU ------------------------------------------------------
CPU_EVENTS=(
  "task-clock"
  "cycles"
  "instructions"
  "branches"
  "branch-misses"
  "stalled-cycles-frontend"
  "stalled-cycles-backend"
  "cache-references"
  "cache-misses"
  "context-switches"
  "cpu-migrations"
  "page-faults"
)

EVENTS_STR=$(
  IFS=,
  echo "${CPU_EVENTS[*]}"
)

# -- File tmp --
PERF_STAT_INTERVAL=$(mktemp /tmp/cpu_metrics_interval_XXXXXX.txt)
PERF_STAT_TOTAL=$(mktemp /tmp/cpu_metrics_total_XXXXXX.txt)
trap 'rm -f "${PERF_STAT_INTERVAL}" "${PERF_STAT_TOTAL}"' EXIT

# Warmup (opzionale) + Raccolta dati
step "STEP 1/3 — Raccolta dati con perf stat"
info "Eseguibile:  ${EXE}"
[[ -n "${EXE_ARGS}" ]] && info "Argomenti:   ${EXE_ARGS}"
info "Repeat:      ${REPEAT}  |  Warmup: ${WARMUP}  |  Intervallo: ${INTERVAL_MS}ms"
echo ""

# -- Warmup runs --
if [[ "${WARMUP}" -gt 0 ]]; then
  info "Eseguo ${WARMUP} run di warmup (ignorati nella media)..."
  WARMUP_TMP=$(mktemp /tmp/cpu_metrics_warmup_XXXXXX.txt)
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

# -- Run con -I per la serie temporale (Perfetto JSON) ------------------------─
info "Eseguo run con -I ${INTERVAL_MS}ms per la serie temporale Perfetto..."
# shellcheck disable=SC2086
"${PERF_BIN}" stat \
  -I "${INTERVAL_MS}" \
  -e "${EVENTS_STR}" \
  --output "${PERF_STAT_INTERVAL}" \
  -- "${EXE}" ${EXE_ARGS} \
  2>&1 | tail -3

# -- Run senza -I per i totali precisi (media su --repeat) --------------------─
info "Eseguo ${REPEAT} run per i totali (media)..."
# shellcheck disable=SC2086
"${PERF_BIN}" stat \
  --repeat "${REPEAT}" \
  -e "${EVENTS_STR}" \
  --output "${PERF_STAT_TOTAL}" \
  -- "${EXE}" ${EXE_ARGS} \
  2>&1 | tail -3

PERF_STAT_RAW="${PERF_STAT_TOTAL}"
ok "Raccolta completata"

# Parsing e generazione report testuale
step "STEP 2/3 — Parsing e generazione report testuale"

RAW_CONTENT=$(cat "${PERF_STAT_RAW}")

# Funzione per estrarre valore da perf stat output
extract_val() {
  local event="$1"
  local val
  val=$(echo "${RAW_CONTENT}" | grep -m1 "${event}" | awk '{gsub(/,/,""); print $1}' || echo "0")
  if [[ ! "${val}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    val="0"
  fi
  echo "${val}"
}

# valori grezzi
CYCLES=$(extract_val "cycles")
INSTR=$(extract_val "instructions")
BRANCHES=$(extract_val "branches")
BRANCH_MISS=$(extract_val "branch-misses")
STALL_FE=$(extract_val "stalled-cycles-frontend")
STALL_BE=$(extract_val "stalled-cycles-backend")
LLC_LOADS=$(extract_val "cache-references")
LLC_LOAD_MISS=$(extract_val "cache-misses")
TASK_CLOCK=$(extract_val "task-clock")
CTX_SW=$(extract_val "context-switches")
MIGRATIONS=$(extract_val "cpu-migrations")
PAGE_FAULTS=$(extract_val "page-faults")

# tempo elapsed e CPU utilizzate
ELAPSED=$(echo "${RAW_CONTENT}" | grep "seconds time elapsed" | awk '{print $1}' || echo "0")
CPU_USED=$(echo "${RAW_CONTENT}" | grep "CPUs utilized" | awk '{for(i=1;i<=NF;i++) if($i=="CPUs" && $(i+1)=="utilized") print $(i-1)}' || echo "N/A")
[[ -n "${CPU_USED}" ]] || CPU_USED="N/A"

# Calcola metriche derivate con awk
IPC=$(awk -v i="${INSTR}" -v c="${CYCLES}" \
  'BEGIN { if (c>0) printf "%.3f", i/c; else print "N/A" }')
BRANCH_MISS_RATE=$(awk -v bm="${BRANCH_MISS}" -v b="${BRANCHES}" \
  'BEGIN { if (b>0) printf "%.2f%%", bm/b*100; else print "N/A" }')
STALL_FE_RATE=$(awk -v sf="${STALL_FE}" -v c="${CYCLES}" \
  'BEGIN { if (c>0) printf "%.2f%%", sf/c*100; else print "N/A" }')
STALL_BE_RATE=$(awk -v sb="${STALL_BE}" -v c="${CYCLES}" \
  'BEGIN { if (c>0) printf "%.2f%%", sb/c*100; else print "N/A" }')
LLC_MISS_RATE=$(awk -v lm="${LLC_LOAD_MISS}" -v ll="${LLC_LOADS}" \
  'BEGIN { if (ll>0) printf "%.2f%%", lm/ll*100; else print "N/A" }')

# Formatta numeri grandi con separatore
fmt_num() {
  printf "%'d" "$1" 2>/dev/null || echo "$1"
}

{
  echo "+===================================================================+"
  echo "|                   CPU METRICS REPORT                            |"
  echo "+===================================================================╣"
  printf "|  Eseguibile: %-52s |\n" "${EXE}"
  printf "|  Data:       %-52s |\n" "$(date '+%Y-%m-%d %H:%M:%S')"
  printf "|  Repeat:     %-52s |\n" "${REPEAT}  (warmup: ${WARMUP})"
  echo "+===================================================================╣"
  echo "|                                                                  |"
  echo "|   EXECUTION TIME                                                |"
  printf "|    Elapsed time          : %-40s |\n" "${ELAPSED} s"
  printf "|    CPUs utilized         : %-40s |\n" "${CPU_USED}"
  echo "|                                                                  |"
  echo "|   INSTRUCTION-LEVEL PARALLELISM                                 |"
  printf "|    IPC  (Instructions/Cycle)  : %-33s |\n" "${IPC}"
  printf "|    Cycles                     : %-33s |\n" "$(fmt_num "${CYCLES:-0}")"
  printf "|    Instructions               : %-33s |\n" "$(fmt_num "${INSTR:-0}")"
  echo "|                                                                  |"
  echo "|   BRANCH PREDICTION                                             |"
  printf "|    Branch instructions        : %-33s |\n" "$(fmt_num "${BRANCHES:-0}")"
  printf "|    Branch mispredictions      : %-33s |\n" "$(fmt_num "${BRANCH_MISS:-0}")"
  printf "|    Branch miss rate           : %-33s |\n" "${BRANCH_MISS_RATE}"
  echo "|                                                                  |"
  echo "|   PIPELINE STALLS                                               |"
  printf "|    Frontend stalled cycles    : %-33s |\n" "$(fmt_num "${STALL_FE:-0}")"
  printf "|    Frontend stall rate        : %-33s |\n" "${STALL_FE_RATE}"
  printf "|    Backend stalled cycles     : %-33s |\n" "$(fmt_num "${STALL_BE:-0}")"
  printf "|    Backend stall rate         : %-33s |\n" "${STALL_BE_RATE}"
  echo "|                                                                  |"
  echo "|   LLC (Last Level Cache)                                        |"
  printf "|    LLC references             : %-33s |\n" "$(fmt_num "${LLC_LOADS:-0}")"
  printf "|    LLC misses (-> RAM)        : %-33s |\n" "$(fmt_num "${LLC_LOAD_MISS:-0}")"
  printf "|    LLC miss rate              : %-33s |\n" "${LLC_MISS_RATE}"
  echo "|                                                                  |"
  echo "|   OS / SCHEDULING                                               |"
  printf "|    Context switches           : %-33s |\n" "$(fmt_num "${CTX_SW:-0}")"
  printf "|    CPU migrations             : %-33s |\n" "$(fmt_num "${MIGRATIONS:-0}")"
  printf "|    Page faults                : %-33s |\n" "$(fmt_num "${PAGE_FAULTS:-0}")"
  echo "|                                                                  |"
  echo "+===================================================================╣"
  echo "+===================================================================╣"
  echo "|  RAW perf stat (totali) → cpu_metrics_raw.txt                   |"
  [[ "${GEN_PERFETTO}" -eq 1 ]] &&
    echo "|  Perfetto JSON          → cpu_metrics.json                      |"
  echo "+===================================================================+"
  echo ""
  echo "=================== RAW PERF STAT OUTPUT (TOTALI) =================="
  echo ""
  cat "${PERF_STAT_RAW}"
} | tee "${OUTPUT_FILE}"

# Copia raw (totali)
cp "${PERF_STAT_RAW}" "${OUT_DIR}/cpu_metrics_raw.txt"
# Copia raw con intervalli (usato da memory_metrics per MPKI, e dal converter Perfetto)
cp "${PERF_STAT_INTERVAL}" "${OUT_DIR}/cpu_metrics_interval.txt"

# -- CSV opzionale --------------------------------------------------------------
if [[ "${SAVE_CSV}" -eq 1 ]]; then
  CSV_FILE="${OUTPUT_FILE%.txt}.csv"
  {
    echo "metric,value,unit"
    echo "elapsed_seconds,${ELAPSED},s"
    echo "cpus_utilized,${CPU_USED},"
    echo "ipc,${IPC},"
    echo "cycles,${CYCLES:-0},count"
    echo "instructions,${INSTR:-0},count"
    echo "branches,${BRANCHES:-0},count"
    echo "branch_misses,${BRANCH_MISS:-0},count"
    echo "branch_miss_rate,${BRANCH_MISS_RATE},%"
    echo "frontend_stalled_cycles,${STALL_FE:-0},count"
    echo "frontend_stall_rate,${STALL_FE_RATE},%"
    echo "backend_stalled_cycles,${STALL_BE:-0},count"
    echo "backend_stall_rate,${STALL_BE_RATE},%"
    echo "llc_references,${LLC_LOADS:-0},count"
    echo "llc_misses,${LLC_LOAD_MISS:-0},count"
    echo "llc_miss_rate,${LLC_MISS_RATE},%"
    echo "context_switches,${CTX_SW:-0},count"
    echo "cpu_migrations,${MIGRATIONS:-0},count"
    echo "page_faults,${PAGE_FAULTS:-0},count"
  } >"${CSV_FILE}"
  ok "CSV salvato: ${CSV_FILE}"
fi

# ==================================================================================
# STEP 3/3 — Conversione in Perfetto JSON
# ==================================================================================
if [[ "${GEN_PERFETTO}" -eq 1 ]]; then
  step "STEP 3/3 — Conversione in Perfetto JSON"
  CONVERTER="${SCRIPT_DIR}/../perfetto_converters/stat_to_perfetto.py"
  if [[ -f "${CONVERTER}" ]]; then
    PERFETTO_OUT="${OUTPUT_FILE%.txt}.json"
    python3 "${CONVERTER}" "${OUT_DIR}/cpu_metrics_interval.txt" "${PERFETTO_OUT}" &&
      ok "Perfetto JSON: ${PERFETTO_OUT}  → aprilo su https://ui.perfetto.dev/" ||
      warn "Conversione Perfetto fallita (controlla stat_to_perfetto.py)"
  else
    warn "stat_to_perfetto.py non trovato in ${SCRIPT_DIR}/../perfetto_converters/"
  fi
fi

echo ""
ok "Report testuale: ${OUTPUT_FILE}"
ok "Raw (totali):    ${OUT_DIR}/cpu_metrics_raw.txt"
ok "Raw (serie):     ${OUT_DIR}/cpu_metrics_interval.txt"
