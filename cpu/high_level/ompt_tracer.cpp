// =============================================================================
// ompt_tracer.cpp  —  OMPT-based OpenMP thread lifecycle, wait, and work tracer
// =============================================================================
//
// This library implements the OpenMP Tools Interface (OMPT) to profile
// OpenMP thread lifecycle, parallel regions, barrier synchronization waits,
// and worksharing region execution (loops, sections, single).
// It bypasses the limitation of LD_PRELOAD which cannot intercept direct
// sys_futex syscalls made by libgomp.
//
// Compile with:
//   g++ -std=c++17 -O2 -fPIC -shared -o libompt_tracer.so ompt_tracer.cpp -I.
//
// Run with:
//   OMP_TOOL_LIBRARIES=./libompt_tracer.so MUDOCK_TRACE_OMPT_OUT=trace_ompt.json ./muDock ...
// =============================================================================

#include <stddef.h>
#include <sys/types.h>
#include <unistd.h>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <mutex>
#include <string>
#include <sys/syscall.h>
#include <vector>
#include <algorithm>

// OMPT header included after standard system headers
#include <omp-tools.h>

// Global flag to stop event recording during flush (prevents races with active threads)
static std::atomic<bool> g_flushing{false};

// OMPT Inquiry Function pointer
static ompt_get_thread_data_t ompt_get_thread_data_fn = nullptr;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
static inline int64_t now_us() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return static_cast<int64_t>(ts.tv_sec) * 1'000'000LL
         + static_cast<int64_t>(ts.tv_nsec) / 1000LL;
}

static inline pid_t get_tid() {
    return static_cast<pid_t>(syscall(SYS_gettid));
}

// Map OMPT sync kind to readable name
static const char* get_sync_kind_name(ompt_sync_region_t kind) {
    switch (kind) {
        case ompt_sync_region_barrier:
            return "OpenMP Barrier";
        case ompt_sync_region_barrier_implicit:
            return "OpenMP Implicit Barrier";
        case ompt_sync_region_barrier_explicit:
            return "OpenMP Explicit Barrier";
        case ompt_sync_region_barrier_implementation:
            return "OpenMP Idle/Wait";
        case ompt_sync_region_taskwait:
            return "OpenMP Taskwait";
        case ompt_sync_region_taskgroup:
            return "OpenMP Taskgroup";
        case ompt_sync_region_reduction:
            return "OpenMP Reduction";
        case ompt_sync_region_barrier_implicit_workshare:
            return "OpenMP Workshare Implicit Barrier";
        case ompt_sync_region_barrier_implicit_parallel:
            return "OpenMP Parallel Implicit Barrier";
        case ompt_sync_region_barrier_teams:
            return "OpenMP Teams Barrier";
        default:
            return "OpenMP Sync Region";
    }
}

// Map OMPT worksharing type to readable name
static const char* get_work_type_name(ompt_work_t type) {
    switch (type) {
        case ompt_work_loop:
            return "OpenMP Loop";
        case ompt_work_sections:
            return "OpenMP Sections";
        case ompt_work_single_executor:
            return "OpenMP Single Executor";
        case ompt_work_single_other:
            return "OpenMP Single Other";
        case ompt_work_workshare:
            return "OpenMP Workshare";
        case ompt_work_distribute:
            return "OpenMP Distribute";
        case ompt_work_taskloop:
            return "OpenMP Taskloop";
        case ompt_work_scope:
            return "OpenMP Scope";
        case ompt_work_loop_static:
            return "OpenMP Loop Static";
        case ompt_work_loop_dynamic:
            return "OpenMP Loop Dynamic";
        case ompt_work_loop_guided:
            return "OpenMP Loop Guided";
        case ompt_work_loop_other:
            return "OpenMP Loop Other";
        default:
            return "OpenMP Work Sharing";
    }
}

