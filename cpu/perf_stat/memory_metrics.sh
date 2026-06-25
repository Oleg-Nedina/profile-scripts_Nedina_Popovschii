#!/usr/bin/env bash
# =============================================================================
# memory_metrics.sh — Generic CPU Memory Hierarchy Performance Analyzer
#
# This script measures L1 Data Cache, L1 Instruction Cache, Last Level Cache (LLC),
# dTLB, iTLB misses, and Page Faults using Linux 'perf stat'.
#
# Usage:
#   ./cpu/perf_stat/memory_metrics.sh --exe <path_to_executable> [options]
#
# Options:
#   --exe PATH          Path to the executable to profile (REQUIRED)
#   --args "ARGS"       Arguments to pass to the executable (quoted)
#   --out-dir DIR       Directory to save output files (default: cpu/traces/memory_metrics/)
#   --output FILE       Custom path for the text report (default: cpu/traces/memory_metrics/memory_metrics.txt)
#   --repeat N          Number of runs to average (default: 2)
#   --warmup N          Number of warmup runs to discard (default: 1)
#   --csv               Save a machine-readable CSV summary
#   -h, --help          Show this help message
#
# Output:
#   cpu/perf_stat/traces/memory_metrics/memory_metrics.txt         Summary report text file
#   cpu/perf_stat/traces/memory_metrics/memory_metrics_raw.txt     Raw output from perf stat (totals)
#   cpu/perf_stat/traces/memory_metrics/memory_metrics_per_thread.txt  Breakdown of metrics per thread
#   cpu/perf_stat/traces/memory_metrics/memory_metrics.log                Console outputs of target application
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Define default paths
OUT_DIR="${SCRIPT_DIR}/traces/memory_metrics"

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
    sed -n '2,20p' "$0" | sed 's/^# \?//'
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
LOG_FILE="${LOG_DIR}/memory_metrics.log"
> "${LOG_FILE}"

# Prevent user event / PAPI tracers from polluting the workspace, redirect to logs
IGNORED_TRACE="${LOG_DIR}/trace_user_events_ignored.json"
IGNORED_PAPI="${LOG_DIR}/kpi_hotspots_ignored.json"
export ACA_TRACE_USER_OUT="${IGNORED_TRACE}"
export ACA_PAPI_REPORT_OUT="${IGNORED_PAPI}"

# Default output file path
[[ -z "${OUTPUT_FILE}" ]] && OUTPUT_FILE="${OUT_DIR}/memory_metrics.txt"

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
echo "  |         Memory Metrics — perf stat Analysis            |"
echo "  |      L1 · LLC · dTLB · iTLB · Page Faults (Traces)     |"
echo "  +--------------------------------------------------------─+"
echo ""

# Unblock hardware counters if needed
PARANOIA=$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo "4")
if [[ "${PARANOIA}" -gt 0 ]]; then
  warn "perf_event_paranoid=${PARANOIA} -> Attempting temporary unlock..."
  sudo sysctl -w kernel.perf_event_paranoid=-1 ||
    warn "Unlock failed - some hardware counters may not be accessible."
fi

# Define memory-related events to collect
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

EVENTS_STR=$(
  IFS=,
  echo "${MEM_EVENTS[*]}"
)

# Temp files for raw results
PERF_STAT_TOTAL=$(mktemp /tmp/mem_metrics_total_XXXXXX.txt)
trap 'rm -f "${PERF_STAT_TOTAL}" "${IGNORED_TRACE}" "${IGNORED_PAPI}"' EXIT

step "STEP 1/2 — Collecting Performance Counters"
info "Target:  ${EXE}"
[[ -n "${EXE_ARGS}" ]] && info "Args:    ${EXE_ARGS}"
info "Repeat:  ${REPEAT}  |  Warmup: ${WARMUP}"
echo ""

# Run warmup runs
if [[ "${WARMUP}" -gt 0 ]]; then
  info "Running ${WARMUP} warmup run(s) to heat caches..."
  WARMUP_TMP=$(mktemp /tmp/mem_metrics_warmup_XXXXXX.txt)
  
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

