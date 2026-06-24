#!/usr/bin/env bash
# =============================================================================
# low_level_probe.sh  —  Profiling mirato Top-N funzioni (entry + return probe)
# =============================================================================
#
# Funzionamento DINAMICO:
#   1. Legge perf.data esistente (generato da base_converter.sh)
#   2. Estrae automaticamente le Top-N funzioni per % CPU nel namespace mudock::
#   3. Aggiunge uprobes dinamici (entry + return probe) via perf probe
#   4. Esegue muDock con le probe attive → misura la DURATA REALE di ogni chiamata
#   5. Converte in trace_low_level.json (Perfetto) con slice reali (ts + dur)
#   6. (Opzionale) Esegue analisi False Sharing con perf c2c
#
# NON modifica il codice sorgente di muDock.
# Richiede: sudo per perf probe (o kernel.perf_event_paranoid=-1)
#
# Utilizzo:
#   ./cpu/low_level/low_level_probe.sh [opzioni]
#
# Opzioni:
#   --top N             Numero di funzioni Top-N da tracciare (default: 3)
#   --perf-data FILE    File perf.data di input (default: traces/perf.data)
#   --output FILE       Traccia Perfetto di output (default: traces/trace_low_level.json)
#   --population N      Dimensione popolazione GA muDock (default: 100)
#   --generations N     Numero generazioni GA muDock (default: 100)
#   --retprobe          Abilita retprobe: misura la durata REALE di ogni chiamata (default: on)
#   --no-retprobe       Disabilita retprobe, usa solo entry probe (modalità semplice)
#   --c2c               Esegui anche analisi False Sharing con perf c2c (default: off)
#   --c2c-out FILE      Report c2c di output (default: traces/c2c_report.txt)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -d "${SCRIPT_DIR}/../../../muDock" ]]; then
  MUDOCK_ROOT="$(cd "${SCRIPT_DIR}/../../../muDock" && pwd)"
elif [[ -d "${SCRIPT_DIR}/../.." ]]; then
  MUDOCK_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
else
  echo "[ERROR] Impossibile trovare la cartella root di muDock" >&2
  exit 1
fi
cd "${MUDOCK_ROOT}"

# -- Configurazione ------------------------------------------------------------
TOP_N=3
PERF_DATA_IN="traces/perf.data"
[[ -f "${PERF_DATA_IN}" ]] || PERF_DATA_IN="perf.data"
PERF_DATA_PROBE="traces/perf_low_level.data"
TRACE_OUT="traces/trace_low_level.json"
C2C_OUT="traces/c2c_report.txt"
POPULATION=100
GENERATIONS=100
PROTEIN="data/1fkb/1fkb_protein.pdb"
# LIGAND="data/1fkb/1fkb_ligand.mol2"
LIGAND="data/1fkb/1fkb_ligand.adtmol2"
DEVICE="CPP:CPU:0"
USE_RETPROBE=1    # 1 = abilita retprobe (misura durata reale), 0 = solo entry probe
USE_C2C=0         # 1 = esegui anche analisi False Sharing con perf c2c

# Trova perf in modo portabile
PERF_BIN=""
for candidate in \
    "/usr/lib/linux-tools/$(uname -r)/perf" \
    "$(ls /usr/lib/linux-tools/*/perf 2>/dev/null | sort -V | tail -1)" \
    "perf"; do
  [[ -x "${candidate}" ]] && { PERF_BIN="${candidate}"; break; }
done
[[ -n "${PERF_BIN}" ]] || { echo "[ERROR] 'perf' non trovato." >&2; exit 1; }

# -- Parsing argomenti --------------------------------------------------------─
while [[ $# -gt 0 ]]; do
  case "$1" in
    --top)          TOP_N="$2";         shift ;;
    --perf-data)    PERF_DATA_IN="$2";  shift ;;
    --output)       TRACE_OUT="$2";     shift ;;
    --population)   POPULATION="$2";    shift ;;
    --generations)  GENERATIONS="$2";   shift ;;
    --retprobe)     USE_RETPROBE=1 ;;
    --no-retprobe)  USE_RETPROBE=0 ;;
    --c2c)          USE_C2C=1 ;;
    --c2c-out)      C2C_OUT="$2";       shift ;;
    -h|--help)
      sed -n '2,30p' "$0" | sed 's/^# \?//'
      exit 0 ;;
    *) echo "[WARN] Argomento sconosciuto: $1" ;;
  esac
  shift
done

