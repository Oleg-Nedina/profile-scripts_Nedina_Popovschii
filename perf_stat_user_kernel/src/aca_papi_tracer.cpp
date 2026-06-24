// =============================================================================
// aca_papi_tracer.cpp — Implementazione PapiTracer
// =============================================================================
// Hardware target: AMD Ryzen AI 7 PRO 350 (Zen 5), PAPI 7.2.0
//
// Nota Zen 5: PAPI_L3_TCM non è disponibile su questo hardware.
//             Usa PAPI_L1_DCM / PAPI_L2_DCM per l'analisi della gerarchia cache.
//
// Prerequisito runtime:
//   sudo sysctl -w kernel.perf_event_paranoid=-1
// =============================================================================
#include "aca_papi_tracer.hpp"
#include <papi.h>

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <sys/syscall.h>
#include <unistd.h>

namespace aca {

static std::mutex g_papi_mutex;
static PapiTracer* g_papi_instance = nullptr;

// ============================================================================
// KernelFlushGuard — RAII thread_local
// Al termine del thread, committa i record nel registro globale di PapiTracer,
// evitando il dangling pointer che si avrebbe mantenendo puntatori a thread_local.
// ============================================================================
struct KernelFlushGuard {
    int  event_set   = PAPI_NULL;
    bool initialized = false;

    std::vector<KernelRecord> records;
    std::vector<long long>    start_vals[kMaxKernels];
    int64_t                   start_time[kMaxKernels] = {};

    // Inizializza l'EventSet PAPI per il thread corrente (lazy, al primo uso)
    bool setup(const std::vector<int>& codes) {
        if (initialized) return (event_set != PAPI_NULL);
        initialized = true;

        if (codes.empty()) return false;

        if (PAPI_register_thread() != PAPI_OK) {
            std::cerr << "[aca_papi] Warning: PAPI_register_thread fallito (TID "
                      << syscall(SYS_gettid) << ") — contatori disabilitati per questo thread\n";
            return false;
        }

        if (PAPI_create_eventset(&event_set) != PAPI_OK) {
            std::cerr << "[aca_papi] Warning: PAPI_create_eventset fallito\n";
            event_set = PAPI_NULL;
            return false;
        }

        // Aggiunge gli eventi uno per uno; se uno fallisce, invalidiamo l'event set per evitare disallineamenti
        for (int code : codes) {
            int ret = PAPI_add_event(event_set, code);
            if (ret != PAPI_OK) {
                char name[PAPI_MAX_STR_LEN] = {};
                PAPI_event_code_to_name(code, name);
                std::cerr << "[aca_papi] Errore: impossibile aggiungere " << name
                          << " (" << PAPI_strerror(ret) << ") — disabilito profilazione per evitare disallineamenti di indici\n";
                PAPI_cleanup_eventset(event_set);
                PAPI_destroy_eventset(&event_set);
                event_set = PAPI_NULL;
                return false;
            }
        }

        if (PAPI_start(event_set) != PAPI_OK) {
            std::cerr << "[aca_papi] Errore: PAPI_start fallito\n"
                      << "  Verifica: sudo sysctl -w kernel.perf_event_paranoid=-1\n";
            PAPI_cleanup_eventset(event_set);
            PAPI_destroy_eventset(&event_set);
            event_set = PAPI_NULL;
            return false;
        }

        return true;
    }

