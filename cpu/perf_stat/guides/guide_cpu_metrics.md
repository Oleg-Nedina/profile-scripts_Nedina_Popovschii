This guide explains how to use `cpu_metrics.sh` to analyze CPU performance metrics using Linux `perf stat`.

---

## Overview

The `cpu_metrics.sh` script is a generic utility designed to measure hardware performance counters of any compiled executable. It executes the target application multiple times and averages the results. The console output of the application is redirected to logs to keep the terminal output focused on the metrics table.

---

## Dependencies

To successfully run `cpu_metrics.sh`, the following dependencies are required:

1. **Linux `perf`**: The standard Linux performance analyzing tool (specifically `perf stat`).
2. **Kernel PMU Permissions**: Accessing hardware performance counters (such as instructions, cycles, branches, etc.) requires proper permissions. Ensure that `kernel.perf_event_paranoid` is set to at most `2` (ideally `-1`) to run without root:

   ```bash
   sudo sysctl -w kernel.perf_event_paranoid=-1
   ```

---

## Usage Syntax

Run the script from the root directory of the repository:

```bash
./cpu/perf_stat/cpu_metrics.sh --exe <path_to_executable> [options]
```

### CLI Options

| Option | Required | Description |
| :--- | :---: | :--- |
| `--exe PATH` | **Yes** | Path to the executable binary to profile. |
| `--args "..."` | No | Quoted arguments to pass to the executable. |
| `--out-dir DIR` | No | Custom output directory (default: `cpu/perf_stat/traces/cpu_metrics/`). |
| `--output FILE` | No | Custom path for the text report. |
| `--repeat N` | No | Number of runs to average (default: 2). |
| `--warmup N` | No | Number of warmup runs to discard (default: 1). |
| `--csv` | No | Save a machine-readable CSV summary. |
| `-h, --help` | No | Display the script help message and exit. |

---

## Targeted Example: Profiling `muDock`

To profile `muDock` using `cpu_metrics.sh`, compile the application first.

### 1. Execution Command

From the root of this repository (`profile-scripts_Nedina_Popovschii`), execute:

```bash
./cpu/perf_stat/cpu_metrics.sh \
  --exe ../muDock/build/application/muDock \
  --args "--protein ../muDock/data/1fkb/1fkb_protein.pdb --ligand ../muDock/data/1fkb/ligands100_12col.adtmol2 --use CPP:CPU:0 --population 100 --generations 100"
```

### 2. Output Files Produced

After a successful run, the following files will be created in your workspace:

**cpu/perf_stat/traces/cpu_metrics/cpu_metrics.txt**: The formatted summary report text file.

**cpu/perf_stat/traces/cpu_metrics/cpu_metrics_raw.txt**: Raw output from perf stat.

**cpu/perf_stat/logs/cpu_metrics.log**: Console outputs and warning logs of the target application.

---
