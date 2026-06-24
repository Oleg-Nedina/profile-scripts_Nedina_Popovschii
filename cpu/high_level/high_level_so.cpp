// =============================================================================
// high_level_so.cpp  —  LD_PRELOAD library: thread lifecycle tracer (v4)
// =============================================================================
//
// Strategia migliorata:
//   - Il thread START viene registrato immediatamente all'interno del wrapper
//     di hl_thread_entry (appena il thread è schedulato dalla OS).
//   - Il thread END viene registrato quando la start_routine ritorna.
//   - Al flush (destructor), i thread ancora "vivi" (pool OpenMP che non
//     ritornano mai) vengono chiusi con il timestamp del momento del flush.
//   → Questo cattura TUTTI i thread: worker muDock + pool OpenMP + qualunque
//     altro thread creato dall'applicazione.
//
// Utilizzo:
//   LD_PRELOAD=./tracer/high_level/libhigh_level.so
//   MUDOCK_TRACE_HL_OUT=trace_high_level.json
//   ./build/application/muDock ...
// =============================================================================

#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <dlfcn.h>
#include <fstream>
#include <mutex>
#include <pthread.h>
#include <string>
#include <sys/syscall.h>
#include <sys/types.h>
#include <unistd.h>
#include <unordered_map>
#include <vector>

// ---------------------------------------------------------------------------
// Re-entrancy guard — evita che i nostri hook intercettino se stessi
// ---------------------------------------------------------------------------
static thread_local bool tl_in_hook = false;

// Flag globale: il flush è in corso → gli hook non accettano più nuovi eventi.
// FIX v4: previene la race condition tra flush() che legge i live_bufs
// e gli hook che ci scrivono contemporaneamente.
static std::atomic<bool> g_flushing{false};

// ---------------------------------------------------------------------------
// SyncRecord: attesa su primitiva di sincronizzazione POSIX
// ---------------------------------------------------------------------------
struct SyncRecord {
    pid_t       tid;
    int64_t     ts_begin;
    int64_t     ts_end;
    const char* kind;   // "mutex", "barrier", "cond_wait"
};
// Buffer per-thread: scrittura lock-free, raccolta al termine del thread
static thread_local std::vector<SyncRecord> tl_sync_events;
// FIX v4: unico flag per-thread di registrazione (invece di uno per ogni hook).
// Evita che register_sync_buf() venga chiamato più volte per lo stesso thread.
static thread_local bool tl_buf_registered = false;

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

// ---------------------------------------------------------------------------
// ThreadRecord: dati di un thread (popolati in due fasi: create + entry)
// ---------------------------------------------------------------------------
struct ThreadRecord {
    int     index;
    pid_t   creator_tid;
    int64_t ts_created;   // quando pthread_create è stato chiamato
    pid_t   tid;          // kernel TID (disponibile solo dopo che il thread parte)
    int64_t ts_start;     // quando hl_thread_entry inizia (thread schedulato)
    int64_t ts_end;       // 0 = thread ancora vivo al momento del flush
};

// ---------------------------------------------------------------------------
// GlobalRegistry
// ---------------------------------------------------------------------------
class GlobalRegistry {
public:
    std::mutex                                  mtx;
    std::unordered_map<pthread_t, ThreadRecord> records;   // in-flight threads
    std::vector<ThreadRecord>                   completed; // thread terminati
    std::atomic<int>                            counter{0};
    std::vector<SyncRecord>                     all_sync;  // da thread terminati
    std::vector<std::vector<SyncRecord>*>       live_bufs; // da thread vivi al flush

    // Raccoglie gli eventi sync di un thread che sta per terminare (svuota il buffer)
    void collect_sync(std::vector<SyncRecord>& buf) {
        std::lock_guard<std::mutex> lock(mtx);
        all_sync.insert(all_sync.end(), buf.begin(), buf.end());
        buf.clear();
    }

    // Registra il buffer live di un thread ancora in esecuzione
    void register_sync_buf(std::vector<SyncRecord>* buf) {
        std::lock_guard<std::mutex> lock(mtx);
        live_bufs.push_back(buf);
    }

    // Fase 1: chiamato da pthread_create nel thread chiamante
    ThreadRecord* create(pthread_t handle, pid_t creator_tid, int64_t ts_created) {
        std::lock_guard<std::mutex> lock(mtx);
        int idx = counter.fetch_add(1);
        auto& rec = records[handle];
        rec = ThreadRecord{idx, creator_tid, ts_created, 0, 0, 0};
        return &rec;
    }

