#!/usr/bin/env bash
# =======================================================================ligands100.adtmol2 #   ./<profile_dir>/cpu/perf_stat/base_converter.sh [opzioni]
#
# Opzioni:
#   --skip-build        Salta la compilazione (usa il binario esistente)
#   --convert-only      Salta build E esecuzione, converte perf.data esistente
#   --clean             Forza una build pulita (rm -rf build)
#   --debug-build       Compila con -Og -fno-inline (simboli completi per perf probe)
#                       Usa questa modalità prima di low_level_probe.sh per tracciare
#                       anche funzioni inlinate (calc_energy, costruttori, ecc.)
#   --population N      Numero di popolazioni (default: 100)
#   --generations N     Numero di generazioni (default: 100)
#   --no-browser        Non aprire il browser automaticamente
#
# Output:
#   traces/perf.data           Dati raw del campionamento hardware
#   traces/trace_perf.json     Traccia Perfetto pronta (aperta automaticamente)
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

# -- Parametri default --

POPULATION=100
GENERATIONS=100
CLEAN_BUILD=0
SKIP_BUILD=0
CONVERT_ONLY=0
OPEN_BROWSER=1
DEBUG_BUILD=0
PROTEIN="data/1fkb/1fkb_protein.pdb"
# LIGAND="data/1fkb/1fkb_ligand.mol2"
LIGAND="data/1fkb/ligands100.adtmol2"
DEVICE="CPP:CPU:0"
PERF_DATA="traces/perf.data"
TRACE_OUT="traces/trace_perf.json"
HTTP_PORT=9001

PERF_BIN="/usr/lib/linux-tools/6.8.0-117-generic/perf"
[[ -x "${PERF_BIN}" ]] || PERF_BIN="perf"

# -- Argomenti CLI --
while [[ $# -gt 0 ]]; do
  case "$1" in
  --clean) CLEAN_BUILD=1 ;;
  --skip-build) SKIP_BUILD=1 ;;
  --debug-build)
    DEBUG_BUILD=1
    CLEAN_BUILD=1 # forza rebuild pulita per cambiare i flag del compilatore
    ;;
  --convert-only)
    CONVERT_ONLY=1
    SKIP_BUILD=1
    ;;
  --no-browser) OPEN_BROWSER=0 ;;
  --population)
    POPULATION="$2"
    shift
    ;;
  --generations)
    GENERATIONS="$2"
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
  --port)
    HTTP_PORT="$2"
    shift
    ;;
  -h | --help)
    sed -n '2,20p' "$0" | sed 's/^# \?//'
    exit 0
    ;;
  *) echo "[WARN] Argomento sconosciuto: $1" ;;
  esac
  shift
done

# -- simboli --

step() { echo -e "\n== $* =="; }
ok() { echo "  [OK]  $*"; }
warn() { echo "  [WARN]  $*"; }
die() {
  echo "  [FAIL]  $*" >&2
  exit 1
}

echo ""
echo "  +----------------------------------------------------─+"
echo "  |         muDock — Base Converter Pipeline            |"
echo "  |     perf record → JSON → Perfetto (browser)        |"
echo "  +----------------------------------------------------─+"
echo ""

#  Build (opzionale)
mkdir -p "${MUDOCK_ROOT}/traces"
if [[ "${SKIP_BUILD}" -eq 0 ]]; then
  step "STEP 1/3 — Build"

  # Spack
  if command -v spack &>/dev/null; then
    eval "$(spack env activate --sh mudock_zen5 2>/dev/null)" || true
    CMAKE_BIN="$(spack location -i cmake@3.31.11)/bin/cmake"
  else
    die "spack non trovato. Esegui: source ~/spack/share/spack/setup-env.sh"
  fi

  [[ "${CLEAN_BUILD}" -eq 1 ]] && {
    warn "Pulizia cartella build ..."
    rm -rf build
  }

  mkdir -p build && cd build

  # Anti-CUDA stubs
  mkdir -p fake_cmake
  cat >fake_cmake/FindCUDAToolkit.cmake <<'EOF'
