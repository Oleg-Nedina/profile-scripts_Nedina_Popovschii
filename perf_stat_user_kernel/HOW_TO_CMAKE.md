# 🛠️ Guida all'Integrazione CMake per muDock (User Events)

Questo documento descrive dettagliatamente come modificare i file `CMakeLists.txt` del progetto `muDock` per integrare il modulo di tracciamento degli **User Events** (Perfetto JSON).

Prendiamo come riferimento la struttura attuale del workspace:
```text
/home/olly/UNI/progetto_aca/
├── muDock/                              # Cartella principale di muDock
│   ├── CMakeLists.txt                   # CMakeLists.txt di root
│   ├── mudock/
│   │   └── CMakeLists.txt               # CMakeLists.txt della libreria core
│   └── application/
│       └── CMakeLists.txt               # CMakeLists.txt dell'eseguibile principale
└── profile-scripts_Nedina_Popovschii/
    └── perf_stat_user_kernel/           # Modulo di profiling
        ├── include/
        │   └── aca_user_events.hpp
        └── src/
            └── aca_user_events.cpp
```

---

## 📝 Modifiche Step-by-Step

Per abilitare il modulo **User Events**, dobbiamo effettuare modifiche in **due** soli file di `muDock`.

### 1️⃣ Modifica del `CMakeLists.txt` di Root
* **File da modificare**: `[muDock/CMakeLists.txt](file:///home/olly/UNI/progetto_aca/muDock/CMakeLists.txt)`
* **Posizione**: Attorno alla riga **401** (subito sotto la sezione `# ### Profiling` dedicata a LIKWID).

Aggiungi il blocco per definire l'opzione `MUDOCK_ENABLE_USER_EVENTS` e configurare la compilazione condizionale dei sorgenti di tracciamento:

```cmake
# ##############################################################################
# ### Profiling
# ##############################################################################
option(MUDOCK_ENABLE_LIKWID "Enable profiling using likwid" OFF)
...
# ---> AGGIUNGI QUESTO BLOCCO QUI SOTTO <---
# ##############################################################################
# ### User Events Profiling (Perfetto)
# ##############################################################################
option(MUDOCK_ENABLE_USER_EVENTS "Enable User Events tracing for Perfetto" OFF)
if(MUDOCK_ENABLE_USER_EVENTS)
  set(ACA_PROFILER_SRCS
    "${PROJECT_SOURCE_DIR}/../profile-scripts_Nedina_Popovschii/perf_stat_user_kernel/src/aca_user_events.cpp"
  )
  add_library(aca_profiler STATIC ${ACA_PROFILER_SRCS})
  target_include_directories(aca_profiler PUBLIC
    "${PROJECT_SOURCE_DIR}/../profile-scripts_Nedina_Popovschii/perf_stat_user_kernel/include"
  )
  target_compile_definitions(aca_profiler PUBLIC ACA_ENABLE_USER_EVENTS)
endif()
```

---

### 2️⃣ Modifica del `CMakeLists.txt` della Libreria Core
* **File da modificare**: `[muDock/mudock/CMakeLists.txt](file:///home/olly/UNI/progetto_aca/muDock/mudock/CMakeLists.txt)`
* **Posizione**: Attorno alla riga **286** (subito sotto la dichiarazione di `target_link_libraries(libmudock PUBLIC ...)`).

Dobbiamo dire a CMake di collegare la nostra libreria `aca_profiler` e di propagare la macro `-DACA_ENABLE_USER_EVENTS` a chiunque usi `libmudock`:

```cmake
target_link_libraries(libmudock PUBLIC Boost::graph ${OpenBabel3_LIBRARIES} TBB::tbb)

# ---> AGGIUNGI QUESTO BLOCCO QUI SOTTO <---
if(MUDOCK_ENABLE_USER_EVENTS)
  target_link_libraries(libmudock PUBLIC aca_profiler)
  target_compile_definitions(libmudock PUBLIC ACA_ENABLE_USER_EVENTS)
endif()
```

> [!NOTE]
> Usando la visibilità `PUBLIC`, CMake si occuperà di:
> - Aggiungere l'include directory del modulo di profiling sia a `libmudock` sia all'eseguibile principale `muDock` (che linka `libmudock`).
> - Propagare la macro `-DACA_ENABLE_USER_EVENTS` all'intero build tree, permettendo di inserire macro anche in `application/src/main.cpp`.

---

## 🛠️ Come Compilare e Configurare muDock

Una volta salvate le modifiche, puoi compilare il progetto muDock abilitando la profilazione:

1. **Configurazione CMake** (es. da una cartella `build/` in `muDock`):
   ```bash
   cd /home/olly/UNI/progetto_aca/muDock
   mkdir -p build && cd build
   
   # Carica spack se necessario
   source /home/olly/spack/share/spack/setup-env.sh
   spack env activate mudock_zen5
   
   cmake -DMUDOCK_ENABLE_USER_EVENTS=ON -DCMAKE_BUILD_TYPE=RelWithDebInfo ..
   ```

2. **Compilazione**:
   ```bash
   make -j$(nproc)
   ```

---

## 🚀 Come Utilizzare le Macro nel Codice C++ di muDock

Una volta compilato con `-DMUDOCK_ENABLE_USER_EVENTS=ON`, puoi includere l'header e piazzare le macro in qualsiasi file di `libmudock` (es. `tbb_pipeline.cpp` o `genetic_cpp.cpp` o `main.cpp`).

```cpp
#include <aca_user_events.hpp>

void run_tbb_pipeline(...) {
    // Registra un evento con ID 1 e nome personalizzato
    ACA_USER_EVENT_START(1, "PipelineDocking");
    
    // ... codice computazionale ...
    
    ACA_USER_EVENT_STOP(1);
}
```

A fine esecuzione, il programma salverà automaticamente la traccia JSON compatibile con Perfetto UI.
