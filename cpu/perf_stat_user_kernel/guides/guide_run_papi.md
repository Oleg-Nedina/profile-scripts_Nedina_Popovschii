This guide explains how to use the [run_papi.sh](../scripts/run_papi.sh) script to measure hardware performance counters inside computational hotspots using PAPI C++ APIs.

---

## Overview

The [run_papi.sh](../scripts/run_papi.sh) script orchestrates hardware counter collection (such as instructions, cycles, and cache misses) inside manually instrumented C++ functions. It handles environment configurations, dynamically filters counter events, runs the target binary, and invokes a formatter script to output readable metrics tables.

---

## Dependencies

To run PAPI metrics profiling, the following dependencies are required:

1. **PAPI Library**: Access to PAPI runtime library objects (PAPI shared library and headers).
2. **PAPI Instrumentation**: The target application must compile and link with PAPI libraries enabled (`-DACA_ENABLE_PAPI -lpapi`).
3. **PMU Permissions**: Accessing physical performance monitor counters requires kernel permissions. Ensure unprivileged access is allowed:
   ```bash
   sudo sysctl -w kernel.perf_event_paranoid=-1
   ```

---

## Usage Syntax

Execute the orchestrator script from the root directory of the repository:

```bash
./cpu/perf_stat_user_kernel/scripts/run_papi.sh --exe <path_to_executable> [options]
```

### CLI Options

| Option | Required | Description |
| :--- | :---: | :--- |
| `--exe PATH` | **Yes** | Path to the target executable to profile. |
| `--args "..."` | No | Quoted arguments to pass to the target application. |
| `--out-dir DIR` | No | Custom folder to save reports (default: `cpu/perf_stat_user_kernel/traces/papi/`). |
| `--preset PRESET` | No | Hardware event preset. Valid values: `ipc`, `cache`, `branch`, `simd`, or `full`. |
| `--events "..."` | No | Comma-separated list of custom PAPI hardware event labels. |
| `--knl-N NAME` | No | Label to associate with hotspot kernel ID N (N from 1 to 10). Example: `--knl-6 "CalcEnergy"`. |
| `--no-paranoid-check`| No | Disable kernel PMU paranoid permission warnings. |
| `-h, --help` | No | Display usage instructions and exit. |

---

## Targeted Example: Profiling muDock

Follow these instructions to profile the muDock application:

### 1. Execution Command

Execute the PAPI orchestrator targeting the cache preset:

```bash
./cpu/perf_stat_user_kernel/scripts/run_papi.sh \
  --exe ../muDock/build/application/muDock \
  --args "--protein ../muDock/data/1fkb/1fkb_protein.pdb --ligand ../muDock/data/1fkb/ligands100_12col.adtmol2 --use CPP:CPU:0-3 --search genetic --population 100 --generations 100" \
  --preset cache \
  --knl-6 "CalcEnergy"
```

Alternatively, execute the orchestrator with custom hardware events instead of a preset:

```bash
./cpu/perf_stat_user_kernel/scripts/run_papi.sh \
  --exe ../muDock/build/application/muDock \
  --args "--protein ../muDock/data/1fkb/1fkb_protein.pdb --ligand ../muDock/data/1fkb/ligands100_12col.adtmol2 --use CPP:CPU:0-3 --search genetic --population 100 --generations 100" \
  --events "PAPI_TOT_CYC,PAPI_L1_DCM" \
  --knl-6 "CalcEnergy"
```

### 2. Output Files Produced

After execution, the following files are created in your workspace:

**cpu/perf_stat_user_kernel/traces/papi/kpi_hotspots.json**: Raw hardware counter outputs in JSON format.

**cpu/perf_stat_user_kernel/traces/papi/kpi_hotspots.txt**: Formatted text summary report containing global aggregates and per-thread detailed statistics.

**cpu/perf_stat_user_kernel/logs/run_papi.log**: Standard output of the target binary (excluding repeating ligand logs).

---

## Understanding the Summary Report

The [kpi_hotspots.txt](../traces/papi/kpi_hotspots.txt) report contains the following details:

1. **Global Summary**: Average metrics per hotspot aggregated across all execution threads (such as total calls, elapsed time, average IPC, and L2 cache miss rates).
2. **Thread Breakdown**: Counter details indexed per hardware Thread ID (TID) to verify workload balance and investigate bottleneck types.