set(CUDAToolkit_FOUND TRUE)
add_library(CUDA::toolkit INTERFACE IMPORTED)
add_library(CUDA::cudart INTERFACE IMPORTED)
EOF

  # Build type: RelWithDebInfo (default) oppure Debug+noinline (per le uprobes)
  if [[ "${DEBUG_BUILD}" -eq 1 ]]; then
    BUILD_TYPE="Debug"
    EXTRA_CXX_FLAGS="-Og -fno-inline -fno-inline-functions -fno-inline-small-functions"
    warn "Modalità DEBUG_BUILD attiva: -Og -fno-inline (ideale per perf probe / uprobes)"
    warn "ATTENZIONE: le performance saranno degradate — usa solo per profiling con low_level_probe.sh"
  else
    BUILD_TYPE="RelWithDebInfo"
    EXTRA_CXX_FLAGS=""
  fi

  "${CMAKE_BIN}" .. \
    -DCMAKE_C_COMPILER=gcc-14 \
    -DCMAKE_CXX_COMPILER=g++-14 \
    -DCMAKE_POLICY_DEFAULT_CMP0144=NEW \
    -DCMAKE_MODULE_PATH="$(pwd)/fake_cmake" \
    -DMUDOCK_ENABLE_SYCL=OFF \
    -DMUDOCK_ENABLE_OMP=ON \
    -DMUDOCK_ENABLE_GH=ON \
    -DMUDOCK_GPU_ARCHITECTURES="none" \
    -DMUDOCK_CPU_TARGET="native" \
    -DCMAKE_BUILD_TYPE="${BUILD_TYPE}" \
    ${EXTRA_CXX_FLAGS:+-DCMAKE_CXX_FLAGS="${EXTRA_CXX_FLAGS}"} \
    -DCMAKE_PREFIX_PATH="$(spack location -i boost@1.90.0);$(spack location -i highway);$(spack location -i openbabel)" \
    2>&1 | grep -E "^(CMake (Error|Warning)|--)" | grep -v "^-- /\|^-- Found\|^-- Check"

  make -j 8 2>&1 | grep -E "^\[|^(Linking|Building|Error)"
  ok "Build completata (${BUILD_TYPE}${DEBUG_BUILD:+ — simboli completi, noinline})"
  cd "${MUDOCK_ROOT}"
fi

[[ -f "./build/application/muDock" ]] || die "Binario non trovato. Rimuovi --skip-build."

# perf record
if [[ "${CONVERT_ONLY}" -eq 0 ]]; then
  step "STEP 2/3 — Esecuzione con perf record"
  echo "  Population=${POPULATION}  Generations=${GENERATIONS}"
  echo "  Protein: ${PROTEIN}"

  # Sblocca contatori hardware
  PARANOIA=$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo "4")
  if [[ "${PARANOIA}" -gt 0 ]]; then
    warn "perf_event_paranoid=${PARANOIA} → sblocco temporaneo..."
    sudo sysctl -w kernel.perf_event_paranoid=-1 ||
      warn "Sblocco fallito — la traccia potrebbe essere parziale"
  fi

  echo ""
  "${PERF_BIN}" record \
    -g \
    --call-graph dwarf \
    -o "${PERF_DATA}" \
    -- ./build/application/muDock \
    --protein "${PROTEIN}" \
    --ligand "${LIGAND}" \
    --use "${DEVICE}" \
    --population "${POPULATION}" \
    --generations "${GENERATIONS}" \
    2>&1

  echo ""
  ok "Registrazione completata: ${PERF_DATA}  ($(du -h "${PERF_DATA}" | cut -f1))"
else
  step "STEP 2/3 — Saltato (modalità convert-only)"
  [[ -f "${PERF_DATA}" ]] || die "Nessun ${PERF_DATA} trovato. Rimuovi --convert-only."
  ok "Uso perf.data esistente: $(du -h "${PERF_DATA}" | cut -f1)"
fi

# Conversione + apertura browser
step "STEP 3/3 — Conversione in Perfetto JSON"

python3 "${SCRIPT_DIR}/../perfetto_converters/perf_to_perfetto.py" "${PERF_DATA}" "${TRACE_OUT}"

# -- Apertura automatica del browser --
if [[ "${OPEN_BROWSER}" -eq 1 ]]; then
  echo ""
  echo "  Avvio server HTTP locale su porta ${HTTP_PORT} ..."

  # Termina server precedenti sulla stessa porta
  lsof -ti tcp:"${HTTP_PORT}" | xargs kill -9 2>/dev/null || true

  # Avvia server in background
  python3 -m http.server "${HTTP_PORT}" \
    --directory "${MUDOCK_ROOT}" \
    >/dev/null 2>&1 &
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

# Riepilogo finale
echo ""
echo ""
echo "  +=======================================================+"
echo "  |              Pipeline completata!                  |"
echo "  +=======================================================╣"
printf "  |  Trace: %-45s |\n" "${MUDOCK_ROOT}/${TRACE_OUT}  ($(du -h "${TRACE_OUT}" | cut -f1))"
echo "  |  Apri:  https://ui.perfetto.dev/                     |"
echo "  +=======================================================+"
echo ""
