# Guida alla Portabilità e all'Ambiente Docker (HPC Profiling)

Questa guida illustra la struttura e le modalità di utilizzo dell'infrastruttura di profiling generica e dell'ambiente Docker. Questa configurazione permette a qualunque collaboratore (anche su macOS Intel, Windows WSL o macchine virtuali) di compilare ed eseguire `muDock`, testare il tracciamento software e lanciare la suite di profiling in modalità adattiva.

---

## 🛠️ 1. Script Generici Adattivi (`*_generic.sh`)

Per evitare che la suite vada in crash su CPU non Zen 5 o all'interno di ambienti virtualizzati (dove mancano i registri hardware PMU), sono stati creati due nuovi script dedicati nella cartella `profile-scripts_Nedina_Popovschii/cpu/`:

*   [cpu_metrics_generic.sh](file:///home/olly/UNI/progetto_aca/profile-scripts_Nedina_Popovschii/cpu/cpu_metrics_generic.sh) (Analisi CPU adattiva)
*   [memory_metrics_generic.sh](file:///home/olly/UNI/progetto_aca/profile-scripts_Nedina_Popovschii/cpu/memory_metrics_generic.sh) (Analisi Cache/Memoria adattiva)

### Come funziona la logica adattiva:
1.  **Rilevamento Dinamico:** All'avvio, lo script esegue un test rapido non distruttivo su ciascun evento desiderato (es. `perf stat -e cycles -- true`).
2.  **Filtraggio:** Se la CPU o il kernel locale non supportano un determinato evento (come `stalled-cycles-frontend` o `L1-dcache-loads`), questo viene rimosso in automatico, evitando l'interruzione dello script.
3.  **Fallback Software:** Se non è disponibile alcun contatore hardware PMU (caso tipico di Docker o VM non configurate per vPMU), lo script commuta autonomamente in modalità **Software Fallback**, raccogliendo solo metriche OS (`task-clock`, `page-faults`, `context-switches`, `cpu-migrations`) e valorizzando le metriche hardware come `N/A`.

---

## 🐳 2. Ambiente Docker Portabile

L'ambiente Docker è configurato tramite un [Dockerfile](file:///home/olly/UNI/progetto_aca/Dockerfile) e un [docker-compose.yml](file:///home/olly/UNI/progetto_aca/docker-compose.yml) situati nella root del progetto.
Fornisce un sistema **Ubuntu 24.04** con compilatori **GCC 14** e tutte le dipendenze esterne di muDock (`Boost`, `Highway`, `OpenBabel`) preinstallate a livello di sistema per minimizzare i tempi di configurazione.

### Workflow Passo-Passo per l'Esecuzione

#### Fase A: Avvio del Container
Dalla root del progetto (`~/UNI/progetto_aca/`), avvia il container di sviluppo montando i file locali:
```bash
docker compose run --rm dev
```
Questo comando apre una shell interattiva all'interno di una VM Linux configurata con tutte le librerie pronte.

#### Fase B: Compilazione Standard in Docker
Una volta dentro la shell del container, compila muDock (CMake rileverà le librerie di sistema in automatico):
```bash
cd muDock
rm -rf build && mkdir build && cd build
cmake .. \
  -DCMAKE_C_COMPILER=gcc-14 \
  -DCMAKE_CXX_COMPILER=g++-14 \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DMUDOCK_ENABLE_SYCL=OFF \
  -DMUDOCK_ENABLE_OMP=ON \
  -DMUDOCK_ENABLE_GH=ON \
  -DMUDOCK_GPU_ARCHITECTURES="none" \
  -DMUDOCK_CPU_TARGET="native"
make -j$(nproc)
```

#### Fase C: Esecuzione della Profilazione Adattiva
Sempre all'interno del container, puoi invocare gli script di profilazione generici puntando al binario appena compilato:
```bash
cd /workspace
./profile-scripts_Nedina_Popovschii/cpu/cpu_metrics_generic.sh \
  --exe ./muDock/build/application/muDock \
  --args "--protein ./muDock/data/1fkb/1fkb_protein.pdb --ligand ./muDock/data/1fkb/1fkb_ligand.mol2 --use CPP:CPU:0 --population 100 --generations 100"
```

---

## ⚠️ Caveat e Limitazioni su macOS / Docker

> [!WARNING]
> **Virtualizzazione PMU su Docker Desktop:**
> Se eseguite il container Docker su macOS (sia Intel che Apple Silicon) o sotto VM Windows/WSL base, l'hypervisor ospite **non esporrà i contatori hardware fisici** (Performance Monitoring Unit) al container.
> *   Gli script rileveranno questa mancanza ed attiveranno automaticamente la modalità **Software Fallback**.
> *   Il tracciamento dei thread software (`LD_PRELOAD`) e l'esecuzione standard funzioneranno perfettamente.
> *   Per l'analisi quantitativa e reale a basso livello (cache-misses, stalls, bandwidth di memoria) dell'architettura Zen 5 target dell'esame, i dati definitivi dovranno essere estratti direttamente sulla macchina Linux Zen 5 nativa.