    ~KernelFlushGuard() {
        if (event_set != PAPI_NULL) {
            std::vector<long long> dummy(64, 0LL);
            PAPI_stop(event_set, dummy.data());
            PAPI_cleanup_eventset(event_set);
            PAPI_destroy_eventset(&event_set);
            PAPI_unregister_thread();
        }
        if (!records.empty()) {
            std::lock_guard<std::mutex> lk(g_papi_mutex);
            if (g_papi_instance) {
                g_papi_instance->committed_records_.insert(
                    g_papi_instance->committed_records_.end(),
                    records.begin(), records.end()
                );
            }
        }
    }
};

static thread_local KernelFlushGuard tl_guard;

// ============================================================================
// Helpers
// ============================================================================
namespace {

inline pid_t get_tid() { return static_cast<pid_t>(syscall(SYS_gettid)); }

inline int64_t now_us() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return static_cast<int64_t>(ts.tv_sec) * 1'000'000LL
         + static_cast<int64_t>(ts.tv_nsec) / 1000LL;
}

std::string fmt_f(double v, int prec = 3) {
    std::ostringstream ss;
    ss << std::fixed << std::setprecision(prec) << v;
    return ss.str();
}

std::string fmt_ll(long long v) {
    std::string s = std::to_string(v < 0 ? 0LL : v);
    std::string out;
    out.reserve(s.size() + s.size() / 3);
    int n = static_cast<int>(s.size());
    for (int i = 0; i < n; ++i) {
        if (i > 0 && (n - i) % 3 == 0) out += '\'';
        out += s[i];
    }
    return out;
}

// Trova il valore di un evento per nome nel vettore dei contatori
long long find_counter(const std::vector<std::string>& names,
                       const std::vector<long long>&   vals,
                       const char*                     target) {
    for (size_t i = 0; i < names.size() && i < vals.size(); ++i)
        if (names[i] == target) return vals[i];
    return -1; // non trovato
}

// Stampa riga formattata nel report
void row(std::ofstream& out, const std::string& label, const std::string& value) {
    out << "  " << std::left  << std::setw(32) << label
                << std::right << std::setw(20) << value << "\n";
}

} // namespace

// ============================================================================
// Default eventi consigliati per AMD Zen 5 (aggiornati sulla base di papi_avail)
// Disponibili verificati: TOT_CYC, TOT_INS, L1_DCM, L2_DCM, BR_MSP, BR_PRC
// NON disponibile: L3_TCM (non mappato su Zen 5 via PAPI 7.2.0)
// ============================================================================
static const char* kDefaultEvents =
    "PAPI_TOT_CYC,PAPI_TOT_INS,PAPI_L1_DCM,PAPI_L2_DCM,PAPI_BR_MSP,PAPI_BR_PRC";

// ============================================================================
// Singleton
// ============================================================================
PapiTracer& PapiTracer::getInstance() {
    static PapiTracer instance;
    return instance;
}

PapiTracer::PapiTracer() : papi_supported_(false), reported_(false) {
    {
        std::lock_guard<std::mutex> lk(g_papi_mutex);
        g_papi_instance = this;
    }
    // Legge i nomi dei kernel dalle env var
    for (int i = 0; i < kMaxKernels; ++i) {
        char buf[40];
        snprintf(buf, sizeof(buf), "ACA_PAPI_KNL_%d_NAME", i + 1);
        const char* v = getenv(buf);
        cached_names_[i] = v ? std::string(v) : std::string();
    }
    initPapi();
}

PapiTracer::~PapiTracer() {
    report(true);
    std::lock_guard<std::mutex> lk(g_papi_mutex);
    g_papi_instance = nullptr;
    PAPI_shutdown();
}

void PapiTracer::initPapi() {
    int ret = PAPI_library_init(PAPI_VER_CURRENT);
    if (ret != PAPI_VER_CURRENT) {
        std::cerr << "[aca_papi] Errore: PAPI_library_init ("
                  << PAPI_strerror(ret) << ")\n";
        return;
    }
    if (PAPI_thread_init(pthread_self) != PAPI_OK) {
        std::cerr << "[aca_papi] Errore: PAPI_thread_init\n";
        return;
    }

    // Legge la lista di eventi: ACA_PAPI_EVENTS → default Zen 5
    const char* env = getenv("ACA_PAPI_EVENTS");
    std::string events_str = env ? env : kDefaultEvents;

    // Crea un EventSet temporaneo per testare quali contatori sono disponibili
    int dummy_set = PAPI_NULL;
    bool has_dummy = (PAPI_create_eventset(&dummy_set) == PAPI_OK);

    std::istringstream ss(events_str);
    std::string token;
    while (std::getline(ss, token, ',')) {
        token.erase(std::remove_if(token.begin(), token.end(), ::isspace), token.end());
        if (token.empty()) continue;

        int code = PAPI_NULL;
        ret = PAPI_event_name_to_code(token.c_str(), &code);
        if (ret == PAPI_OK) {
            if (has_dummy) {
                int add_ret = PAPI_add_event(dummy_set, code);
                if (add_ret == PAPI_OK) {
                    event_names_.push_back(token);
                    event_codes_.push_back(code);
                } else {
                    std::cerr << "[aca_papi] Warning: evento '" << token
                              << "' non supportato o incompatibile con le risorse correnti ("
                              << PAPI_strerror(add_ret) << ") — ignorato\n";
                }
            } else {
                event_names_.push_back(token);
                event_codes_.push_back(code);
            }
        } else {
            std::cerr << "[aca_papi] Warning: evento '" << token
                      << "' non riconosciuto (" << PAPI_strerror(ret) << ") — ignorato\n";
        }
    }

    if (has_dummy) {
        PAPI_cleanup_eventset(dummy_set);
        PAPI_destroy_eventset(&dummy_set);
    }

    if (event_codes_.empty()) {
        std::cerr << "[aca_papi] Errore: nessun evento valido configurato.\n"
                  << "  Controlla ACA_PAPI_EVENTS e verifica con: papi_avail\n";
        return;
    }

    papi_supported_ = true;

    const PAPI_hw_info_t* hw = PAPI_get_hardware_info();
    std::cerr << "[aca_papi] ✓ Inizializzato su "
              << (hw ? hw->model_string : "hardware sconosciuto")
              << "\n  Contatori (" << event_codes_.size() << "):";
    for (const auto& n : event_names_) std::cerr << "  " << n;
    std::cerr << "\n";
}