// Map OMPT thread type to readable name
static const char* get_thread_type_name(ompt_thread_t type) {
    switch (type) {
        case ompt_thread_initial:
            return "Initial Thread";
        case ompt_thread_worker:
            return "Worker Thread";
        case ompt_thread_other:
            return "Other Thread";
        default:
            return "Unknown Thread";
    }
}

// ---------------------------------------------------------------------------
// Data structures
// ---------------------------------------------------------------------------
struct SyncEvent {
    pid_t    tid;
    int64_t  ts_begin;
    int64_t  ts_end;
    const char* kind;
    const char* cat;
};

// Heap-allocated structure for thread-local OMPT data
// (Prevents glibc uninitialized dynamic TLS bugs in loaded tool libraries)
struct ThreadData {
    int idx;
    pid_t tid;
    int64_t wait_start;
    const char* wait_kind;
    int64_t work_start;
    const char* work_kind;
    std::vector<SyncEvent> sync_events;
};

struct ThreadRecord {
    int      index;
    pid_t    tid;
    int64_t  ts_start;
    int64_t  ts_end;
    const char* type;
};

struct ParallelRecord {
    int64_t  ts_start;
    int64_t  ts_end;
    pid_t    encountering_tid;
    unsigned int requested_parallelism;
};

// Task lifecycle record (create → schedule execute → schedule complete/cancel)
struct TaskRecord {
    int64_t  ts_create;    // when ompt_task_create fired
    int64_t  ts_exec;      // when the task started executing (ompt_task_switch)
    int64_t  ts_done;      // when the task finished (ompt_task_complete / cancel)
    pid_t    creator_tid;
    pid_t    exec_tid;
    int      task_type;    // ompt_task_t flags
    const char* status;    // "complete", "cancel", "yield"
};

// Global Registry
class OMPTRegistry {
public:
    std::mutex mtx;
    std::vector<ThreadRecord> threads;
    std::vector<ParallelRecord> parallel_regions;
    std::vector<TaskRecord> task_records;
    std::vector<SyncEvent> all_sync_events;
    std::vector<ThreadData*> live_threads;
    std::atomic<int> thread_counter{0};
    int64_t t0 = 0;

    OMPTRegistry() {
        t0 = now_us();
    }

    void register_thread(ThreadData* td) {
        std::lock_guard<std::mutex> lock(mtx);
        live_threads.push_back(td);
    }

    void unregister_thread(ThreadData* td) {
        std::lock_guard<std::mutex> lock(mtx);
        // Collect thread-local events accumulated so far
        all_sync_events.insert(all_sync_events.end(), td->sync_events.begin(), td->sync_events.end());
        td->sync_events.clear();
        
        auto it = std::find(live_threads.begin(), live_threads.end(), td);
        if (it != live_threads.end()) {
            live_threads.erase(it);
        }
    }

    void add_thread_start(pid_t tid, int64_t ts, const char* type, int idx) {
        std::lock_guard<std::mutex> lock(mtx);
        threads.push_back({idx, tid, ts, 0, type});
    }

    void add_thread_end(pid_t tid, int64_t ts) {
        std::lock_guard<std::mutex> lock(mtx);
        for (auto& t : threads) {
            if (t.tid == tid && t.ts_end == 0) {
                t.ts_end = ts;
                break;
            }
        }
    }

    void add_parallel_region(int64_t ts_start, int64_t ts_end, pid_t tid, unsigned int parallelism) {
        std::lock_guard<std::mutex> lock(mtx);
        parallel_regions.push_back({ts_start, ts_end, tid, parallelism});
    }

    void add_task(TaskRecord&& tr) {
        std::lock_guard<std::mutex> lock(mtx);
        task_records.push_back(std::move(tr));
    }

