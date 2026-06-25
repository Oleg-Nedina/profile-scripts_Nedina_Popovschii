# High Performance Computing Profiling Infrastructure

This repository provides tools and scripts to profile compiled applications, analyze hardware utilization, and diagnose performance bottlenecks across CPU and GPU architectures.

---

## Supported Environments

1. CPU Profiling: Application-wide statistics and fine-grained micro-profiling using Linux `perf` and PAPI.
2. GPU Profiling: Kernel-level metrics collection and roofline analysis for NVIDIA (Nsight Compute) and AMD (ROCProfiler).

---

## Directory Structure

The workspace is organized into architecture-specific folders:

1. `cpu/`: Contains scripts and guides for CPU profiling, including system-wide performance counter metrics and micro-profiling instrumentation.
2. `gpu/`: Contains scripts and tools for GPU profiling, covering vendor-specific metrics collection and roofline plots.

---

## Note on Workspace Layouts in Guides

All directory trees shown across the guides in this repository are reported solely to clarify how the example commands are structured and executed relative to sibling application paths (such as `muDock`).

---

## Acknowledgements

1. GPU roofline mapping inspired by: `https://github.com/nazavode/gpu-charts`.
2. Roofline model methodology: N. Ding and S. Williams, “An Instruction Roofline Model for GPUs,” in 2019 IEEE/ACM Performance Modeling, Benchmarking and Simulation of High Performance Computer Systems (PMBS), Denver, CO, USA: IEEE, Nov. 2019, pp. 7–18. doi: 10.1109/PMBS49563.2019.00007.
