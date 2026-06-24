#!/usr/bin/env bash
#
# Pipeline completa:
#   1. Compila libhigh_level.so o libperfetto_preload.so (se necessario)
#   2. Esegue muDock pre-caricando la libreria selezionata
#   3. Genera traces/trace_high_level.json o traces/muDock.pftrace
#   4. (Opzionale) Converte il JSON in formato traces/otf2_high_level/
#   5. Opzionalmente avvia server HTTP e apre Perfetto nel browser
#
# Utilizzo:
#   ./cpu/high_level/profile_high_level.sh [opzioni]
#
# Opzioni:
#   --native            Usa l'SDK Perfetto nativo in C++ (produce .pftrace direttamente)
#   --skip-build        Salta la compilazione delle librerie
#   --population N      Numero di popolazioni (default: 100)
#   --generations N     Numero di generazioni (default: 100)
#   --out-dir DIR       Directory di output (default: traces/)
#   --no-otf2           Disabilita la conversione in OTF2 (solo per traccia JSON)
#   --no-browser        Non aprire il browser automaticamente
#   --port PORT         Porta per il server HTTP locale (default: 9002)

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
SKIP_BUILD=0
OPEN_BROWSER=1
GEN_OTF2=1
USE_NATIVE=0
OUT_DIR=""
HTTP_PORT=9002
PROTEIN="data/1fkb/1fkb_protein.pdb"
# LIGAND="data/1fkb/1fkb_ligand.mol2"
LIGAND="data/1fkb/ligands100.adtmol2"
DEVICE="CPP:CPU:0"

# -- Argomenti CLI --
while [[ $# -gt 0 ]]; do
  case "$1" in
  --native) USE_NATIVE=1 ;;
  --skip-build) SKIP_BUILD=1 ;;
  --no-browser) OPEN_BROWSER=0 ;;
  --no-otf2) GEN_OTF2=0 ;;
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
  -h | --help)
    sed -n '2,24p' "$0" | sed 's/^# \?//'
    exit 0
    ;;
  *) echo "[WARN] Argomento sconosciuto: $1" ;;
  esac
  shift
done

# Set output directory
if [[ -z "${OUT_DIR}" ]]; then
  OUT_DIR="${MUDOCK_ROOT}/traces"
fi
mkdir -p "${OUT_DIR}"

if [[ "${USE_NATIVE}" -eq 1 ]]; then
  TRACE_OUT="${OUT_DIR}/muDock.pftrace"
else
  TRACE_OUT="${OUT_DIR}/trace_high_level.json"
fi
OTF2_OUT_DIR="${OUT_DIR}/otf2_high_level"

# -- Simboli --
step() { echo -e "\n== $* =="; }
ok() { echo "  [OK]  $*"; }
warn() { echo "  [WARN]  $*"; }
die() {
  echo "  [FAIL]  $*" >&2
  exit 1
}

echo ""
echo "  +--------------------------------------------------------─+"
echo "  |        muDock — High Level Thread Lifecycle             |"
if [[ "${USE_NATIVE}" -eq 1 ]]; then
  echo "  |    LD_PRELOAD → Perfetto Native SDK (.pftrace)          |"
else
  echo "  |    LD_PRELOAD → JSON Trace → OTF2 → Perfetto (web)      |"
fi
echo "  +--------------------------------------------------------─+"
echo ""

# Compilazione libreria
if [[ "${SKIP_BUILD}" -eq 0 ]]; then
  step "STEP 1/3 — Compilazione delle librerie di tracciamento"
  cd "${SCRIPT_DIR}"
  make clean
  make -j 8
  cd "${MUDOCK_ROOT}"
  ok "Librerie compilate correttamente"
else
  step "STEP 1/3 — Compilazione saltata (usa esistente)"
fi

if [[ "${USE_NATIVE}" -eq 1 ]]; then
  SO_LIB="${SCRIPT_DIR}/libperfetto_preload.so"
else
  # Usa direttamente il runtime OpenMP di LLVM (da Spack) per abilitare OMPT
  SO_LIB="/home/olly/spack/opt/spack/linux-zen5/llvm-18.1.8-rzjx6cb6fxkwsnyojx6zitj6kdq3x7va/lib/libomp.so"
fi

[[ -f "${SO_LIB}" ]] || die "Libreria '${SO_LIB}' non trovata."
[[ -f "./build/application/muDock" ]] || die "Binario muDock non trovato in build/."

# Esecuzione con LD_PRELOAD e OMPT
step "STEP 2/3 — Esecuzione muDock con LD_PRELOAD"
echo "  Libreria precaricata: ${SO_LIB}"
echo "  Output traccia:       ${TRACE_OUT}"
echo "  Population:           ${POPULATION}  Generations: ${GENERATIONS}"

