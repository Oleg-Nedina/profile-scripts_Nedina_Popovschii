#!/usr/bin/env bash
# =============================================================================
# cpu_metrics.sh — Generic CPU Hardware Performance Counter Analyzer
#
# This script measures instruction-level parallelism, branch prediction efficiency,
# cache usage, and scheduler statistics using Linux 'perf stat'.
#
# Usage:
#   ./cpu/perf_stat/cpu_metrics.sh --exe <path_to_executable> [options]
#
# Options:
#   --exe PATH          Path to the executable to profile (REQUIRED)
#   --args "ARGS"       Arguments to pass to the executable (quoted)
#   --out-dir DIR       Directory to save output files (default: cpu/traces/cpu_metrics/)
#   --output FILE       Custom path for the text report (default: cpu/traces/cpu_metrics/cpu_metrics.txt)
#   --repeat N          Number of runs to average (default: 2)
#   --warmup N          Number of warmup runs to discard (default: 1)
#   --csv               Save a machine-readable CSV summary
#   -h, --help          Show this help message
#
# Output:
#   cpu/perf_stat/traces/cpu_metrics/cpu_metrics.txt      Summary report text file
#   cpu/perf_stat/traces/cpu_metrics/cpu_metrics_raw.txt  Raw output from perf stat
#   cpu/perf_stat/traces/cpu_metrics/cpu_metrics.log      Console outputs of target application
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Define default paths
OUT_DIR="${SCRIPT_DIR}/traces/cpu_metrics"

EXE=""
EXE_ARGS=""
OUTPUT_FILE=""
REPEAT=2
WARMUP=1
SAVE_CSV=0