// ============================================================================
// commitThreadRecords
// ============================================================================
void PapiTracer::commitThreadRecords(std::vector<KernelRecord>& recs) {
    std::lock_guard<std::mutex> lk(g_papi_mutex);
    if (g_papi_instance) {
        g_papi_instance->committed_records_.insert(
            g_papi_instance->committed_records_.end(),
            recs.begin(), recs.end()
        );
    }
    recs.clear();
}

// ============================================================================
// startKernel / stopKernel
// ============================================================================
void PapiTracer::startKernel(int id, const char* /*default_name*/) {
    if (!papi_supported_ || id < 1 || id > kMaxKernels) return;
    const int idx = id - 1;

    if (!tl_guard.initialized)
        if (!tl_guard.setup(event_codes_)) return;
    if (tl_guard.event_set == PAPI_NULL) return;

    std::vector<long long> vals(event_codes_.size(), 0LL);
    if (PAPI_read(tl_guard.event_set, vals.data()) != PAPI_OK) return;

    tl_guard.start_vals[idx] = vals;
    tl_guard.start_time[idx] = now_us();
}

void PapiTracer::stopKernel(int id) {
    if (!papi_supported_ || id < 1 || id > kMaxKernels) return;
    const int idx = id - 1;

    if (tl_guard.start_time[idx] == 0) return;

    const int64_t t_end   = now_us();
    const int64_t elapsed = t_end - tl_guard.start_time[idx];
    tl_guard.start_time[idx] = 0;

    std::vector<long long> end_vals(event_codes_.size(), 0LL);
    if (tl_guard.event_set == PAPI_NULL ||
        PAPI_read(tl_guard.event_set, end_vals.data()) != PAPI_OK) return;

    // Delta = valore finale − valore iniziale
    std::vector<long long> delta(event_codes_.size(), 0LL);
    const auto& sv = tl_guard.start_vals[idx];
    for (size_t i = 0; i < event_codes_.size(); ++i) {
        delta[i] = end_vals[i] - (i < sv.size() ? sv[i] : 0LL);
        if (delta[i] < 0) delta[i] = 0; // difesa contro rollover contatori
    }

    const std::string& cached = cached_names_[idx];
    std::string name = cached.empty() ? ("Kernel-" + std::to_string(id)) : cached;
    const int tid = get_tid();

    // Cerca record esistente (stessa coppia id+tid) → accumula
    auto it = std::find_if(tl_guard.records.begin(), tl_guard.records.end(),
                           [id, tid](const KernelRecord& r) {
                               return r.id == id && r.tid == tid;
                           });
    if (it == tl_guard.records.end()) {
        KernelRecord rec;
        rec.id          = id;
        rec.name        = name;
        rec.tid         = tid;
        rec.call_count  = 1;
        rec.elapsed_us  = elapsed;
        rec.hw_counters = delta;
        tl_guard.records.push_back(std::move(rec));
    } else {
        it->call_count++;
        it->elapsed_us += elapsed;
        for (size_t i = 0; i < delta.size() && i < it->hw_counters.size(); ++i)
            it->hw_counters[i] += delta[i];
    }
}

