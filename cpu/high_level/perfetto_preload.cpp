// =============================================================================
// perfetto_preload.cpp  —  LD_PRELOAD wrapper using Perfetto SDK natively
// =============================================================================
//
// Questa libreria intercetta la creazione dei thread tramite pthread_create,
// inizializza l'SDK in-process di Perfetto all'avvio e salva una traccia nativa
// in formato .pftrace (Protocol Buffer) senza toccare il codice di muDock.
//
// Funzionalità:
//   - Traccia il lifecycle di ogni thread (BEGIN/END con nome leggibile)
//   - Counter "ParallelThreads" per visualizzare il parallelismo in tempo reale
//   - Nome del thread automatico nella timeline Perfetto
//   - Buffer configurabile via variabile d'ambiente
//   - Gestione sicura del flush anche in presenza di abort/crash
//
// Utilizzo:
//   LD_PRELOAD=./libperfetto_preload.so \
//   MUDOCK_TRACE_PERFETTO_OUT=traces/muDock.pftrace \
//   MUDOCK_PERFETTO_BUF_MB=128 \
//   ./build/application/muDock ...
//
// Variabili d'ambiente:
//   MUDOCK_TRACE_PERFETTO_OUT  Percorso del file .pftrace (default: traces/muDock.pftrace)
//   MUDOCK_PERFETTO_BUF_MB     Dimensione buffer in MB (default: 64, max: 1024)
// =============================================================================

#include "perfetto_sdk/perfetto.h"
#include <pthread.h>
#include <dlfcn.h>
#include <atomic>
#include <iostream>
#include <fstream>
#include <memory>
#include <unistd.h>
#include <sys/types.h>
#include <sys/syscall.h>
#include <string>
#include <cstdlib>
#include <climits>

// Definisce la categoria per gli eventi muDock
PERFETTO_DEFINE_CATEGORIES(
    perfetto::Category("mudock")
        .SetDescription("muDock molecular docking events"),
    perfetto::Category("thread")
        .SetDescription("Thread lifecycle events")
);

// Alloca le strutture statiche necessarie all'SDK
PERFETTO_TRACK_EVENT_STATIC_STORAGE();

namespace {

std::unique_ptr<perfetto::TracingSession> g_session;
std::atomic<int>  g_active_threads{0};
std::atomic<int>  g_thread_index{0};   // indice progressivo per i thread worker
std::atomic<bool> g_flushed{false};    // evita doppio flush

static inline pid_t get_tid() {
    return static_cast<pid_t>(syscall(SYS_gettid));
}

// Legge una variabile d'ambiente come intero con valore di default
static int getenv_int(const char* name, int default_val, int max_val = INT_MAX) {
    const char* val = getenv(name);
    if (!val) return default_val;
    int parsed = atoi(val);
    if (parsed <= 0) return default_val;
    if (parsed > max_val) return max_val;
    return parsed;
}

// Struttura di supporto per passare gli argomenti al thread entry wrapper
struct ThreadWrapper {
    void*  (*real_fn)(void*);
    void*    real_arg;
    int      index;       // indice progressivo del thread (per il nome)
};

// Wrapper della funzione del thread per iniettare gli eventi Perfetto
static void* hl_thread_entry(void* arg) {
    auto* w = static_cast<ThreadWrapper*>(arg);
    auto  real_fn  = w->real_fn;
    auto  real_arg = w->real_arg;
    int   idx      = w->index;
    delete w;

    // Nomina il thread nella timeline Perfetto (visibile como label nella lane)
    std::string thread_name = "Worker-" + std::to_string(idx)
                            + " [TID " + std::to_string(get_tid()) + "]";
    perfetto::ThreadTrack track = perfetto::ThreadTrack::Current();
    perfetto::protos::gen::TrackDescriptor desc = track.Serialize();
    desc.set_name(thread_name);
    perfetto::TrackEvent::SetTrackDescriptor(track, desc);

    // Aggiorna il counter di thread attivi
    int active = ++g_active_threads;
    TRACE_COUNTER("mudock", "ParallelThreads", active);

    // Marca l'inizio della vita del thread con nome identificativo
    TRACE_EVENT_BEGIN("thread", "Thread Execution",
        perfetto::ThreadTrack::Current(),
        "thread_index", idx,
        "tid", static_cast<int>(get_tid()));

    void* result = real_fn(real_arg);

    TRACE_EVENT_END("thread");

    // Decrementa il counter
    active = --g_active_threads;
    TRACE_COUNTER("mudock", "ParallelThreads", active);

    return result;
}

} // namespace

