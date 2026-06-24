#!/usr/bin/env bash
# ww
# Pipeline completa:
#   1. Carica l'ambiente Spack (mudock_zen5) e il modulo Score-P
#   2. Compila muDock con i wrapper scorep-g++/scorep-gcc in build_scorep/
#   3. Esegue muDock con Score-P abilitato:
#        - TRACING  → traces/scorep_trace/traces.otf2  (timeline)
#        - PROFILING → traces/scorep_trace/profile.cubex (metriche aggregate)
#   4. Converte la traccia OTF2 → JSON Perfetto (visualizzazione browser)
#   5. Avvia server HTTP e apre ui.perfetto.dev automaticamente
#
# Utilizzo:
#   ./cpu/score/profile_scorep.sh [opzioni]
#
# Opzioni:
#   --skip-build        Salta la compilazione (usa l'eseguibile già compilato)
#   --no-browser        Non aprire il browser automaticamente
#   --population N      Dimensione della popolazione del GA (default: 100)
#   --generations N     Numero di generazioni del GA (default: 100)
#   --out-dir DIR       Directory di output (default: traces/)
#   --port PORT         Porta del server HTTP (default: 9003)
#   --compiler COMPILER Seleziona compilatore: gcc o clang (default: gcc)
#
#   visualizzazione con cube :
#   cube ~/UNI/progetto_aca/muDock/traces/scorep_trace/profile.cubex
#

# Protezione
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
  echo "[ERROR] Non eseguire con 'source'. Usa direttamente:" >&2
  echo "        ./cpu/score/profile_scorep.sh [opzioni]" >&2
  return 1 2>/dev/null || exit 1
fi

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

# -- Parametri default --
POPULATION=100
GENERATIONS=100
SKIP_BUILD=0
OPEN_BROWSER=1
OUT_DIR=""
PROTEIN="data/1fkb/1fkb_protein.pdb"
# LIGAND="data/1fkb/1fkb_ligand.mol2"
LIGAND="data/1fkb/1fkb_ligand.adtmol2"
DEVICE="CPP:CPU:0"
HTTP_PORT=9003
COMPILER="gcc"

# -- Argomenti CLI --
# while [[ $# -gt 0 ]]; do
#   case "$1" in
#   --skip-build) SKIP_BUILD=1 ;;
#   --no-browser) OPEN_BROWSER=0 ;;
#   --population)
#     POPULATION="$2"
#     shift
#     ;;
#   --generations)
#     GENERATIONS="$2"
#     shift
#     ;;
#   --out-dir)
#     OUT_DIR="$2"
#     shift
#     ;;
#   --protein)
#     PROTEIN="$2"
#     shift
#     ;;
#   --ligand)
#     LIGAND="$2"
#     shift
#     ;;
#   --port)
#     HTTP_PORT="$2"
#     shift
#     ;;
#   -h | --help)
#     sed -n '2,19p' "$0" | sed 's/^# \?//'
#     exit 0
#     ;;
#   *) echo "[WARN] Argomento sconosciuto: $1" ;;
#   esac
#   shift
# done

while [[ $# -gt 0 ]]; do
  case "$1" in
  --skip-build) SKIP_BUILD=1 ;;
  --no-browser) OPEN_BROWSER=0 ;;
  --population)
    POPULATION="$2"
    shift
    ;;
  --generations)
    GENERATIONS="$2"
    shift
    ;;
  --out-dir)
    OUT_DIR="$2"
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
  --compiler)
    COMPILER="$2"
    if [[ "${COMPILER}" != "gcc" && "${COMPILER}" != "clang" ]]; then
      echo "[ERROR] Compilatore non supportato: ${COMPILER}. Scegli 'gcc' o 'clang'." >&2
      exit 1
    fi
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

if [[ -z "${OUT_DIR}" ]]; then
  OUT_DIR="${MUDOCK_ROOT}/traces"
fi
mkdir -p "${OUT_DIR}"

# -- Colori --
step() { echo -e "\n== $* =="; }
ok() { echo "  [OK]  $*"; }
warn() { echo "  [WARN]  $*"; }
die() {
  echo "  [FAIL]  $*" >&2
  exit 1
}

