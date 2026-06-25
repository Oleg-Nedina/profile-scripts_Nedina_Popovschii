#!/usr/bin/env bash
# =============================================================================
# base_converter.sh — Generic Linux perf to Perfetto Trace Converter
#
# This script automates capturing a CPU execution trace and converting it:
#   1. Runs the specified executable under 'perf record' to capture CPU events.
#   2. Converts the resulting raw 'perf.data' trace into a Perfetto JSON timeline.
#
# Usage:
#   ./cpu/perf_stat/base_converter.sh --exe <path_to_executable> [options]
#
# Options:
#   --exe PATH          Path to the executable to profile (REQUIRED)
#   --args "ARGS"       Arguments to pass to the executable (quoted)
#   --out-dir DIR       Directory to save output files (default: cpu/traces/base_converter/)
#   --convert-only      Skip profiling, only convert existing perf.data in out-dir
#   -h, --help          Show this help message
#
# Output:
#   <out-dir>/perf.data          Raw hardware sampling data
#   <out-dir>/trace_perf.json    Perfetto JSON trace timeline
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Define default output trace directory
OUT_DIR="${SCRIPT_DIR}/traces/base_converter"
CONVERT_ONLY=0
EXE=""
EXE_ARGS=""
# Find perf binary portably, searching for local kernel tools if wrappers are broken
PERF_BIN=""
for candidate in \
  "/usr/lib/linux-tools/$(uname -r)/perf" \
  $(ls /usr/lib/linux-tools/*/perf 2>/dev/null | sort -V | tail -1) \
  "perf"; do
  if [[ -x "${candidate}" ]]; then
    # Verify the candidate is actually functional (e.g. not a broken Ubuntu wrapper)
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
  --out-dir)
    OUT_DIR="$2"
    shift
    ;;
  --convert-only)
    CONVERT_ONLY=1
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

# Logger functions
step() { echo -e "\n== $* =="; }
ok() { echo "  [OK]  $*"; }
warn() { echo "  [WARN]  $*"; }
die() {
  echo "  [FAIL]  $*" >&2
  exit 1
}

# Define default log directory
LOG_DIR="${SCRIPT_DIR}/logs"

# Output files paths
PERF_DATA="${OUT_DIR}/perf.data"
TRACE_OUT="${OUT_DIR}/trace_perf.json"
LOG_FILE="${LOG_DIR}/base_converter.log"

echo ""
echo "  +----------------------------------------------------─+"
echo "  |            Generic Base Converter Pipeline          |"
echo "  |          perf record → JSON (Perfetto UI)           |"
echo "  +----------------------------------------------------─+"

# Ensure output and log directories exist
mkdir -p "${OUT_DIR}"
mkdir -p "${LOG_DIR}"

# Prevent user event / PAPI tracers from polluting the workspace, redirect to logs and clean up on exit
IGNORED_TRACE="${LOG_DIR}/trace_user_events_ignored.json"
IGNORED_PAPI="${LOG_DIR}/kpi_hotspots_ignored.json"
export ACA_TRACE_USER_OUT="${IGNORED_TRACE}"
export ACA_PAPI_REPORT_OUT="${IGNORED_PAPI}"
trap 'rm -f "${IGNORED_TRACE}" "${IGNORED_PAPI}"' EXIT

# Step 1: Run perf record
if [[ "${CONVERT_ONLY}" -eq 0 ]]; then
  # Validation
  [[ -n "${EXE}" ]] || die "Executable path is required. Use --exe <path>."
  [[ -x "${EXE}" ]] || die "Binary not found or not executable: ${EXE}"

  step "STEP 1/2 — Profiling with perf record"
  echo "  Target: ${EXE}"
  [[ -n "${EXE_ARGS}" ]] && echo "  Args:   ${EXE_ARGS}"

  # Unblock hardware counters if needed
  PARANOIA=$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo "4")
  if [[ "${PARANOIA}" -gt 0 ]]; then
    warn "perf_event_paranoid=${PARANOIA} -> Attempting temporary unlock..."
    sudo sysctl -w kernel.perf_event_paranoid=-1 ||
      warn "Unlock failed - recording might be incomplete or fail if running as non-root."
  fi

  echo ""
  echo "  Profiling target application in background..."
  echo "  (Console output and warnings redirected to: ${LOG_FILE})"
  
  # Run perf record (using eval to correctly expand quoted arguments)
  # We use temporary array to split arguments safely
  read -r -a ARGS_ARR <<< "${EXE_ARGS}"
  
  if ! "${PERF_BIN}" record \
    -g \
    --call-graph dwarf \
    -o "${PERF_DATA}" \
    -- "${EXE}" "${ARGS_ARR[@]}" \
    2>&1 | grep -v -E "(_ligand|ligand)" > "${LOG_FILE}"; then
    
    echo ""
    die "perf record failed! Check logs in: cpu/perf_stat/logs/base_converter.log"
  fi

  echo ""
  ok "Recording completed: ${PERF_DATA} ($(du -h "${PERF_DATA}" | cut -f1))"
else
  step "STEP 1/2 — Skipped profiling (convert-only mode)"
  [[ -f "${PERF_DATA}" ]] || die "Existing ${PERF_DATA} not found. Remove --convert-only."
  ok "Using existing perf.data: $(du -h "${PERF_DATA}" | cut -f1)"
fi

# Step 2: Convert trace to Perfetto JSON
step "STEP 2/2 — Converting to Perfetto JSON"

if ! command -v python3 &>/dev/null; then
  die "python3 is not available. Cannot convert trace to Perfetto JSON."
fi

python3 "${SCRIPT_DIR}/utils/perf_to_perfetto.py" "${PERF_DATA}" "${TRACE_OUT}"

# Final Summary
echo ""
echo "  +=======================================================+"
echo "  |              Pipeline completed successfully!         |"
echo "  +=======================================================+"
printf "  |  Trace JSON: %-40s |\n" "$(realpath --relative-to="$(pwd)" "${TRACE_OUT}")"
printf "  |  Raw Data:   %-40s |\n" "$(realpath --relative-to="$(pwd)" "${PERF_DATA}")"
echo "  |  Open in:    https://ui.perfetto.dev/                 |"
echo "  +=======================================================+"
echo ""
