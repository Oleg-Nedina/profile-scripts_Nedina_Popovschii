#!/bin/bash
# =============================================================================
# run_papi.sh — Orchestratore PAPI Kernel Hotspot Profiling
#
# Utilizzo:
#   ./scripts/run_papi.sh --exe <binario> [opzioni]
#
# Opzioni obbligatorie:
#   --exe PATH              Percorso del binario da profilare
#
# Opzioni facoltative:
#   --args "ARGS"           Argomenti da passare al binario (tra virgolette)
#   --out-dir DIR           Directory di output (default: ./traces/papi)
#   --events "E1,E2,..."    Lista personalizzata di eventi PAPI separati da virgola
#                           (default: set completo --preset full)
#   --preset PRESET         Seleziona un preset di eventi (sovrascrive --events):
#                             ipc    -> PAPI_TOT_CYC,PAPI_TOT_INS
#                             cache  -> PAPI_TOT_CYC,PAPI_TOT_INS,PAPI_L1_DCM,PAPI_L2_DCM,PAPI_L2_TCM,PAPI_TLB_DM
#                             branch -> PAPI_TOT_CYC,PAPI_TOT_INS,PAPI_BR_MSP,PAPI_BR_PRC,PAPI_BR_INS,PAPI_BR_CN
#                             simd   -> PAPI_TOT_CYC,PAPI_TOT_INS,PAPI_VEC_INS,PAPI_FP_OPS,PAPI_FMA_INS,PAPI_FP_INS
#                             full   -> PAPI_TOT_CYC,PAPI_TOT_INS,PAPI_L1_DCM,PAPI_L2_DCM,PAPI_BR_MSP,PAPI_BR_PRC
#   --knl-N NAME            Associa il nome NAME al kernel strumentato N (N da 1 a 10)
#                           Esempio: --knl-1 "CalcEnergia" --knl-2 "GA_Search"
#   --list-events           Mostra tutti gli eventi hardware supportati su Zen 5
#   --no-paranoid-check     Disabilita il controllo sul valore di perf_event_paranoid
#
# Prerequisiti:
#   sudo sysctl -w kernel.perf_event_paranoid=-1
#   source ./scripts/setup_papi.sh
#
# Esempio:
#   ./perf_stat_user_kernel/scripts/run_papi.sh \
#      --exe "$(realpath ../muDock/build/application/muDock)" \
#      --args "--protein $(realpath ../muDock/data/1fkb/1fkb_protein.pdb) --ligand $(realpath ../muDock/data/1fkb/ligands100_12col.adtmol2) --use CPP:CPU:0-3" \
#      --preset cache \
#      --knl-1 "Evaluate" --knl-2 "Generation"
# =============================================================================
set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'
ok() { echo -e "${GREEN}[OK]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err() { echo -e "${RED}[ERR]${NC}  $*"; }
info() { echo -e "${CYAN}[INFO]${NC} $*"; }

# ============================================================================
# Tabella degli eventi disponibili su AMD Zen 5 (da papi_avail --paranoid=-1)
# Usata per il menu interattivo --list-events
# ============================================================================
ZEN5_EVENTS=(
  "PAPI_TOT_CYC:Total cycles (base, sempre presente)"
  "PAPI_TOT_INS:Instructions completed (base, sempre presente)"
  "PAPI_L1_DCM:L1 data cache misses  → L1 MPKI"
  "PAPI_L2_DCM:L2 data cache misses  → L2 MPKI (proxy memory-bound)"
  "PAPI_L2_TCM:L2 total cache misses (derivato)"
  "PAPI_BR_MSP:Branch mispredictions → Branch Miss Rate"
  "PAPI_BR_PRC:Branch correct pred.  (derivato)"
  "PAPI_BR_INS:Total branch instructions"
  "PAPI_BR_CN:Conditional branches"
  "PAPI_TLB_DM:Data TLB misses       → TLB MPKI"
  "PAPI_VEC_INS:Vector/SIMD instructions → Vectorization Rate"
  "PAPI_FP_OPS:Floating point operations"
  "PAPI_FP_INS:FP instructions (derivato)"
  "PAPI_FMA_INS:FMA instructions (derivato)"
  "PAPI_L1_DCA:L1 data cache accesses"
  "PAPI_L2_DCH:L2 data cache hits"
  "PAPI_L2_DCR:L2 data cache reads"
)

# ============================================================================
# Preset raggruppati per tipo di analisi
# ============================================================================
PRESET_IPC="PAPI_TOT_CYC,PAPI_TOT_INS"
PRESET_FULL="PAPI_TOT_CYC,PAPI_TOT_INS,PAPI_L1_DCM,PAPI_L2_DCM,PAPI_BR_MSP,PAPI_BR_PRC"
PRESET_CACHE="PAPI_TOT_CYC,PAPI_TOT_INS,PAPI_L1_DCM,PAPI_L2_DCM,PAPI_L2_TCM,PAPI_TLB_DM"
PRESET_BRANCH="PAPI_TOT_CYC,PAPI_TOT_INS,PAPI_BR_MSP,PAPI_BR_PRC,PAPI_BR_INS,PAPI_BR_CN"
PRESET_SIMD="PAPI_TOT_CYC,PAPI_TOT_INS,PAPI_VEC_INS,PAPI_FP_OPS,PAPI_FMA_INS,PAPI_FP_INS"

# ============================================================================
# Valori di default
# ============================================================================
EXE=""
ARGS=""
OUT_DIR="./traces/papi"
PAPI_EVENTS="${ACA_PAPI_EVENTS:-$PRESET_FULL}"
KNL_NAMES=()
PRESET=""
SKIP_PARANOID_CHECK=0

# ============================================================================
# Help
# ============================================================================
usage() {
  sed -n '2,37p' "$0" | sed 's/^# \?//'
  exit 0
}

list_events() {
  echo ""
  echo "  Eventi PAPI disponibili su AMD Ryzen AI 7 PRO 350 (Zen 5)"
  echo "  (verificati con perf_event_paranoid=-1, PAPI 7.2.0)"
  echo ""
  printf "  %-20s %s\n" "EVENTO" "DESCRIZIONE"
  printf "  %-20s %s\n" "------" "-----------"
  for entry in "${ZEN5_EVENTS[@]}"; do
    name="${entry%%:*}"
    desc="${entry#*:}"
    printf "  ${GREEN}%-20s${NC} %s\n" "$name" "$desc"
  done
  echo ""
  echo "  ❌ NON disponibile: PAPI_L3_TCM (L3 miss non mappato su Zen 5)"
  echo ""
  echo "  Preset disponibili:"
  echo "    ipc    → $PRESET_IPC"
  echo "    cache  → $PRESET_CACHE"
  echo "    branch → $PRESET_BRANCH"
  echo "    simd   → $PRESET_SIMD"
  echo "    full   → $PRESET_FULL"
  echo ""
  exit 0
}

# ============================================================================
# Parsing argomenti
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
  --list-events) list_events ;;
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
      err "Preset sconosciuto: '$2'"
      err "Valori validi: ipc, cache, branch, simd, full"
      exit 1
      ;;
    esac
    shift 2
    ;;
  --knl-*)
    idx="${1#--knl-}"
    if ! [[ "$idx" =~ ^([1-9]|10)$ ]]; then
      err "Indice kernel non valido: $idx (1..10)"
      exit 1
    fi
    KNL_NAMES[$idx]="$2"
    shift 2
    ;;
  *)
    err "Opzione sconosciuta: $1"
    usage
    ;;
  esac