echo ""
echo "  +----------------------------------------------------------+"
echo "  |        muDock — Score-P Profiling & Tracing             |"
echo "  |   Tracing → OTF2 + Perfetto  |  Profiling → Cube GUI   |"
echo "  +----------------------------------------------------------+"
echo ""

# Caricamento ambiente Spack e Score-P

step "STEP 1/5 — Caricamento ambiente Spack e Score-P"

[[ -f "/home/olly/spack/share/spack/setup-env.sh" ]] ||
  die "setup-env.sh Spack non trovato in /home/olly/spack"

source /home/olly/spack/share/spack/setup-env.sh
eval "$(spack env activate --sh mudock_zen5 2>/dev/null)" || true
spack load scorep
CMAKE_BIN="$(spack location -i cmake@3.31.11)/bin/cmake"

ok "Score-P caricato:  $(scorep --version)"
ok "CMake:             ${CMAKE_BIN}"

# Compilazione muDock con wrapper Score-P

BUILD_DIR="${MUDOCK_ROOT}/build_scorep"
EXE_PATH="${BUILD_DIR}/application/muDock"

if [[ "${SKIP_BUILD}" -eq 0 ]]; then
  step "STEP 2/5 — Compilazione muDock in '${BUILD_DIR}'"

  # --nocompiler  → disabilita la strumentazione per-funzione (evita overhead senza plugin GCC)
  # --thread=omp  → strumentazione OpenMP via OPARI2 (parallel, barrier, work)
  export SCOREP_WRAPPER_INSTRUMENTER_FLAGS="--nocompiler --thread=omp:opari2"

  mkdir -p "${BUILD_DIR}"
  cd "${BUILD_DIR}"

  # Stub anti-CUDA
  mkdir -p fake_cmake
  cat >fake_cmake/FindCUDAToolkit.cmake <<'EOF'
set(CUDAToolkit_FOUND TRUE)
add_library(CUDA::toolkit INTERFACE IMPORTED)
add_library(CUDA::cudart INTERFACE IMPORTED)
EOF

  # "${CMAKE_BIN}" "${MUDOCK_ROOT}" \
  #   -DCMAKE_CXX_COMPILER=scorep-g++ \
  #   -DCMAKE_C_COMPILER=scorep-gcc \
  #   -DCMAKE_POLICY_DEFAULT_CMP0144=NEW \
  #   -DCMAKE_MODULE_PATH="$(pwd)/fake_cmake" \
  #   -DMUDOCK_ENABLE_SYCL=OFF \
  #   -DMUDOCK_ENABLE_OMP=ON \
  #   -DMUDOCK_ENABLE_GH=ON \
  #   -DMUDOCK_GPU_ARCHITECTURES="none" \
  #   -DMUDOCK_CPU_TARGET="native" \
  #   -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  #   -DCMAKE_PREFIX_PATH="$(spack location -i boost@1.90.0);$(spack location -i highway);$(spack location -i openbabel)" \
  #   2>&1 | grep -E "^(CMake (Error|Warning)|--)" |
  #   grep -v "^-- /\|^-- Found\|^-- Check" || true

  # c_compiler="scorep-gcc"
  # cxx_compiler="scorep-g++"
  # if [[ "${COMPILER}" == "clang" ]]; then
  #   c_compiler="scorep-clang"
  #   cxx_compiler="scorep-clang++"
  # fi

  c_compiler="scorep-gcc"
  cxx_compiler="scorep-g++"
  if [[ "${COMPILER}" == "clang" ]]; then
    # Create the clang/clang++ wrappers in build_scorep/bin since they don't exist by default
    wrapper_bin_dir="${BUILD_DIR}/bin"
    mkdir -p "${wrapper_bin_dir}"
    scorep_root="$(spack location -i scorep)"
    
    if [[ ! -f "${wrapper_bin_dir}/scorep-clang" ]]; then
      "${scorep_root}/bin/scorep-wrapper" --create clang "${wrapper_bin_dir}" >/dev/null
    fi
    if [[ ! -f "${wrapper_bin_dir}/scorep-clang++" ]]; then
      "${scorep_root}/bin/scorep-wrapper" --create clang++ "${wrapper_bin_dir}" >/dev/null
    fi
    
    c_compiler="${wrapper_bin_dir}/scorep-clang"
    cxx_compiler="${wrapper_bin_dir}/scorep-clang++"
  fi

  "${CMAKE_BIN}" "${MUDOCK_ROOT}" \
    -DCMAKE_CXX_COMPILER="${cxx_compiler}" \
    -DCMAKE_C_COMPILER="${c_compiler}" \
    -DCMAKE_POLICY_DEFAULT_CMP0144=NEW \
    -DCMAKE_MODULE_PATH="$(pwd)/fake_cmake" \
    -DMUDOCK_ENABLE_SYCL=OFF \
    -DMUDOCK_ENABLE_OMP=ON \
    -DMUDOCK_ENABLE_GH=ON \
    -DMUDOCK_GPU_ARCHITECTURES="none" \
    -DMUDOCK_CPU_TARGET="native" \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DCMAKE_PREFIX_PATH="$(spack location -i boost@1.90.0);$(spack location -i highway);$(spack location -i openbabel)" \
    2>&1 | grep -E "^(CMake (Error|Warning)|--)" |
    grep -v "^-- /\|^-- Found\|^-- Check" || true

  echo "  Compilazione in corso..."
  make -j"$(nproc)" 2>&1 | grep -E "^\[|^(Linking|Building|Error)" || true

  cd "${MUDOCK_ROOT}"
  ok "Compilazione completata → ${EXE_PATH}"