# Run profiling runs for totals
info "Running ${REPEAT} profiling run(s) for averaging..."
echo "  (Console output and warnings redirected to: cpu/perf_stat/logs/memory_metrics.log)"
read -r -a ARGS_ARR <<< "${EXE_ARGS}"

if ! "${PERF_BIN}" stat \
  --repeat "${REPEAT}" \
  -e "${EVENTS_STR}" \
  --output "${PERF_STAT_TOTAL}" \
  -- "${EXE}" "${ARGS_ARR[@]}" \
  2>&1 | grep -v -E "(_ligand|ligand)" >> "${LOG_FILE}"; then
  
  echo ""
  die "perf stat failed! Check logs in: cpu/perf_stat/logs/memory_metrics.log"
fi

# Note: Thread breakdown run removed as it is not supported/functional

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

# Rate and formatting calculations
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

L1D_MISS_RATE=$(calc_rate "${L1D_MISS}" "${L1D_LOADS}")
L1D_HIT_RATE=$(calc_hits "${L1D_MISS}" "${L1D_LOADS}")
L1I_MISS_RATE=$(calc_rate "${L1I_MISS}" "${L1I_LOADS}")
L1I_HIT_RATE=$(calc_hits "${L1I_MISS}" "${L1I_LOADS}")
LLC_MISS_RATE=$(calc_rate "${LLC_MISS}" "${LLC_REFS}")
LLC_HIT_RATE=$(calc_hits "${LLC_MISS}" "${LLC_REFS}")
DTLB_MISS_RATE=$(calc_rate "${DTLB_MISS}" "${DTLB_LOADS}")
ITLB_MISS_RATE=$(calc_rate "${ITLB_MISS}" "${ITLB_LOADS}")

# Try to find instructions count to calculate LLC MPKI (Misses Per Kilo-Instructions)
INSTR=0
if [[ -f "${SCRIPT_DIR}/traces/cpu_metrics/cpu_metrics_raw.txt" ]]; then
  INSTR=$(grep -m1 "instructions" "${SCRIPT_DIR}/traces/cpu_metrics/cpu_metrics_raw.txt" | awk '{gsub(/,/,""); print $1}' || echo "0")
elif [[ -f "${OUT_DIR}/../cpu_metrics/cpu_metrics_raw.txt" ]]; then
  INSTR=$(grep -m1 "instructions" "${OUT_DIR}/../cpu_metrics/cpu_metrics_raw.txt" | awk '{gsub(/,/,""); print $1}' || echo "0")
fi

LLC_MPKI="N/A"
if [[ "${INSTR}" -gt 0 ]]; then
  LLC_MPKI=$(awk -v miss="${LLC_MISS}" -v instr="${INSTR}" \
    'BEGIN { printf "%.2f", miss/instr*1000 }')
fi

# Define thresholds for formatting
L1D_MISS_STR="${L1D_MISS_RATE}  (Critical if > 5.0%)"
LLC_MISS_STR="${LLC_MISS_RATE}  (Critical if > 10.0%)"
DTLB_MISS_STR="${DTLB_MISS_RATE}  (Critical if > 2.0%)"
ITLB_MISS_STR="${ITLB_MISS_RATE}  (Critical if > 1.0%)"

