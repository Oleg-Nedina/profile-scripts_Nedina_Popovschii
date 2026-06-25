# perf_stat_user_kernel — Combined User & PAPI Hotspot Profiling

This module provides a low-overhead, integrated profiling infrastructure for C++ applications. It combines high-level timeline tracking (User Events in Perfetto JSON format) with micro-level hardware counter collection (Kernel Hotspots per thread using PAPI C++ APIs).

---

## Module Structure

The components of this profiling module are organized to remain independent of the main application source code:

```text
perf_stat_user_kernel/
├── README.md                 # This documentation
├── ROADMAP_HPC.md            # Roadmap and HPCToolkit installation commands
├── GUIDA_HPCVIEWER.md        # Guide to interpreting results in hpcviewer
│
├── guides/                   # Individual orchestrator script manuals
│   ├── guide_run_user_kernel.md
│   ├── guide_run_papi.md
│   └── guide_run_hpctoolkit.md
│
├── include/                  # C++ instrumentation headers
│   ├── aca_user_events.hpp   # Macros for User Events (Perfetto timeline)
│   └── aca_papi_tracer.hpp   # Macros for PAPI Hotspots (hardware counters)
│
├── src/                      # Source code (PapiTracer, UserEventTracer)
│   ├── aca_user_events.cpp   # Event manager and JSON export
│   └── aca_papi_tracer.cpp   # PAPI manager, validation, and JSON export
│
└── scripts/                  # Orchestrator and post-processing scripts
    ├── setup_papi.sh         # PAPI/Spack environment initialization
    ├── run_user_kernel.sh    # Orchestration script for User Events tracing
    ├── run_papi.sh           # Orchestration script for PAPI tracing
    ├── run_hpctoolkit.sh     # Orchestration script for HPCToolkit profiling
    └── format_papi_report.py # Text report formatting script
```

Note: The directory layout displayed above is a generic example included solely to demonstrate sample execution paths.

---

## 1. C++ Source Code Integration (muDock)

Include the headers and wrap critical computational sections with the profiling macros.

### A. User Events Tracing

Use `ACA_USER_EVENT_START` and `ACA_USER_EVENT_STOP` to mark high-level phases, parallel loops, or pipeline stages:

```cpp
#include <aca_user_events.hpp>

void run_pipeline() {
    ACA_USER_EVENT_START(1, "TbbPipeline");
    // ... parallel pipeline code ...
    ACA_USER_EVENT_STOP(1);
}
```

### B. PAPI Hotspots Tracing

Use `ACA_PAPI_KNL_START` and `ACA_PAPI_KNL_STOP` to measure hardware counters inside critical computational kernels:

```cpp
#include <aca_papi_tracer.hpp>

void calc_energy() {
    ACA_PAPI_KNL_START(6, "CalcEnergy");
    // ... energy calculation loops ...
    ACA_PAPI_KNL_STOP(6);
}
```

---

## 2. Configuration and Compilation of muDock

To compile with User Events and PAPI profiling enabled, load the Spack environment and configure CMake with the appropriate build options:

```bash
# 1. Navigate to the muDock folder
cd /home/olly/UNI/progetto_aca/muDock

# 2. Create and access the build folder
mkdir -p build && cd build

# 3. Activate the local Spack environment
source /home/olly/spack/share/spack/setup-env.sh
spack env activate mudock_zen5

# 4. Configure CMake with profiling flags
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

# 5. Compile the project
make -j$(nproc)
```

---

## 3. Execution and Profiling

All profiling script executions should be launched from the root directory of the repository (`profile-scripts_Nedina_Popovschii`).

### A. User Events Profiling (Perfetto Timeline)