done

# ============================================================================
# Validazione
# ============================================================================
if [[ -z "$EXE" ]]; then
  err "Specificare --exe."
  usage
fi
if [[ ! -x "$EXE" ]]; then
  err "Binario non trovato/eseguibile: $EXE"
  exit 1
fi

# Controllo perf_event_paranoid
if [[ $SKIP_PARANOID_CHECK -eq 0 ]]; then
  PARANOID=$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo "N/A")
  if [[ "$PARANOID" != "-1" ]]; then
    warn "kernel.perf_event_paranoid=$PARANOID — i contatori PMU hardware potrebbero fallire."
    warn "Sblocca i PMU con: sudo sysctl -w kernel.perf_event_paranoid=-1"
    warn "Oppure usa: source ./scripts/setup_papi.sh"
    warn "Continuo comunque... (usa --no-paranoid-check per silenziare)"
  fi
fi

mkdir -p "$OUT_DIR"

# ============================================================================
# Esporta le variabili d'ambiente
# ============================================================================
export ACA_PAPI_EVENTS="$PAPI_EVENTS"
export ACA_PAPI_REPORT_OUT="${OUT_DIR}/kpi_hotspots.json"

for i in $(seq 1 10); do
  if [[ -n "${KNL_NAMES[$i]+set}" ]]; then
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
info "Binario    : $EXE"
info "Argomenti  : ${ARGS:-<nessuno>}"
info "Output dir : $OUT_DIR"
info "Report     : $ACA_PAPI_REPORT_OUT"
info "Contatori  : $PAPI_EVENTS"
[[ -n "$PRESET" ]] && info "Preset     : $PRESET"
echo ""

