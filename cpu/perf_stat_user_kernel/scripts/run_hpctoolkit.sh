#!/usr/bin/env bash
# =============================================================================
# run_hpctoolkit.sh — Run HPCToolkit Statistical Sampling Profiler
#
# Usage:
#   ./scripts/run_hpctoolkit.sh --exe <binary> [options]
#
# Required Options:
#   --exe PATH              Path to the binary to profile
#
# Optional Options:
#   --args "ARGS"           Arguments to pass to the binary (quoted)
#   --out-dir DIR           Output directory (default: ./traces/hpctoolkit)
#   --src-dir DIR           Source directory of muDock (default: ../../muDock)
#   --events "E1,E2,..."    Comma-separated list of custom hardware events
#                           (default: "cycles,PAPI_L2_DCM")
#   --preset PRESET         Select a predefined event preset (overrides --events):
#                             ipc    -> cycles,PAPI_TOT_INS
#                             cache  -> cycles,PAPI_L1_DCM,PAPI_L2_DCM,PAPI_TLB_DM
#                             branch -> cycles,PAPI_BR_MSP,PAPI_BR_INS
#                             simd   -> cycles,PAPI_VEC_INS,PAPI_FP_OPS
#                             full   -> cycles,PAPI_TOT_INS,PAPI_L1_DCM,PAPI_L2_DCM,PAPI_BR_MSP
# =============================================================================
set -euo pipefail

# ---- Colors -----------------------------------------------------------------
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC}   $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERR]${NC}  $*"; }
info() { echo -e "${CYAN}[INFO]${NC} $*"; }

# ---- Presets ----------------------------------------------------------------
PRESET_IPC="cycles,PAPI_TOT_INS"
PRESET_CACHE="cycles,PAPI_L1_DCM,PAPI_L2_DCM,PAPI_TLB_DM"
PRESET_BRANCH="cycles,PAPI_BR_MSP,PAPI_BR_INS"
PRESET_SIMD="cycles,PAPI_VEC_INS,PAPI_FP_OPS"
PRESET_FULL="cycles,PAPI_TOT_INS,PAPI_L1_DCM,PAPI_L2_DCM,PAPI_BR_MSP"

# ---- Default Values ---------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXE=""
ARGS=""
OUT_DIR="${SCRIPT_DIR}/../traces/hpctoolkit"
LOG_DIR="${SCRIPT_DIR}/../logs"
LOG_FILE="${LOG_DIR}/run_hpctoolkit.log"
EVENTS=("cycles" "PAPI_L2_DCM")
SRC_DIR="${SCRIPT_DIR}/../../../../muDock"

# ---- Argument Parsing -------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case $1 in
        --exe)        EXE="$2";              shift 2 ;;
        --args)       ARGS="$2";             shift 2 ;;
        --out-dir)    OUT_DIR="$2";          shift 2 ;;
        --src-dir)    SRC_DIR="$2";          shift 2 ;;
        --events)
            IFS=',' read -r -a EVENTS <<< "$2"
            shift 2
            ;;
        --preset)
            case "$2" in
                ipc)    PRESET_EVENTS="$PRESET_IPC" ;;
                cache)  PRESET_EVENTS="$PRESET_CACHE" ;;
                branch) PRESET_EVENTS="$PRESET_BRANCH" ;;
                simd)   PRESET_EVENTS="$PRESET_SIMD" ;;
                full)   PRESET_EVENTS="$PRESET_FULL" ;;
                *)      err "Unknown preset: $2" ; exit 1 ;;
            esac
            IFS=',' read -r -a EVENTS <<< "$PRESET_EVENTS"
            shift 2
            ;;
        --help|-h)
            sed -n '2,23p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *)
            err "Unknown option: $1"
            sed -n '2,23p' "$0" | sed 's/^# \?//'
            exit 1
            ;;
    esac
done

# ---- Validation -------------------------------------------------------------
if [[ -z "$EXE" ]]; then
    err "Executable path is required. Use --exe."
    exit 1
fi
if [[ ! -x "$EXE" ]]; then
    err "Binary not found or not executable: $EXE"
    exit 1
fi

