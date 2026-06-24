#!/usr/bin/env bash
# =============================================================================
# full_pipeline.sh  —  Orchestratore completo del profiling muDock (3 livelli)
# =============================================================================
#
# Esegue in sequenza i 3 livelli di profiling:
#
#   Livello 1 — System-wide (perf stat):
#     a) cpu_metrics.sh    → IPC, branch, stall, frontend stall
#     b) memory_metrics.sh → L1/LLC/TLB miss rate, MPKI
#
#   Livello 2 — Process-wide (LD_PRELOAD thread lifecycle):
#     c) profile_high_level.sh → timeline creazione/vita thread OpenMP
#
#   Livello 3 — Function-wide (uprobes + retprobe):
#     d) low_level_probe.sh → durata reale Top-N funzioni muDock
#
#   (Opzionale) False Sharing:
#     e) perf c2c → analisi cache line sharing tra thread
#
# Utilizzo:
#   ./full_pipeline.sh [opzioni]
#
# Opzioni:
#   --exe PATH          Binario muDock da profilare (default: ./build/application/muDock)
#   --protein PATH      File proteina per muDock (default: data/1fkb/1fkb_protein.pdb)
#   --ligand  PATH      File ligando per muDock  (default: data/1fkb/1fkb_ligand.mol2)
#   --use DEVICE        Backend muDock           (default: CPP:CPU:0)
#   --population N      Dimensione popolazione GA (default: 100)
#   --generations N     Numero generazioni GA    (default: 100)
#   --top N             Top-N funzioni per il Livello 3 (default: 3)
#   --repeat N          Repeat per cpu/memory metrics (default: 3)
#   --warmup N          Warmup run per cpu/memory metrics (default: 1)
#   --out-dir DIR       Directory output (default: ./traces/full_pipeline/)
#   --skip-l1           Salta Livello 1 (cpu + memory metrics)
#   --skip-l2           Salta Livello 2 (thread lifecycle LD_PRELOAD)
#   --skip-l3           Salta Livello 3 (uprobes / retprobe)
#   --c2c               Esegui anche analisi False Sharing con perf c2c
#   --no-browser        Non aprire Perfetto automaticamente alla fine
#
# Esempi:
#   # Pipeline completa standard:
#   ./full_pipeline.sh --population 100 --generations 100
#
#   # Solo Livello 1 + 3 (salta LD_PRELOAD):
#   ./full_pipeline.sh --skip-l2
#
#   # Con analisi False Sharing:
#   ./full_pipeline.sh --c2c --top 5
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# -- Risolvi MUDOCK_ROOT ------------------------------------------------------─
if [[ -d "${SCRIPT_DIR}/../muDock" ]]; then
  MUDOCK_ROOT="$(cd "${SCRIPT_DIR}/../muDock" && pwd)"
elif [[ -d "${SCRIPT_DIR}/../../muDock" ]]; then
  MUDOCK_ROOT="$(cd "${SCRIPT_DIR}/../../muDock" && pwd)"
else
  echo "[ERROR] Impossibile trovare la cartella root di muDock" >&2
  exit 1
fi
cd "${MUDOCK_ROOT}"

CPU_SCRIPTS="${SCRIPT_DIR}/cpu"

# -- Default --------------------------------------------------------------------
EXE="./build/application/muDock"
PROTEIN="data/1fkb/1fkb_protein.pdb"
# LIGAND="data/1fkb/1fkb_ligand.mol2"
LIGAND="data/1fkb/1fkb_ligand.adtmol2"
DEVICE="CPP:CPU:0"
POPULATION=100
GENERATIONS=100
TOP_N=3
REPEAT=3
WARMUP=1
OUT_DIR="traces/full_pipeline"
SKIP_L1=0
SKIP_L2=0
SKIP_L3=0
USE_C2C=0
OPEN_BROWSER=1

# -- Parsing argomenti ----------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
  --exe)
    EXE="$2"
    shift
    ;;
  --protein)
    PROTEIN="$2"
    shift
    ;;
  --ligand)
    LIGAND="$2"
    shift
    ;;
  --use)
    DEVICE="$2"
    shift
    ;;
  --population)
    POPULATION="$2"
    shift
    ;;
  --generations)
    GENERATIONS="$2"
    shift
    ;;
  --top)
    TOP_N="$2"
    shift
    ;;
  --repeat)
    REPEAT="$2"
    shift
    ;;
  --warmup)
    WARMUP="$2"
    shift
    ;;
  --out-dir)
    OUT_DIR="$2"
    shift
    ;;
  --skip-l1) SKIP_L1=1 ;;
  --skip-l2) SKIP_L2=1 ;;
  --skip-l3) SKIP_L3=1 ;;
  --c2c) USE_C2C=1 ;;
  --no-browser) OPEN_BROWSER=0 ;;
  -h | --help)
    sed -n '2,50p' "$0" | sed 's/^# \?//'
    exit 0
    ;;
  *) echo "[WARN] Argomento sconosciuto: $1" ;;
  esac
  shift