    void flush(const std::string& path) {
        std::lock_guard<std::mutex> lock(mtx);

        // 1. Signal threads to stop recording and wait for active writers
        g_flushing.store(true, std::memory_order_seq_cst);
        struct timespec pause_ts{0, 1'000'000L}; // 1 ms
        nanosleep(&pause_ts, nullptr);

        int64_t now = now_us();
        
        // Close any threads that are still active
        for (auto& t : threads) {
            if (t.ts_end == 0) {
                t.ts_end = now;
            }
        }

        // Collect sync events from live threads safely
        for (auto* td : live_threads) {
            all_sync_events.insert(all_sync_events.end(), td->sync_events.begin(), td->sync_events.end());
            td->sync_events.clear();
        }

        std::ofstream out(path);
        if (!out.is_open()) {
            fprintf(stderr, "[OMPT Tracer] Error: cannot open file %s\n", path.c_str());
            return;
        }

        const pid_t pid = getpid();
        out << "{\"traceEvents\":[\n";
        bool first = true;

        // 1. Thread lifecycle slices (ph: X)
        for (const auto& t : threads) {
            if (t.ts_start <= 0 || t.ts_end <= 0) continue;
            int64_t ts = t.ts_start - t0;
            int64_t dur = t.ts_end - t.ts_start;
            std::string name = std::string(t.type) + " " + std::to_string(t.index);

            if (!first) out << ",\n";
            first = false;

            out << "{\"ph\":\"X\""
                << ",\"name\":\"" << name << "\""
                << ",\"cat\":\"thread_lifecycle\""
                << ",\"ts\":" << ts
                << ",\"dur\":" << (dur > 0 ? dur : 1)
                << ",\"pid\":" << pid
                << ",\"tid\":" << t.tid
                << ",\"args\":{"
                << "\"index\":" << t.index
                << ",\"type\":\"" << t.type << "\""
                << "}}";
        }

        // 2. Metadata Thread Names (ph: M)
        for (const auto& t : threads) {
            if (!first) out << ",\n";
            first = false;
            out << "{\"ph\":\"M\""
                << ",\"name\":\"thread_name\""
                << ",\"pid\":" << pid
                << ",\"tid\":" << t.tid
                << ",\"args\":{\"name\":\"OpenMP " << t.type << " " << t.index << " [TID " << t.tid << "]\"}}";
        }

        // 3. Parallel region slices (ph: X)
        for (const auto& p : parallel_regions) {
            int64_t ts = p.ts_start - t0;
            int64_t dur = p.ts_end - p.ts_start;

            if (!first) out << ",\n";
            first = false;

            out << "{\"ph\":\"X\""
                << ",\"name\":\"Parallel Region\""
                << ",\"cat\":\"openmp_region\""
                << ",\"ts\":" << ts
                << ",\"dur\":" << (dur > 0 ? dur : 1)
                << ",\"pid\":" << pid
                << ",\"tid\":" << p.encountering_tid
                << ",\"args\":{"
                << "\"requested_parallelism\":" << p.requested_parallelism
                << "}}";
        }

        // 4. Task records (ph: X) — one slice per executed task
        for (const auto& tk : task_records) {
            if (tk.ts_exec <= 0 || tk.ts_done <= 0) continue;
            int64_t ts  = tk.ts_exec - t0;
            int64_t dur = tk.ts_done - tk.ts_exec;
            if (dur <= 0) continue;

            if (!first) out << ",\n";
            first = false;

            out << "{\"ph\":\"X\""
                << ",\"name\":\"OMP Task\""
                << ",\"cat\":\"omp_task\""
                << ",\"ts\":" << ts
                << ",\"dur\":" << dur
                << ",\"pid\":" << pid
                << ",\"tid\":" << tk.exec_tid
                << ",\"args\":{"
                << "\"status\":\"" << (tk.status ? tk.status : "complete") << "\""
                << ",\"task_type\":" << tk.task_type
                << "}}";
        }

        // 5. Sync / wait / work events (ph: X)
        for (const auto& s : all_sync_events) {
            int64_t ts = s.ts_begin - t0;
            int64_t dur = s.ts_end - s.ts_begin;
            if (dur <= 0) continue;

            if (!first) out << ",\n";
            first = false;

            out << "{\"ph\":\"X\""
                << ",\"name\":\"" << s.kind << "\""
                << ",\"cat\":\"" << s.cat << "\""
                << ",\"ts\":" << ts
                << ",\"dur\":" << dur
                << ",\"pid\":" << pid
                << ",\"tid\":" << s.tid
                << ",\"args\":{\"duration_us\":" << dur << "}}";
        }

        out << "\n],\"displayTimeUnit\":\"us\"}\n";
        fprintf(stderr, "[OMPT Tracer] Trace written: %s (%zu threads, %zu parallel regions, %zu tasks, %zu sync/work events)\n",
                path.c_str(), threads.size(), parallel_regions.size(), task_records.size(), all_sync_events.size());
    }
};