The orchestrator script [run_user_kernel.sh](file:///home/olly/UNI/progetto_aca/profile-scripts_Nedina_Popovschii/cpu/perf_stat_user_kernel/scripts/run_user_kernel.sh) configures the environment and executes the instrumented binary.

Example execution using relative paths and targeting CPU implementation (`CPP:CPU:0-3`):

```bash
cd /home/olly/UNI/progetto_aca/profile-scripts_Nedina_Popovschii

./cpu/perf_stat_user_kernel/scripts/run_user_kernel.sh \
  --exe ../muDock/build/application/muDock \
  --args "--protein ../muDock/data/1fkb/1fkb_protein.pdb --ligand ../muDock/data/1fkb/ligands100_12col.adtmol2 --use CPP:CPU:0-3 --search genetic --population 100 --generations 100" \
  --event-1 "TbbPipeline" \
  --event-2 "ParserFilter" \
  --event-3 "GeneticInit" \
  --event-4 "GeneticIterate" \
  --event-5 "GeomTransform" \
  --event-6 "CalcEnergy" \
  --event-7 "WorkerInit"
```

Visualization: Open `https://ui.perfetto.dev/` in a web browser and upload the generated JSON trace file located at `./cpu/perf_stat_user_kernel/traces/user_events/trace_user_events.json`.

---

### B. Kernel Hotspots Profiling (PAPI)

Before running the PAPI profiling tool, initialize the environment for your terminal session using [setup_papi.sh](file:///home/olly/UNI/progetto_aca/profile-scripts_Nedina_Popovschii/cpu/perf_stat_user_kernel/scripts/setup_papi.sh):

```bash
cd /home/olly/UNI/progetto_aca/profile-scripts_Nedina_Popovschii
source ./cpu/perf_stat_user_kernel/scripts/setup_papi.sh
```

Execute the profiling suite using [run_papi.sh](file:///home/olly/UNI/progetto_aca/profile-scripts_Nedina_Popovschii/cpu/perf_stat_user_kernel/scripts/run_papi.sh). The orchestrator supports predefined event presets (`ipc`, `cache`, `branch`, `simd`, `full`) or custom event configurations:

1. **Execution with the SIMD/FP Preset**:
   ```bash
   ./cpu/perf_stat_user_kernel/scripts/run_papi.sh \
     --exe ../muDock/build/application/muDock \
     --args "--protein ../muDock/data/1fkb/1fkb_protein.pdb --ligand ../muDock/data/1fkb/ligands100_12col.adtmol2 --use CPP:CPU:0-3 --search genetic --population 100 --generations 100" \
     --preset simd \
     --knl-3 "GeneticInit" --knl-4 "GeneticIterate" --knl-5 "GeomTransform" --knl-6 "CalcEnergy"
   ```
2. **Execution with the Cache Preset**:
   ```bash
   ./cpu/perf_stat_user_kernel/scripts/run_papi.sh \
     --exe ../muDock/build/application/muDock \
     --args "--protein ../muDock/data/1fkb/1fkb_protein.pdb --ligand ../muDock/data/1fkb/ligands100_12col.adtmol2 --use CPP:CPU:0-3 --search genetic --population 100 --generations 100" \
     --preset cache \
     --knl-3 "GeneticInit" --knl-4 "GeneticIterate" --knl-5 "GeomTransform" --knl-6 "CalcEnergy"
   ```
3. **Execution looping over all Presets**:
   Run the entire suite of presets sequentially, saving the results in distinct output folders:
   ```bash
   for preset in ipc cache branch simd full; do
     ./cpu/perf_stat_user_kernel/scripts/run_papi.sh \
       --exe ../muDock/build/application/muDock \
       --args "--protein ../muDock/data/1fkb/1fkb_protein.pdb --ligand ../muDock/data/1fkb/ligands100_12col.adtmol2 --use CPP:CPU:0-3 --search genetic --population 100 --generations 100" \
       --preset "$preset" \
       --out-dir "./cpu/perf_stat_user_kernel/traces/papi_$preset" \
       --knl-3 "GeneticInit" --knl-4 "GeneticIterate" --knl-5 "GeomTransform" --knl-6 "CalcEnergy"
   done
   ```

---

### C. Statistical Sampling Profiling (HPCToolkit)

The script [run_hpctoolkit.sh](file:///home/olly/UNI/progetto_aca/profile-scripts_Nedina_Popovschii/cpu/perf_stat_user_kernel/scripts/run_hpctoolkit.sh) automates statistical sampling profiling. This method is non-intrusive and carries low execution overhead.

It supports the `ipc`, `cache`, `branch`, `simd`, and `full` presets:

1. **Execution with the Cache Preset**:
   ```bash
   ./cpu/perf_stat_user_kernel/scripts/run_hpctoolkit.sh \
     --exe ../muDock/build/application/muDock \
     --args "--protein ../muDock/data/1fkb/1fkb_protein.pdb --ligand ../muDock/data/1fkb/ligands100_12col.adtmol2 --use CPP:CPU:0-3 --search genetic --population 100 --generations 100" \
     --preset cache
   ```
2. **Visualization with hpcviewer**:
   Launch the graphical interface pointing to the generated performance database:
   ```bash
   hpcviewer ./cpu/perf_stat_user_kernel/traces/hpctoolkit/database/
   ```

For a detailed step-by-step description of macro profiling (Perfetto) and micro profiling (HPCToolkit), inspect [GUIDA_COMPLETA_PROFILING.md](file:///home/olly/UNI/progetto_aca/profile-scripts_Nedina_Popovschii/cpu/perf_stat_user_kernel/GUIDA_COMPLETA_PROFILING.md). For installation and fast reports, inspect [ROADMAP_HPC.md](file:///home/olly/UNI/progetto_aca/profile-scripts_Nedina_Popovschii/cpu/perf_stat_user_kernel/ROADMAP_HPC.md) and [GUIDA_HPCVIEWER.md](file:///home/olly/UNI/progetto_aca/profile-scripts_Nedina_Popovschii/cpu/perf_stat_user_kernel/GUIDA_HPCVIEWER.md). For individual orchestrator script manuals, consult [guide_run_user_kernel.md](file:///home/olly/UNI/progetto_aca/profile-scripts_Nedina_Popovschii/cpu/perf_stat_user_kernel/guides/guide_run_user_kernel.md), [guide_run_papi.md](file:///home/olly/UNI/progetto_aca/profile-scripts_Nedina_Popovschii/cpu/perf_stat_user_kernel/guides/guide_run_papi.md), and [guide_run_hpctoolkit.md](file:///home/olly/UNI/progetto_aca/profile-scripts_Nedina_Popovschii/cpu/perf_stat_user_kernel/guides/guide_run_hpctoolkit.md).

---

## 4. Final Reports and Interpretation

Upon completion of a PAPI profiling run, the system automatically writes a formatted text report to the output destination (defaulting to `./traces/papi/kpi_hotspots.txt`).

The generated report contains two sections:

1. **Global Section**: Overall statistics aggregated across all hardware threads (including total elapsed time, invocation counts, and calculated metric rates like IPC or cache miss rate).
2. **Per-Thread Subsection**: Individual metrics broken down per hardware Thread ID (TID) to analyze workload balancing and target bottlenecks.

---
*perf_stat_user_kernel documentation — ACA Project*  
*Last updated: June 2026*
