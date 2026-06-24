#!/usr/bin/env bash
# =============================================================================
# low_level_probe_generic.sh  —  Profiling mirato con perf probe (generico)
# =============================================================================
#
# Profiling con uprobes dinamiche sulle Top-N funzioni più costose,
# rilevate automaticamente da un perf.data esistente.
#
# NON richiede Spack, muDock, né percorsi hardcodati.
#
# Utilizzo:
#   ./cpu/low_level/low_level_probe_generic.sh \
#       --exe /path/to/binary \
#       --perf-data perf.data \
#       [opzioni]
#
# Opzioni:
#   --exe FILE          Binario da profilare (OBBLIGATORIO)
#   --args "..."        Argomenti extra da passare al binario
#   --namespace NS      Namespace C++ da tracciare (default: "" = tutti i simboli)
#   --top N             Numero di funzioni calde da tracciare (default: 3)
#   --perf-data FILE    File perf.data di input (default: perf.data)
#   --output FILE       File JSON di output (default: trace_low_level.json)
#   --perf-out FILE     File perf.data con probe (default: perf_low_level.data)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# -- Default --------------------------------------------------------------------
EXE=""
EXE_ARGS=""
NAMESPACE=""        # es. "mudock::" — se vuoto filtra solo per tipo simbolo
TOP_N=3
PERF_DATA_IN="perf.data"
PERF_DATA_PROBE="perf_low_level.data"
TRACE_OUT="trace_low_level.json"

# -- Trova perf automaticamente ------------------------------------------------─
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
    --exe)         EXE="$2";             shift ;;
    --args)        EXE_ARGS="$2";        shift ;;
    --namespace)   NAMESPACE="$2";       shift ;;
    --top)         TOP_N="$2";           shift ;;
    --perf-data)   PERF_DATA_IN="$2";    shift ;;
    --output)      TRACE_OUT="$2";       shift ;;
    --perf-out)    PERF_DATA_PROBE="$2"; shift ;;
    -h|--help)
      sed -n '2,25p' "$0" | sed 's/^# \?//'
      exit 0 ;;
    *) echo "[WARN] Argomento sconosciuto: $1" ;;
  esac
  shift
# Set default paths if not explicitly overridden by CLI options
if [[ "${PERF_DATA_IN}" == "perf.data" ]]; then
  if [[ -f "traces/perf.data" ]]; then
    PERF_DATA_IN="traces/perf.data"
  fi
fi
if [[ "${PERF_DATA_PROBE}" == "perf_low_level.data" ]]; then
  PERF_DATA_PROBE="traces/perf_low_level.data"
fi
if [[ "${TRACE_OUT}" == "trace_low_level.json" ]]; then
  TRACE_OUT="traces/trace_low_level.json"
fi
mkdir -p "$(dirname "${PERF_DATA_PROBE}")"
mkdir -p "$(dirname "${TRACE_OUT}")"

# -- Colori --------------------------------------------------------------------─
step() { echo -e "\n== $* =="; }
ok()   { echo "  [OK]  $*"; }
warn() { echo "  [WARN]  $*"; }
die()  { echo "  [FAIL]  $*" >&2; exit 1; }

echo ""
echo "  +----------------------------------------------------------+"
echo "  |           Low Level Probe — Generico                    |"
echo "  |   Auto-discovery Top-${TOP_N} → perf probe → Perfetto JSON    |"
echo "  +----------------------------------------------------------+"
echo ""

# -- Validazione ----------------------------------------------------------------
[[ -n "${EXE}" ]]         || die "Specifica l'eseguibile con --exe /path/to/binary"
[[ -x "${EXE}" ]]         || die "Binario non trovato o non eseguibile: ${EXE}"
[[ -f "${PERF_DATA_IN}" ]] || die "File '${PERF_DATA_IN}' non trovato. Generalo prima con base_converter_generic.sh"

BINARY="$(realpath "${EXE}")"

# ===============================================================================
# STEP 1 — Estrai Top-N funzioni da perf.data
# ===============================================================================
step "STEP 1/4 — Discovery: Top-${TOP_N} funzioni da '${PERF_DATA_IN}'"
[[ -n "${NAMESPACE}" ]] && echo "  Filtro namespace: ${NAMESPACE}"

