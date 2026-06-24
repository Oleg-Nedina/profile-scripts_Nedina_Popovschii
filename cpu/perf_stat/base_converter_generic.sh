#!/usr/bin/env bash
# =============================================================================
# base_converter_generic.sh  —  Pipeline generica: perf record → JSON Perfetto
# =============================================================================
#
# Utilizzo:
#   ./cpu/base_converter_generic.sh [opzioni]
#
# Opzioni:
#   --exe PATH          Percorso del binario da profilare (OBBLIGATORIO)
#   --args "..."        Argomenti da passare all'eseguibile (opzionale)
#   --skip-perf         Salta la registrazione perf (usa perf.data esistente)
#   --convert-only      Salta anche l'esecuzione, converte perf.data esistente
#   --perf-data FILE    Nome del file perf.data (default: perf.data)
#   --output FILE       Nome del file JSON di output (default: trace_perf.json)
#   --no-browser        Non aprire il browser automaticamente
#   --port N            Porta del server HTTP (default: 9001)
#
# Esempi:
#   ./cpu/base_converter_generic.sh --exe ./myapp --args "--input data.txt"
#   ./cpu/base_converter_generic.sh --convert-only
#   ./cpu/base_converter_generic.sh --exe ./myapp --no-browser
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# -- Valori default ------------------------------------------------------------─
EXE=""
EXE_ARGS=""
SKIP_PERF=0
CONVERT_ONLY=0
PERF_DATA="perf.data"
TRACE_OUT="trace_perf.json"
OPEN_BROWSER=1
HTTP_PORT=9001

# -- Trova perf automaticamente ------------------------------------------------─
# Cerca il perf corrispondente al kernel in uso
PERF_BIN=""
for candidate in \
    "perf" \
    "/usr/lib/linux-tools/$(uname -r)/perf" \
    "$(ls /usr/lib/linux-tools/*/perf 2>/dev/null | tail -1)"; do
  if [[ -x "${candidate}" ]]; then
    PERF_BIN="${candidate}"
    break
  fi
done
[[ -n "${PERF_BIN}" ]] || { echo "[ERROR] 'perf' non trovato. Installa: sudo apt install linux-tools-\$(uname -r)" >&2; exit 1; }

# -- Parsing argomenti ----------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --exe)           EXE="$2";        shift ;;
    --args)          EXE_ARGS="$2";   shift ;;
    --skip-perf)     SKIP_PERF=1 ;;
    --convert-only)  CONVERT_ONLY=1; SKIP_PERF=1 ;;
    --perf-data)     PERF_DATA="$2";  shift ;;
    --output)        TRACE_OUT="$2";  shift ;;
    --no-browser)    OPEN_BROWSER=0 ;;
    --port)          HTTP_PORT="$2";  shift ;;
    -h|--help)
      sed -n '2,20p' "$0" | sed 's/^# \?//'
      exit 0 ;;
    *) echo "[WARN] Argomento sconosciuto: $1" ;;
  esac
  shift
# Set default output paths to traces/ subdirectory and create it
if [[ "${PERF_DATA}" == "perf.data" && "${TRACE_OUT}" == "trace_perf.json" ]]; then
  PERF_DATA="traces/perf.data"
  TRACE_OUT="traces/trace_perf.json"
fi
mkdir -p "$(dirname "${PERF_DATA}")"
mkdir -p "$(dirname "${TRACE_OUT}")"

# -- Colori --------------------------------------------------------------------─
step() { echo -e "\n== $* =="; }
ok()   { echo "  [OK]  $*"; }
warn() { echo "  [WARN]  $*"; }
die()  { echo "  [FAIL]  $*" >&2; exit 1; }

echo ""
echo "  +----------------------------------------------------─+"
echo "  |         Base Converter — Generico                   |"
echo "  |     perf record → JSON → Perfetto (browser)        |"
echo "  +----------------------------------------------------─+"
echo ""

# -- Validazione ----------------------------------------------------------------
if [[ "${CONVERT_ONLY}" -eq 0 && "${SKIP_PERF}" -eq 0 ]]; then
  [[ -n "${EXE}" ]]  || die "Specifica l'eseguibile con --exe /path/to/binary"
  [[ -x "${EXE}" ]]  || die "Binario non trovato o non eseguibile: ${EXE}"
fi

