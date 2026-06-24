// =============================================================================
// aca_user_events.hpp — Tracciamento generico User Events per Perfetto
// =============================================================================
//
// Fornisce macro attivabili in fase di compilazione per marcare regioni di
// codice "utente" e distinguerle dal codice di sistema (I/O, overhead runtime).
//
// Utilizzo nel codice sorgente:
//   ACA_USER_EVENT_START(1, "NomeDiDefault");
//   // ... codice utente ...
//   ACA_USER_EVENT_STOP(1);
//
// Attivazione in compilazione:
//   -DACA_ENABLE_USER_EVENTS
//
// Configurazione a runtime (nomi e output via env):
//   ACA_USER_EVENT_1_NAME="MioEvento"   (sovrascrive il nome di default)
//   ACA_TRACE_USER_OUT="traccia.json"   (percorso file di output)
//
// Output: file JSON in formato Chrome Trace Event (compatibile Perfetto UI)
// =============================================================================
#pragma once

#include <cstdint>
#include <mutex>
#include <string>
#include <vector>

// ----------------------------------------------------------------------------
// Macro pubbliche — zero overhead se non compilate con -DACA_ENABLE_USER_EVENTS
// ----------------------------------------------------------------------------
#ifdef ACA_ENABLE_USER_EVENTS
  #define ACA_USER_EVENT_START(id, default_name) \
      aca::UserEventTracer::getInstance().startEvent((id), (default_name))
  #define ACA_USER_EVENT_STOP(id) \
      aca::UserEventTracer::getInstance().stopEvent((id))
  #define ACA_USER_EVENTS_FLUSH() \
      aca::UserEventTracer::getInstance().flush()
#else
  #define ACA_USER_EVENT_START(id, default_name)  ((void)0)
  #define ACA_USER_EVENT_STOP(id)                 ((void)0)
  #define ACA_USER_EVENTS_FLUSH()                 ((void)0)
#endif

namespace aca {

// Numero massimo di eventi supportati contemporaneamente
static constexpr int kMaxUserEvents = 10;

// Un singolo record di evento completato
struct UserEventRecord {
    int         id;           // ID evento (1..10)
    std::string name;         // Nome visualizzato in Perfetto
    int64_t     ts_start_us;  // Timestamp assoluto di inizio (CLOCK_MONOTONIC, µs)
    int64_t     duration_us;  // Durata in µs
    int         tid;          // Linux TID del thread che ha registrato l'evento
};

// =============================================================================
// UserEventTracer — Singleton thread-safe
// =============================================================================
// Design: ogni thread usa un thread_local RAII guard (ThreadFlushGuard) che al
// momento della sua distruzione (fine del thread) copia i record nel registro
// globale committed_events_, evitando dangling pointer.
// =============================================================================
class UserEventTracer {
public:
    static UserEventTracer& getInstance();

    // Registra l'inizio di un evento (id: 1..10)
    void startEvent(int id, const char* default_name);

    // Registra la fine di un evento e salva il record nel buffer thread-locale
    void stopEvent(int id);

    // Raccoglie tutti i record, calcola l'utilization, scrive il JSON Perfetto.
    // Invocato automaticamente dal distruttore; può essere chiamato manualmente.
    void flush(bool from_destructor = false);

    // Chiamato dal distruttore di ThreadFlushGuard — non invocare direttamente
    void commitThreadEvents(std::vector<UserEventRecord>& evts);

private:
    friend struct ThreadFlushGuard;
    UserEventTracer();
    ~UserEventTracer();

    UserEventTracer(const UserEventTracer&) = delete;
    UserEventTracer& operator=(const UserEventTracer&) = delete;

    // ---- Stato globale (protetto da static g_user_events_mutex) -------------
    std::vector<UserEventRecord> committed_events_; // record già committati dai thread
    int64_t                      program_start_us_;
    bool                         flushed_;
    std::string                  cached_names_[kMaxUserEvents]; // nomi da env var
};

} // namespace aca
