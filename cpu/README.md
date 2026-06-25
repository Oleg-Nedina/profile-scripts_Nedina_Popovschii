# CPU Profiling Infrastructure

Welcome to the CPU performance analysis and profiling infrastructure. This module provides general tools to analyze execution efficiency, hardware utilization, bottlenecks, and threading behavior.

The CPU profiling tools are organized into two main subdirectories depending on the level of analysis required:

---

## Profiling Modules Overview

### 1. [perf_stat/](file:///home/olly/UNI/progetto_aca/profile-scripts_Nedina_Popovschii/cpu/perf_stat/) — Application-Wide Macro-Profiling

This module focuses on application-wide and system-wide performance analysis using Linux `perf`. It measures general hardware metrics without modifying the application source code.

**Target**: Entire application execution.

**Key Metrics**: Instructions Per Cycle (IPC), branch prediction miss rates, cache hierarchy misses (L1, LLC), dTLB/iTLB misses, frontend stalls, page faults, and context switches.

**Visualizations**: Time-series charts exported to [Perfetto UI](https://ui.perfetto.dev/) for interactive timeline analysis of hardware counters.

**Guides**: Each script has a specific markdown guide inside the `guides/` folder detailing how to execute it, along with a targeted example for profiling `muDock`. For example, see the **[base_converter.sh Guide](file:///home/olly/UNI/progetto_aca/profile-scripts_Nedina_Popovschii/cpu/perf_stat/guides/guide_base_converter.md)** to profile executions, or the **[cpu_metrics.sh Guide](file:///home/olly/UNI/progetto_aca/profile-scripts_Nedina_Popovschii/cpu/perf_stat/guides/guide_cpu_metrics.md)** to collect general performance counters.

### 2. [perf_stat_user_kernel/](file:///home/olly/UNI/progetto_aca/profile-scripts_Nedina_Popovschii/cpu/perf_stat_user_kernel/) — Fine-Grained Micro-Profiling & Instrumentation

This module enables fine-grained profiling by integrating PAPI (Performance Application Programming Interface) and custom instrumentation macros directly into the C++ source code.

**Target**: Specific functions, parallel loops, or critical computational kernels (e.g., scoring functions, genetic algorithms).

**Key Metrics**: High-precision thread-specific hardware counters (via PAPI C++ API) and custom high-level runtime events (User Events).

**Visualizations**: Multi-threaded timeline execution traces in Perfetto UI and detailed terminal statistics per kernel.

**Guides**: Each script has a specific markdown guide inside the `guides/` folder detailing how to execute it (to be populated during refactoring).

---

## Directory Tree & Workspace Layout for the varius examples

To execute the profiling scripts against our target application : `muDock`, you must pass the relative path of the target compiled binary. Since this repository (`profile-scripts_Nedina_Popovschii`) and the main project (`muDock`) are **sibling directories**, the layout looks like the tree below. Note that this directory tree is shown solely to clarify the relative execution paths and workspace setup used in the script guides:

```text
progetto_aca/
├── muDock/                            # Sibling project folder
│   ├── data/
│   │   └── 1fkb/                      # Dataset folder
│   └── build/
│       └── application/
│           └── muDock                 # Compiled binary
│
└── profile-scripts_Nedina_Popovschii/ # This repository
    └── cpu/                           # CPU profiling folder
        ├── README.md                  # Main overview (this file)
        │
        ├── perf_stat/                 # Application-level Linux perf scripts
        │   ├── base_converter.sh      # Pipeline profiling script
        │   │
        │   ├── guides/                # Script-specific guides
        │   │   └── guide_base_converter.md
        │   │
        │   ├── logs/                  # Log outputs (untracked warnings)
        │   │   └── base_converter.log
        │   │
        │   └── utils/                 # Perfetto JSON Python converters
        │       ├── perf_to_perfetto.py
        │       └── stat_to_perfetto.py
        │
        └── perf_stat_user_kernel/     # Fine-grained C++ instrumented profiling
            ├── include/               # C++ instrumentation headers (aca_*.hpp)
            ├── src/                   # Library source files (aca_*.cpp)
            ├── scripts/               # Orchestrator run scripts
            └── guides/                # Script-specific guides (to be added)
```

For instance, when executing from the root of `profile-scripts_Nedina_Popovschii`, you refer to the sibling binary using `../muDock/build/application/muDock` and its datasets using `../muDock/data/1fkb/...`.