static OMPTRegistry* g_registry = nullptr;

// ---------------------------------------------------------------------------
// OMPT Callback Implementations
// ---------------------------------------------------------------------------

// Thread begin callback
static void on_thread_begin(
    ompt_thread_t thread_type,
    ompt_data_t *thread_data)
{
    if (g_flushing.load(std::memory_order_relaxed)) return;

    pid_t tid = get_tid();
    int64_t ts = now_us();
    int idx = g_registry->thread_counter.fetch_add(1);
    
    // Allocate ThreadData structure on heap
    ThreadData* td = new ThreadData{idx, tid, 0, nullptr, 0, nullptr, {}};
    thread_data->ptr = td;

    g_registry->add_thread_start(tid, ts, get_thread_type_name(thread_type), idx);
    g_registry->register_thread(td);
}

// Thread end callback
static void on_thread_end(
    ompt_data_t *thread_data)
{
    if (g_flushing.load(std::memory_order_relaxed)) return;

    pid_t tid = get_tid();
    int64_t ts = now_us();

    g_registry->add_thread_end(tid, ts);

    if (thread_data && thread_data->ptr) {
        ThreadData* td = static_cast<ThreadData*>(thread_data->ptr);
        g_registry->unregister_thread(td);
        delete td;
        thread_data->ptr = nullptr;
    }
}

// Parallel region begin callback
static void on_parallel_begin(
    ompt_data_t *encountering_task_data,
    const ompt_frame_t *encountering_task_frame,
    ompt_data_t *parallel_data,
    unsigned int requested_parallelism,
    int flags,
    const void *codeptr_ra)
{
    (void)encountering_task_data;
    (void)encountering_task_frame;
    (void)requested_parallelism;
    (void)flags;
    (void)codeptr_ra;
    
    if (g_flushing.load(std::memory_order_relaxed)) return;

    int64_t ts = now_us();
    // Save start timestamp in parallel_data
    parallel_data->value = static_cast<uint64_t>(ts);
}

// Parallel region end callback
static void on_parallel_end(
    ompt_data_t *parallel_data,
    ompt_data_t *encountering_task_data,
    int flags,
    const void *codeptr_ra)
{
    (void)encountering_task_data;
    (void)codeptr_ra;

    if (g_flushing.load(std::memory_order_relaxed)) return;

    int64_t ts_end = now_us();
    int64_t ts_start = static_cast<int64_t>(parallel_data->value);
    pid_t tid = get_tid();

    g_registry->add_parallel_region(ts_start, ts_end, tid, flags);
}