done

# -- Colori --------------------------------------------------------------------─
BOLD=''
CYAN=''
GREEN=''
YELLOW=''
RED=''
BLUE=''
MAGENTA=''
NC=''

step() { echo -e "\n${BOLD}${CYAN}+== $* ==+${NC}"; }
ok() { echo -e "${GREEN}  [OK]${NC}  $*"; }
warn() { echo -e "${YELLOW}  [WARN]${NC}  $*"; }
info() { echo -e "${BLUE}  [INFO]${NC}  $*"; }
die() {
  echo -e "${RED}  [FAIL]${NC}  $*" >&2
  exit 1
}
phase() {
  echo -e "\n${BOLD}${MAGENTA}------------------------------------------------------------${NC}"
  echo -e "${BOLD}${MAGENTA}  $*${NC}"
  echo -e "${BOLD}${MAGENTA}------------------------------------------------------------${NC}"
}

# -- Banner --------------------------------------------------------------------
echo -e "${BOLD}"
echo "  +----------------------------------------------------------------+"
echo "  |             muDock — Full Profiling Pipeline                  |"
echo "  |   Livello 1: perf stat  |  Livello 2: LD_PRELOAD  |  L3: uprobes |"
echo "  +----------------------------------------------------------------+"
echo -e "${NC}"

info "EXE:        ${EXE}"
info "Dataset:    ${PROTEIN} + ${LIGAND}"
info "Backend:    ${DEVICE}"
info "GA:         pop=${POPULATION}  gen=${GENERATIONS}"
info "Out dir:    ${OUT_DIR}/"
info "L1 (perf):  repeat=${REPEAT}  warmup=${WARMUP}"
info "L3 (probe): top=${TOP_N}  c2c=$([ ${USE_C2C} -eq 1 ] && echo sì || echo no)"
echo ""

# -- Prerequisiti --------------------------------------------------------------─
[[ -x "${EXE}" ]] || die "Binario non trovato o non eseguibile: ${EXE}"
[[ -f "${PROTEIN}" ]] || die "File proteina non trovato: ${PROTEIN}"
[[ -f "${LIGAND}" ]] || die "File ligando non trovato: ${LIGAND}"

mkdir -p "${OUT_DIR}"
START_TIME=$(date +%s)

# Registro di tutti i file generati (per il riepilogo finale)
declare -a OUTPUT_FILES=()
# ==============================================================================
#
# LIVELLO 1A — CPU Metrics (IPC, branch, stall)
#
#
if [[ "${SKIP_L1}" -eq 0 ]]; then
  phase "LIVELLO 1A — CPU Metrics (IPC, branch, stall)"

  CPU_SCRIPT="${CPU_SCRIPTS}/perf_stat/cpu_metrics.sh"
  [[ -x "${CPU_SCRIPT}" ]] || die "Script non trovato: ${CPU_SCRIPT}"

  L1A_DIR="${OUT_DIR}/l1_cpu"
  mkdir -p "${L1A_DIR}"

  "${CPU_SCRIPT}" \
    --exe "${EXE}" \
    --args "--protein ${PROTEIN} --ligand ${LIGAND} --use ${DEVICE} --population ${POPULATION} --generations ${GENERATIONS}" \
    --out-dir "${L1A_DIR}" \
    --repeat "${REPEAT}" \
    --warmup "${WARMUP}" \
    --csv &&
    ok "Livello 1A completato" ||
    warn "Livello 1A completato con errori (controlla l'output)"

  OUTPUT_FILES+=("${L1A_DIR}/cpu_metrics.txt")
  OUTPUT_FILES+=("${L1A_DIR}/cpu_metrics.json")

  # ----------------------------------------------------------------------------
  # LIVELLO 1B — Memory Metrics (cache, TLB, MPKI)
  #
  #
  phase "LIVELLO 1B — Memory Metrics (cache / TLB / MPKI)"

  MEM_SCRIPT="${CPU_SCRIPTS}/perf_stat/memory_metrics.sh"
  [[ -x "${MEM_SCRIPT}" ]] || die "Script non trovato: ${MEM_SCRIPT}"

  L1B_DIR="${OUT_DIR}/l1_memory"
  mkdir -p "${L1B_DIR}"

  "${MEM_SCRIPT}" \
    --exe "${EXE}" \
    --args "--protein ${PROTEIN} --ligand ${LIGAND} --use ${DEVICE} --population ${POPULATION} --generations ${GENERATIONS}" \
    --out-dir "${L1B_DIR}" \
    --repeat "${REPEAT}" \
    --warmup "${WARMUP}" \
    --csv &&
    ok "Livello 1B completato" ||
    warn "Livello 1B completato con errori"

  OUTPUT_FILES+=("${L1B_DIR}/memory_metrics.txt")
  OUTPUT_FILES+=("${L1B_DIR}/memory_metrics.json")