// Intercetta la chiamata a pthread_create
extern "C" int pthread_create(pthread_t*            thread,
                               const pthread_attr_t* attr,
                               void*               (*start_routine)(void*),
                               void*                 arg) {
    using pthread_create_fn_t = int(*)(pthread_t*, const pthread_attr_t*, void*(*)(void*), void*);
    static pthread_create_fn_t real_fn = nullptr;
    if (!real_fn) {
        real_fn = reinterpret_cast<pthread_create_fn_t>(dlsym(RTLD_NEXT, "pthread_create"));
    }

    // Assegna un indice progressivo al thread
    int idx = ++g_thread_index;

    // Incapsula la start_routine con metadati
    auto* wrapper = new ThreadWrapper{start_routine, arg, idx};
    int ret = real_fn(thread, attr, hl_thread_entry, wrapper);

    if (ret != 0) {
        delete wrapper;
    }
    return ret;
}

// Esegue il flush della traccia su disco
static void do_flush() {
    // Flag atomico: esegui il flush al massimo una volta
    if (g_flushed.exchange(true)) return;

    TRACE_EVENT_END("mudock");   // chiudi l'evento "Main Execution"
    TRACE_COUNTER("mudock", "ParallelThreads", 0);

    if (!g_session) return;

    g_session->StopBlocking();
    std::vector<char> trace_data = g_session->ReadTraceBlocking();

    // Determina il percorso del file di output
    const char* env_path = getenv("MUDOCK_TRACE_PERFETTO_OUT");
    std::string path = env_path ? env_path : "traces/muDock.pftrace";

    // Crea le directory intermedie se necessario
    std::string dir = path.substr(0, path.rfind('/'));
    if (!dir.empty() && dir != path) {
        // mkdir -p via system() — non critico se fallisce
        system(("mkdir -p '" + dir + "' 2>/dev/null").c_str());
    }

    std::ofstream output(path, std::ios::binary);
    if (output.is_open()) {
        output.write(trace_data.data(), static_cast<std::streamsize>(trace_data.size()));
        output.close();
        std::cerr << "[perfetto_preload] ✓ Traccia salvata: " << path
                  << " (" << (trace_data.size() / 1024) << " KB, "
                  << g_thread_index.load() << " thread tracciati)"
                  << std::endl;
    } else {
        std::cerr << "[perfetto_preload] ✗ Errore: impossibile scrivere su: " << path << std::endl;
    }
}

// Inizializza l'SDK di Perfetto all'avvio della libreria dinamica
void __attribute__((constructor)) init_perfetto_preload() {
    // Configura e inizializza l'SDK in-process (non richiede demoni root)
    perfetto::TracingInitArgs args;
    args.backends = perfetto::kInProcessBackend;
    perfetto::Tracing::Initialize(args);
    perfetto::TrackEvent::Register();

    // Dimensione buffer configurabile via env (default 64 MB, max 1024 MB)
    int buf_mb = getenv_int("MUDOCK_PERFETTO_BUF_MB", 64, 1024);

    // Definisce la sessione di tracciamento
    perfetto::TraceConfig cfg;
    cfg.add_buffers()->set_size_kb(static_cast<uint32_t>(buf_mb) * 1024u);

    auto* ds_cfg = cfg.add_data_sources()->mutable_config();
    ds_cfg->set_name("track_event");

    g_session = perfetto::Tracing::NewTrace(perfetto::kInProcessBackend);
    g_session->Setup(cfg);
    g_session->StartBlocking();

    // Marca il main thread e avvia il counter
    {
        std::string main_name = "Main [TID " + std::to_string(get_tid()) + "]";
        perfetto::ThreadTrack track = perfetto::ThreadTrack::Current();
        perfetto::protos::gen::TrackDescriptor desc = track.Serialize();
        desc.set_name(main_name);
        perfetto::TrackEvent::SetTrackDescriptor(track, desc);
    }

    g_active_threads = 1;
    TRACE_COUNTER("mudock", "ParallelThreads", 1);
    TRACE_EVENT_BEGIN("mudock", "Main Execution");

    std::cerr << "[perfetto_preload] SDK Perfetto inizializzato"
              << " (buffer: " << buf_mb << " MB, in-process backend)" << std::endl;
}

// Ferma il tracciamento e scrive il file pftrace al termine dell'applicazione
void __attribute__((destructor)) fini_perfetto_preload() {
    do_flush();
}
