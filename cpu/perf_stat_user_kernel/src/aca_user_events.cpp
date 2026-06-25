/**
 * @file aca_user_events.cpp
 * @brief UserEventTracer class implementation.
 */

#include "aca_user_events.hpp"

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <sys/syscall.h>
#include <unistd.h>

namespace aca {

static std::mutex g_user_events_mutex;
static UserEventTracer* g_user_events_instance = nullptr;

namespace {
/**
 * @struct UserEventTracerInitializer
 * @brief Helper utility to trigger singleton instantiation at startup.
 */
struct UserEventTracerInitializer {
    UserEventTracerInitializer() {
        UserEventTracer::getInstance();
    }
} g_user_event_tracer_initializer;
} // namespace

namespace {

/**
 * @brief Fetch the current Linux thread ID.
 * @return Linux TID.
 */
inline pid_t get_tid() {
    return static_cast<pid_t>(syscall(SYS_gettid));
}

/**
 * @brief Get absolute monotonic clock timestamp.
 * @return Timestamp in microseconds.
 */
inline int64_t now_us() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return static_cast<int64_t>(ts.tv_sec) * 1'000'000LL
         + static_cast<int64_t>(ts.tv_nsec) / 1000LL;
}

} // namespace

/**
 * @struct ThreadFlushGuard
 * @brief Thread-local guard that flushes thread records upon exit.
 */
struct ThreadFlushGuard {
    std::vector<UserEventRecord> events;
    int64_t starts[kMaxUserEvents] = {};
    bool registered = false;

    ~ThreadFlushGuard() {
        if (!events.empty()) {
            std::lock_guard<std::mutex> lk(g_user_events_mutex);
            if (g_user_events_instance) {
                g_user_events_instance->committed_events_.insert(
                    g_user_events_instance->committed_events_.end(),
                    events.begin(), events.end()
                );
            }
        }
    }
};

static thread_local ThreadFlushGuard tl_guard;

UserEventTracer& UserEventTracer::getInstance() {
    static UserEventTracer instance;
    return instance;
}

UserEventTracer::UserEventTracer()
    : program_start_us_(now_us()), flushed_(false)
{
    {
        std::lock_guard<std::mutex> lk(g_user_events_mutex);
        g_user_events_instance = this;
    }
    for (int i = 0; i < kMaxUserEvents; ++i) {
        char env_var[32];
        snprintf(env_var, sizeof(env_var), "ACA_USER_EVENT_%d_NAME", i + 1);
        const char* v = getenv(env_var);
        cached_names_[i] = v ? std::string(v) : std::string();
    }
}

UserEventTracer::~UserEventTracer() {
    flush(true);
    std::lock_guard<std::mutex> lk(g_user_events_mutex);
    g_user_events_instance = nullptr;
}

void UserEventTracer::commitThreadEvents(std::vector<UserEventRecord>& evts) {
    std::lock_guard<std::mutex> lk(g_user_events_mutex);
    if (g_user_events_instance) {
        g_user_events_instance->committed_events_.insert(
            g_user_events_instance->committed_events_.end(),
            evts.begin(), evts.end()
        );
    }
    evts.clear();
}

void UserEventTracer::startEvent(int id, const char* /*default_name*/) {
    if (id < 1 || id > kMaxUserEvents) return;
    tl_guard.starts[id - 1] = now_us();
}

void UserEventTracer::stopEvent(int id) {
    if (id < 1 || id > kMaxUserEvents) return;
    const int idx = id - 1;
    if (tl_guard.starts[idx] == 0) return;

    const int64_t t_end   = now_us();
    const int64_t t_start = tl_guard.starts[idx];
    tl_guard.starts[idx]  = 0;

    const std::string& cached = cached_names_[idx];
    std::string name = cached.empty()
                           ? ("UserEvent-" + std::to_string(id))
                           : cached;

    tl_guard.events.push_back({id, name, t_start, t_end - t_start, get_tid()});
}

