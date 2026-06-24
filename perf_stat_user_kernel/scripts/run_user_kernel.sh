#!/usr/bin/env bash
# =============================================================================
# run_user_kernel.sh — Orchestratore per tracciamento User Events
#
# Utilizzo:
#   ./scripts/run_user_kernel.sh --exe <binario> [opzioni]
#
# Opzioni obbligatorie:
#   --exe PATH              Percorso del binario da profilare
#
# Opzioni facoltative:
#   --args "ARGS"           Argomenti da passare al binario (tra virgolette)
#   --out-dir DIR           Directory di output (default: ./traces/user_events)
#   --event-N NAME          Assegna il nome NAME all'evento N (N da 1 a 10)
#                           Esempio: --event-1 "FaseParsing" --event-2 "KernelGA"
#
# Esempio:
#   ./scripts/run_user_kernel.sh \
#      --exe ../../muDock/build/application/muDock \
#      --args "--protein ../../muDock/data/1fkb/1fkb_protein.pdb --ligand ../../muDock/data/1fkb/ligands100_12col.adtmol2 --use CPP:CPU:0-3" \
#      --event-1 "TbbPipeline" --event-2 "ParserFilter"
# =============================================================================
set -euo pipefail

# ---- Colori -----------------------------------------------------------------
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'
ok() { echo -e "${GREEN}[OK]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err() { echo -e "${RED}[ERR]${NC}  $*"; }
info() { echo -e "$*"; }
# ---- Valori di default ------------------------------------------------------
EXE=""
ARGS=""
OUT_DIR="./traces/user_events"
EVENT_NAMES=() # Array sparse: EVENT_NAMES[1]..EVENT_NAMES[10]

# ---- Parsing argomenti ------------------------------------------------------
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
    sed -n '2,22p' "$0" | sed 's/^# \?//'
    exit 0
    ;;
  --event-*)
    # Estrae l'indice N da --event-N
    idx="${1#--event-}"
    if ! [[ "$idx" =~ ^[1-9]$|^10$ ]]; then
      err "Indice evento non valido: $idx (deve essere 1..10)"
      exit 1
    fi
    EVENT_NAMES[$idx]="$2"
    shift 2
    ;;
  *)
    err "Opzione sconosciuta: $1"
    sed -n '2,22p' "$0" | sed 's/^# \?//'
    exit 1
    ;;
  esac
done

# ---- Validazione ------------------------------------------------------------
if [[ -z "$EXE" ]]; then
  err "Specificare l'eseguibile con --exe."
  sed -n '2,21p' "$0" | sed 's/^# \?//'
  exit 1
fi
if [[ ! -x "$EXE" ]]; then
  err "Binario non trovato o non eseguibile: $EXE"
  exit 1
fi

mkdir -p "$OUT_DIR"

# ---- Esporta i nomi degli eventi nell'ambiente ------------------------------
for i in $(seq 1 10); do
  if [[ -n "${EVENT_NAMES[$i]+set}" ]]; then
    export "ACA_USER_EVENT_${i}_NAME=${EVENT_NAMES[$i]}"
  fi
  # Se già impostata dall'esterno, non sovrascriviamo (l'utente ha la precedenza)
done

# ---- Percorso di output del JSON Perfetto -----------------------------------
export ACA_TRACE_USER_OUT="${OUT_DIR}/trace_user_events.json"

# ---- Banner -----------------------------------------------------------------
echo ""
echo "  +--------------------------------------------------------+"
echo "  |          User Events — Perfetto Timeline Profiler      |"
echo "  |     Visualizing OpenMP/TBB Pipeline & Concurrency      |"
echo "  +--------------------------------------------------------+"
echo ""
info "Binario    : $EXE"
info "Argomenti  : ${ARGS:-<nessuno>}"
info "Output dir : $OUT_DIR"
info "Trace JSON : $ACA_TRACE_USER_OUT"
echo ""
info "Nomi eventi configurati:"
for i in $(seq 1 10); do
  var="ACA_USER_EVENT_${i}_NAME"
  val="${!var:-}"
  if [[ -n "$val" ]]; then
    echo "    Evento $i → $val"
  fi
done
echo "  +--------------------------------------------------------+"
echo ""

# ---- Esecuzione -------------------------------------------------------------
echo -e "\n== STEP 1/2 — Esecuzione e Tracciamento =="
START_TS=$(date +%s%N)

# shellcheck disable=SC2086
$EXE $ARGS >"${OUT_DIR}/docking_output.log"
EXIT_CODE=$?

END_TS=$(date +%s%N)
ELAPSED_MS=$(((END_TS - START_TS) / 1000000))

# ---- Report finale ----------------------------------------------------------
echo -e "\n== STEP 2/2 — Analisi e Report =="
if [[ $EXIT_CODE -eq 0 ]]; then
  ok "Esecuzione completata in ${ELAPSED_MS} ms."
  echo ""
  echo "  Output generato:"
  if [[ -f "$ACA_TRACE_USER_OUT" ]]; then
    SIZE=$(du -sh "$ACA_TRACE_USER_OUT" | cut -f1)
    ok "  Traccia Perfetto : $ACA_TRACE_USER_OUT  (${SIZE})"
    echo ""
    echo "  Visualizzazione:"
    echo "    1. Apri https://ui.perfetto.dev/"
    echo "    2. Trascina $ACA_TRACE_USER_OUT"
    echo "    3. Espandi il processo per vedere:"
    echo "       - Le slice colorate degli User Events per thread"
    echo "       - Il counter 'user_events_active' (parallelismo istantaneo)"
    echo "       - L'evento 'UserUtilization' con la % di CPU user-code"
  else
    warn "Il file di traccia non è stato generato."
    warn "Verifica che il binario sia compilato con -DACA_ENABLE_USER_EVENTS"
    warn "e che le macro ACA_USER_EVENT_START/STOP siano presenti nel codice."
  fi
else
  err "Il processo è terminato con errore (exit code: $EXIT_CODE)."
fi
echo "  +--------------------------------------------------------+"
echo ""

exit $EXIT_CODE
