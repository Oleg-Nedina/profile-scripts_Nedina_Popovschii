#!/usr/bin/env bash
# =============================================================================
# run_hpctoolkit.sh — Esegue il profiling statistico con HPCToolkit
#
# Utilizzo:
#   ./scripts/run_hpctoolkit.sh --exe <binario> [opzioni]
#
# Opzioni obbligatorie:
#   --exe PATH              Percorso del binario da profilare
#
# Opzioni facoltative:
#   --args "ARGS"           Argomenti da passare al binario (tra virgolette)
#   --out-dir DIR           Directory di output (default: ./traces/hpctoolkit)
#   --src-dir DIR           Directory sorgente di muDock (default: ../../muDock)
#   --events "E1,E2,..."    Lista personalizzata di eventi PAPI separati da virgola
#                           (default: "cycles,PAPI_L2_DCM")
#   --preset PRESET         Seleziona un preset predefinito (sovrascrive --events):
#                             ipc    -> cycles,PAPI_TOT_INS
#                             cache  -> cycles,PAPI_L1_DCM,PAPI_L2_DCM,PAPI_TLB_DM
#                             branch -> cycles,PAPI_BR_MSP,PAPI_BR_INS
#                             simd   -> cycles,PAPI_VEC_INS,PAPI_FP_OPS
#                             full   -> cycles,PAPI_TOT_INS,PAPI_L1_DCM,PAPI_L2_DCM,PAPI_BR_MSP
#
# Esempio:
#   ./scripts/run_hpctoolkit.sh \
#      --exe ../../muDock/build/application/muDock \
#      --args "--protein ../../muDock/data/1fkb/1fkb_protein.pdb --ligand ../../muDock/data/1fkb/ligands100_12col.adtmol2 --use CPP:CPU:0-3" \
#      --preset cache
# =============================================================================
set -euo pipefail

# ---- Colori -----------------------------------------------------------------
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

# ---- Valori di default ------------------------------------------------------
EXE=""
ARGS=""
OUT_DIR="./traces/hpctoolkit"
EVENTS=("cycles" "PAPI_L2_DCM")
SRC_DIR="../../muDock"

# ---- Parsing argomenti ------------------------------------------------------
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
                *)      err "Preset sconosciuto: $2" ; exit 1 ;;
            esac
            IFS=',' read -r -a EVENTS <<< "$PRESET_EVENTS"
            shift 2
            ;;
        --help|-h)
            sed -n '2,29p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *)
            err "Opzione sconosciuta: $1"
            sed -n '2,29p' "$0" | sed 's/^# \?//'
            exit 1
            ;;
    esac
done

# ---- Validazione ------------------------------------------------------------
if [[ -z "$EXE" ]]; then
    err "Specificare l'eseguibile con --exe."
    usage
fi
if [[ ! -x "$EXE" ]]; then
    err "Binario non trovato o non eseguibile: $EXE"
    exit 1
fi

# ---- Setup Ambiente Spack ---------------------------------------------------
if ! command -v hpcrun &>/dev/null; then
    info "HPCToolkit non rilevato nel PATH. Provo a caricare Spack..."
    SPACK_SETUP="${SPACK_ROOT:-/home/olly/spack}/share/spack/setup-env.sh"
    if [[ -f "$SPACK_SETUP" ]]; then
        # shellcheck disable=SC1090
        source "$SPACK_SETUP"
        spack env activate mudock_zen5 2>/dev/null || warn "Impossibile attivare l'ambiente Spack 'mudock_zen5'."
        spack load hpctoolkit 2>/dev/null || warn "Impossibile caricare il modulo 'hpctoolkit' via Spack."
    fi
fi

# Verifica finale dei tool
for tool in hpcrun hpcstruct hpcprof; do
    if ! command -v "$tool" &>/dev/null; then
        err "Strumento richiesto non trovato: $tool"
        err "Assicurati che HPCToolkit sia installato e caricato nel PATH."
        exit 1
    fi
done

# Risoluzione percorsi assoluti
EXE_ABS=$(readlink -f "$EXE")
SRC_DIR_ABS=$(readlink -f "$SRC_DIR")
mkdir -p "$OUT_DIR"
OUT_DIR_ABS=$(readlink -f "$OUT_DIR")

# Directory temporanee per HPCToolkit
MEASUREMENTS_DIR="${OUT_DIR_ABS}/measurements"
DATABASE_DIR="${OUT_DIR_ABS}/database"

# Pulizia run precedenti
rm -rf "$MEASUREMENTS_DIR" "$DATABASE_DIR"

# ---- Costruzione argomenti hpcrun -------------------------------------------
HPCRUN_ARGS=()
for event in "${EVENTS[@]}"; do
    HPCRUN_ARGS+=("-e" "$event")
done

# ---- Banner -----------------------------------------------------------------
echo ""
echo "  +--------------------------------------------------------+"
echo "  |              HPCToolkit — Profiling Suite              |"
echo "  |         Sampling-based Performance Measurement         |
  +--------------------------------------------------------+"
echo ""
info "Binario       : $EXE_ABS"
info "Argomenti     : ${ARGS:-<nessuno>}"
info "Output Dir    : $OUT_DIR_ABS"
info "Eventi PAPI   : ${EVENTS[*]}"
echo ""

# ---- 1. Esecuzione Misurazione (hpcrun) -------------------------------------
echo -e "\n== STEP 1/3 — Campionamento ed Esecuzione (hpcrun) =="
# Costruiamo la lista di argomenti completa
# shellcheck disable=SC2086
hpcrun "${HPCRUN_ARGS[@]}" -t -o "$MEASUREMENTS_DIR" "$EXE_ABS" $ARGS > "${OUT_DIR_ABS}/docking_output.log" 2>&1

if [[ -d "$MEASUREMENTS_DIR" ]]; then
    ok "Misurazioni completate con successo in: $MEASUREMENTS_DIR"
else
    err "Errore: le misurazioni non sono state generate da hpcrun."
    exit 1
fi

# ---- 2. Analisi Struttura (hpcstruct) ---------------------------------------
echo -e "\n== STEP 2/3 — Analisi Struttura (hpcstruct) =="
hpcstruct "$MEASUREMENTS_DIR"
ok "Struttura del binario recuperata ed associata alle misurazioni."

# ---- 3. Generazione Database Performance (hpcprof) -------------------------
echo -e "\n== STEP 3/3 — Generazione Database (hpcprof) =="
hpcprof -o "$DATABASE_DIR" "$MEASUREMENTS_DIR"

# ---- Report finale ----------------------------------------------------------
echo -e "\n== CONCLUSIONE — Profiling Completato =="
ok "Profiling HPCToolkit terminato con successo!"
echo ""
info "Database generato in:"
ok "  $DATABASE_DIR"
echo ""
info "Per visualizzare la timeline e i grafici dei contatori, esegui:"
ok "  hpcviewer $DATABASE_DIR"
echo "  +--------------------------------------------------------+"
echo ""