    // Fase 2: chiamato da hl_thread_entry quando il thread inizia
    void thread_started(pthread_t handle, pid_t tid, int64_t ts_start) {
        std::lock_guard<std::mutex> lock(mtx);
        auto it = records.find(handle);
        if (it != records.end()) {
            it->second.tid      = tid;
            it->second.ts_start = ts_start;
        }
    }

    // Fase 3: chiamato da hl_thread_entry quando il thread finisce
    void thread_ended(pthread_t handle, int64_t ts_end) {
        std::lock_guard<std::mutex> lock(mtx);
        auto it = records.find(handle);
        if (it != records.end()) {
            it->second.ts_end = ts_end;
            completed.push_back(it->second);
            records.erase(it);
        }
    }

    // Flush: scrive il JSON Perfetto su disco
    void flush(const std::string& path) {
        std::lock_guard<std::mutex> lock(mtx);

        // I thread ancora "in-flight" (es. pool OpenMP) vengono chiusi ora
        int64_t now = now_us();
        for (auto& [handle, rec] : records) {
            if (rec.ts_start > 0) {  // solo se sono effettivamente partiti
                rec.ts_end = now;
                completed.push_back(rec);
            }
        }

        if (completed.empty()) {
            fprintf(stderr, "[high_level_so] Nessun thread catturato.\n");
            return;
        }

        // Trova t0 = timestamp minimo assoluto
        int64_t t0 = completed[0].ts_created;
        for (const auto& r : completed) {
            t0 = std::min(t0, r.ts_created);
            if (r.ts_start > 0) t0 = std::min(t0, r.ts_start);
        }

        const pid_t pid = getpid();
        std::ofstream out(path);
        if (!out.is_open()) {
            fprintf(stderr, "[high_level_so] Errore: impossibile aprire '%s'\n",
                    path.c_str());
            return;
        }

        out << "{\"traceEvents\":[\n";
        bool first = true;

        // ── Slice per ogni thread (durata = ts_start → ts_end) ───────────────
        for (const auto& r : completed) {
            if (r.ts_start <= 0 || r.ts_end <= 0) continue;

            int64_t ts  = r.ts_start - t0;
            int64_t dur = r.ts_end   - r.ts_start;
            std::string name = "Thread " + std::to_string(r.index);

            if (!first) out << ",\n";
            first = false;

            out << "{\"ph\":\"X\""
                << ",\"name\":\""  << name  << "\""
                << ",\"cat\":\"thread_lifecycle\""
                << ",\"ts\":"  << ts
                << ",\"dur\":" << (dur > 0 ? dur : 1)
                << ",\"pid\":" << pid
                << ",\"tid\":" << r.tid
                << ",\"args\":{"
                <<   "\"index\":"         << r.index
                << ",\"creator_tid\":"    << r.creator_tid
                << ",\"spawn_delay_us\":" << (r.ts_start - r.ts_created)
                << "}}";

            // Evento istantaneo al momento della creazione (su chi ha chiamato)
            out << ",\n"
                << "{\"ph\":\"i\""
                << ",\"name\":\"thread_spawn\""
                << ",\"cat\":\"thread_lifecycle\""
                << ",\"ts\":"  << (r.ts_created - t0)
                << ",\"pid\":" << pid
                << ",\"tid\":" << r.creator_tid
                << ",\"s\":\"t\"}";
        }

        // ── Metadata thread names ─────────────────────────────────────────────
        for (const auto& r : completed) {
            if (r.tid == 0) continue;
            out << ",\n"
                << "{\"ph\":\"M\""
                << ",\"name\":\"thread_name\""
                << ",\"pid\":" << pid
                << ",\"tid\":" << r.tid
                << ",\"args\":{\"name\":\"Thread "
                << r.index << " [TID " << r.tid << "]\"}}";
        }

        // ── Counter: thread attivi in parallelo ───────────────────────────────
        int64_t max_t = 0;
        for (const auto& r : completed)
            if (r.ts_end > 0) max_t = std::max(max_t, r.ts_end - t0);

        const int64_t STEP = 500;
        for (int64_t t = 0; t <= max_t; t += STEP) {
            int active = 0;
            for (const auto& r : completed) {
                if (r.ts_start <= 0 || r.ts_end <= 0) continue;
                int64_t s = r.ts_start - t0;
                int64_t e = r.ts_end   - t0;
                if (t >= s && t <= e) ++active;
            }
            out << ",\n"
                << "{\"ph\":\"C\""
                << ",\"name\":\"parallel_threads\""
                << ",\"pid\":" << pid
                << ",\"ts\":"  << t
                << ",\"args\":{\"count\":" << active << "}}";
        }

        // ── Sync events: mutex / barrier / cond_wait ─────────────────────────
        // Prima i thread terminati (already collected), poi i thread vivi al flush
        auto emit_sync = [&](const std::vector<SyncRecord>& evts) {
            for (const auto& s : evts) {
                int64_t dur = s.ts_end - s.ts_begin;
                if (dur <= 0) continue;
                int64_t ts  = s.ts_begin - t0;
                out << ",\n"
                    << "{\"ph\":\"X\""
                    << ",\"name\":\"" << s.kind << "\""
                    << ",\"cat\":\"sync\""
                    << ",\"ts\":"  << ts
                    << ",\"dur\":" << dur
                    << ",\"pid\":" << pid
                    << ",\"tid\":" << s.tid
                    << ",\"args\":{\"blocked_us\":" << dur << "}}";
            }
        };
        emit_sync(all_sync);

        // FIX v4: segnala agli hook di smettere di scrivere sui buffer live
        // PRIMA di leggerli. Poi aspettiamo 1ms come finestra conservativa
        // per garantire che eventuali hook già entrati (tra il check g_flushing
        // e il push_back) abbiano il tempo di completare.
        g_flushing.store(true, std::memory_order_seq_cst);
        struct timespec pause_ts{0, 1'000'000L};  // 1 ms
        nanosleep(&pause_ts, nullptr);

        for (auto* buf : live_bufs) emit_sync(*buf);

        out << "\n],\"displayTimeUnit\":\"us\"}\n";

        fprintf(stderr,
                "[high_level_so] Trace scritta: %s (%zu thread, %zu ancora attivi al flush)\n",
                path.c_str(), completed.size(), records.size());
    }
};