// Sync region wait callback
static void on_sync_region_wait(
    ompt_sync_region_t kind,
    ompt_scope_endpoint_t endpoint,
    ompt_data_t *parallel_data,
    ompt_data_t *task_data,
    const void *codeptr_ra)
{
    (void)parallel_data;
    (void)task_data;
    (void)codeptr_ra;

    if (g_flushing.load(std::memory_order_relaxed)) return;
    if (!ompt_get_thread_data_fn) return;

    int64_t now = now_us();

    // Query OMPT for the current thread's heap-allocated ThreadData
    ompt_data_t* tdata = ompt_get_thread_data_fn();
    if (tdata && tdata->ptr) {
        ThreadData* td = static_cast<ThreadData*>(tdata->ptr);
        
        if (endpoint == ompt_scope_begin) {
            td->wait_start = now;
            td->wait_kind = get_sync_kind_name(kind);
        } else if (endpoint == ompt_scope_end) {
            if (td->wait_start > 0 && td->wait_kind != nullptr) {
                // Filter out extremely short events (< 1 us) to reduce noise
                if (now - td->wait_start > 1) {
                    td->sync_events.push_back({td->tid, td->wait_start, now, td->wait_kind, "sync"});
                }
                td->wait_start = 0;
                td->wait_kind = nullptr;
            }
        }
    }
}

