# 📊 `perf_stat_user_kernel/` — Profiling Combinato User & PAPI Hotspot

Questo modulo fornisce un'infrastruttura di profiling integrata a basso overhead per le applicazioni C++. Consente di combinare il tracciamento grafico ad alto livello (**User Events** in formato Perfetto JSON) con l'acquisizione di metriche hardware microscopiche (**Kernel Hotspots** per thread tramite le API C++ di PAPI).

---

## 📁 Struttura del Modulo

Tutte le parti del modulo sono organizzate in modo da essere indipendenti dal codice dell'applicazione principale:

```text
perf_stat_user_kernel/
├── README.md                 # Questa documentazione
├── ROADMAP_HPC.md            # Roadmap e comandi di installazione HPCToolkit
├── GUIDA_HPCVIEWER.md        # Guida all'interpretazione dei risultati in hpcviewer
│
├── include/                  # Header di strumentazione C++
│   ├── aca_user_events.hpp   # Macro per User Events (timeline Perfetto)
│   └── aca_papi_tracer.hpp   # Macro per PAPI Hotspots (contatori hardware)
│
├── src/                      # Codice sorgente (PapiTracer, UserEventTracer)
│   ├── aca_user_events.cpp   # Gestore eventi + export JSON
│   └── aca_papi_tracer.cpp   # Gestore PAPI + validazione + export JSON
│
└── scripts/                  # Script orchestratori e post-elaborazione
    ├── setup_papi.sh         # Inizializzazione ambiente PAPI/Spack (una volta per sessione)
    ├── run_user_kernel.sh    # Esecuzione orchestrata per tracciamento User Events
    ├── run_papi.sh           # Esecuzione orchestrata per tracciamento PAPI
    ├── run_hpctoolkit.sh     # Esecuzione orchestrata per profiling con HPCToolkit
    └── format_papi_report.py # Script di formattazione del report testuale
```

---

## ⚙️ 1. Integrazione nel Codice Sorgente C++ (muDock)

Inserisci gli header e racchiudi le sezioni computazionali critiche tra le macro del modulo.

### A. Tracciamento degli User Events

Utilizza `ACA_USER_EVENT_START` ed `ACA_USER_EVENT_STOP` per marcare regioni ad alto livello, loop paralleli o fasi di pipeline:

```cpp
#include <aca_user_events.hpp>

void run_pipeline() {
    ACA_USER_EVENT_START(1, "TbbPipeline");
    // ... codice della pipeline parallela ...
    ACA_USER_EVENT_STOP(1);
}
```

### B. Tracciamento dei PAPI Hotspots

Usa `ACA_PAPI_KNL_START` ed `ACA_PAPI_KNL_STOP` per misurare i contatori hardware all'interno di funzioni computazionali critiche:

```cpp
#include <aca_papi_tracer.hpp>

void calc_energy() {
    ACA_PAPI_KNL_START(6, "CalcEnergy");
    // ... loop di calcolo dell'energia ...
    ACA_PAPI_KNL_STOP(6);
}
```

---

## 🛠️ 2. Configurazione e Compilazione di muDock

Per compilare abilitando gli User Events e il profiling PAPI è necessario caricare l'ambiente Spack corretto e configurare CMake con le opzioni di compilazione adeguate:

```bash
# 1. Spostati nella cartella di muDock
cd /home/olly/UNI/progetto_aca/muDock

# 2. Crea e accedi alla cartella di build
mkdir -p build && cd build

# 3. Attiva l'ambiente Spack locale
source /home/olly/spack/share/spack/setup-env.sh
spack env activate mudock_zen5

# 4. Configura CMake specificando i flag per attivare il profiling
$(spack location -i cmake@3.31.11)/bin/cmake .. \
  -DCMAKE_C_COMPILER=gcc-14 \
  -DCMAKE_CXX_COMPILER=g++-14 \
  -DCMAKE_POLICY_DEFAULT_CMP0144=NEW \
  -DCMAKE_MODULE_PATH="$(pwd)/fake_cmake" \
  -DMUDOCK_ENABLE_SYCL=OFF \
  -DMUDOCK_ENABLE_OMP=ON \
  -DMUDOCK_ENABLE_GH=ON \
  -DMUDOCK_GPU_ARCHITECTURES="none" \
  -DMUDOCK_CPU_TARGET="native" \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DMUDOCK_ENABLE_USER_EVENTS=ON \
  -DMUDOCK_ENABLE_PAPI=ON \
  -DCMAKE_PREFIX_PATH="$(spack location -i boost@1.90.0);$(spack location -i highway);$(spack location -i openbabel)"

# 5. Compila il progetto
make -j$(nproc)
```