// Heap singleton (evita problemi ordine distruzione static)
static GlobalRegistry* g_reg = nullptr;

// ---------------------------------------------------------------------------
// Thread wrapper
// ---------------------------------------------------------------------------
struct ThreadWrapper {
    void*  (*real_fn)(void*);
    void*    real_arg;
    pthread_t handle;        // handle assegnato da pthread_create
};

static void* hl_thread_entry(void* arg) {
    auto* w = static_cast<ThreadWrapper*>(arg);
    auto  real_fn  = w->real_fn;
    auto  real_arg = w->real_arg;
    auto  handle   = w->handle;
    delete w;

    pid_t   my_tid   = get_tid();
    int64_t ts_start = now_us();

    if (g_reg) g_reg->thread_started(handle, my_tid, ts_start);

    // FIX v4: registra il buffer sync IMMEDIATAMENTE quando il thread parte,
    // prima che qualsiasi hook di sincronizzazione possa sparare su questo thread.
    // Precedentemente la registrazione era lazy (al primo hook chiamato), causando
    // una registrazione mancata per i thread del pool OpenMP che entrano subito
    // in pthread_cond_wait senza prima chiamare altri hook.
    // tl_in_hook=true previene che std::mutex interno di register_sync_buf
    // richiami ricorsivamente il nostro hook pthread_mutex_lock.
    if (g_reg && !tl_buf_registered) {
        tl_in_hook = true;
        g_reg->register_sync_buf(&tl_sync_events);
        tl_buf_registered = true;
        tl_in_hook = false;
    }

    void* result = real_fn(real_arg);

    int64_t ts_end = now_us();
    if (g_reg) g_reg->thread_ended(handle, ts_end);

    // Raccoglie gli eventi sync accumulati da questo thread prima che
    // il thread_local venga distrutto alla terminazione del thread
    if (g_reg && !tl_sync_events.empty())
        g_reg->collect_sync(tl_sync_events);

    return result;
}

// ---------------------------------------------------------------------------
// Hook pthread_create
// ---------------------------------------------------------------------------
using pthread_create_fn_t = int(*)(pthread_t*, const pthread_attr_t*,
                                    void*(*)(void*), void*);

extern "C" int pthread_create(pthread_t*            thread,
                               const pthread_attr_t* attr,
                               void*               (*start_routine)(void*),
                               void*                 arg) {
    static pthread_create_fn_t real_fn = nullptr;
    if (!real_fn)
        real_fn = reinterpret_cast<pthread_create_fn_t>(
            dlsym(RTLD_NEXT, "pthread_create"));

    int64_t ts_created  = now_us();
    pid_t   creator_tid = get_tid();

    auto* wrapper = new ThreadWrapper{start_routine, arg, {}};

    int ret = real_fn(thread, attr, hl_thread_entry, wrapper);

    if (ret == 0 && g_reg) {
        wrapper->handle = *thread;
        g_reg->create(*thread, creator_tid, ts_created);
    } else if (ret != 0) {
        delete wrapper;
    }
    return ret;
}

