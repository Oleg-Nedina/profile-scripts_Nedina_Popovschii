Here are 5 Perfetto SQL queries optimized for analyzing C++ user events and performance metrics.

### 1. Identify Top 5 Longest Slices (Bottlenecks)

Finds the individual execution blocks that took the most wall-clock time. This is critical for locating immediate frame drops or heavy operations.

```sql
SELECT 
    name AS event_name, 
    dur / 1e6 AS duration_ms, 
    ts
FROM slice
WHERE dur IS NOT NULL
ORDER BY dur DESC
LIMIT 5;

```

### 2. Event Statistics (Frequency and Total Overhead)

Aggregates performance data by event name. It helps you see if a performance issue is caused by a single slow execution or a fast function called thousands of times.

```sql
SELECT 
    name AS event_name, 
    COUNT(*) AS call_count, 
    SUM(dur) / 1e6 AS total_dur_ms, 
    AVG(dur) / 1e6 AS avg_dur_ms, 
    MAX(dur) / 1e6 AS max_dur_ms
FROM slice
WHERE dur IS NOT NULL
GROUP BY event_name
ORDER BY total_dur_ms DESC
LIMIT 5;

```

### 3. CPU Time vs. Wall Time (Detecting Blocked Threads)

Compares actual CPU execution time (`thread_dur`) against real-world elapsed time (`dur`). If Wall Time is high but CPU Time is low, your C++ thread is blocked waiting for a mutex, I/O, or a system call.

```sql
SELECT 
    name AS event_name,
    dur / 1e6 AS wall_time_ms,
    thread_dur / 1e6 AS cpu_time_ms,
    (dur - IFNULL(thread_dur, 0)) / 1e6 AS blocked_time_ms
FROM slice
WHERE dur IS NOT NULL AND thread_dur IS NOT NULL
ORDER BY blocked_time_ms DESC
LIMIT 5;

```

### 4. Per-Thread Event Breakdown

Maps your custom profiling events to the specific OS threads executing them. This ensures tasks are running on the intended worker or background threads.

```sql
SELECT 
    thread.name AS thread_name,
    slice.name AS event_name,
    COUNT(*) AS call_count,
    SUM(slice.dur) / 1e6 AS total_dur_ms
FROM slice
JOIN thread_track ON slice.track_id = thread_track.id
JOIN thread USING (utid)
GROUP BY thread_name, event_name
ORDER BY total_dur_ms DESC
LIMIT 5;

```

### 5. Instant Events / Zero-Duration Markers Frequency

If your profiling library tracks instant milestones (e.g., specific user clicks, state transitions, or network packet receipts) where duration is zero, this query identifies the most frequent triggers.

```sql
SELECT 
    name AS instant_event_name, 
    COUNT(*) AS occurrence_count
FROM slice
WHERE dur = 0 OR dur IS NULL
GROUP BY instant_event_name
ORDER BY occurrence_count DESC
LIMIT 5;

```