# Find perf binary portably, searching for local kernel tools if wrappers are broken
PERF_BIN=""
for candidate in \
  "/usr/lib/linux-tools/$(uname -r)/perf" \
  $(ls /usr/lib/linux-tools/*/perf 2>/dev/null | sort -V | tail -1) \
  "perf"; do
  if [[ -x "${candidate}" ]]; then
    if "${candidate}" --version &>/dev/null; then
      PERF_BIN="${candidate}"
      break
    fi
  fi
done

[[ -n "${PERF_BIN}" ]] || {
  echo "[ERROR] 'perf' binary not found or not working." >&2
  exit 1
}

# Command line parsing
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
  --csv)
    SAVE_CSV=1
    ;;
  -h | --help)
    sed -n '2,19p' "$0" | sed 's/^# \?//'
    exit 0
    ;;
  *)
    echo "[WARN] Unknown argument: $1" >&2
    ;;
  esac
  shift
done

# Define default log directory
LOG_DIR="${SCRIPT_DIR}/logs"

# Ensure output and log directories exist
mkdir -p "${OUT_DIR}"
mkdir -p "${LOG_DIR}"

# Define log file path
LOG_FILE="${LOG_DIR}/cpu_metrics.log"
> "${LOG_FILE}"

# Prevent user event / PAPI tracers from polluting the workspace, redirect to logs
IGNORED_TRACE="${LOG_DIR}/trace_user_events_ignored.json"
IGNORED_PAPI="${LOG_DIR}/kpi_hotspots_ignored.json"
export ACA_TRACE_USER_OUT="${IGNORED_TRACE}"
export ACA_PAPI_REPORT_OUT="${IGNORED_PAPI}"

# Default output file path
[[ -z "${OUTPUT_FILE}" ]] && OUTPUT_FILE="${OUT_DIR}/cpu_metrics.txt"

# Logger functions
step() { echo -e "\n== $* =="; }
ok() { echo "  [OK]  $*"; }
warn() { echo "  [WARN]  $*"; }
info() { echo "  [INFO]  $*"; }
die() {
  echo "  [FAIL]  $*" >&2
  exit 1
}

# Validation
[[ -n "${EXE}" ]] || die "Executable path is required. Use --exe <path>."
[[ -x "${EXE}" ]] || die "Binary not found or not executable: ${EXE}"
[[ "${REPEAT}" =~ ^[0-9]+$ && "${REPEAT}" -ge 1 ]] || die "--repeat must be an integer >= 1"
[[ "${WARMUP}" =~ ^[0-9]+$ ]] || die "--warmup must be an integer >= 0"

echo ""
echo "  +--------------------------------------------------------─+"
echo "  |           CPU Metrics — perf stat Analysis             |"
echo "  |      IPC · Branch · Stalls · Cache (Saved in traces)   |"
echo "  +--------------------------------------------------------─+"
echo ""

# Unblock hardware counters if needed
PARANOIA=$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo "4")
if [[ "${PARANOIA}" -gt 0 ]]; then
  warn "perf_event_paranoid=${PARANOIA} -> Attempting temporary unlock..."
  sudo sysctl -w kernel.perf_event_paranoid=-1 ||
    warn "Unlock failed - some hardware counters may not be accessible."
fi

# Define CPU performance events to collect
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

# Temp files for raw results
PERF_STAT_TOTAL=$(mktemp /tmp/cpu_metrics_total_XXXXXX.txt)
trap 'rm -f "${PERF_STAT_TOTAL}" "${IGNORED_TRACE}" "${IGNORED_PAPI}"' EXIT

step "STEP 1/2 — Collecting Performance Counters"
info "Target:  ${EXE}"
[[ -n "${EXE_ARGS}" ]] && info "Args:    ${EXE_ARGS}"
info "Repeat:  ${REPEAT}  |  Warmup: ${WARMUP}"
echo ""

# Run warmup runs
if [[ "${WARMUP}" -gt 0 ]]; then
  info "Running ${WARMUP} warmup run(s) to heat caches..."
  WARMUP_TMP=$(mktemp /tmp/cpu_metrics_warmup_XXXXXX.txt)
  
  for ((i = 1; i <= WARMUP; i++)); do
    info "  Warmup run ${i}/${WARMUP}..."
    read -r -a ARGS_ARR <<< "${EXE_ARGS}"
    
    "${PERF_BIN}" stat \
      -e "${EVENTS_STR}" \
      --output "${WARMUP_TMP}" \
      -- "${EXE}" "${ARGS_ARR[@]}" \
      2>&1 | grep -v -E "(_ligand|ligand)" >> "${LOG_FILE}" || true
  done
  rm -f "${WARMUP_TMP}"
  ok "Warmup completed successfully."
  echo ""
fi

# Run profiling runs
info "Running ${REPEAT} profiling run(s) for averaging..."
echo "  (Console output and warnings redirected to: cpu/perf_stat/logs/cpu_metrics.log)"
read -r -a ARGS_ARR <<< "${EXE_ARGS}"

if ! "${PERF_BIN}" stat \
  --repeat "${REPEAT}" \
  -e "${EVENTS_STR}" \
  --output "${PERF_STAT_TOTAL}" \
  -- "${EXE}" "${ARGS_ARR[@]}" \
  2>&1 | grep -v -E "(_ligand|ligand)" >> "${LOG_FILE}"; then
  
  echo ""
  die "perf stat failed! Check logs in: cpu/perf_stat/logs/cpu_metrics.log"
fi

ok "Performance counters collected successfully."

# Parsing and Report Generation
step "STEP 2/2 — Parsing and Generating Report"

RAW_CONTENT=$(cat "${PERF_STAT_TOTAL}")

# Extract value from perf stat output
extract_val() {
  local event="$1"
  local val
  val=$(echo "${RAW_CONTENT}" | grep -m1 "${event}" | awk '{gsub(/,/,""); print $1}' || echo "0")
  if [[ ! "${val}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    val="0"
  fi
  echo "${val}"
}

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

# Extract execution duration and CPU utilization
ELAPSED=$(echo "${RAW_CONTENT}" | grep "seconds time elapsed" | awk '{print $1}' || echo "0")
CPU_USED=$(echo "${RAW_CONTENT}" | grep "CPUs utilized" | awk '{for(i=1;i<=NF;i++) if($i=="CPUs" && $(i+1)=="utilized") print $(i-1)}' || echo "N/A")
[[ -n "${CPU_USED}" ]] || CPU_USED="N/A"

# Calculate derived metrics
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

# Helper to format large numbers
fmt_num() {
  printf "%'d" "$1" 2>/dev/null || echo "$1"
}

# Helper strings with thresholds
IPC_STR="${IPC}  (Critical if < 1.0)"
BRANCH_MISS_STR="${BRANCH_MISS_RATE}  (Critical if > 5.0%)"
STALL_FE_STR="${STALL_FE_RATE}  (Critical if > 20.0%)"
LLC_MISS_STR="${LLC_MISS_RATE}  (Critical if > 10.0%)"

# Write summary text report to terminal and to file (excluding raw perf output)
{
  echo "+===================================================================+"
  echo "|                       CPU METRICS REPORT                          |"
  echo "+===================================================================+"
  printf "|  Executable: %-52s |\n" "$(basename "${EXE}")"
  printf "|  Date      : %-52s |\n" "$(date '+%Y-%m-%d %H:%M:%S')"
  printf "|  Repeat    : %-52s |\n" "${REPEAT} run(s) (warmup: ${WARMUP})"
  echo "+===================================================================+"
  echo "|                                                                   |"
  echo "|   EXECUTION TIME                                                  |"
  printf "|    Elapsed time          : %-38s |\n" "${ELAPSED} s"
  printf "|    CPUs utilized         : %-38s |\n" "${CPU_USED}"
  echo "|                                                                   |"
  echo "|   INSTRUCTION-LEVEL PARALLELISM                                   |"
  printf "|    IPC (Instructions/Cycle)   : %-33s |\n" "${IPC_STR}"
  printf "|    Cycles                     : %-33s |\n" "$(fmt_num "${CYCLES:-0}")"
  printf "|    Instructions               : %-33s |\n" "$(fmt_num "${INSTR:-0}")"
  echo "|                                                                   |"
  echo "|   BRANCH PREDICTION                                               |"
  printf "|    Branch instructions        : %-33s |\n" "$(fmt_num "${BRANCHES:-0}")"
  printf "|    Branch mispredictions      : %-33s |\n" "$(fmt_num "${BRANCH_MISS:-0}")"
  printf "|    Branch miss rate           : %-33s |\n" "${BRANCH_MISS_STR}"
  echo "|                                                                   |"
  echo "|   PIPELINE STALLS                                                 |"
  printf "|    Frontend stalled cycles    : %-33s |\n" "$(fmt_num "${STALL_FE:-0}")"
  printf "|    Frontend stall rate        : %-33s |\n" "${STALL_FE_STR}"
  printf "|    Backend stalled cycles     : %-33s |\n" "$(fmt_num "${STALL_BE:-0}")"
  printf "|    Backend stall rate         : %-33s |\n" "${STALL_BE_RATE}"
  echo "|                                                                   |"
  echo "|   LLC (Last Level Cache)                                          |"
  printf "|    LLC references             : %-33s |\n" "$(fmt_num "${LLC_LOADS:-0}")"
  printf "|    LLC misses (memory access) : %-33s |\n" "$(fmt_num "${LLC_LOAD_MISS:-0}")"
  printf "|    LLC miss rate              : %-33s |\n" "${LLC_MISS_STR}"
  echo "|                                                                   |"
  echo "|   OS / SCHEDULING                                                 |"
  printf "|    Context switches           : %-33s |\n" "$(fmt_num "${CTX_SW:-0}")"
  printf "|    CPU migrations             : %-33s |\n" "$(fmt_num "${MIGRATIONS:-0}")"
  printf "|    Page faults                : %-33s |\n" "$(fmt_num "${PAGE_FAULTS:-0}")"
  echo "|                                                                   |"
  echo "+===================================================================+"
  echo "|  RAW perf stat output -> cpu_metrics_raw.txt                      |"
  echo "+===================================================================+"
} | tee "${OUTPUT_FILE}"

# Save raw output (totals)
cp "${PERF_STAT_TOTAL}" "${OUT_DIR}/cpu_metrics_raw.txt"

# Save optional CSV
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
  echo ""
  ok "CSV summary saved: ${CSV_FILE}"
fi

echo ""
ok "Report summary: ${OUTPUT_FILE}"
ok "Raw totals:     ${OUT_DIR}/cpu_metrics_raw.txt"
