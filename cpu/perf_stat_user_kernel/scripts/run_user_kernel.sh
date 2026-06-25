#!/usr/bin/env bash
# =============================================================================
# run_user_kernel.sh — Orchestration Script for User Events Tracing
#
# Usage:
#   ./scripts/run_user_kernel.sh --exe <binary> [options]
#
# Required Options:
#   --exe PATH              Path to the binary to profile
#
# Optional Options:
#   --args "ARGS"           Arguments to pass to the binary (quoted)
#   --out-dir DIR           Output directory (default: ./traces/user_events)
#   --event-N NAME          Assign name NAME to event N (N from 1 to 10)
#                           Example: --event-1 "ParsingPhase" --event-2 "GA_Kernel"
# =============================================================================
set -euo pipefail

# ---- Colors -----------------------------------------------------------------
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'
ok() { echo -e "${GREEN}[OK]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err() { echo -e "${RED}[ERR]${NC}  $*"; }
info() { echo -e "$*"; }

# ---- Default Values ---------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXE=""
ARGS=""
OUT_DIR="${SCRIPT_DIR}/../traces/user_events"
LOG_DIR="${SCRIPT_DIR}/../logs"
LOG_FILE="${LOG_DIR}/run_user_kernel.log"
EVENT_NAMES=() # Sparse array: EVENT_NAMES[1]..EVENT_NAMES[10]

# ---- Argument Parsing -------------------------------------------------------
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
  --help | -h)
    sed -n '2,16p' "$0" | sed 's/^# \?//'
    exit 0
    ;;
  --event-*)
    idx="${1#--event-}"
    if ! [[ "$idx" =~ ^[1-9]$|^10$ ]]; then
      err "Invalid event index: $idx (deve essere 1..10)"
      exit 1
    fi
    EVENT_NAMES[$idx]="$2"
    shift 2
    ;;
  *)
    err "Unknown option: $1"
    sed -n '2,16p' "$0" | sed 's/^# \?//'
    exit 1
    ;;
  esac
done

# ---- Validation -------------------------------------------------------------
if [[ -z "$EXE" ]]; then
  err "Executable path is required. Use --exe."
  sed -n '2,16p' "$0" | sed 's/^# \?//'
  exit 1
fi
if [[ ! -x "$EXE" ]]; then
  err "Binary not found or not executable: $EXE"
  exit 1
fi

# Resolve paths to absolute format portably
OUT_DIR="$(readlink -f "${OUT_DIR}")"
LOG_DIR="$(readlink -f "${LOG_DIR}")"
LOG_FILE="${LOG_DIR}/run_user_kernel.log"

mkdir -p "$OUT_DIR"
mkdir -p "$LOG_DIR"
> "$LOG_FILE"

# ---- Export Event Names into Environment -------------------------------------
for i in $(seq 1 10); do
  if [[ -n "${EVENT_NAMES[$i]+set}" ]]; then
    export "ACA_USER_EVENT_${i}_NAME=${EVENT_NAMES[$i]}"
  fi
done

# ---- Output Paths for Double Instrumentation Cleanliness --------------------
export ACA_TRACE_USER_OUT="${OUT_DIR}/trace_user_events.json"
export ACA_PAPI_REPORT_OUT="${OUT_DIR}/kpi_hotspots.json"

# ---- Banner -----------------------------------------------------------------
echo ""
echo "  +--------------------------------------------------------+"
echo "  |          User Events — Perfetto Timeline Profiler      |"
echo "  |     Visualizing OpenMP/TBB Pipeline & Concurrency      |"
echo "  +--------------------------------------------------------+"
echo ""
info "Binary       : $EXE"
info "Arguments    : ${ARGS:-<none>}"
info "Output dir   : $OUT_DIR"
info "Trace JSON   : $ACA_TRACE_USER_OUT"
info "Log file     : $LOG_FILE"
echo ""
info "Configured Event Names:"
for i in $(seq 1 10); do
  var="ACA_USER_EVENT_${i}_NAME"
  val="${!var:-}"
  if [[ -n "$val" ]]; then
    echo "    Event $i → $val"
  fi
done
echo "  +--------------------------------------------------------+"
echo ""

# ---- Execution -------------------------------------------------------------
echo -e "\n== STEP 1/2 — Execution and Tracing =="
START_TS=$(date +%s%N)

# Run target executable with filtered logs to keep output clean and compact
read -r -a ARGS_ARR <<< "${ARGS}"
set +e
"${EXE}" "${ARGS_ARR[@]}" 2>&1 | grep -v -E "(_ligand|ligand)" >> "${LOG_FILE}"
EXIT_CODE=$?
set -e

END_TS=$(date +%s%N)
ELAPSED_MS=$(((END_TS - START_TS) / 1000000))

# ---- Final Report -----------------------------------------------------------
echo -e "\n== STEP 2/2 — Analysis and Report =="
if [[ $EXIT_CODE -eq 0 ]]; then
  ok "Execution completed in ${ELAPSED_MS} ms."
  echo ""
  echo "  Generated Output:"
  if [[ -f "$ACA_TRACE_USER_OUT" ]]; then
    SIZE=$(du -sh "$ACA_TRACE_USER_OUT" | cut -f1)
    ok "  Perfetto Trace : $ACA_TRACE_USER_OUT  (${SIZE})"
    echo ""
    echo "  Visualization Guide:"
    echo "    1. Open https://ui.perfetto.dev/ in a browser"
    echo "    2. Drag and drop the $ACA_TRACE_USER_OUT file"
    echo "    3. Expand the process to view:"
    echo "       - Color-coded slices for User Events per thread"
    echo "       - The 'user_events_active' counter (instantaneous concurrency)"
    echo "       - The 'UserUtilization' counter displaying active CPU percentage"
  else
    warn "The trace file was not generated."
    warn "Check if the binary is compiled with -DACA_ENABLE_USER_EVENTS"
    warn "and that the ACA_USER_EVENT_START/STOP macros are present in the source."
  fi
else
  err "The process terminated with errors (exit code: $EXIT_CODE)."
  err "Check the log file: $LOG_FILE"
fi
echo "  +--------------------------------------------------------+"
echo ""

exit $EXIT_CODE
