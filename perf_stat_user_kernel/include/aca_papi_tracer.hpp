// =============================================================================
// aca_papi_tracer.hpp — Profiling Hardware Hotspot via PAPI API
// =============================================================================
//
// Fornisce macro compile-time per misurare i contatori hardware PMU
// esclusivamente nelle regioni di codice "kernel" (hotspot computazionali),
// isolandole dall'overhead di inizializzazione, I/O, e sistema.
//
// Utilizzo nel codice sorgente:
//   ACA_PAPI_KNL_START(1, "NomeKernel");
//   // ... loop computazionale caldo ...
//   ACA_PAPI_KNL_STOP(1);
//
// Attivazione in compilazione (richiede -lpapi e path include corretto):
//   -DACA_ENABLE_PAPI -I<papi_include_dir> -L<papi_lib_dir> -lpapi
//
// Configurazione a runtime via env:
//   ACA_PAPI_EVENTS="PAPI_TOT_CYC,PAPI_TOT_INS,PAPI_L3_TCM"
//   ACA_PAPI_KNL_1_NAME="MioKernel"
//   ACA_PAPI_REPORT_OUT="kpi_hotspots.txt"
//
// PREREQUISITO HARDWARE:
//   sudo sysctl -w kernel.perf_event_paranoid=-1
//   (richiesto una volta per sessione per abilitare i PMU hardware)
//
// Output: report testuale con contatori grezzi e metriche derivate
//         (IPC, MPKI, Branch Miss Rate, ecc.) per ogni hotspot e thread.
// =============================================================================
#pragma once

#include <cstdint>
#include <mutex>
#include <string>
#include <vector>

// ----------------------------------------------------------------------------
// Macro pubbliche — zero overhead se non compilate con -DACA_ENABLE_PAPI
// ----------------------------------------------------------------------------
#ifdef ACA_ENABLE_PAPI
  #define ACA_PAPI_KNL_START(id, default_name) \
      aca::PapiTracer::getInstance().startKernel((id), (default_name))
  #define ACA_PAPI_KNL_STOP(id) \
      aca::PapiTracer::getInstance().stopKernel((id))
  #define ACA_PAPI_REPORT() \
      aca::PapiTracer::getInstance().report()
#else
  #define ACA_PAPI_KNL_START(id, default_name) ((void)0)
  #define ACA_PAPI_KNL_STOP(id)                ((void)0)
  #define ACA_PAPI_REPORT()                    ((void)0)
#endif

namespace aca {

static constexpr int kMaxKernels = 10;

// Un record accumulato per un singolo kernel su un singolo thread
struct KernelRecord {
    int         id;           // ID kernel (1..10)
    std::string name;         // Nome del kernel
    int         tid;          // Linux TID
    int         call_count;   // Numero di invocazioni accumulate
    int64_t     elapsed_us;   // Tempo totale trascorso nel kernel (µs)

    // Contatori PAPI accumulati (parallelo a PapiTracer::event_names_)
    std::vector<long long> hw_counters;
};

// =============================================================================
// PapiTracer — Singleton thread-safe per profiling hardware hotspot
// =============================================================================
// Design: stesso pattern RAII del UserEventTracer.
// Ogni thread ha un KernelFlushGuard thread_local che al momento della sua
// distruzione committa i record nel vettore globale, evitando dangling pointer.
// =============================================================================
class PapiTracer {
public:
    static PapiTracer& getInstance();

    // Avvia la lettura dei contatori HW per il kernel `id`
    void startKernel(int id, const char* default_name);

    // Ferma i contatori e accumula il delta nel record del thread corrente
    void stopKernel(int id);

    // Scrive il report testuale su file. Chiamato automaticamente dal distruttore.
    void report(bool from_destructor = false);

    // Chiamato dal distruttore di KernelFlushGuard — non invocare direttamente
    void commitThreadRecords(std::vector<KernelRecord>& recs);

    // Stato PAPI (usato da KernelFlushGuard per inizializzare l'EventSet per thread)
    bool isPapiSupported()          const { return papi_supported_; }
    const std::vector<int>& eventCodes() const { return event_codes_; }
    const std::string&      kernelName(int idx) const { return cached_names_[idx]; }

private:
    friend struct KernelFlushGuard;
    PapiTracer();
    ~PapiTracer();

    PapiTracer(const PapiTracer&) = delete;
    PapiTracer& operator=(const PapiTracer&) = delete;

    void initPapi();

    // ---- Stato globale (protetto da static g_papi_mutex) ---------------------
    bool                         papi_supported_;
    bool                         reported_;
    std::vector<std::string>     event_names_;   // nomi leggibili dei contatori
    std::vector<int>             event_codes_;   // codici PAPI corrispondenti
    std::string                  cached_names_[kMaxKernels];
    std::vector<KernelRecord>    committed_records_; // record committati dai thread
};

} // namespace aca
