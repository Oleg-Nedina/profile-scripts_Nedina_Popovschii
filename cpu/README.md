# CPU Profiling Suite

This project implements an automated, generic CPU profiling suite designed to measure instruction-level parallelism, memory hierarchies, pipeline bottlenecks, and threading behaviors of compiled applications. The suite contains automated script pipelines for uninstrumented macro-profiling, C++ instrumentation APIs for micro-profiling, and custom timeline converters.

The CPU profiling tools are organized into two main subdirectories depending on the level of analysis required:

---

## Profiling Modules Overview

### 1. [perf_stat/](perf_stat/) — Application-Wide Macro-Profiling

This module focuses on application-wide and system-wide performance analysis using Linux `perf`. It measures general hardware metrics without modifying the application source code.

**Target**: Entire application execution.

**Key Metrics**: Instructions Per Cycle (IPC), branch prediction miss rates, cache hierarchy misses (L1, LLC), dTLB/iTLB misses, frontend stalls, page faults, and context switches.

**Visualizations**: Time-series charts exported to [Perfetto UI](https://ui.perfetto.dev/) for interactive timeline analysis of hardware counters.

**Guides**: Each script has a specific markdown guide inside the `guides/` folder detailing how to execute it, along with a targeted example for profiling `muDock`. For example, see the **[base_converter.sh Guide](perf_stat/guides/guide_base_converter.md)** to profile executions, the **[cpu_metrics.sh Guide](perf_stat/guides/guide_cpu_metrics.md)** to collect general performance counters, or the **[memory_metrics.sh Guide](perf_stat/guides/guide_memory_metrics.md)** to track memory metrics.

### 2. [perf_stat_user_kernel/](perf_stat_user_kernel/) — Fine-Grained Micro-Profiling & Instrumentation

This module enables fine-grained profiling by integrating PAPI (Performance Application Programming Interface) and custom instrumentation macros directly into the C++ source code.

**Target**: Specific functions, parallel loops, or critical computational kernels (e.g., scoring functions, genetic algorithms).

**Key Metrics**: High-precision thread-specific hardware counters (via PAPI C++ API) and custom high-level runtime events (User Events).

**Visualizations**: Multi-threaded timeline execution traces in Perfetto UI and detailed terminal statistics per kernel.

**Guides**: Each script has a specific markdown guide inside the `guides/` folder detailing how to execute it (such as the **[USER_GUIDE.md](perf_stat_user_kernel/guides/USER_GUIDE.md)** for general integration, or the specific orchestrator guides for PAPI, User Events, and HPCToolkit).

---

## Directory Structure

The components of the CPU profiling suite are organized as follows:

```text
cpu/
├── README.md                  # Main overview (this file)
│
├── perf_stat/                 # Application-level Linux perf scripts (uninstrumented)
│   ├── base_converter.sh      # Sampling & timeline trace converter script
│   ├── cpu_metrics.sh         # CPU hardware counter analyzer script
│   ├── memory_metrics.sh      # Memory hierarchy counters profiling script
│   ├── sample_perfetto_ui_query.md
│   │
│   ├── guides/                # Script-specific manuals
│   │   ├── guide_base_converter.md
│   │   ├── guide_cpu_metrics.md
│   │   └── guide_memory_metrics.md
│   │
│   └── utils/                 # Trace conversion helpers
│       ├── perf_to_perfetto.py
│       └── stat_to_perfetto.py
│
└── perf_stat_user_kernel/     # Fine-grained instrumented profiling (PAPI & User Events)
    ├── README.md              # Module-specific overview
    │
    ├── include/               # C++ instrumentation headers
    │   ├── aca_papi_tracer.hpp
    │   └── aca_user_events.hpp
    │
    ├── src/                   # Library C++ source files
    │   ├── aca_papi_tracer.cpp
    │   └── aca_user_events.cpp
    │
    ├── scripts/               # Orchestrator and formatter scripts
    │   ├── run_papi.sh
    │   ├── run_user_kernel.sh
    │   ├── run_hpctoolkit.sh
    │   └── format_papi_report.py
    │
    ├── guides/                # Module-specific guides & integration instructions
    │   ├── USER_GUIDE.md
    │   ├── guide_run_papi.md
    │   ├── guide_run_user_kernel.md
    │   └── guide_run_hpctoolkit.md
    │
    └── preset_template/       # Event preset report definitions (JSON)
        ├── ipc.json
        ├── cache.json
        ├── branch.json
        ├── simd.json
        └── full.json
```

---

## Sibling Workspace Layout for Examples

To demonstrate and test the profiling capabilities of this suite, we provide targeted example commands and configuration integrations using **`muDock`** as a reference target application.

For the example commands and automated CMake paths in the guides to work out-of-the-box, this repository (`profile-scripts_Nedina_Popovschii`) and the target application repository (e.g., `muDock`) must be located in the same parent directory as **sibling folders**:

```text
parent_workspace/
├── muDock/                            # Sibling application directory
└── profile-scripts_Nedina_Popovschii/ # Sibling profiling suite directory (this repo)
```

For instance, when executing from the root of `profile-scripts_Nedina_Popovschii`, you can refer to the compiled sibling binary using the relative path `../muDock/build/application/muDock` and access its datasets using `../muDock/data/1fkb/...`.