TOP_FUNCTIONS=()
while IFS= read -r line; do
  if [[ "${line}" =~ ^[[:space:]]+([0-9]+\.[0-9]+)%.*\[\.\][[:space:]]+(.*) ]]; then
    pct="${BASH_REMATCH[1]}"
    sym_full="${BASH_REMATCH[2]}"
    sym_base=$(echo "${sym_full}" | sed 's/(.*//' | awk '{print $1}')
    [[ -z "${sym_base}" ]] && continue

    # Se è specificato un namespace, filtra; altrimenti accetta tutto (escluidi glibc)
    if [[ -n "${NAMESPACE}" ]]; then
      [[ "${sym_base}" =~ ^${NAMESPACE} ]] || continue
    fi
    [[ "${sym_base}" =~ (clone|start_thread|__libc|_dl_) ]] && continue

    if [[ ! " ${TOP_FUNCTIONS[*]} " =~ " ${sym_base} " ]]; then
      TOP_FUNCTIONS+=("${sym_base}")
      echo "  $(printf '%5s' "${pct}")%  →  ${sym_base}"
    fi
    [[ ${#TOP_FUNCTIONS[@]} -ge ${TOP_N} ]] && break
  fi
done < <("${PERF_BIN}" report \
    -i "${PERF_DATA_IN}" \
    --stdio \
    --no-children \
    --demangle \
    -w 500 \
    --sort comm,dso,sym \
    2>/dev/null | grep -v "^#" | grep -v "^$")

if [[ ${#TOP_FUNCTIONS[@]} -eq 0 ]]; then
  die "Nessuna funzione trovata nel report. Prova senza --namespace o controlla il perf.data."
fi
ok "Trovate ${#TOP_FUNCTIONS[@]} funzioni target"

# ===============================================================================
# STEP 2 — Aggiungi uprobes
# ===============================================================================
step "STEP 2/4 — Aggiunta uprobes dinamiche (perf probe)"
warn "Questo step richiede sudo per scrivere su tracefs."

# Pulizia probe precedenti (case-insensitive per il nome del binario)
BINARY_NAME="$(basename "${BINARY}")"
sudo "${PERF_BIN}" probe --del "probe_${BINARY_NAME}:*" 2>/dev/null || true
sudo "${PERF_BIN}" probe --del "probe:*" 2>/dev/null || true

PROBE_EVENTS=()

for sym_base in "${TOP_FUNCTIONS[@]}"; do
  echo "  Cerco mangled symbol per: ${sym_base}"
  MANGLED=""
  while IFS=" " read -r addr type m; do
    demangled=$(echo "${m}" | c++filt 2>/dev/null)
    if [[ "${demangled}" == "${sym_base}"* ]]; then
      MANGLED="${m}"
      break
    fi
  done < <(nm "${BINARY}" 2>/dev/null | grep ' [tTwW] ')

  if [[ -n "${MANGLED}" ]]; then
    echo "  Mangled trovato: ${MANGLED:0:70}"
    if sudo "${PERF_BIN}" probe \
        --exec "${BINARY}" \
        --add "${MANGLED}" \
        2>&1 | grep -v "^$"; then
      EVENT=$(sudo "${PERF_BIN}" probe --list 2>/dev/null | grep -o "probe_[^:]*:[^ ]*" | tail -1 || true)
      if [[ -n "${EVENT}" ]]; then
        PROBE_EVENTS+=("${EVENT}")
        ok "  Probe aggiunta: ${EVENT}"
      fi
    else
      warn "  perf probe fallito per: ${MANGLED:0:60} — salto"
    fi
  else
    warn "  Simbolo mangled non trovato per: ${sym_base} — salto"
  fi
done

# ===============================================================================
# STEP 3 — Esecuzione con probe attive
# ===============================================================================
if [[ ${#PROBE_EVENTS[@]} -eq 0 ]]; then
  warn "Nessuna probe aggiunta. Fallback a perf record standard."
  # shellcheck disable=SC2086
  "${PERF_BIN}" record -g -o "${PERF_DATA_PROBE}" -- "${BINARY}" ${EXE_ARGS} 2>&1
else
  step "STEP 3/4 — Esecuzione con probe attive"
  echo "  Probe eventi: ${PROBE_EVENTS[*]}"

  EVENT_ARGS=()
  for ev in "${PROBE_EVENTS[@]}"; do
    EVENT_ARGS+=("-e" "${ev}")
  done

  # shellcheck disable=SC2086
  sudo "${PERF_BIN}" record \
    -g \
    "${EVENT_ARGS[@]}" \
    -o "${PERF_DATA_PROBE}" \
    -- "${BINARY}" ${EXE_ARGS} \
    2>&1

  sudo chown "$(id -u):$(id -g)" "${PERF_DATA_PROBE}" || true
  ok "Run completato: ${PERF_DATA_PROBE} ($(du -h "${PERF_DATA_PROBE}" | cut -f1))"
fi

# Pulizia probe
BINARY_NAME="$(basename "${BINARY}")"
sudo "${PERF_BIN}" probe --del "probe_${BINARY_NAME}:*" 2>/dev/null || true

# ===============================================================================
# STEP 4 — Conversione in Perfetto JSON
# ===============================================================================
step "STEP 4/4 — Conversione in Perfetto JSON"

CONVERTER_PY=""
for candidate in \
    "${SCRIPT_DIR}/../perfetto_converters/perf_to_perfetto.py" \
    "${SCRIPT_DIR}/../perf_to_perfetto.py" \
    "${SCRIPT_DIR}/perf_to_perfetto.py"; do
  if [[ -f "${candidate}" ]]; then
    CONVERTER_PY="${candidate}"
    break
  fi
done
[[ -n "${CONVERTER_PY}" ]] || die "perf_to_perfetto.py non trovato nella cartella perfetto_converters/."

python3 "${CONVERTER_PY}" "${PERF_DATA_PROBE}" "${TRACE_OUT}"

echo ""
echo ""
echo "  +==========================================================+"
echo "  |        Low Level Probe — Pipeline completata          |"
echo "  +==========================================================╣"
printf  "  |  Trace: %-47s |\n" "${TRACE_OUT}  ($(du -h "${TRACE_OUT}" | cut -f1))"
echo "  |  Funzioni tracciate: ${#PROBE_EVENTS[@]}/${TOP_N}                               |"
echo "  |  Apri:  https://ui.perfetto.dev/                        |"
echo "  +==========================================================+"
echo ""
