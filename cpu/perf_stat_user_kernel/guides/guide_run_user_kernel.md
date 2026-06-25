This guide explains how to use the [run_user_kernel.sh](../scripts/run_user_kernel.sh) script to profile high-level timeline phases inside C++ programs using Perfetto.

---

## Overview

The [run_user_kernel.sh](../scripts/run_user_kernel.sh) orchestrator is a wrapper script designed to trace custom user-defined execution slices (such as pipeline stages or search loop segments) inside C++ applications. It exports environment variables representing event labels and triggers trace generation. The target application's terminal printouts are redirected to log files, keeping execution details clean.

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
      --args "--protein ../muDock/data/1fkb/1fkb_protein.pdb --ligand ../muDock/data/1fkb/ligands100_12col.adtmol2 --use CPP:CPU:0-3 --search genetic --population 100 --generations 100" \
      --event-1 "TbbPipeline" \
      --event-2 "ParserFilter" \
      --event-3 "GeneticInit" \
      --event-4 "GeneticIterate" \
      --event-5 "GeomTransform" \
      --event-6 "CalcEnergy" \
      --event-7 "WorkerInit"


```

### 2. Output Files Produced

After execution, the following files are created in your workspace:

1. **cpu/perf_stat_user_kernel/traces/user_events/trace_user_events.json**: The JSON formatted execution trace containing event durations and concurrency details.
2. **cpu/perf_stat_user_kernel/logs/run_user_kernel.log**: Consolidated terminal prints of the target program (excluding repeating ligand logs).

---

## Visualizing Traces in Perfetto

To inspect the execution flow:

1. Open `https://ui.perfetto.dev/` in a web browser.
2. Load the generated JSON file located at [trace_user_events.json](../traces/user_events/trace_user_events.json).
3. Lanes represent thread activities. Look for overlapping colored blocks to verify active parallelization, and inspect the `UserUtilization` chart to analyze total active compute ratios.

---

## Querying Trace Data in Perfetto

Perfetto UI allows running custom SQL queries directly on the loaded trace data to analyze high-level performance and thread activity. Open the **"Query (SQL)"** tab in the sidebar and execute the following queries:

### 1. App Execution Wall-Clock Time

Calculate the total wall-clock duration of the application (in seconds) based on the first and last recorded events:

```sql
SELECT (MAX(ts + dur) - MIN(ts)) / 1000000.0 AS total_execution_time_sec
FROM slice;
```

### 2. Thread Active vs. Idle/Waiting Time

Analyze workload balance by calculating how much time each thread spent executing tracked user events (Active), how much time it spent waiting or idle (Idle), and its activity percentage:

```sql
WITH app_duration AS (
  SELECT 
    MIN(ts) AS start_ts,
    (MAX(ts + dur) - MIN(ts)) / 1000000.0 AS total_sec
  FROM slice
)
SELECT 
  t.tid AS thread_tid,
  t.name AS thread_name,
  SUM(s.dur) / 1000000.0 AS active_time_sec,
  (app_duration.total_sec - (SUM(s.dur) / 1000000.0)) AS idle_waiting_time_sec,
  (SUM(s.dur) * 100.0) / (app_duration.total_sec * 1000000.0) AS active_percentage
FROM slice s
JOIN thread_track tt ON s.track_id = tt.id
JOIN thread t USING (utid)
CROSS JOIN app_duration
GROUP BY t.tid, t.name, app_duration.total_sec
ORDER BY active_time_sec DESC;
```

### 3. Tracked Event Breakdown per Thread (TID)

Identify which specific user function/event kept each thread busy, showing its active time and its percentage relative to both the thread active time and the entire application execution time:

```sql
WITH thread_total AS (
  SELECT 
    t2.tid AS thread_tid,
    SUM(s2.dur) AS thread_active_dur
  FROM slice s2
  JOIN thread_track tt2 ON s2.track_id = tt2.id
  JOIN thread t2 USING (utid)
  GROUP BY t2.tid
),
app_duration AS (
  SELECT 
    (MAX(ts + dur) - MIN(ts)) / 1000000.0 AS total_sec
  FROM slice
)
SELECT 
  t.tid AS thread_tid,
  s.name AS event_name,
  SUM(s.dur) / 1000000.0 AS active_time_sec,
  -- % of this event relative to total active time of THIS thread
  (SUM(s.dur) * 100.0) / thread_total.thread_active_dur AS pct_of_thread_active_time,
  -- % of this event relative to total wall-clock duration of the APP
  (SUM(s.dur) * 100.0) / (app_duration.total_sec * 1000000.0) AS pct_of_app_total_time
FROM slice s
JOIN thread_track tt ON s.track_id = tt.id
JOIN thread t USING (utid)
JOIN thread_total ON t.tid = thread_total.thread_tid
CROSS JOIN app_duration
GROUP BY t.tid, s.name, thread_total.thread_active_dur, app_duration.total_sec
ORDER BY thread_tid, active_time_sec DESC;
```

### 4. Global Event Active Time (App-wide impact)

Summarize the cumulative execution impact and total active percentage of each user function/event across all threads:

```sql
WITH app_duration AS (
  SELECT 
    (MAX(ts + dur) - MIN(ts)) / 1000000.0 AS total_sec
  FROM slice
)
SELECT 
  s.name AS event_name,
  COUNT(*) AS invocation_count,
  SUM(s.dur) / 1000000.0 AS total_duration_sec,
  (SUM(s.dur) * 100.0) / (app_duration.total_sec * 1000000.0) AS active_percentage
FROM slice s
CROSS JOIN app_duration
GROUP BY s.name, app_duration.total_sec
ORDER BY total_duration_sec DESC;
```

### 5. Event Execution Metrics (Averages)

Summarize invocations, total duration, and average duration (in milliseconds) per user event:

```sql
SELECT 
  name AS event_name,
  COUNT(*) AS invocation_count,
  SUM(dur) / 1000000.0 AS total_duration_sec,
  AVG(dur) / 1000.0 AS avg_duration_ms
FROM slice
GROUP BY name
ORDER BY total_duration_sec DESC;
```

### 6. Peak Concurrency (Active Threads)

Determine the peak number of threads executing a tracked event simultaneously:

```sql
SELECT 
  MAX(value) AS max_parallel_threads
FROM counter c
JOIN counter_track ct ON c.track_id = ct.id
WHERE ct.name = 'user_events_active';
```
