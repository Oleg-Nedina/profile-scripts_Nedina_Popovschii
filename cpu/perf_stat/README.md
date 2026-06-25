This directory contains standalone profiling scripts designed to capture system-wide or process-specific hardware performance counters using the standard Linux `perf` utility.

---

## Script Overview

1. **`cpu_metrics.sh`**: Captures processor execution statistics (IPC, branch mispredictions, frontend/backend stall rates, CPU migration).
2. **`memory_metrics.sh`**: Measures cache and memory hierarchy events (L1-D, L1-I, LLC/L3 reference/miss rates, dTLB/iTLB miss rates, Page Faults).
3. **`base_converter.sh`**: Records call-graph samples (`perf record`) and translates raw `perf.data` into Perfetto JSON timeline traces.

---

## Dependencies

To run any script in this directory, the following system requirements must be met:

1. **Linux `perf`**: The performance counters system utility. Ensure it matches your kernel version:
   - Command: `perf` (specifically `perf stat` and `perf record`).
2. **Python 3**: Required specifically for the JSON conversion task in `base_converter.sh` (executing `perf_to_perfetto.py`).
3. **Kernel PMU Permissions**: To read hardware performance event counters, set:

   ```bash
   sudo sysctl -w kernel.perf_event_paranoid=-1
   ```

---

## Directory Structure

The module is structured as follows:

```text
perf_stat/
├── guides/                     # Fixed: Contains Markdown manuals for each script
├── utils/                      # Fixed: Contains Python helper scripts for trace conversion
├── logs/                       # Runtime: Generated to store diagnostic warnings and stderr logs
└── traces/                     # Runtime: Generated to store target raw/parsed performance reports
    ├── base_converter/         # Timeline traces and sampling records (perf.data, trace_perf.json)
    ├── cpu_metrics/            # Processor hardware counter reports (cpu_metrics.txt, cpu_metrics_raw.txt)
    └── memory_metrics/         # Cache hierarchy, TLB, and OS paging reports (memory_metrics.txt, memory_metrics_raw.txt)
```

---

## Further Documentation

For detailed parameters, CLI configurations, and targeted execution examples with `muDock`, please consult the individual documents in the [guides/](guides/) folder.