# ===============================================================================
# STEP 1 — perf record
# ===============================================================================
if [[ "${SKIP_PERF}" -eq 0 ]]; then
  step "STEP 1/2 — Esecuzione con perf record"
  echo "  Eseguibile: ${EXE}"
  [[ -n "${EXE_ARGS}" ]] && echo "  Argomenti:  ${EXE_ARGS}"

  # Sblocca contatori hardware se necessario
  PARANOIA=$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo "4")
  if [[ "${PARANOIA}" -gt 0 ]]; then
    warn "perf_event_paranoid=${PARANOIA} → sblocco temporaneo..."
    sudo sysctl -w kernel.perf_event_paranoid=-1 \
      || warn "Sblocco fallito — la traccia potrebbe essere parziale"
  fi

  echo ""
  # shellcheck disable=SC2086
  "${PERF_BIN}" record \
    -g \
    --call-graph dwarf \
    -o "${PERF_DATA}" \
    -- "${EXE}" ${EXE_ARGS} \
    2>&1

  echo ""
  ok "Registrazione completata: ${PERF_DATA}  ($(du -h "${PERF_DATA}" | cut -f1))"
else
  step "STEP 1/2 — Saltato (modalità convert-only o skip-perf)"
  [[ -f "${PERF_DATA}" ]] || die "Nessun ${PERF_DATA} trovato. Rimuovi --convert-only o --skip-perf."
  ok "Uso perf.data esistente: $(du -h "${PERF_DATA}" | cut -f1)"
fi

# ===============================================================================
# STEP 2 — Conversione + apertura browser
# ===============================================================================
step "STEP 2/2 — Conversione in Perfetto JSON"

# Cerca perf_to_perfetto.py: prima in perfetto_converters/ (nuova struttura), poi fallback vecchi path
CONVERTER_PY=""
for candidate in \
    "${SCRIPT_DIR}/../perfetto_converters/perf_to_perfetto.py" \
    "${SCRIPT_DIR}/perf_to_perfetto.py" \
    "${SCRIPT_DIR}/../perf_to_perfetto.py"; do
  if [[ -f "${candidate}" ]]; then
    CONVERTER_PY="${candidate}"
    break
  fi
done
[[ -n "${CONVERTER_PY}" ]] || die "perf_to_perfetto.py non trovato. Assicurati che sia nella cartella perfetto_converters/"

python3 "${CONVERTER_PY}" "${PERF_DATA}" "${TRACE_OUT}"

# -- Apertura automatica del browser ------------------------------------------─
if [[ "${OPEN_BROWSER}" -eq 1 ]]; then
  echo ""
  echo "  Avvio server HTTP locale su porta ${HTTP_PORT} ..."

  lsof -ti tcp:"${HTTP_PORT}" | xargs kill -9 2>/dev/null || true

  python3 -m http.server "${HTTP_PORT}" \
    --directory "$(pwd)" \
    > /dev/null 2>&1 &
  HTTP_PID=$!

  sleep 1

  PERFETTO_URL="https://ui.perfetto.dev/#!/?url=http://localhost:${HTTP_PORT}/${TRACE_OUT}"
  ok "Server HTTP avviato (PID ${HTTP_PID}) → http://localhost:${HTTP_PORT}"
  echo ""

  BROWSER_OPENED=0
  for BROWSER_CMD in xdg-open google-chrome chromium-browser firefox; do
    if command -v "${BROWSER_CMD}" &>/dev/null; then
      "${BROWSER_CMD}" "${PERFETTO_URL}" &>/dev/null &
      ok "Browser aperto: ${BROWSER_CMD}"
      BROWSER_OPENED=1
      break
    fi
  done

  if [[ "${BROWSER_OPENED}" -eq 0 ]]; then
    warn "Nessun browser trovato. Apri manualmente:"
    echo "       ${PERFETTO_URL}"
  fi

  echo ""
  echo "  Nota: il server HTTP (PID ${HTTP_PID}) resterà attivo."
  echo "  Per fermarlo:  kill ${HTTP_PID}"
fi

# ===============================================================================
# Riepilogo
# ===============================================================================
echo ""
echo ""
echo "  +=======================================================+"
echo "  |              Pipeline completata!                  |"
echo "  +=======================================================╣"
printf  "  |  Trace: %-45s |\n" "${TRACE_OUT}  ($(du -h "${TRACE_OUT}" | cut -f1))"
echo "  |  Apri:  https://ui.perfetto.dev/                     |"
echo "  +=======================================================+"
echo ""