# -- Colori --------------------------------------------------------------------
step() { echo -e "\n== $* =="; }
ok()   { echo "  [OK]  $*"; }
warn() { echo "  [WARN]  $*"; }
info() { echo "  [INFO]  $*"; }
die()  { echo "  [FAIL]  $*" >&2; exit 1; }

RETPROBE_LABEL="$( [[ ${USE_RETPROBE} -eq 1 ]] && echo "entry+return (durata reale)" || echo "solo entry" )"
C2C_LABEL="$( [[ ${USE_C2C} -eq 1 ]] && echo "sì" || echo "no" )"

echo ""
echo "  +--------------------------------------------------------------+"
echo "  |         muDock — Low Level Probe Pipeline                   |"
echo "  |   Auto-discovery Top-${TOP_N} → uprobes → Perfetto JSON (dur)  |"
echo "  +--------------------------------------------------------------+"
echo ""
info "Top-N:    ${TOP_N}  |  Probe: ${RETPROBE_LABEL}  |  c2c: ${C2C_LABEL}"

[[ -f "${PERF_DATA_IN}" ]] || die "File '${PERF_DATA_IN}' non trovato. Esegui prima base_converter.sh"
[[ -f "./build/application/muDock" ]] || die "Binario muDock non trovato in build/"

mkdir -p "${MUDOCK_ROOT}/traces"

# ===============================================================================
# STEP 1 — Estrai automaticamente le Top-N funzioni da perf.data
# ===============================================================================
step "STEP 1/4 — Discovery: Top-${TOP_N} consumer da '${PERF_DATA_IN}'"