# Stampa nomi kernel configurati
HAS_KNL=0
for i in $(seq 1 10); do
  var="ACA_PAPI_KNL_${i}_NAME"
  val="${!var:-}"
  if [[ -n "$val" ]]; then
    [[ $HAS_KNL -eq 0 ]] && info "Kernel configurati:"
    echo "    [$i] $val"
    HAS_KNL=1
  fi
done
echo "  +--------------------------------------------------------+"
echo ""

# ============================================================================
# Esecuzione
# ============================================================================
echo -e "\n== STEP 1/2 — Esecuzione e Campionamento PAPI =="
START_NS=$(date +%s%N)

# shellcheck disable=SC2086
$EXE $ARGS >"${OUT_DIR}/docking_output.log"
EXIT_CODE=$?

END_NS=$(date +%s%N)
ELAPSED_MS=$(((END_NS - START_NS) / 1000000))

# ============================================================================
# Report
# ============================================================================
echo -e "\n== STEP 2/2 — Elaborazione e Report Metriche =="
if [[ $EXIT_CODE -eq 0 ]]; then
  ok "Esecuzione completata in ${ELAPSED_MS} ms."
  echo ""
  JSON_REPORT="${OUT_DIR}/kpi_hotspots.json"
  TXT_REPORT="${OUT_DIR}/kpi_hotspots.txt"
  if [[ -f "$JSON_REPORT" ]]; then
    # Eseguiamo il formatter Python
    python3 "$(dirname "$0")/format_papi_report.py" \
      --json "$JSON_REPORT" \
      --preset "${PRESET:-custom}" \
      --templates-dir "$(dirname "$0")/../preset_template" \
      --out "$TXT_REPORT"

    ok "Report PAPI generato: $TXT_REPORT"
    echo ""
    echo "  Anteprima (prime 35 righe):"
    echo "  ────────────────────────────────────────"
    head -n 35 "$TXT_REPORT" | sed 's/^/  /'
    echo "  ────────────────────────────────────────"
    echo ""
    info "Visualizzazione completa:  cat $TXT_REPORT"
  else
    warn "Report JSON non generato. Verifica:"
    warn "  1. Binario compilato con -DACA_ENABLE_PAPI -lpapi"
    warn "  2. Macro ACA_PAPI_KNL_START/STOP presenti nel codice"
    warn "  3. kernel.perf_event_paranoid=-1"
  fi
else
  err "Processo terminato con errore (exit: $EXIT_CODE)."
fi
echo "  +--------------------------------------------------------+"
echo ""

exit $EXIT_CODE
