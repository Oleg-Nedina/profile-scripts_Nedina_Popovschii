#!/usr/bin/env bash
# =============================================================================
# run_papi.sh — PAPI Kernel Hotspot Profiler Orchestrator
#
# Usage:
#   ./scripts/run_papi.sh --exe <binary> [options]
#
# Required Options:
#   --exe PATH              Path to the binary to profile
#
# Optional Options:
#   --args "ARGS"           Arguments to pass to the binary (quoted)
#   --out-dir DIR           Output directory (default: ./traces/papi)
#   --events "E1,E2,..."    Comma-separated list of custom PAPI hardware events
#                           (default: full preset)
#   --preset PRESET         Select a predefined event preset (overrides --events):
#                             ipc    -> PAPI_TOT_CYC,PAPI_TOT_INS
#                             cache  -> PAPI_TOT_CYC,PAPI_TOT_INS,PAPI_L1_DCM,PAPI_L2_DCM,PAPI_L2_TCM,PAPI_TLB_DM
#                             branch -> PAPI_TOT_CYC,PAPI_TOT_INS,PAPI_BR_MSP,PAPI_BR_PRC,PAPI_BR_INS,PAPI_BR_CN
#                             simd   -> PAPI_TOT_CYC,PAPI_TOT_INS,PAPI_VEC_INS,PAPI_FP_OPS,PAPI_FMA_INS,PAPI_FP_INS
#                             full   -> PAPI_TOT_CYC,PAPI_TOT_INS,PAPI_L1_DCM,PAPI_L2_DCM,PAPI_BR_MSP,PAPI_BR_PRC
#   --knl-N NAME            Assign name NAME to instrumented kernel N (N from 1 to 10)
#                           Example: --knl-1 "CalcEnergy" --knl-2 "GA_Search"
#   --no-paranoid-check     Disable warning checks for perf_event_paranoid
#
# Prerequisites:
#   sudo sysctl -w kernel.perf_event_paranoid=-1
# =============================================================================
set -euo pipefail

ok() { echo "[OK]   $*"; }
warn() { echo "[WARN] $*"; }
err() { echo "[ERR]  $*"; }
info() { echo "[INFO] $*"; }


# ============================================================================
# Predefined Event Presets
# ============================================================================
PRESET_IPC="PAPI_TOT_CYC,PAPI_TOT_INS"
PRESET_FULL="PAPI_TOT_CYC,PAPI_TOT_INS,PAPI_L1_DCM,PAPI_L2_DCM,PAPI_BR_MSP,PAPI_BR_PRC"
PRESET_CACHE="PAPI_TOT_CYC,PAPI_TOT_INS,PAPI_L1_DCM,PAPI_L2_DCM,PAPI_L2_TCM,PAPI_TLB_DM"
PRESET_BRANCH="PAPI_TOT_CYC,PAPI_TOT_INS,PAPI_BR_MSP,PAPI_BR_PRC,PAPI_BR_INS,PAPI_BR_CN"
PRESET_SIMD="PAPI_TOT_CYC,PAPI_TOT_INS,PAPI_VEC_INS,PAPI_FP_OPS,PAPI_FMA_INS,PAPI_FP_INS"

# ============================================================================
# Default Values
# ============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXE=""
ARGS=""
OUT_DIR="${SCRIPT_DIR}/../traces/papi"
LOG_DIR="${SCRIPT_DIR}/../logs"
LOG_FILE="${LOG_DIR}/run_papi.log"
PAPI_EVENTS="${ACA_PAPI_EVENTS:-$PRESET_FULL}"
KNL_NAMES=()
PRESET=""
SKIP_PARANOID_CHECK=0

# ============================================================================
# Help functions
# ============================================================================
usage() {
  sed -n '2,28p' "$0" | sed 's/^# \?//'
  exit 0
}

# ============================================================================
# Argument Parsing
# ============================================================================
while [[ $# -gt 0 ]]; do
  case $1 in
  --exe)
    EXE="$2"
    shift 2
    ;;
  --args)
    ARGS="$2"
    shift 2
    ;;
  --out-dir)
    OUT_DIR="$2"
    shift 2
    ;;
  --events)
    PAPI_EVENTS="$2"
    shift 2
    ;;
  --no-paranoid-check)
    SKIP_PARANOID_CHECK=1
    shift
    ;;
  --help | -h) usage ;;
  --preset)
    PRESET="$2"
    case "$2" in
    ipc) PAPI_EVENTS="$PRESET_IPC" ;;
    cache) PAPI_EVENTS="$PRESET_CACHE" ;;
    branch) PAPI_EVENTS="$PRESET_BRANCH" ;;
    simd) PAPI_EVENTS="$PRESET_SIMD" ;;
    full) PAPI_EVENTS="$PRESET_FULL" ;;
    *)
      err "Unknown preset: '$2'"
      err "Valid presets: ipc, cache, branch, simd, full"
      exit 1
      ;;
    esac
    shift 2
    ;;
  --knl-*)
    idx="${1#--knl-}"
    if ! [[ "$idx" =~ ^([1-9]|10)$ ]]; then
      err "Invalid kernel index: $idx (must be 1..10)"
      exit 1
    fi
    KNL_NAMES[$idx]="$2"
    shift 2
    ;;
  *)
    err "Unknown option: $1"
    usage
    ;;
  esac
done

# ============================================================================
# Validation
# ============================================================================
if [[ -z "$EXE" ]]; then
  err "Executable path is required. Use --exe."
  usage