// ============================================================================
// report
// ============================================================================
void PapiTracer::report(bool from_destructor) {
    if (!from_destructor) {
        if (!tl_guard.records.empty()) {
            commitThreadRecords(tl_guard.records);
        }
    }
    std::lock_guard<std::mutex> lk(g_papi_mutex);
    if (reported_) return;
    reported_ = true;

    if (committed_records_.empty()) {
        std::cerr << "[aca_papi] Nessun record da riportare.\n";
        return;
    }

    const char* env_out = getenv("ACA_PAPI_REPORT_OUT");
    const std::string path = env_out ? env_out : "kpi_hotspots.txt";

    // Crea directory se necessario
    {
        auto slash = path.rfind('/');
        if (slash != std::string::npos) {
            std::string dir = path.substr(0, slash);
            if (!dir.empty()) {
                std::string cmd = "mkdir -p '" + dir + "' 2>/dev/null";
                if (system(cmd.c_str()) != 0) { /* silenzioso */ }
            }
        }
    }

    std::ofstream out(path);
    if (!out.is_open()) {
        std::cerr << "[aca_papi] Errore: impossibile scrivere " << path << "\n";
        return;
    }

    const PAPI_hw_info_t* hw = PAPI_get_hardware_info();
    std::string model = hw ? hw->model_string : "hardware sconosciuto";

    out << "{\n";
    out << "  \"hardware\": {\n";
    out << "    \"model\": \"" << model << "\",\n";
    out << "    \"papi_version\": \"7.2.0\"\n";
    out << "  },\n";

    out << "  \"events\": [";
    for (size_t i = 0; i < event_names_.size(); ++i) {
        out << "\"" << event_names_[i] << "\"";
        if (i + 1 < event_names_.size()) out << ", ";
    }
    out << "],\n";

    // Raccoglie kernel ID unici
    std::vector<int> kernel_ids;
    for (const auto& r : committed_records_) {
        if (std::find(kernel_ids.begin(), kernel_ids.end(), r.id) == kernel_ids.end())
            kernel_ids.push_back(r.id);
    }
    std::sort(kernel_ids.begin(), kernel_ids.end());

    out << "  \"kernels\": [\n";
    for (size_t k_idx = 0; k_idx < kernel_ids.size(); ++k_idx) {
        int kid = kernel_ids[k_idx];
        std::string kname;
        int64_t     total_us    = 0;
        int         total_calls = 0;
        std::vector<long long> sum_hw(event_names_.size(), 0LL);
        std::vector<const KernelRecord*> krecs;

        for (const auto& r : committed_records_) {
            if (r.id != kid) continue;
            krecs.push_back(&r);
            if (kname.empty()) kname = r.name;
            total_us    += r.elapsed_us;
            total_calls += r.call_count;
            for (size_t i = 0; i < event_names_.size() && i < r.hw_counters.size(); ++i)
                sum_hw[i] += r.hw_counters[i];
        }

        out << "    {\n";
        out << "      \"id\": " << kid << ",\n";
        out << "      \"name\": \"" << kname << "\",\n";
        out << "      \"total_calls\": " << total_calls << ",\n";
        out << "      \"total_time_us\": " << total_us << ",\n";
        out << "      \"thread_count\": " << krecs.size() << ",\n";

        out << "      \"aggregated_counters\": [";
        for (size_t i = 0; i < event_names_.size(); ++i) {
            out << sum_hw[i];
            if (i + 1 < event_names_.size()) out << ", ";
        }
        out << "],\n";

        out << "      \"threads\": [\n";
        for (size_t t_idx = 0; t_idx < krecs.size(); ++t_idx) {
            const auto* rp = krecs[t_idx];
            out << "        {\n";
            out << "          \"tid\": " << rp->tid << ",\n";
            out << "          \"calls\": " << rp->call_count << ",\n";
            out << "          \"time_us\": " << rp->elapsed_us << ",\n";
            out << "          \"counters\": [";
            for (size_t i = 0; i < event_names_.size(); ++i) {
                long long val = (i < rp->hw_counters.size()) ? rp->hw_counters[i] : 0LL;
                out << val;
                if (i + 1 < event_names_.size()) out << ", ";
            }
            out << "]\n";
            out << "        }";
            if (t_idx + 1 < krecs.size()) out << ",";
            out << "\n";
        }
        out << "      ]\n";

        out << "    }";
        if (k_idx + 1 < kernel_ids.size()) out << ",";
        out << "\n";
    }
    out << "  ]\n";
    out << "}\n";

    out.close();
    std::cerr << "[aca_papi] ✓ Report JSON: " << path
              << " (" << kernel_ids.size() << " kernel, "
              << committed_records_.size() << " thread records)\n";
}

} // namespace aca