else
  step "STEP 2/5 — Compilazione saltata (--skip-build)"
  [[ -f "${EXE_PATH}" ]] || die "Binario non trovato in '${EXE_PATH}'. Rimuovi --skip-build."
  ok "Uso binario esistente: ${EXE_PATH}"
fi

# Esecuzione con Score-P (Tracing + Profiling)

step "STEP 3/5 — Esecuzione muDock con Score-P"

SCOREP_EXP_DIR="${OUT_DIR}/scorep_trace"
OTF2_PATH="${SCOREP_EXP_DIR}/traces.otf2"
CUBEX_PATH="${SCOREP_EXP_DIR}/profile.cubex"
RUN_LOG="${OUT_DIR}/scorep_run.log"

rm -rf "${SCOREP_EXP_DIR}"

# abilita sia la traccia OTF2 (timeline) che il profilo Cube (metriche)
export SCOREP_ENABLE_TRACING=true
export SCOREP_ENABLE_PROFILING=true
export SCOREP_TOTAL_MEMORY=512M
export SCOREP_FILTERING_FILE="${SCRIPT_DIR}/scorep.filter"
export SCOREP_EXPERIMENT_DIRECTORY="${SCOREP_EXP_DIR}"

# Metriche hardware via PAPI

if scorep-info config-summary 2>/dev/null | grep -q "PAPI"; then
  export SCOREP_METRIC_PAPI="PAPI_TOT_CYC,PAPI_TOT_INS,PAPI_L2_TCM"
  ok "PAPI disponibile: raccolta di PAPI_TOT_CYC, PAPI_TOT_INS, PAPI_L2_TCM"
else
  warn "PAPI non disponibile in questa build di Score-P — metriche hardware disabilitate"
fi

echo "  Population=${POPULATION}  Generations=${GENERATIONS}"
echo "  Output: ${SCOREP_EXP_DIR}"
echo "  Log:    ${RUN_LOG}"

cd "${MUDOCK_ROOT}"
if ! "${EXE_PATH}" \
  --protein "${PROTEIN}" \
  --ligand "${LIGAND}" \
  --use "${DEVICE}" \
  --population "${POPULATION}" \
  --generations "${GENERATIONS}" \
  >"${RUN_LOG}" 2>&1; then
  echo "[ERROR] muDock è terminato con errore. Ultimi log:"
  tail -n 20 "${RUN_LOG}"
  die "Esecuzione fallita."
fi