# ---- Load Spack Environment -------------------------------------------------
if ! command -v hpcrun &>/dev/null; then
    info "HPCToolkit not detected in PATH. Attempting to load Spack..."
    SPACK_SETUP="${SPACK_ROOT:-$HOME/spack}/share/spack/setup-env.sh"
    if [[ -f "$SPACK_SETUP" ]]; then
        # shellcheck disable=SC1090
        source "$SPACK_SETUP"
        spack env activate mudock_zen5 2>/dev/null || warn "Failed to activate Spack environment 'mudock_zen5'."
        spack load hpctoolkit 2>/dev/null || warn "Failed to load 'hpctoolkit' via Spack."
    fi
fi

# Verify required tools are available
for tool in hpcrun hpcstruct hpcprof; do
    if ! command -v "$tool" &>/dev/null; then
        err "Required HPCToolkit tool not found: $tool"
        err "Ensure HPCToolkit is installed and loaded in your PATH."
        exit 1
    fi
done

# Resolve absolute paths
EXE_ABS=$(readlink -f "$EXE")
SRC_DIR_ABS=$(readlink -f "$SRC_DIR")
mkdir -p "$OUT_DIR"
mkdir -p "$LOG_DIR"
> "$LOG_FILE"
OUT_DIR_ABS=$(readlink -f "$OUT_DIR")

# HPCToolkit output directories
MEASUREMENTS_DIR="${OUT_DIR_ABS}/measurements"
DATABASE_DIR="${OUT_DIR_ABS}/database"

# Clean up previous runs
rm -rf "$MEASUREMENTS_DIR" "$DATABASE_DIR"

# ---- Export output paths to keep root directory clean -----------------------
export ACA_TRACE_USER_OUT="${OUT_DIR_ABS}/trace_user_events.json"
export ACA_PAPI_REPORT_OUT="${OUT_DIR_ABS}/kpi_hotspots.json"

# ---- Build hpcrun arguments -------------------------------------------------
HPCRUN_ARGS=()
for event in "${EVENTS[@]}"; do
    HPCRUN_ARGS+=("-e" "$event")
done

# ---- Banner -----------------------------------------------------------------
echo ""
echo "  +--------------------------------------------------------+"
echo "  |              HPCToolkit — Profiling Suite              |"
echo "  |         Sampling-based Performance Measurement         |"
echo "  +--------------------------------------------------------+"
echo ""
info "Binary       : $EXE_ABS"
info "Arguments    : ${ARGS:-<none>}"
info "Output Dir   : $OUT_DIR_ABS"
info "PAPI Events  : ${EVENTS[*]}"
info "Log File     : $LOG_FILE"
echo ""

# ---- 1. Measurement Execution (hpcrun) -------------------------------------
echo -e "\n== STEP 1/3 — Sampling and Execution (hpcrun) =="
read -r -a ARGS_ARR <<< "$ARGS"
set +e
hpcrun "${HPCRUN_ARGS[@]}" -t -o "$MEASUREMENTS_DIR" "$EXE_ABS" "${ARGS_ARR[@]}" 2>&1 | grep -v -E "(_ligand|ligand)" >> "$LOG_FILE"
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -eq 0 && -d "$MEASUREMENTS_DIR" ]]; then
    ok "Measurements successfully completed in: $MEASUREMENTS_DIR"
else
    err "HPCToolkit sampling failed. Check logs in: $LOG_FILE"
    exit 1
fi

# ---- 2. Structural Analysis (hpcstruct) ---------------------------------------
echo -e "\n== STEP 2/3 — Structural Analysis (hpcstruct) =="
hpcstruct "$MEASUREMENTS_DIR"
ok "Binary control structure analyzed and linked to measurements."

# ---- 3. Performance Database Generation (hpcprof) -------------------------
echo -e "\n== STEP 3/3 — Database Generation (hpcprof) =="
hpcprof -o "$DATABASE_DIR" "$MEASUREMENTS_DIR"

# ---- Final Summary ----------------------------------------------------------
echo -e "\n== CONCLUSION — Profiling Completed =="
ok "HPCToolkit profiling finished successfully!"
echo ""
info "Database generated at:"
ok "  $DATABASE_DIR"
echo ""
info "To visualize the call tree and trace timeline, run:"
ok "  hpcviewer $DATABASE_DIR"
echo "  +--------------------------------------------------------+"
echo ""

exit 0