void UserEventTracer::flush(bool from_destructor) {
    if (!from_destructor) {
        if (!tl_guard.events.empty()) {
            commitThreadEvents(tl_guard.events);
        }
    }

    std::lock_guard<std::mutex> lk(g_user_events_mutex);
    if (flushed_) return;
    flushed_ = true;

    const int64_t program_end_us = now_us();
    const int64_t total_time_us  = program_end_us - program_start_us_;

    auto& all_events = committed_events_;

    const char* env_out    = getenv("ACA_TRACE_USER_OUT");
    const std::string filepath = env_out ? env_out : "trace_user_events.json";

    {
        const auto slash = filepath.rfind('/');
        if (slash != std::string::npos) {
            std::string dir = filepath.substr(0, slash);
            if (!dir.empty()) {
                std::string cmd = "mkdir -p '" + dir + "' 2>/dev/null";
                if (system(cmd.c_str()) != 0) { }
            }
        }
    }

    if (all_events.empty()) {
        std::cerr << "[aca_user_events] No user events captured.\n"
                  << "  Verify that -DACA_ENABLE_USER_EVENTS is defined and START/STOP macros are placed in source.\n";
        return;
    }

    std::sort(all_events.begin(), all_events.end(),
              [](const UserEventRecord& a, const UserEventRecord& b) {
                  return a.ts_start_us < b.ts_start_us;
              });

    const int64_t t0  = program_start_us_;
    const pid_t   pid = getpid();

    int64_t total_user_time_us = 0;
    for (const auto& ev : all_events) total_user_time_us += ev.duration_us;
    const double utilization_pct =
        total_time_us > 0
            ? (100.0 * static_cast<double>(total_user_time_us)
                     / static_cast<double>(total_time_us))
            : 0.0;

    std::ofstream out(filepath);
    if (!out.is_open()) {
        std::cerr << "[aca_user_events] Error opening " << filepath << " for writing\n";
        return;
    }

    out << "{\"traceEvents\":[\n";
    bool first = true;

    for (const auto& ev : all_events) {
        if (!first) out << ",\n";
        first = false;
        out << "{\"ph\":\"X\""
            << ",\"name\":\"" << ev.name << "\""
            << ",\"cat\":\"user\""
            << ",\"ts\":"  << (ev.ts_start_us - t0)
            << ",\"dur\":" << (ev.duration_us > 0 ? ev.duration_us : 1)
            << ",\"pid\":" << pid
            << ",\"tid\":" << ev.tid
            << ",\"args\":{\"id\":" << ev.id << "}"
            << "}";
    }

    {
        int64_t max_t = 0;
        for (const auto& ev : all_events)
            max_t = std::max(max_t, (ev.ts_start_us - t0) + ev.duration_us);

        const int64_t STEP_US = 1000;
        for (int64_t t = 0; t <= max_t; t += STEP_US) {
            int active = 0;
            for (const auto& ev : all_events) {
                int64_t s = ev.ts_start_us - t0;
                int64_t e = s + ev.duration_us;
                if (t >= s && t < e) ++active;
            }
            out << ",\n"
                << "{\"ph\":\"C\""
                << ",\"name\":\"user_events_active\""
                << ",\"pid\":" << pid
                << ",\"ts\":" << t
                << ",\"args\":{\"count\":" << active << "}"
                << "}";
        }
    }

    out << ",\n"
        << "{\"ph\":\"i\""
        << ",\"name\":\"UserUtilization\""
        << ",\"cat\":\"summary\""
        << ",\"ts\":0"
        << ",\"pid\":" << pid
        << ",\"s\":\"g\""
        << ",\"args\":{"
        << "\"user_time_ms\":"    << (total_user_time_us / 1000)
        << ",\"total_time_ms\":"  << (total_time_us / 1000)
        << ",\"utilization_pct\":" << utilization_pct
        << "}"
        << "}";

    out << "\n],\"displayTimeUnit\":\"us\"}\n";
    out.close();

    std::cerr << "[aca_user_events] ✓ Trace file written: " << filepath << "\n"
              << "  - Total events : " << all_events.size() << "\n"
              << "  - User code duration : " << (total_user_time_us / 1000) << " ms\n"
              << "  - Program total time : " << (total_time_us / 1000) << " ms\n"
              << "  - Active CPU utilization : " << utilization_pct << " %\n";
}

} // namespace aca
