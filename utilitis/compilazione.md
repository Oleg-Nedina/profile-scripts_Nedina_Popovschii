# 🛠️ Compilazione muDock con User Events e Kernel Hotspots

Questa guida mostra come configurare e compilare `muDock` includendo l'infrastruttura per il tracciamento degli **User Events** e dei **Kernel Hotspots** (PAPI).

---

## ⚙️ Flag CMake per le Analisi

Per abilitare il profiling all'interno di `muDock`, è necessario passare le seguenti opzioni al comando di generazione di CMake:

- **`-DMUDOCK_ENABLE_USER_EVENTS=ON`**: Abilita il tracciamento ad alto livello (timeline compatibile con Perfetto) tramite le macro in [aca_user_events.hpp](file:///home/olly/UNI/progetto_aca/profile-scripts_Nedina_Popovschii/perf_stat_user_kernel/include/aca_user_events.hpp).
- **`-DMUDOCK_ENABLE_PAPI=ON`**: Abilita il profiling a basso livello (contatori hardware delle metriche PAPI) tramite le macro in [aca_papi_tracer.hpp](file:///home/olly/UNI/progetto_aca/profile-scripts_Nedina_Popovschii/perf_stat_user_kernel/include/aca_papi_tracer.hpp).

Questi flag sono integrati nel file [CMakeLists.txt](file:///home/olly/UNI/progetto_aca/muDock/CMakeLists.txt#L439-L466) principale.

---

## 🔨 Comandi per la Compilazione

Esegui i seguenti comandi per configurare l'ambiente Spack, generare la build tramite CMake ed effettuare la compilazione:

```bash
# Spostati nella cartella di muDock
cd /home/olly/UNI/progetto_aca/muDock

# Crea e accedi alla cartella di build
mkdir -p build && cd build

# Attiva l'ambiente Spack per caricare le dipendenze
source /home/olly/spack/share/spack/setup-env.sh
spack env activate mudock_zen5

# Configura il progetto includendo i flag di profiling
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

# Compila usando tutti i core disponibili
make -j$(nproc)
```

---

## ℹ️ Informazioni Aggiuntive

- Per i dettagli sull'utilizzo delle macro nel codice sorgente C++ o sull'esecuzione degli script di analisi, consulta il file [README.md](file:///home/olly/UNI/progetto_aca/profile-scripts_Nedina_Popovschii/perf_stat_user_kernel/README.md).
- Per consultare la guida di build base non strumentata, vedi [build_and_run.md](file:///home/olly/UNI/progetto_aca/profile-scripts_Nedina_Popovschii/utilitis/build_and_run.md).
