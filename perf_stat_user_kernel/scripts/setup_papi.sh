#!/bin/bash
# =============================================================================
# setup_papi.sh — Setup ambiente per il profiling hardware PAPI
# =============================================================================
# Esegui questo script UNA VOLTA per sessione prima di usare aca_papi_tracer.
#
# Cosa fa:
#   1. Verifica che PAPI sia disponibile nell'ambiente Spack
#   2. Sblocca i PMU hardware del kernel (richiede sudo)
#   3. Verifica quali eventi PAPI sono disponibili su questo hardware
#   4. Stampa la stringa ACA_PAPI_EVENTS consigliata per questo sistema
#
# Utilizzo:
#   source ./setup_papi.sh           # (raccomandato: esporta le variabili)
#   bash ./setup_papi.sh             # solo verifica, non esporta
# =============================================================================
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC}   $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERR]${NC}  $*"; }
info() { echo -e "${CYAN}[INFO]${NC} $*"; }

echo "============================================================"
echo "  PAPI Hardware Profiling — Setup Ambiente"
echo "============================================================"

# ---- 1. Carica Spack + PAPI ------------------------------------------------
if ! command -v spack &>/dev/null; then
    # Prova a caricare Spack dal percorso default
    SPACK_SETUP="${SPACK_ROOT:-/home/olly/spack}/share/spack/setup-env.sh"
    if [[ -f "$SPACK_SETUP" ]]; then
        # shellcheck disable=SC1090
        source "$SPACK_SETUP"
    else
        err "Spack non trovato. Imposta SPACK_ROOT o installa Spack."
        exit 1
    fi
fi

info "Caricando ambiente Spack 'mudock_zen5'..."
spack env activate mudock_zen5 2>/dev/null || {
    err "Impossibile attivare l'ambiente Spack 'mudock_zen5'."
    exit 1
}

spack load papi 2>/dev/null || {
    err "PAPI non trovato nell'ambiente Spack. Verifica con: spack find papi"
    exit 1
}

PAPI_PREFIX=$(spack location -i papi 2>/dev/null)
ok "PAPI trovato: $PAPI_PREFIX"
ok "Versione: $(papi_avail 2>/dev/null | grep 'PAPI version' | awk '{print $NF}')"

# Aggiunge PAPI al PATH e LIBRARY_PATH per la sessione corrente
export PATH="${PAPI_PREFIX}/bin:${PATH}"
export LD_LIBRARY_PATH="${PAPI_PREFIX}/lib:${LD_LIBRARY_PATH:-}"
export PAPI_PREFIX

# ---- 2. Sblocca PMU hardware -----------------------------------------------
echo ""
info "Impostazione kernel.perf_event_paranoid=-1 (richiede sudo)..."
CURRENT_PARANOID=$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo "N/A")
info "Valore attuale: $CURRENT_PARANOID"

if [[ "$CURRENT_PARANOID" == "-1" ]]; then
    ok "PMU già sbloccati (paranoid=-1), nessuna azione necessaria."
else
    if sudo sysctl -w kernel.perf_event_paranoid=-1 &>/dev/null; then
        ok "PMU sbloccati con successo (kernel.perf_event_paranoid=-1)"
        warn "NOTA: questa impostazione è temporanea — viene resettata al riavvio."
        warn "      Per renderla permanente: echo 'kernel.perf_event_paranoid=-1' >> /etc/sysctl.conf"
    else
        warn "sudo non disponibile o password richiesta. I contatori PMU potrebbero non funzionare."
        warn "Esegui manualmente: sudo sysctl -w kernel.perf_event_paranoid=-1"
    fi
fi

# ---- 3. Verifica eventi disponibili su questo hardware ----------------------
echo ""
info "Verifico gli eventi PAPI disponibili su questo hardware..."

# Lista degli eventi di interesse per il profiling ACA
EVENTS_TO_CHECK=(
    PAPI_TOT_CYC
    PAPI_TOT_INS
    PAPI_L1_DCM
    PAPI_L2_DCM
    PAPI_L3_TCM
    PAPI_BR_MSP
    PAPI_BR_PRC
    PAPI_TLB_DM
    PAPI_VEC_DP
    PAPI_FP_OPS
    PAPI_STL_ICY
    PAPI_LD_INS
    PAPI_SR_INS
)

AVAILABLE_EVENTS=()
UNAVAILABLE_EVENTS=()

for ev in "${EVENTS_TO_CHECK[@]}"; do
    # Testa l'evento con papi_command_line (output silenzioso)
    if papi_command_line "$ev" &>/dev/null; then
        AVAILABLE_EVENTS+=("$ev")
    else
        UNAVAILABLE_EVENTS+=("$ev")
    fi
done

echo ""
echo "  Eventi disponibili:"
for ev in "${AVAILABLE_EVENTS[@]}"; do
    echo -e "    ${GREEN}✓${NC} $ev"
done

if [[ ${#UNAVAILABLE_EVENTS[@]} -gt 0 ]]; then
    echo ""
    echo "  Eventi non disponibili su questo hardware:"
    for ev in "${UNAVAILABLE_EVENTS[@]}"; do
        echo -e "    ${YELLOW}✗${NC} $ev"
    done
fi

# ---- 4. Suggerisci configurazione ottimale ----------------------------------
echo ""
echo "============================================================"

# Costruisce la stringa ACA_PAPI_EVENTS con gli eventi disponibili di interesse
# Preferisce: CYC, INS, L3 miss, branch miss, branch correct
RECOMMENDED=""
for candidate in PAPI_TOT_CYC PAPI_TOT_INS PAPI_L3_TCM PAPI_BR_MSP PAPI_BR_PRC PAPI_TLB_DM PAPI_VEC_DP; do
    for avail in "${AVAILABLE_EVENTS[@]}"; do
        if [[ "$candidate" == "$avail" ]]; then
            RECOMMENDED="${RECOMMENDED:+${RECOMMENDED},}${candidate}"
        fi
    done
done

# Fallback se nessun evento è disponibile (paranoid ancora alto?)
if [[ -z "$RECOMMENDED" ]]; then
    warn "Nessun evento PMU disponibile. Verifica il perf_event_paranoid."
    RECOMMENDED="PAPI_TOT_CYC,PAPI_TOT_INS,PAPI_L3_TCM,PAPI_BR_MSP,PAPI_BR_PRC"
    warn "Usando configurazione di default (potrebbe non funzionare)."
else
    ok "Stringa eventi consigliata per questo hardware (Zen 5 / AMD Ryzen AI 7 PRO 350):"
fi

echo ""
echo "  export ACA_PAPI_EVENTS=\"${RECOMMENDED}\""
echo ""

# Se chiamato con 'source', esporta le variabili nella shell corrente
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    export ACA_PAPI_EVENTS="$RECOMMENDED"
    ok "ACA_PAPI_EVENTS esportata nella shell corrente."
fi

echo "============================================================"
echo "  Setup completato. Ora puoi eseguire il profiling."
echo "  Per profilare un binario usa:"
echo "    ./scripts/run_papi.sh --exe <binario> --knl-1 'MioKernel'"
echo "============================================================"