---

## 🚀 3. Esecuzione e Profilazione

Tutti gli script di esecuzione devono essere eseguiti posizionandosi all'interno della directory `profile-scripts_Nedina_Popovschii/perf_stat_user_kernel`.

### 🟢 A. Profiling degli User Events (Timeline Perfetto)

Il comando [run_user_kernel.sh](file:///home/olly/UNI/progetto_aca/profile-scripts_Nedina_Popovschii/perf_stat_user_kernel/scripts/run_user_kernel.sh) configura l'ambiente ed esegue il binario strumentato.

Esempio di comando con percorsi relativi corretti ed esecuzione su CPU (`CPP:CPU:0-3`):

```bash
cd /home/olly/UNI/progetto_aca/profile-scripts_Nedina_Popovschii/perf_stat_user_kernel

./scripts/run_user_kernel.sh \
  --exe ../../muDock/build/application/muDock \
  --args "--protein ../../muDock/data/1fkb/1fkb_protein.pdb --ligand ../../muDock/data/1fkb/ligands100_12col.adtmol2 --use CPP:CPU:0-3 --search genetic --population 100 --generations 100" \
  --event-1 "TbbPipeline" \
  --event-2 "ParserFilter" \
  --event-3 "GeneticInit" \
  --event-4 "GeneticIterate" \
  --event-5 "GeomTransform" \
  --event-6 "CalcEnergy" \
  --event-7 "WorkerInit"
```

* **Visualizzazione**: Apri [ui.perfetto.dev](https://ui.perfetto.dev/) nel browser e trascina il file `./traces/user_events/trace_user_events.json` generato.

---

### 🔴 B. Profiling dei Kernel Hotspots (PAPI)

Prima di lanciare la profilazione PAPI, è necessario inizializzare l'ambiente una volta per sessione tramite [setup_papi.sh](file:///home/olly/UNI/progetto_aca/profile-scripts_Nedina_Popovschii/perf_stat_user_kernel/scripts/setup_papi.sh):

```bash
cd /home/olly/UNI/progetto_aca/profile-scripts_Nedina_Popovschii/perf_stat_user_kernel
source ./scripts/setup_papi.sh
```

A questo punto, puoi eseguire il profiling utilizzando [run_papi.sh](file:///home/olly/UNI/progetto_aca/profile-scripts_Nedina_Popovschii/perf_stat_user_kernel/scripts/run_papi.sh). Lo script supporta diversi preset predefiniti (`ipc`, `cache`, `branch`, `simd`, `full`) o una lista di eventi personalizzati.

#### 1. Esecuzione con preset SIMD/FP (Intensità Vettoriale)

```bash
./scripts/run_papi.sh \
  --exe ../../muDock/build/application/muDock \
  --args "--protein ../../muDock/data/1fkb/1fkb_protein.pdb --ligand ../../muDock/data/1fkb/ligands100_12col.adtmol2 --use CPP:CPU:0-3 --search genetic --population 100 --generations 100" \
  --preset simd \
  --knl-3 "GeneticInit" --knl-4 "GeneticIterate" --knl-5 "GeomTransform" --knl-6 "CalcEnergy"
```

#### 2. Esecuzione con preset Cache (Analisi L1/L2 e TLB)

```bash
./scripts/run_papi.sh \
  --exe ../../muDock/build/application/muDock \
  --args "--protein ../../muDock/data/1fkb/1fkb_protein.pdb --ligand ../../muDock/data/1fkb/ligands100_12col.adtmol2 --use CPP:CPU:0-3 --search genetic --population 100 --generations 100" \
  --preset cache \
  --knl-3 "GeneticInit" --knl-4 "GeneticIterate" --knl-5 "GeomTransform" --knl-6 "CalcEnergy"
```

#### 3. Esecuzione in loop su tutti i Preset

Per lanciare l'intera suite di preset in una sola volta e salvare i report separatamente:

```bash
for preset in ipc cache branch simd full; do
  ./scripts/run_papi.sh \
    --exe ../../muDock/build/application/muDock \
    --args "--protein ../../muDock/data/1fkb/1fkb_protein.pdb --ligand ../../muDock/data/1fkb/ligands100_12col.adtmol2 --use CPP:CPU:0-3 --search genetic --population 100 --generations 100" \
    --preset "$preset" \
    --out-dir "./traces/papi_$preset" \
    --knl-3 "GeneticInit" --knl-4 "GeneticIterate" --knl-5 "GeomTransform" --knl-6 "CalcEnergy"
```

---

### 🔵 C. Profiling Statistico (HPCToolkit)

Il comando [run_hpctoolkit.sh](file:///home/olly/UNI/progetto_aca/profile-scripts_Nedina_Popovschii/perf_stat_user_kernel/scripts/run_hpctoolkit.sh) automatizza l'intera catena di profiling per campionamento statistico (non intrusivo, a bassissimo overhead).

Supporta i seguenti preset di profiling: `ipc`, `cache`, `branch`, `simd` e `full`.

#### 1. Esecuzione con preset Cache (L1/L2 e TLB Miss)

```bash
./scripts/run_hpctoolkit.sh \
  --exe ../../muDock/build/application/muDock \
  --args "--protein ../../muDock/data/1fkb/1fkb_protein.pdb --ligand ../../muDock/data/1fkb/ligands100_12col.adtmol2 --use CPP:CPU:0-3 --search genetic --population 100 --generations 100" \
  --preset cache
```

#### 2. Visualizzazione con hpcviewer

Al termine della misurazione, avvia l'interfaccia grafica passando il percorso del database:

```bash
hpcviewer ./traces/hpctoolkit/database/
```

*Per una guida completa passo-passo sul profiling macro (Perfetto) e micro (HPCToolkit) comprensiva di comandi ed esempi di analisi, consulta **[GUIDA_COMPLETA_PROFILING.md](file:///home/olly/UNI/progetto_aca/profile-scripts_Nedina_Popovschii/perf_stat_user_kernel/GUIDA_COMPLETA_PROFILING.md)** (per installazione e report veloci puoi far riferimento anche a [ROADMAP_HPC.md](file:///home/olly/UNI/progetto_aca/profile-scripts_Nedina_Popovschii/perf_stat_user_kernel/ROADMAP_HPC.md) e [GUIDA_HPCVIEWER.md](file:///home/olly/UNI/progetto_aca/profile-scripts_Nedina_Popovschii/perf_stat_user_kernel/GUIDA_HPCVIEWER.md)).*

---

## 📊 4. Report Finali e Interpretazione

Al termine dell'esecuzione del profiling PAPI, lo script genera automaticamente il report testuale formattato all'interno del percorso definito (default: `./traces/papi/kpi_hotspots.txt`).

Il report è diviso in due sezioni:

1. **SEZIONE GLOBALE**: Statistiche complessive di tutti i thread (tempo totale accumulato, numero di esecuzioni del kernel, metriche aggregate di alto livello come l'IPC medio o il cache miss rate).
2. **SOTTOSEZIONE PER THREAD**: Dettagli individuali per ciascun thread hardware (TID), utile per monitorare il bilanciamento del carico tra i thread e rilevare eventuali colli di bottiglia localizzati.

---
*Documentazione perf_stat_user_kernel — Progetto ACA*  
*Ultima modifica: Giugno 2026*