TOP_FUNCTIONS=()
while IFS= read -r line; do
  if [[ "${line}" =~ ^[[:space:]]+([0-9]+\.[0-9]+)%.*\[\.\][[:space:]]+(.*) ]]; then
    pct="${BASH_REMATCH[1]}"
    sym_full="${BASH_REMATCH[2]}"
    sym_base=$(echo "${sym_full}" | sed 's/(.*//' | awk '{print $1}')
    [[ -z "${sym_base}" ]] && continue
    if [[ "${sym_base}" =~ ^mudock:: ]] && \
       [[ ! "${sym_base}" =~ (clone|start_thread|__libc) ]]; then
      if [[ ! " ${TOP_FUNCTIONS[@]:-} " =~ " ${sym_base} " ]]; then
        TOP_FUNCTIONS+=("${sym_base}")
        echo "  $(printf '%5s' "${pct}")%  →  ${sym_base}"
      fi
      [[ ${#TOP_FUNCTIONS[@]} -ge ${TOP_N} ]] && break
    fi
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
  die "Nessuna funzione muDock trovata nel report."
fi
ok "Trovate ${#TOP_FUNCTIONS[@]} funzioni target"

# ===============================================================================
# STEP 2 — Aggiungi uprobes (entry) e retprobes (return) via perf probe
# ===============================================================================
step "STEP 2/4 — Aggiunta uprobes$([ ${USE_RETPROBE} -eq 1 ] && echo " + retprobes") (perf probe)"

BINARY="$(realpath ./build/application/muDock)"
PROBE_EVENTS=()        # eventi entry  → usati in perf record
RETPROBE_EVENTS=()     # eventi return → usati in perf record (se USE_RETPROBE=1)
# Mappa: nome evento entry → nome evento return (per il converter)
declare -A ENTRY_TO_RETURN

warn "Step 2 richiede sudo per aggiungere uprobes nel kernel tracefs."
echo "  Ti verrà chiesta la password una volta sola."

# Rimuovi probe residui da run precedenti
sudo "${PERF_BIN}" probe --del 'probe_muDock:*' 2>/dev/null || true
sudo "${PERF_BIN}" probe --del 'probe_mudock:*' 2>/dev/null || true

for sym_base in "${TOP_FUNCTIONS[@]}"; do
  echo ""
  info "Cerco mangled symbol per: ${sym_base}"

  # Trova il nome mangled tramite nm + c++filt
  MANGLED=""
  while IFS=" " read -r addr type m; do
    demangled=$(echo "${m}" | c++filt 2>/dev/null)
    if [[ "${demangled}" == "${sym_base}"* ]]; then
      MANGLED="${m}"
      break
    fi
  done < <(nm "${BINARY}" 2>/dev/null | grep ' [tTwW] ')

  if [[ -z "${MANGLED}" ]]; then
    warn "  Simbolo mangled non trovato per: ${sym_base} — salto"
    continue
  fi

  info "  Mangled: ${MANGLED:0:70}"

  # -- Aggiunta entry probe --------------------------------------------------─
  if sudo "${PERF_BIN}" probe \
      --exec "${BINARY}" \
      --add "${MANGLED}" \
      2>&1 | grep -v "^$"; then
    EVENT=$(sudo "${PERF_BIN}" probe --list 2>/dev/null \
            | grep -o "probe_[^:]*:[^ ]*" | grep -v "__return" | tail -1 || true)
    if [[ -n "${EVENT}" ]]; then
      PROBE_EVENTS+=("${EVENT}")
      ok "  Entry probe: ${EVENT}"
    fi
  else
    warn "  Entry probe fallita per: ${MANGLED:0:60} — salto"
    continue
  fi

  # -- Aggiunta return probe (se abilitata) ----------------------------------─
  if [[ "${USE_RETPROBE}" -eq 1 ]]; then
    if sudo "${PERF_BIN}" probe \
        --exec "${BINARY}" \
        --add "${MANGLED}%return" \
        2>&1 | grep -v "^$"; then
      RET_EVENT=$(sudo "${PERF_BIN}" probe --list 2>/dev/null \
              | grep -o "probe_[^:]*:[^ ]*__return" | tail -1 || true)
      if [[ -n "${RET_EVENT}" ]] && [[ -n "${EVENT}" ]]; then
        RETPROBE_EVENTS+=("${RET_EVENT}")
        ENTRY_TO_RETURN["${EVENT}"]="${RET_EVENT}"
        ok "  Return probe: ${RET_EVENT}"
      fi
    else
      warn "  Return probe non supportata per: ${sym_base} (inline/template) — solo entry"
    fi
  fi
done

echo ""

if [[ ${#PROBE_EVENTS[@]} -eq 0 ]]; then
  warn "Nessuna probe aggiunta. Fallback: perf record standard senza probe mirate."
  "${PERF_BIN}" record -g -o "${PERF_DATA_PROBE}" \
    -- ./build/application/muDock \
      --protein "${PROTEIN}" --ligand "${LIGAND}" \
      --use "${DEVICE}" --population "${POPULATION}" --generations "${GENERATIONS}" \
    2>&1
else
  # =============================================================================
  # STEP 3 — Esecuzione muDock con entry + return probe attive
  # =============================================================================
  step "STEP 3/4 — Esecuzione muDock con probe attive"

  ALL_EVENTS=("${PROBE_EVENTS[@]}" "${RETPROBE_EVENTS[@]}")
  info "Entry probes:  ${PROBE_EVENTS[*]}"
  [[ ${#RETPROBE_EVENTS[@]} -gt 0 ]] && \
    info "Return probes: ${RETPROBE_EVENTS[*]}"

  EVENT_ARGS=()
  for ev in "${ALL_EVENTS[@]}"; do
    EVENT_ARGS+=("-e" "${ev}")
  done

  sudo "${PERF_BIN}" record \
    -g \
    "${EVENT_ARGS[@]}" \
    -o "${PERF_DATA_PROBE}" \
    -- ./build/application/muDock \
      --protein "${PROTEIN}" \
      --ligand  "${LIGAND}" \
      --use     "${DEVICE}" \
      --population  "${POPULATION}" \
      --generations "${GENERATIONS}" \
    2>&1

  # Ripristina proprietà del file
  sudo chown "$(id -u):$(id -g)" "${PERF_DATA_PROBE}" || true

  ok "Run completato: ${PERF_DATA_PROBE} ($(du -h "${PERF_DATA_PROBE}" | cut -f1))"
fi

# Pulizia probe dopo il run
sudo "${PERF_BIN}" probe --del 'probe_mudock:*' 2>/dev/null || true
sudo "${PERF_BIN}" probe --del 'probe_muDock:*' 2>/dev/null || true

# ===============================================================================
# STEP 4 — Conversione in Perfetto JSON (con durate reali se retprobe attive)
# ===============================================================================
step "STEP 4/4 — Conversione in Perfetto JSON"

# Seleziona il converter: probe_to_perfetto.py (retprobe) o perf_to_perfetto.py (standard)
CONVERTER_DIR="${SCRIPT_DIR}/../perfetto_converters"

if [[ "${USE_RETPROBE}" -eq 1 ]] && [[ ${#RETPROBE_EVENTS[@]} -gt 0 ]] && \
   [[ -f "${CONVERTER_DIR}/probe_to_perfetto.py" ]]; then
  info "Uso probe_to_perfetto.py (slice con durata reale da retprobe)"
  # Passa la mappa entry→return come argomenti --pair entry:return
  PAIR_ARGS=()
  for entry_ev in "${!ENTRY_TO_RETURN[@]}"; do
    PAIR_ARGS+=("--pair" "${entry_ev}:${ENTRY_TO_RETURN[${entry_ev}]}")
  done
  python3 "${CONVERTER_DIR}/probe_to_perfetto.py" \
    "${PERF_DATA_PROBE}" "${TRACE_OUT}" \
    "${PAIR_ARGS[@]}" \
    && ok "Perfetto JSON con durate reali: ${TRACE_OUT}" \
    || {
      warn "probe_to_perfetto.py fallito, fallback su perf_to_perfetto.py standard"
      python3 "${CONVERTER_DIR}/perf_to_perfetto.py" "${PERF_DATA_PROBE}" "${TRACE_OUT}"
    }
elif [[ -f "${CONVERTER_DIR}/perf_to_perfetto.py" ]]; then
  info "Uso perf_to_perfetto.py (campionamento standard)"
  python3 "${CONVERTER_DIR}/perf_to_perfetto.py" "${PERF_DATA_PROBE}" "${TRACE_OUT}"
else
  die "Nessun converter trovato in ${CONVERTER_DIR}"
fi

# ===============================================================================
# (Opzionale) Analisi False Sharing con perf c2c
# ===============================================================================
if [[ "${USE_C2C}" -eq 1 ]]; then
  echo ""
  step "STEP BONUS — Analisi False Sharing (perf c2c)"

  C2C_DATA="traces/perf_c2c.data"
  info "Eseguo muDock con perf c2c record (campionamento load/store)..."
  warn "perf c2c richiede cpu-cycles:pp o mem_trans_retired — può richiedere sudo"

  sudo "${PERF_BIN}" c2c record \
    -o "${C2C_DATA}" \
    -- ./build/application/muDock \
      --protein "${PROTEIN}" \
      --ligand  "${LIGAND}" \
      --use     "${DEVICE}" \
      --population  "${POPULATION}" \
      --generations "${GENERATIONS}" \
    2>&1 || {
    warn "perf c2c record fallito (hardware non supportato o permessi insufficienti)"
    warn "Verifica: sudo perf c2c record --help"
    USE_C2C=0
  }

  if [[ "${USE_C2C}" -eq 1 ]]; then
    sudo chown "$(id -u):$(id -g)" "${C2C_DATA}" || true

    info "Generazione report False Sharing..."
    {
      echo "========================================================"
      echo "  perf c2c report — False Sharing Analysis"
      echo "  Data: $(date '+%Y-%m-%d %H:%M:%S')"
      echo "  File: ${C2C_DATA}"
      echo "========================================================"
      echo ""
      echo "--- RIEPILOGO CACHE LINE SHARING ---"
      echo ""
      # Report compatto: top cache line con sharing più alto
      "${PERF_BIN}" c2c report \
        -i "${C2C_DATA}" \
        --stdio \
        -s offset,pid,tid \
        2>/dev/null | head -80 || true
      echo ""
      echo "--- INTERPRETAZIONE ---"
      echo ""
      echo "  Lcl Hitm  = Local HITM (True/False Sharing sulla stessa CPU socket)"
      echo "  Rmt Hitm  = Remote HITM (sharing cross-socket — molto più costoso)"
      echo "  LLC Miss  = Accessi andati in RAM (non in cache)"
      echo ""
      echo "  Se 'Lcl Hitm' o 'Rmt Hitm' > 5% del totale LOAD → possibile False Sharing."
      echo "  Controlla 'Symbol' e 'Data Symbol' per identificare la variabile condivisa."
      echo ""
      echo "--- COMMAND PER REPORT INTERATTIVO ---"
      echo ""
      echo "  sudo ${PERF_BIN} c2c report -i ${C2C_DATA} --stdio -s offset,pid,tid,iaddr"
    } | tee "${C2C_OUT}"

    ok "Report False Sharing: ${C2C_OUT}"
  fi
fi

# ===============================================================================
# Riepilogo finale
# ===============================================================================
echo ""
echo ""
echo "  +==========================================================+"
echo "  |          Low Level Probe — Pipeline completata        |"
echo "  +==========================================================╣"
printf  "  |  Trace:          %-39s |\n" "${TRACE_OUT}"
printf  "  |  Funzioni:       %-39s |\n" "${#PROBE_EVENTS[@]}/${TOP_N} tracciate (${RETPROBE_LABEL})"
[[ "${USE_C2C}" -eq 1 ]] && \
printf  "  |  c2c report:     %-39s |\n" "${C2C_OUT}"
echo "  |  Apri:           https://ui.perfetto.dev/              |"
echo "  +==========================================================+"
echo ""
