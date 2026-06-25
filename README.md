# High Performance Computing Profiling Infrastructure

This repository provides tools and scripts to profile compiled applications, analyze hardware utilization, and diagnose performance bottlenecks across CPU and GPU architectures.

---

## Supported Environments

1. **CPU Profiling**: A generic, automated CPU profiling suite supporting non-intrusive application-wide macro-profiling (via Linux `perf`) and source-instrumented thread-level micro-profiling (via PAPI C++ APIs and HPCToolkit) with timeline trace visualisations (Perfetto UI).
2. **GPU Profiling**: Kernel-level metrics collection and roofline analysis for NVIDIA (Nsight Compute) and AMD (ROCProfiler).

---

## Directory Structure

The workspace is organized into architecture-specific folders:

1. `cpu/`: Contains the complete CPU profiling suite, organized into two main sub-modules:
   - **[perf_stat/](cpu/perf_stat/) (Macro-Profiling)**: Uninstrumented profiling tools. Includes scripts to measure CPU metrics ([cpu_metrics.sh](cpu/perf_stat/cpu_metrics.sh)), analyze memory/cache hierarchies ([memory_metrics.sh](cpu/perf_stat/memory_metrics.sh)), and convert raw sampling traces into Perfetto timelines ([base_converter.sh](cpu/perf_stat/base_converter.sh)).
   - **[perf_stat_user_kernel/](cpu/perf_stat_user_kernel/) (Micro-Profiling)**: Source-level C++ instrumentation tracer. Contains the headers/source library for User Events timeline tracking and PAPI Hotspots, orchestration run scripts ([run_user_kernel.sh](cpu/perf_stat_user_kernel/scripts/run_user_kernel.sh), [run_papi.sh](cpu/perf_stat_user_kernel/scripts/run_papi.sh), [run_hpctoolkit.sh](cpu/perf_stat_user_kernel/scripts/run_hpctoolkit.sh)), and analytical Perfetto SQL templates.
2. `gpu/`: Contains scripts and tools for GPU profiling, covering vendor-specific metrics collection and roofline plots.

---

## Note on Workspace Layouts in Guides

All directory trees shown across the guides in this repository are reported solely to clarify how the example commands are structured and executed relative to sibling application paths (such as `muDock`).

---

## Acknowledgements

1. GPU roofline mapping inspired by: `https://github.com/nazavode/gpu-charts`.
2. Roofline model methodology: N. Ding and S. Williams, “An Instruction Roofline Model for GPUs,” in 2019 IEEE/ACM Performance Modeling, Benchmarking and Simulation of High Performance Computer Systems (PMBS), Denver, CO, USA: IEEE, Nov. 2019, pp. 7–18. doi: 10.1109/PMBS49563.2019.00007.