// Worksharing region begin/end callback
static void on_work(
    ompt_work_t work_type,
    ompt_scope_endpoint_t endpoint,
    ompt_data_t *parallel_data,
    ompt_data_t *task_data,
    uint64_t count,
    const void *codeptr_ra)
{
    (void)parallel_data;
    (void)task_data;
    (void)count;
    (void)codeptr_ra;

    if (g_flushing.load(std::memory_order_relaxed)) return;
    if (!ompt_get_thread_data_fn) return;

    int64_t now = now_us();

    // Query OMPT for the current thread's heap-allocated ThreadData
    ompt_data_t* tdata = ompt_get_thread_data_fn();
    if (tdata && tdata->ptr) {
        ThreadData* td = static_cast<ThreadData*>(tdata->ptr);
        
        if (endpoint == ompt_scope_begin) {
            td->work_start = now;
            td->work_kind = get_work_type_name(work_type);
        } else if (endpoint == ompt_scope_end) {
            if (td->work_start > 0 && td->work_kind != nullptr) {
                // Filter out extremely short events (< 1 us) to reduce noise
                if (now - td->work_start > 1) {
                    td->sync_events.push_back({td->tid, td->work_start, now, td->work_kind, "work"});
                }
                td->work_start = 0;
                td->work_kind = nullptr;
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Task callbacks
// ---------------------------------------------------------------------------

// Task create: record the creation timestamp and creator thread
static void on_task_create(
    ompt_data_t *encountering_task_data,
    const ompt_frame_t *encountering_task_frame,
    ompt_data_t *new_task_data,
    int flags,
    int has_dependences,
    const void *codeptr_ra)
{
    (void)encountering_task_frame;
    (void)has_dependences;
    (void)codeptr_ra;

    if (g_flushing.load(std::memory_order_relaxed)) return;

    // Allocate a TaskRecord on the heap and store a pointer in new_task_data
    TaskRecord* tr = new TaskRecord{};
    tr->ts_create   = now_us();
    tr->creator_tid = get_tid();
    tr->task_type   = flags;
    tr->ts_exec     = 0;
    tr->ts_done     = 0;
    tr->exec_tid    = 0;
    tr->status      = nullptr;
    new_task_data->ptr = tr;

    (void)encountering_task_data;
}

// Task schedule: fires when a task is switched in or out of a thread
static void on_task_schedule(
    ompt_data_t *prior_task_data,
    ompt_task_status_t prior_task_status,
    ompt_data_t *next_task_data)
{
    if (g_flushing.load(std::memory_order_relaxed)) return;

    int64_t now = now_us();
    pid_t   tid = get_tid();

    // The prior task is being de-scheduled: record its completion
    if (prior_task_data && prior_task_data->ptr) {
        TaskRecord* tr = static_cast<TaskRecord*>(prior_task_data->ptr);
        if (tr->ts_exec > 0 && tr->ts_done == 0) {
            tr->ts_done = now;
            switch (prior_task_status) {
                case ompt_task_complete:      tr->status = "complete";          break;
                case ompt_task_yield:         tr->status = "yield";             break;
                case ompt_task_cancel:        tr->status = "cancel";            break;
                case ompt_task_detach:        tr->status = "detach";            break;
                case ompt_task_early_fulfill: tr->status = "early_fulfill";     break;
                case ompt_task_late_fulfill:  tr->status = "late_fulfill";      break;
                case ompt_task_switch:        tr->status = "switch";            break;
                case ompt_taskwait_complete:  tr->status = "taskwait_complete"; break;
                default:                      tr->status = "unknown";           break;
            }
            g_registry->add_task(std::move(*tr));
            delete tr;
            prior_task_data->ptr = nullptr;
        }
    }

    // The next task is being scheduled in: record its start
    if (next_task_data && next_task_data->ptr) {
        TaskRecord* tr = static_cast<TaskRecord*>(next_task_data->ptr);
        if (tr->ts_exec == 0) {
            tr->ts_exec  = now;
            tr->exec_tid = tid;
        }
    }
}

// ---------------------------------------------------------------------------
// Tool Initialization & Finalization
// ---------------------------------------------------------------------------

static int ompt_initialize(
    ompt_function_lookup_t lookup,
    int initial_device_num,
    ompt_data_t *tool_data)
{
    (void)initial_device_num;
    (void)tool_data;

    // Find the OMPT callback setter
    ompt_set_callback_t ompt_set_callback = (ompt_set_callback_t) lookup("ompt_set_callback");
    if (!ompt_set_callback) {
        fprintf(stderr, "[OMPT Tracer] Error: ompt_set_callback not found in runtime.\n");
        return 0; // Fail initialization
    }

    // Lookup ompt_get_thread_data function
    ompt_get_thread_data_fn = (ompt_get_thread_data_t) lookup("ompt_get_thread_data");
    if (!ompt_get_thread_data_fn) {
        fprintf(stderr, "[OMPT Tracer] Error: ompt_get_thread_data not found in runtime.\n");
        return 0;
    }

    g_registry = new OMPTRegistry();

    // Register OMPT callbacks
    ompt_set_callback(ompt_callback_thread_begin,    (ompt_callback_t) on_thread_begin);
    ompt_set_callback(ompt_callback_thread_end,      (ompt_callback_t) on_thread_end);
    ompt_set_callback(ompt_callback_parallel_begin,  (ompt_callback_t) on_parallel_begin);
    ompt_set_callback(ompt_callback_parallel_end,    (ompt_callback_t) on_parallel_end);
    ompt_set_callback(ompt_callback_sync_region_wait,(ompt_callback_t) on_sync_region_wait);
    ompt_set_callback(ompt_callback_work,            (ompt_callback_t) on_work);
    ompt_set_callback(ompt_callback_task_create,     (ompt_callback_t) on_task_create);
    ompt_set_callback(ompt_callback_task_schedule,   (ompt_callback_t) on_task_schedule);

    fprintf(stderr, "[OMPT Tracer] Library initialized successfully. Callbacks registered.\n");
    return 1; // Success
}

static void ompt_finalize(ompt_data_t *tool_data) {
    (void)tool_data;
    if (!g_registry) return;

    const char* path = getenv("MUDOCK_TRACE_OMPT_OUT");
    std::string out_path = path ? path : "trace_ompt.json";

    g_registry->flush(out_path);
    delete g_registry;
    g_registry = nullptr;
    fprintf(stderr, "[OMPT Tracer] Library finalized.\n");
}

// This is the entrypoint called by the OpenMP runtime to initialize the tool
extern "C" ompt_start_tool_result_t* ompt_start_tool(
    unsigned int omp_version,
    const char* runtime_version)
{
    static ompt_start_tool_result_t result;
    result.initialize = ompt_initialize;
    result.finalize = ompt_finalize;
    result.tool_data.value = 0;
    result.tool_data.ptr = nullptr;
    
    fprintf(stderr, "[OMPT Tracer] ompt_start_tool called. OMP Version: %u, Runtime: %s\n",
            omp_version, runtime_version);
            
    return &result;
}