// ---------------------------------------------------------------------------
// Hook pthread_mutex_lock — registra quanto a lungo un thread aspetta un lock
// Filtro: attese < 1µs vengono scartate per non inondare la traccia
// ---------------------------------------------------------------------------
extern "C" int pthread_mutex_lock(pthread_mutex_t* m) {
    using fn_t = int(*)(pthread_mutex_t*);
    static fn_t real = (fn_t)dlsym(RTLD_NEXT, "pthread_mutex_lock");
    // FIX v4: controlla g_flushing — se il flush è in corso, passa direttamente
    if (tl_in_hook || !g_reg || g_flushing.load(std::memory_order_relaxed)) return real(m);

    tl_in_hook = true;
    // Registrazione lazy per thread non passati da hl_thread_entry (es. thread main)
    if (!tl_buf_registered) { g_reg->register_sync_buf(&tl_sync_events); tl_buf_registered = true; }
    int64_t t0 = now_us();
    tl_in_hook = false;

    int ret = real(m);

    tl_in_hook = true;
    int64_t t1 = now_us();
    if (t1 - t0 > 1)
        tl_sync_events.push_back({get_tid(), t0, t1, "mutex"});
    tl_in_hook = false;
    return ret;
}

// ---------------------------------------------------------------------------
// Hook pthread_barrier_wait — attesa alla barriera OpenMP
// Sempre registrata (anche breve): rivela il load imbalance tra i thread
// ---------------------------------------------------------------------------
extern "C" int pthread_barrier_wait(pthread_barrier_t* b) {
    using fn_t = int(*)(pthread_barrier_t*);
    static fn_t real = (fn_t)dlsym(RTLD_NEXT, "pthread_barrier_wait");
    // FIX v4: controlla g_flushing — se il flush è in corso, passa direttamente
    // NOTA: libgomp NON usa pthread_barrier_wait per le barriere OpenMP implicite.
    // Questo hook cattura solo barriere POSIX esplicite (pthread_barrier_t),
    // che muDock potrebbe non usare. Le barriere OpenMP vanno invece su cond_wait.
    if (tl_in_hook || !g_reg || g_flushing.load(std::memory_order_relaxed)) return real(b);

    tl_in_hook = true;
    if (!tl_buf_registered) { g_reg->register_sync_buf(&tl_sync_events); tl_buf_registered = true; }
    int64_t t0 = now_us();
    tl_in_hook = false;

    int ret = real(b);

    tl_in_hook = true;
    int64_t t1 = now_us();
    tl_sync_events.push_back({get_tid(), t0, t1, "barrier"});
    tl_in_hook = false;
    return ret;
}

// ---------------------------------------------------------------------------
// Hook pthread_cond_wait — thread del pool OpenMP in attesa di lavoro
// ---------------------------------------------------------------------------
extern "C" int pthread_cond_wait(pthread_cond_t* c, pthread_mutex_t* m) {
    using fn_t = int(*)(pthread_cond_t*, pthread_mutex_t*);
    static fn_t real = (fn_t)dlsym(RTLD_NEXT, "pthread_cond_wait");
    // FIX v4: controlla g_flushing — se il flush è in corso, passa direttamente
    // NOTA: questo è l'hook più importante per OpenMP. libgomp usa pthread_cond_wait
    // per mettere a riposo i thread del pool in attesa del prossimo task parallelo.
    if (tl_in_hook || !g_reg || g_flushing.load(std::memory_order_relaxed)) return real(c, m);

    tl_in_hook = true;
    if (!tl_buf_registered) { g_reg->register_sync_buf(&tl_sync_events); tl_buf_registered = true; }
    int64_t t0 = now_us();
    tl_in_hook = false;

    int ret = real(c, m);

    tl_in_hook = true;
    int64_t t1 = now_us();
    tl_sync_events.push_back({get_tid(), t0, t1, "cond_wait"});
    tl_in_hook = false;
    return ret;
}

// ---------------------------------------------------------------------------
// Init / Fini della libreria
// ---------------------------------------------------------------------------
__attribute__((constructor))
static void hl_init() {
    g_reg = new GlobalRegistry();
    fprintf(stderr,
            "[high_level_so] v4 caricata — pthread_create + mutex/barrier/cond_wait + race-fix\n");
}

__attribute__((destructor))
static void hl_fini() {
    if (!g_reg) return;
    const char* p = getenv("MUDOCK_TRACE_HL_OUT");
    g_reg->flush(p ? p : "trace_high_level.json");
}