{
  echo "+===================================================================+"
  echo "|                       MEMORY METRICS REPORT                       |"
  echo "+===================================================================+"
  printf "|  Executable: %-52s |\n" "$(basename "${EXE}")"
  printf "|  Date      : %-52s |\n" "$(date '+%Y-%m-%d %H:%M:%S')"
  printf "|  Elapsed   : %-52s |\n" "${ELAPSED} s"
  printf "|  Repeat    : %-52s |\n" "${REPEAT} run(s) (warmup: ${WARMUP})"
  echo "+===================================================================+"
  echo "|                                                                   |"
  echo "|   L1 DATA CACHE (L1-D)                                            |"
  printf "|    Total loads           : %-37s |\n" "$(fmt_M "${L1D_LOADS}") ($(fmt_num "${L1D_LOADS}"))"
  printf "|    Misses                : %-37s |\n" "$(fmt_M "${L1D_MISS}") ($(fmt_num "${L1D_MISS}"))"
  printf "|    Miss rate             : %-37s |\n" "${L1D_MISS_STR}"
  printf "|    Hit rate              : %-37s |\n" "${L1D_HIT_RATE}"
  echo "|                                                                   |"
  echo "|   L1 INSTRUCTION CACHE (L1-I)                                     |"
  printf "|    Total loads           : %-37s |\n" "$(fmt_M "${L1I_LOADS}") ($(fmt_num "${L1I_LOADS}"))"
  printf "|    Misses                : %-37s |\n" "$(fmt_M "${L1I_MISS}") ($(fmt_num "${L1I_MISS}"))"
  printf "|    Miss rate             : %-37s |\n" "${L1I_MISS_RATE}"
  printf "|    Hit rate              : %-37s |\n" "${L1I_HIT_RATE}"
  echo "|                                                                   |"
  echo "|   LAST LEVEL CACHE (LLC / L3)                                     |"
  printf "|    Total references      : %-37s |\n" "$(fmt_M "${LLC_REFS}") ($(fmt_num "${LLC_REFS}"))"
  printf "|    Misses (RAM accesses) : %-37s |\n" "$(fmt_M "${LLC_MISS}") ($(fmt_num "${LLC_MISS}"))"
  printf "|    Miss rate             : %-37s |\n" "${LLC_MISS_STR}"
  printf "|    Hit rate              : %-37s |\n" "${LLC_HIT_RATE}"
  printf "|    LLC MPKI (misses/KI)  : %-37s |\n" "${LLC_MPKI}"
  echo "|                                                                   |"
  echo "|   dTLB (Data Translation Lookaside Buffer)                        |"
  printf "|    Total loads           : %-37s |\n" "$(fmt_M "${DTLB_LOADS}") ($(fmt_num "${DTLB_LOADS}"))"
  printf "|    Misses                : %-37s |\n" "$(fmt_M "${DTLB_MISS}") ($(fmt_num "${DTLB_MISS}"))"
  printf "|    Miss rate             : %-37s |\n" "${DTLB_MISS_STR}"
  echo "|                                                                   |"
  echo "|   iTLB (Instruction TLB)                                          |"
  printf "|    Total loads           : %-37s |\n" "$(fmt_M "${ITLB_LOADS}") ($(fmt_num "${ITLB_LOADS}"))"
  printf "|    Misses                : %-37s |\n" "$(fmt_M "${ITLB_MISS}") ($(fmt_num "${ITLB_MISS}"))"
  printf "|    Miss rate             : %-37s |\n" "${ITLB_MISS_STR}"
  echo "|                                                                   |"
  echo "|   PAGE FAULTS                                                     |"
  printf "|    Total page faults     : %-37s |\n" "$(fmt_num "${PAGE_FAULTS}")"
  printf "|    Major (disk I/O)      : %-37s |\n" "$(fmt_num "${MAJOR_FAULTS}")"
  printf "|    Minor (CoW / alloc)   : %-37s |\n" "$(fmt_num "${MINOR_FAULTS}")"
  echo "|                                                                   |"
  echo "+===================================================================+"
  echo "|  RAW perf stat output -> memory_metrics_raw.txt                   |"
  echo "+===================================================================+"
} | tee "${OUTPUT_FILE}"

# Save raw output (totals)
cp "${PERF_STAT_TOTAL}" "${OUT_DIR}/memory_metrics_raw.txt"


# Save optional CSV
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
  echo ""
  ok "CSV summary saved: ${CSV_FILE}"
fi

echo ""
ok "Report summary: ${OUTPUT_FILE}"
ok "Raw totals:     ${OUT_DIR}/memory_metrics_raw.txt"
