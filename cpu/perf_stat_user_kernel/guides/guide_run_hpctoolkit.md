This guide explains how to use the [run_hpctoolkit.sh](../scripts/run_hpctoolkit.sh) script to profile applications using statistical sampling via HPCToolkit.

---

## Overview

The [run_hpctoolkit.sh](../scripts/run_hpctoolkit.sh) script automates the multi-stage HPCToolkit workflow. It runs the statistical counter sampling (`hpcrun`), decodes loop architectures (`hpcstruct`), and correlates timing/hardware counter measurements with the application source files (`hpcprof`) to generate a performance database visualisable in hpcviewer.

---

## Dependencies

To run HPCToolkit statistical profiling, ensure the following utilities are set up:

1. **HPCToolkit**: HPCToolkit commands (`hpcrun`, `hpcstruct`, and `hpcprof`) must be installed and available in your shell `PATH`.
2. **Debug Symbols**: Target binaries must compile with debugging symbols enabled (`-DCMAKE_BUILD_TYPE=RelWithDebInfo`). If debug symbols (`-g`) are omitted, HPCToolkit cannot map execution costs back to source code lines.
3. **hpcviewer**: A graphical interface is required to browse the profiling database. A JRE must be installed:

   ```bash
   sudo apt install default-jre
   ```

---

## Usage Syntax

Execute the orchestrator script from the root directory of the repository:

```bash
./cpu/perf_stat_user_kernel/scripts/run_hpctoolkit.sh --exe <path_to_executable> [options]
```

### CLI Options

| Option | Required | Description |
| :--- | :---: | :--- |
| `--exe PATH` | **Yes** | Path to the target executable to profile. |
| `--args "..."` | No | Quoted arguments to pass to the target binary. |
| `--out-dir DIR` | No | Custom folder to save the generated database (default: `cpu/perf_stat_user_kernel/traces/hpctoolkit/`). |
| `--src-dir DIR` | No | Path to the target application source code folder (default: `../../muDock`). |
| `--preset PRESET` | No | Predefined event sampling preset: `ipc`, `cache`, `branch`, `simd`, or `full`. |
| `--events "..."` | No | Comma-separated list of custom hardware sampling counters (default: `cycles,PAPI_L2_DCM`). |
| `-h, --help` | No | Display usage instructions and exit. |

---

## Targeted Example: Profiling muDock

Follow these instructions to profile the muDock application:

### 1. Execution Command

Run the orchestrator script targeting the cache sampling preset:

```bash
./cpu/perf_stat_user_kernel/scripts/run_hpctoolkit.sh \
  --exe ../muDock/build/application/muDock \
  --args "--protein ../muDock/data/1fkb/1fkb_protein.pdb --ligand ../muDock/data/1fkb/ligands100_12col.adtmol2 --use CPP:CPU:0-3 --search genetic --population 100 --generations 100" \
  --preset cache
```

Alternatively, run the orchestrator with custom sampling events instead of a preset:

```bash
./cpu/perf_stat_user_kernel/scripts/run_hpctoolkit.sh \
  --exe ../muDock/build/application/muDock \
  --args "--protein ../muDock/data/1fkb/1fkb_protein.pdb --ligand ../muDock/data/1fkb/ligands100_12col.adtmol2 --use CPP:CPU:0-3 --search genetic --population 100 --generations 100" \
  --events "cycles,PAPI_L1_DCM"
```

### 2. Output Files Produced

After execution, the following folders are created in your workspace:

1. **cpu/perf_stat_user_kernel/traces/hpctoolkit/measurements/**: Contains raw sampling data and loop structural structures.
2. **cpu/perf_stat_user_kernel/traces/hpctoolkit/database/**: The generated hpcviewer database containing consolidated measurements, source correlations, and thread timelines.
3. **cpu/perf_stat_user_kernel/logs/run_hpctoolkit.log**: Logging stdout prints of the sampling process (excluding repeating ligand logs).

---

## Visualizing Results in hpcviewer

Open the generated database in the hpcviewer graphical utility:

```bash
hpcviewer ./cpu/perf_stat_user_kernel/traces/hpctoolkit/database/
```
