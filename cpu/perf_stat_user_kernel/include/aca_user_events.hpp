/**
 * @file aca_user_events.hpp
 * @brief Generic User Events Tracking for Perfetto.
 *
 * Provides compile-time macros to mark "user" code regions and distinguish
 * them from system execution (I/O, scheduler, or runtime overhead).
 * Writes Chrome Trace Event JSON trace files compatible with Perfetto UI.
 */

#pragma once

#include <cstdint>
#include <mutex>
#include <string>
#include <vector>

/**
 * @def ACA_USER_EVENT_START
 * @brief Mark the beginning of a user event timeline slice.
 * @param id The event identifier (must be between 1 and 10).
 * @param default_name Fallback label for the event.
 */
/**
 * @def ACA_USER_EVENT_STOP
 * @brief Mark the end of a user event timeline slice.
 * @param id The event identifier (must be between 1 and 10).
 */
/**
 * @def ACA_USER_EVENTS_FLUSH
 * @brief Manually flush collected events to JSON.
 */
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

/**
 * @brief Maximum number of concurrent events supported.
 */
static constexpr int kMaxUserEvents = 10;

/**
 * @struct UserEventRecord
 * @brief Data record representing a completed event slice.
 */
struct UserEventRecord {
    int         id;           /**< Event ID (1..10) */
    std::string name;         /**< Name displayed in the Perfetto interface */
    int64_t     ts_start_us;  /**< Absolute starting timestamp (CLOCK_MONOTONIC, µs) */
    int64_t     duration_us;  /**< Event duration in µs */
    int         tid;          /**< Linux thread ID (TID) that recorded the event */
};

/**
 * @class UserEventTracer
 * @brief Thread-safe singleton tracer for user events.
 *
 * Each active thread records event timings in local buffers. A thread-local
 * RAII guard commits these records to the global list when the thread exits,
 * avoiding lock contention and dangling pointers during exit.
 */
class UserEventTracer {
public:
    /**
     * @brief Get the singleton instance of UserEventTracer.
     * @return Reference to the singleton instance.
     */
    static UserEventTracer& getInstance();

    /**
     * @brief Mark the beginning of an event slice.
     * @param id The event identifier (1..10).
     * @param default_name Fallback label for the event.
     */
    void startEvent(int id, const char* default_name);

    /**
     * @brief Mark the end of an event slice.
     * @param id The event identifier (1..10).
     */
    void stopEvent(int id);

    /**
     * @brief Aggregates all thread data, computes CPU utilization, and writes the JSON trace.
     * @param from_destructor True if invoked during static destruction.
     */
    void flush(bool from_destructor = false);

    /**
     * @brief Commit thread-local records to the global event repository.
     * @param evts Vector of thread-local event records.
     */
    void commitThreadEvents(std::vector<UserEventRecord>& evts);

private:
    friend struct ThreadFlushGuard;
    UserEventTracer();
    ~UserEventTracer();

    UserEventTracer(const UserEventTracer&) = delete;
    UserEventTracer& operator=(const UserEventTracer&) = delete;

    std::vector<UserEventRecord> committed_events_; /**< Accumulated event records */
    int64_t                      program_start_us_; /**< Program start timestamp */
    bool                         flushed_;          /**< Trace flush status flag */
    std::string                  cached_names_[kMaxUserEvents]; /**< Cached labels from env */
};

} // namespace aca
