// =============================================================================
// example_papi.cpp — Esempio di utilizzo di aca_papi_tracer
// =============================================================================
//
// Mostra come strumentare un hotspot computazionale con le macro ACA_PAPI.
// Simula due kernel: uno compute-bound (IPC alto) e uno memory-bound
// (accesso stride grande → molti cache miss).
//
// Compilazione (dalla root di perf_stat_user_kernel):
//   make example_papi
//
// Prerequisito hardware:
//   sudo sysctl -w kernel.perf_event_paranoid=-1
//
// Esecuzione:
//   export ACA_PAPI_EVENTS="PAPI_TOT_CYC,PAPI_TOT_INS,PAPI_L3_TCM,PAPI_BR_MSP,PAPI_BR_PRC"
//   export ACA_PAPI_KNL_1_NAME="ComputeBound"
//   export ACA_PAPI_KNL_2_NAME="MemoryBound"
//   export ACA_PAPI_REPORT_OUT="traces/kpi_example.txt"
//   ./example_papi
// =============================================================================

#include "aca_papi_tracer.hpp"

#include <cmath>
#include <cstdint>
#include <iostream>
#include <thread>
#include <vector>

// Kernel 1: compute-bound (molte istruzioni per ciclo, tutto in cache)
void kernel_compute_bound(int n) {
    ACA_PAPI_KNL_START(1, "ComputeBound");
    volatile double acc = 0.0;
    for (int i = 0; i < n; ++i) {
        acc += std::sin(static_cast<double>(i) * 0.001) * std::cos(static_cast<double>(i) * 0.001);
    }
    ACA_PAPI_KNL_STOP(1);
    (void)acc;
}

// Kernel 2: memory-bound (accesso con stride grande → cache miss elevati)
void kernel_memory_bound(std::vector<int64_t>& arr, int stride) {
    ACA_PAPI_KNL_START(2, "MemoryBound");
    volatile int64_t sum = 0;
    const int n = static_cast<int>(arr.size());
    for (int i = 0; i < n; i += stride) {
        sum += arr[i];
    }
    ACA_PAPI_KNL_STOP(2);
    (void)sum;
}

// Wrapper per esecuzione multi-thread del kernel compute
void worker_compute(int id, int n) {
    (void)id;
    // Ogni thread misura il proprio kernel (contatori hardware indipendenti)
    kernel_compute_bound(n);
}

int main() {
    std::cout << "=== Esempio aca_papi_tracer ===\n";

    // ---- Kernel 1: compute-bound (main thread, 3 invocazioni) ---------------
    std::cout << "Avvio kernel compute-bound (3 iterazioni, main thread)...\n";
    for (int run = 0; run < 3; ++run) {
        kernel_compute_bound(500'000);
    }

    // ---- Kernel 2: memory-bound con stride grande (main thread) --------------
    std::cout << "Avvio kernel memory-bound (stride=256, array 64MB)...\n";
    const int N = 8'000'000;
    std::vector<int64_t> big_array(N, 1LL);
    // Primo accesso: stride=1 (cache-friendly)
    kernel_memory_bound(big_array, 1);

    // ---- Kernel 2 multi-thread: ogni thread ha i propri contatori hw --------
    std::cout << "Avvio kernel memory-bound parallelo (4 thread, stride=256)...\n";
    {
        std::vector<std::thread> workers;
        for (int t = 0; t < 4; ++t) {
            workers.emplace_back([&big_array]() {
                kernel_memory_bound(big_array, 256);
            });
        }
        for (auto& w : workers) w.join();
    }

    // Il report viene scritto automaticamente nel distruttore del singleton.
    // Si può forzare manualmente con:
    ACA_PAPI_REPORT();

    std::cout << "Fatto! Controlla il file di report indicato da ACA_PAPI_REPORT_OUT.\n";
    return 0;
}