else
  warn "Livello 1 saltato (--skip-l1)"
fi

# ==============================================================================
# LIVELLO 2 — Thread Lifecycle (LD_PRELOAD libhigh_level.so)
# ==============================================================================
if [[ "${SKIP_L2}" -eq 0 ]]; then
  phase "LIVELLO 2 — Thread Lifecycle (LD_PRELOAD)"

  HL_SCRIPT="${CPU_SCRIPTS}/high_level/profile_high_level.sh"
  [[ -x "${HL_SCRIPT}" ]] || {
    warn "Script non trovato: ${HL_SCRIPT}"
    warn "Provo a compilare la libreria ..."
    make -C "${CPU_SCRIPTS}/high_level" libhigh_level.so 2>&1 | tail -3 || true
  }

  L2_TRACE="${OUT_DIR}/l2_threads/trace_high_level.json"
  mkdir -p "${OUT_DIR}/l2_threads"

  if [[ -x "${HL_SCRIPT}" ]]; then
    "${HL_SCRIPT}" \
      --population "${POPULATION}" \
      --generations "${GENERATIONS}" \
      --out-dir "${OUT_DIR}/l2_threads" \
      --no-browser &&
      ok "Livello 2 completato" ||
      warn "Livello 2 completato con errori"
    OUTPUT_FILES+=("${L2_TRACE}")
  else
    # Fallback: esegui direttamente con LD_PRELOAD
    HL_SO="${CPU_SCRIPTS}/high_level/libhigh_level.so"
    if [[ -f "${HL_SO}" ]]; then
      info "Eseguo con LD_PRELOAD direttamente ..."
      LD_PRELOAD="${HL_SO}" \
        MUDOCK_TRACE_HL_OUT="${L2_TRACE}" \
        "${EXE}" \
        --protein "${PROTEIN}" \
        --ligand "${LIGAND}" \
        --use "${DEVICE}" \
        --population "${POPULATION}" \
        --generations "${GENERATIONS}" \
        2>&1 | tail -5
      ok "Livello 2 completato (LD_PRELOAD diretto)"
      OUTPUT_FILES+=("${L2_TRACE}")
    else
      warn "libhigh_level.so non trovata. Compila con: make -C ${CPU_SCRIPTS}/high_level"
      warn "Livello 2 saltato"
    fi
  fi
else
  warn "Livello 2 saltato (--skip-l2)"
fi

