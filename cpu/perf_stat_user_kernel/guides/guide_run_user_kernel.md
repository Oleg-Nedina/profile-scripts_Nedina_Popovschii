# Guide: `run_user_kernel.sh`

This guide explains how to use the [run_user_kernel.sh](file:///home/olly/UNI/progetto_aca/profile-scripts_Nedina_Popovschii/cpu/perf_stat_user_kernel/scripts/run_user_kernel.sh) script to profile high-level timeline phases inside C++ programs using Perfetto.

---

## Overview

The [run_user_kernel.sh](file:///home/olly/UNI/progetto_aca/profile-scripts_Nedina_Popovschii/cpu/perf_stat_user_kernel/scripts/run_user_kernel.sh) orchestrator is a wrapper script designed to trace custom user-defined execution slices (such as pipeline stages or search loop segments) inside C++ applications. It exports environment variables representing event labels and triggers trace generation. The target application's terminal printouts are redirected to log files, keeping execution details clean.

---

## Dependencies

To run the tracing script successfully, ensure the following requirements are met:

1. **Perfetto Instrumentation**: The target application must compile with the user events static library and link with `-DACA_ENABLE_USER_EVENTS` enabled.
2. **Visualizer Access**: Traces are visualised via the web-based Perfetto UI viewer. Access to `https://ui.perfetto.dev/` is recommended.

---

## Usage Syntax

Run the script from the root directory of the repository:

```bash
./cpu/perf_stat_user_kernel/scripts/run_user_kernel.sh --exe <path_to_executable> [options]
```

### CLI Options

| Option | Required | Description |
| :--- | :---: | :--- |
| `--exe PATH` | **Yes** | Path to the target executable to profile. |
| `--args "..."` | No | Quoted command line arguments to pass to the target binary. |
| `--out-dir DIR` | No | Custom folder to save the trace files (default: `cpu/perf_stat_user_kernel/traces/user_events/`). |
| `--event-N NAME` | No | Label to associate with event ID N (N from 1 to 10). Example: `--event-1 "Parsing"`. |
| `-h, --help` | No | Display usage instructions and exit. |

---

## Targeted Example: Profiling muDock

Follow these instructions to profile the muDock application:

### 1. Execution Command

From the root directory of the repository (`profile-scripts_Nedina_Popovschii`), execute the orchestrator:

```bash
./cpu/perf_stat_user_kernel/scripts/run_user_kernel.sh \
  --exe ../muDock/build/application/muDock \
  --args "--protein ../muDock/data/1fkb/1fkb_protein.pdb --ligand ../muDock/data/1fkb/ligands100_12col.adtmol2 --use CPP:CPU:0-3 --population 100 --generations 100" \
  --event-1 "TbbPipeline" --event-6 "CalcEnergy"
```

### 2. Output Files Produced

After execution, the following files are created in your workspace:

1. **cpu/perf_stat_user_kernel/traces/user_events/trace_user_events.json**: The JSON formatted execution trace containing event durations and concurrency details.
2. **cpu/perf_stat_user_kernel/logs/run_user_kernel.log**: Consolidated terminal prints of the target program (excluding repeating ligand logs).

---

## Visualizing Traces in Perfetto

To inspect the execution flow:

1. Open `https://ui.perfetto.dev/` in a web browser.
2. Load the generated JSON file located at [trace_user_events.json](file:///home/olly/UNI/progetto_aca/profile-scripts_Nedina_Popovschii/cpu/perf_stat_user_kernel/traces/user_events/trace_user_events.json).
3. Lanes represent thread activities. Look for overlapping colored blocks to verify active parallelization, and inspect the `UserUtilization` chart to analyze total active compute ratios.