[[ -f "${OTF2_PATH}" ]] || die "Traccia OTF2 non trovata in ${SCOREP_EXP_DIR}."
[[ -f "${CUBEX_PATH}" ]] || warn "Profilo Cube (.cubex) non trovato — profiling potrebbe non essere attivo."

ok "Traccia OTF2:   ${OTF2_PATH}  ($(du -h "${OTF2_PATH}" | cut -f1))"
[[ -f "${CUBEX_PATH}" ]] && ok "Profilo Cube:   ${CUBEX_PATH} ($(du -h "${CUBEX_PATH}" | cut -f1))"

# Conversione OTF2 in perfetto JSON

step "STEP 4/5 — Conversione OTF2 → Perfetto JSON"

PERFETTO_JSON="${OUT_DIR}/scorep_perfetto.json"
CONVERTER="${SCRIPT_DIR}/otf2_to_perfetto.py"

[[ -f "${CONVERTER}" ]] || die "Convertitore non trovato: ${CONVERTER}"

if python3 "${CONVERTER}" "${OTF2_PATH}" "${PERFETTO_JSON}" 2>&1; then
  ok "Perfetto JSON: ${PERFETTO_JSON} ($(du -h "${PERFETTO_JSON}" | cut -f1))"
else
  warn "Conversione OTF2→Perfetto fallita (traccia OTF2 disponibile comunque)."
  PERFETTO_JSON=""
fi

# Apertura automatica Perfetto nel browser
step "STEP 5/5 — Apertura Perfetto nel browser"

if [[ -n "${PERFETTO_JSON}" && "${OPEN_BROWSER}" -eq 1 ]]; then
  # Termina server preced
  lsof -ti tcp:"${HTTP_PORT}" | xargs kill -9 2>/dev/null || true

  TRACE_REL=$(realpath --relative-to="${MUDOCK_ROOT}" "${PERFETTO_JSON}")
  python3 -m http.server "${HTTP_PORT}" --directory "${MUDOCK_ROOT}" \
    >/dev/null 2>&1 &
  HTTP_PID=$!
  sleep 1

  PERFETTO_URL="https://ui.perfetto.dev/#!/?url=http://localhost:${HTTP_PORT}/${TRACE_REL}"

  ok "Server HTTP avviato (PID ${HTTP_PID}) → http://localhost:${HTTP_PORT}"

  BROWSER_OPENED=0
  for CMD in xdg-open google-chrome chromium-browser firefox; do
    if command -v "${CMD}" &>/dev/null; then
      "${CMD}" "${PERFETTO_URL}" &>/dev/null &
      ok "Browser aperto: ${CMD}"
      BROWSER_OPENED=1
      break
    fi
  done
  [[ "${BROWSER_OPENED}" -eq 0 ]] &&
    warn "Nessun browser trovato. Apri manualmente: ${PERFETTO_URL}"

  echo ""
  echo "  Nota: server HTTP attivo (PID ${HTTP_PID}). Per fermarlo: kill ${HTTP_PID}"
elif [[ "${OPEN_BROWSER}" -eq 0 ]]; then
  ok "Apertura browser saltata (--no-browser)"
else
  warn "Nessun JSON Perfetto da aprire (conversione fallita al passo precedente)."
fi

echo ""
echo ""
echo "  +============================================================+"
echo "  |          Score-P Profiling completato!                   |"
echo "  +============================================================╣"
printf "  |  OTF2  (timeline):  %-38s |\n" "${OTF2_PATH}"
[[ -f "${CUBEX_PATH}" ]] && printf "  |  Cube  (profilo):   %-38s |\n" "${CUBEX_PATH}"
[[ -n "${PERFETTO_JSON}" ]] && printf "  |  Perfetto JSON:     %-38s |\n" "${PERFETTO_JSON}"
echo "  |                                                            |"
echo "  |  Visualizzazioni disponibili:                              |"
echo "  |    • Browser:  https://ui.perfetto.dev/  (carica il JSON) |"
[[ -f "${CUBEX_PATH}" ]] &&
  echo "  |    • Cube GUI: cube ${CUBEX_PATH##*/}          |"
echo "  |    • Testo:    otf2-print traces.otf2 | head -50          |"
echo "  +============================================================+"
echo ""