# ==============================================================================
# LIVELLO 3 — Function-wide (uprobes + retprobe sulle Top-N funzioni)
# ==============================================================================
if [[ "${SKIP_L3}" -eq 0 ]]; then
  phase "LIVELLO 3 — Function-wide (uprobes + retprobe)"

  # Per il Livello 3 serve un perf.data di input per la discovery
  # Se non esiste in traces/, lo generiamo con un perf record veloce
  PERF_DATA_BASE="${MUDOCK_ROOT}/traces/perf.data"

  if [[ ! -f "${PERF_DATA_BASE}" ]]; then
    info "traces/perf.data non trovato, genero con perf record ..."

    PERF_BIN=""
    for candidate in \
      "/usr/lib/linux-tools/$(uname -r)/perf" \
      "$(ls /usr/lib/linux-tools/*/perf 2>/dev/null | sort -V | tail -1)" \
      "perf"; do
      [[ -x "${candidate}" ]] && {
        PERF_BIN="${candidate}"
        break
      }
    done
    [[ -n "${PERF_BIN}" ]] || die "'perf' non trovato"

    mkdir -p "${MUDOCK_ROOT}/traces"
    "${PERF_BIN}" record \
      -g \
      --call-graph dwarf \
      -o "${PERF_DATA_BASE}" \
      -- "${EXE}" \
      --protein "${PROTEIN}" \
      --ligand "${LIGAND}" \
      --use "${DEVICE}" \
      --population "${POPULATION}" \
      --generations "${GENERATIONS}" \
      2>&1 | tail -3
    ok "perf.data generato: ${PERF_DATA_BASE} ($(du -h "${PERF_DATA_BASE}" | cut -f1))"
  else
    ok "Uso perf.data esistente: ${PERF_DATA_BASE}"
  fi

  L3_SCRIPT="${CPU_SCRIPTS}/low_level/low_level_probe.sh"
  [[ -x "${L3_SCRIPT}" ]] || die "Script non trovato: ${L3_SCRIPT}"

  L3_TRACE="${OUT_DIR}/l3_functions/trace_low_level.json"
  mkdir -p "${OUT_DIR}/l3_functions"

  C2C_ARGS=()
  [[ "${USE_C2C}" -eq 1 ]] && C2C_ARGS=("--c2c" "--c2c-out" "${OUT_DIR}/l3_functions/c2c_report.txt")

  "${L3_SCRIPT}" \
    --top "${TOP_N}" \
    --perf-data "${PERF_DATA_BASE}" \
    --output "${L3_TRACE}" \
    --population "${POPULATION}" \
    --generations "${GENERATIONS}" \
    --retprobe \
    "${C2C_ARGS[@]}" &&
    ok "Livello 3 completato" ||
    warn "Livello 3 completato con errori (controlla l'output)"

  OUTPUT_FILES+=("${L3_TRACE}")
  [[ "${USE_C2C}" -eq 1 ]] &&
    OUTPUT_FILES+=("${OUT_DIR}/l3_functions/c2c_report.txt")
else
  warn "Livello 3 saltato (--skip-l3)"
fi

# ==============================================================================
# Riepilogo finale
# ==============================================================================
END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))
ELAPSED_MIN=$((ELAPSED / 60))
ELAPSED_SEC=$((ELAPSED % 60))

echo ""
echo -e "${BOLD}${GREEN}"
echo "  +=================================================================+"
echo "  +=================================================================╣"
printf "  |  Durata totale: %dm %ds%-40s |\n" "${ELAPSED_MIN}" "${ELAPSED_SEC}" ""
echo "  +=================================================================╣"
echo "  |  File generati:                                                |"
for f in "${OUTPUT_FILES[@]}"; do
  if [[ -f "${f}" ]]; then
    SIZE="$(du -h "${f}" | cut -f1)"
    printf "  |    [OK] %-54s |\n" "$(basename "${f}")  (${SIZE})"
  fi
done
echo "  +=================================================================╣"
echo "  |  Apri le tracce .json su:  https://ui.perfetto.dev/           |"
echo "  +=================================================================+"
echo -e "${NC}"

# Apri automaticamente Perfetto con la prima traccia disponibile
if [[ "${OPEN_BROWSER}" -eq 1 ]]; then
  FIRST_JSON=""
  for f in "${OUTPUT_FILES[@]}"; do
    [[ "${f}" == *.json ]] && [[ -f "${f}" ]] && {
      FIRST_JSON="${f}"
      break
    }
  done

  if [[ -n "${FIRST_JSON}" ]]; then
    HTTP_PORT=9003
    lsof -ti tcp:"${HTTP_PORT}" | xargs kill -9 2>/dev/null || true
    python3 -m http.server "${HTTP_PORT}" \
      --directory "${MUDOCK_ROOT}" \
      >/dev/null 2>&1 &
    sleep 1
    PERFETTO_URL="https://ui.perfetto.dev/#!/?url=http://localhost:${HTTP_PORT}/${FIRST_JSON}"
    for BROWSER_CMD in xdg-open google-chrome chromium-browser firefox; do
      if command -v "${BROWSER_CMD}" &>/dev/null; then
        "${BROWSER_CMD}" "${PERFETTO_URL}" &>/dev/null &
        ok "Browser aperto con la prima traccia: $(basename "${FIRST_JSON}")"
        break
      fi
    done
  fi
fi

ok "Output directory: ${MUDOCK_ROOT}/${OUT_DIR}/"