fi
if [[ ! -x "$EXE" ]]; then
  err "Binary not found or not executable: $EXE"
  exit 1
fi

# Paranoid Check
if [[ $SKIP_PARANOID_CHECK -eq 0 ]]; then
  PARANOID=$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo "N/A")
  if [[ "$PARANOID" != "-1" ]]; then
    warn "kernel.perf_event_paranoid=$PARANOID — hardware PMU counters may fail."
    warn "Unlock CPU PMUs using: sudo sysctl -w kernel.perf_event_paranoid=-1"
    warn "Or ensure PAPI is loaded and CPU PMUs are unlocked."
    warn "Proceeding execution... (use --no-paranoid-check to silence)"
  fi
fi

# Resolve paths to absolute format portably
# Create directories first to ensure they exist before resolving absolute paths
mkdir -p "$OUT_DIR"
mkdir -p "$LOG_DIR"

OUT_DIR="$(readlink -f "${OUT_DIR}")"
LOG_DIR="$(readlink -f "${LOG_DIR}")"
LOG_FILE="${LOG_DIR}/run_papi.log"
> "$LOG_FILE"

# Prevent user event tracer from polluting the workspace, redirect to logs and clean up on exit
IGNORED_TRACE="${LOG_DIR}/trace_user_events_ignored.json"
export ACA_TRACE_USER_OUT="${IGNORED_TRACE}"
trap 'rm -f "${IGNORED_TRACE}"' EXIT

# ============================================================================
# Export Environment Variables
# ============================================================================
export ACA_PAPI_EVENTS="$PAPI_EVENTS"
export ACA_PAPI_REPORT_OUT="${OUT_DIR}/kpi_hotspots.json"

for i in $(seq 1 10); do
  if [[ -n "${KNL_NAMES[$i]-}" ]]; then
    export "ACA_PAPI_KNL_${i}_NAME=${KNL_NAMES[$i]}"
  fi
done

# ============================================================================
# Banner
# ============================================================================
echo ""
echo "  +--------------------------------------------------------+"
echo "  |            PAPI — Kernel Hotspot Profiler              |"
echo "  |     Hardware Counter Measurements for C++ Hotspots     |"
echo "  +--------------------------------------------------------+"
echo ""
info "Binary       : $EXE"
info "Arguments    : ${ARGS:-<none>}"
info "Output dir   : $OUT_DIR"
info "Report JSON  : $ACA_PAPI_REPORT_OUT"
info "PAPI Events  : $PAPI_EVENTS"
info "Log file     : $LOG_FILE"
[[ -n "$PRESET" ]] && info "Preset       : $PRESET"
echo ""

# Print configured kernel names
HAS_KNL=0
for i in $(seq 1 10); do
  var="ACA_PAPI_KNL_${i}_NAME"
  val="${!var:-}"
  if [[ -n "$val" ]]; then
    [[ $HAS_KNL -eq 0 ]] && info "Configured Kernels:"
    echo "    [$i] $val"
    HAS_KNL=1
  fi
done
echo "  +--------------------------------------------------------+"
echo ""

# ============================================================================
# Execution
# ============================================================================
echo -e "\n== STEP 1/2 — Execution and PAPI Counter Sampling =="
START_NS=$(date +%s%N)

# Execute target program with filtered logs to keep output clean and compact
read -r -a ARGS_ARR <<< "${ARGS}"
set +e
"${EXE}" "${ARGS_ARR[@]}" 2>&1 | grep -v -E "(_ligand|ligand)" >> "${LOG_FILE}"
EXIT_CODE=$?
set -e

END_NS=$(date +%s%N)
ELAPSED_MS=$(((END_NS - START_NS) / 1000000))

# ============================================================================
# Report Formatting
# ============================================================================
echo -e "\n== STEP 2/2 — Metric Parsing and Report Generation =="
if [[ $EXIT_CODE -eq 0 ]]; then
  ok "Execution completed in ${ELAPSED_MS} ms."
  echo ""
  JSON_REPORT="${OUT_DIR}/kpi_hotspots.json"
  TXT_REPORT="${OUT_DIR}/kpi_hotspots.txt"
  if [[ -f "$JSON_REPORT" ]]; then
    # Run python script formatter
    python3 "${SCRIPT_DIR}/format_papi_report.py" \
      --json "$JSON_REPORT" \
      --preset "${PRESET:-custom}" \
      --templates-dir "${SCRIPT_DIR}/../preset_template" \
      --out "$TXT_REPORT"

    ok "PAPI Report generated: $TXT_REPORT"
    echo ""
    echo "  Report Preview (First 35 lines):"
    echo "  ────────────────────────────────────────"
    head -n 35 "$TXT_REPORT" | sed 's/^/  /'
    echo "  ────────────────────────────────────────"
    echo ""
    info "To view the full report, run:  cat $TXT_REPORT"
  else
    warn "JSON report was not generated. Please check:"
    warn "  1. Binary is compiled with -DACA_ENABLE_PAPI -lpapi"
    warn "  2. ACA_PAPI_KNL_START/STOP macros are correctly placed in code"
    warn "  3. kernel.perf_event_paranoid is unlocked (= -1)"
  fi
else
  err "Target process failed with exit code: $EXIT_CODE."
  err "Check the log file: $LOG_FILE"
fi
echo "  +--------------------------------------------------------+"
echo ""

exit $EXIT_CODE
