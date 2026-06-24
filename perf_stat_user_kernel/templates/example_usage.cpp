// =============================================================================
// example_usage.cpp — Esempio di utilizzo di aca_user_events
// =============================================================================
//
// Mostra come strumentare un'applicazione C++ con le macro ACA_USER_EVENT.
// Simula un loop di elaborazione con fasi seriali e parallele.
//
// Compilazione (dalla root di perf_stat_user_kernel):
//   make example
//
// Esecuzione (impostare le variabili prima del comando):
//   export ACA_USER_EVENT_1_NAME="FaseParsing"
//   export ACA_USER_EVENT_2_NAME="KernelComputazione"
//   export ACA_USER_EVENT_3_NAME="OutputRisultati"
//   export ACA_TRACE_USER_OUT="traces/example.json"
//   ./example_usage
//
// Poi apri traces/example.json su https://ui.perfetto.dev/
// =============================================================================

#include "aca_user_events.hpp"
#include <chrono>
#include <iostream>
#include <thread>
#include <vector>

// Simula una fase di parsing (tipicamente seriale)
void fase_parsing(int n_items) {
    ACA_USER_EVENT_START(1, "Parsing");
    for (int i = 0; i < n_items; ++i) {
        // Simula lavoro di I/O
        std::this_thread::sleep_for(std::chrono::microseconds(500));
    }
    ACA_USER_EVENT_STOP(1);
}

// Simula il kernel computazionale (può essere parallelizzato)
void kernel_computazione(int thread_id, int iterations) {
    ACA_USER_EVENT_START(2, "KernelCompute");
    // Simula calcolo intensivo
    volatile double result = 0.0;
    for (int i = 0; i < iterations; ++i) {
        result += static_cast<double>(i) * 0.001;
    }
    ACA_USER_EVENT_STOP(2);
    (void)result;
    (void)thread_id;
}

// Simula la fase di output
void fase_output() {
    ACA_USER_EVENT_START(3, "Output");
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
    ACA_USER_EVENT_STOP(3);
}

int main() {
    std::cout << "=== Esempio aca_user_events ===\n";
    std::cout << "Avvio elaborazione...\n";

    // Fase 1: Parsing seriale (codice non-user: overhead iniziale)
    std::this_thread::sleep_for(std::chrono::milliseconds(5));  // overhead sistema
    fase_parsing(10);

    // Fase 2: Kernel parallelo su 4 thread
    {
        std::vector<std::thread> workers;
        for (int t = 0; t < 4; ++t) {
            workers.emplace_back(kernel_computazione, t, 500'000);
        }
        for (auto& w : workers) w.join();
    }

    // Fase 3: Output seriale
    fase_output();

    // Il flush avviene automaticamente nel distruttore del singleton.
    // Puoi anche forzarlo manualmente con:
    ACA_USER_EVENTS_FLUSH();

    std::cout << "Fatto! Controlla il file JSON di output.\n";
    return 0;
}
