/**
 * @file aca_papi_tracer.hpp
 * @brief Profiling Hardware Hotspots via PAPI API.
 *
 * Provides compile-time macros to measure hardware PMU performance counters
 * exclusively inside "kernel" regions (computational hotspots), isolating
 * them from the overhead of initialization, system libraries, and file I/O.
 */

#pragma once

#include <cstdint>
#include <mutex>
#include <string>
#include <vector>

/**
 * @def ACA_PAPI_KNL_START
 * @brief Start hardware performance counter collection for a computational kernel hotspot.
 * @param id The kernel identifier (must be between 1 and 10).
 * @param default_name Fallback label for the kernel.
 */
/**
 * @def ACA_PAPI_KNL_STOP
 * @brief Stop hardware performance counter collection for a computational kernel hotspot.
 * @param id The kernel identifier (must be between 1 and 10).
 */
/**
 * @def ACA_PAPI_REPORT
 * @brief Trigger final PAPI report generation.
 */
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

/**
 * @brief Maximum number of kernels supported.
 */
static constexpr int kMaxKernels = 10;

/**
 * @struct KernelRecord
 * @brief Accumulated hardware counters data for a single kernel on a single thread.
 */
struct KernelRecord {
    int         id;           /**< Kernel ID (1..10) */
    std::string name;         /**< Kernel label */
    int         tid;          /**< Linux thread ID (TID) */
    int         call_count;   /**< Accumulated invocation count */
    int64_t     elapsed_us;   /**< Total elapsed time inside the kernel (µs) */
    std::vector<long long> hw_counters; /**< Hardware counters (parallel to PapiTracer::event_names_) */
};

/**
 * @class PapiTracer
 * @brief Thread-safe singleton for hotspot performance profiling.
 *
 * Allocates thread-local EventSets to track performance events on active threads
 * and aggregates results into a global registry.
 */
class PapiTracer {
public:
    /**
     * @brief Get the singleton instance of PapiTracer.
     * @return Reference to the singleton instance.
     */
    static PapiTracer& getInstance();

    /**
     * @brief Starts the PAPI hardware events collection.
     * @param id Kernel ID (1..10).
     * @param default_name Default label for the kernel.
     */
    void startKernel(int id, const char* default_name);

    /**
     * @brief Stops PAPI counters and calculates delta values.
     * @param id Kernel ID (1..10).
     */
    void stopKernel(int id);

    /**
     * @brief Formats and writes the performance report to a JSON file.
     * @param from_destructor True if invoked during static destruction.
     */
    void report(bool from_destructor = false);

    /**
     * @brief Commits thread-local records to the global registry.
     * @param recs Thread-local kernel records vector.
     */
    void commitThreadRecords(std::vector<KernelRecord>& recs);

    /**
     * @brief Verify if PAPI is initialized and supported.
     * @return True if initialized successfully.
     */
    bool isPapiSupported()          const { return papi_supported_; }

    /**
     * @brief Get the list of active PAPI event codes.
     * @return Reference to the event codes vector.
     */
    const std::vector<int>& eventCodes() const { return event_codes_; }

    /**
     * @brief Get the kernel name label at a given index.
     * @param idx The index (0..kMaxKernels-1).
     * @return The cached name string.
     */
    const std::string&      kernelName(int idx) const { return cached_names_[idx]; }

private:
    friend struct KernelFlushGuard;
    PapiTracer();
    ~PapiTracer();

    PapiTracer(const PapiTracer&) = delete;
    PapiTracer& operator=(const PapiTracer&) = delete;

    void initPapi();

    bool                         papi_supported_;
    bool                         reported_;
    std::vector<std::string>     event_names_;       /**< Active event labels */
    std::vector<int>             event_codes_;       /**< Active event PAPI codes */
    std::string                  cached_names_[kMaxKernels];
    std::vector<KernelRecord>    committed_records_; /**< Accumulated kernel records */
};

} // namespace aca