# Rimuovi traccia vecchia se presente
rm -f "${TRACE_OUT}"

# Esegui muDock con LD_PRELOAD
if [[ "${USE_NATIVE}" -eq 1 ]]; then
  LD_PRELOAD="${SO_LIB}" \
    MUDOCK_TRACE_PERFETTO_OUT="${TRACE_OUT}" \
    ./build/application/muDock \
    --protein "${PROTEIN}" \
    --ligand "${LIGAND}" \
    --use "${DEVICE}" \
    --population "${POPULATION}" \
    --generations "${GENERATIONS}" \
    2>&1 | tail -n 15
else
  LD_PRELOAD="${SO_LIB}" \
    OMP_TOOL_LIBRARIES="${SCRIPT_DIR}/libompt_tracer.so" \
    MUDOCK_TRACE_OMPT_OUT="${TRACE_OUT}" \
    ./build/application/muDock \
    --protein "${PROTEIN}" \
    --ligand "${LIGAND}" \
    --use "${DEVICE}" \
    --population "${POPULATION}" \
    --generations "${GENERATIONS}" \
    2>&1 | tail -n 15
fi

if [[ -f "${TRACE_OUT}" ]]; then
  ok "Traccia thread generata correttamente: ${TRACE_OUT} ($(du -h "${TRACE_OUT}" | cut -f1))"
else
  die "Errore: la traccia '${TRACE_OUT}' non è stata creata."
fi

# ===============================================================================
# STEP 3 — Conversione OTF2 (opzionale - solo per JSON)
# ===============================================================================
if [[ "${USE_NATIVE}" -eq 0 && "${GEN_OTF2}" -eq 1 ]]; then
  step "STEP 3/3 — Conversione in formato OTF2"
  CONVERTER="${SCRIPT_DIR}/high_level_to_otf2.py"
  if [[ -f "${CONVERTER}" ]]; then
    rm -rf "${OTF2_OUT_DIR}"
    python3 "${CONVERTER}" "${TRACE_OUT}" "${OTF2_OUT_DIR}" &&
      ok "OTF2 convertito in: ${OTF2_OUT_DIR}/traces.otf2" ||
      warn "Conversione OTF2 fallita (controlla high_level_to_otf2.py)"
  else
    warn "Convertitore OTF2 non trovato in ${SCRIPT_DIR}"
  fi
else
  step "STEP 3/3 — Conversione OTF2 non applicabile o disabilitata"
fi

# -- Apertura automatica del browser ------------------------------------------
if [[ "${OPEN_BROWSER}" -eq 1 ]]; then
  echo ""
  echo "  Avvio server HTTP locale su porta ${HTTP_PORT} ..."

  # Termina eventuali server precedenti sulla stessa porta
  lsof -ti tcp:"${HTTP_PORT}" | xargs kill -9 2>/dev/null || true

  # Ottieni path relativo a MUDOCK_ROOT per il caricamento
  TRACE_REL_PATH=$(realpath --relative-to="${MUDOCK_ROOT}" "${TRACE_OUT}")

  # Avvia server in background dalla directory del progetto
  python3 -m http.server "${HTTP_PORT}" \
    --directory "${MUDOCK_ROOT}" \
    >/dev/null 2>&1 &
  HTTP_PID=$!

  # Attendi che il server sia pronto
  sleep 1

  # URL Perfetto con caricamento automatico del file via parametro url
  PERFETTO_URL="https://ui.perfetto.dev/#!/?url=http://localhost:${HTTP_PORT}/${TRACE_REL_PATH}"

  ok "Server HTTP avviato (PID ${HTTP_PID}) → http://localhost:${HTTP_PORT}"
  echo ""

  # Prova ad aprire il browser
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
# Riepilogo finale
# ===============================================================================
echo ""
echo ""
echo "  +=======================================================+"
echo "  |        Profilazione Thread completata!             |"
echo "  +=======================================================╣"
if [[ "${USE_NATIVE}" -eq 1 ]]; then
  printf "  |  Trace PFT:  %-40s |\n" "${TRACE_OUT}"
else
  printf "  |  Trace JSON: %-40s |\n" "${TRACE_OUT}"
  if [[ "${GEN_OTF2}" -eq 1 ]]; then
    printf "  |  Trace OTF2: %-40s |\n" "${OTF2_OUT_DIR}/traces.otf2"
  fi
fi
echo "  |  Apri traccia:  https://ui.perfetto.dev/              |"
echo "  +=======================================================+"
echo ""
