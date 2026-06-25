# User Guide for CPU Profiling Integration (PAPI & User Events)

This guide details how to integrate and use the CPU profiling module (supporting PAPI and User Events instrumentation) inside the muDock application.

---

## 1. Introduction to the Profiling Libraries

The CPU profiling suite consists of two primary instrumentation components designed to analyze execution timelines and hardware counters:

1. **User Events (Perfetto Integration)**: Enabled via [aca_user_events.hpp](../include/aca_user_events.hpp) and [aca_user_events.cpp](../src/aca_user_events.cpp). This library captures the timeline duration of custom user-defined execution slices. The output is generated as a JSON file in Chrome Trace Event format, which can be visualized graphically on the Perfetto UI website.
2. **PAPI Hotspot Profiling**: Enabled via [aca_papi_tracer.hpp](../include/aca_papi_tracer.hpp) and [aca_papi_tracer.cpp](../src/aca_papi_tracer.cpp). This library interfaces with the Performance Application Programming Interface (PAPI) to read hardware PMU counters (such as CPU cycles, instructions, cache misses, and branch mispredictions) during critical computational kernels.

---

## 2. Code Instrumentation for Profiling

To profile specific sections of the C++ codebase, you must include the appropriate headers and place instrumentation macros at the boundaries of the code regions of interest.

### 2.1. Profiling with User Events

To track execution phases on a timeline, include [aca_user_events.hpp](../include/aca_user_events.hpp) and use the following macros:

1. **ACA_USER_EVENT_START(id, default_name)**: Starts tracing an event slice. The `id` parameter must be an integer between 1 and 10. The `default_name` parameter serves as a fallback name.
2. **ACA_USER_EVENT_STOP(id)**: Stops tracing the event slice with the corresponding `id` value.
3. **ACA_USER_EVENTS_FLUSH()**: Flushes the collected events to the JSON trace. This call runs automatically upon program termination, but you can also trigger it manually.

Example code instrumentation:

```cpp
#include <aca_user_events.hpp>

void process_data() {
    ACA_USER_EVENT_START(1, "DataProcessingPhase");
    // ... computational or I/O work ...
    ACA_USER_EVENT_STOP(1);
}
```

### 2.2. Profiling with PAPI

To record hardware performance counters in a hot loop, include [aca_papi_tracer.hpp](../include/aca_papi_tracer.hpp) and use the following macros:

1. **ACA_PAPI_KNL_START(id, default_name)**: Starts counting hardware events. The `id` parameter must be an integer between 1 and 10. The `default_name` parameter serves as a fallback name.
2. **ACA_PAPI_KNL_STOP(id)**: Stops counting hardware events for the corresponding `id` value and aggregates results.
3. **ACA_PAPI_REPORT()**: Generates the final text report file. This call runs automatically when the application exits.

Example code instrumentation:

```cpp
#include <aca_papi_tracer.hpp>

void execute_kernel() {
    ACA_PAPI_KNL_START(1, "HotKernel");
    // ... performance-critical computation ...
    ACA_PAPI_KNL_STOP(1);
}
```

### 2.3. Double Instrumentation (PAPI and User Events)

When both libraries are compiled into the target application, you can instrument regions with both macros. They will execute in parallel, and both libraries will initialize independent data tracking.

Example double instrumentation:

```cpp
#include <aca_user_events.hpp>
#include <aca_papi_tracer.hpp>

void heavy_computation() {
    ACA_USER_EVENT_START(1, "OverallTask");
    ACA_PAPI_KNL_START(1, "HeavyKernel");
    
    // ... parallel or SIMD loops ...
    
    ACA_PAPI_KNL_STOP(1);
    ACA_USER_EVENT_STOP(1);
}
```

---

## 3. Modifying CMake Targets

To compile the profiling libraries with a target application, you must configure the CMake build system. This section explains the general approach first, followed by the specific configuration applied to the muDock project.

### 3.1. General CMake Integration

In any C++ project using CMake, you can integrate the profiling libraries by defining options, finding dependencies, and adding a static library target. The general integration recipe is structured as follows:

1. **Define Compilation Options**:
   Add options to toggle PAPI and User Events instrumentation:
   ```cmake
   option(ACA_ENABLE_USER_EVENTS "Enable Perfetto User Events tracking" OFF)
   option(ACA_ENABLE_PAPI        "Enable PAPI hardware counters" OFF)
   ```
2. **Configure PAPI Dependency**:
   If PAPI is enabled, search for the library headers and binary objects (typically via `pkg-config`):
   ```cmake
   if(ACA_ENABLE_PAPI)
     find_package(PkgConfig REQUIRED)
     pkg_check_modules(PAPI REQUIRED papi)
   endif()
   ```
3. **Define the Profiler Static Library Target**:
   Collect the profiling source files and build them as a static library called `aca_profiler`, linking with PAPI if active:
   ```cmake
   set(ACA_PROFILER_SRCS
     "path/to/perf_stat_user_kernel/src/aca_user_events.cpp"
     "path/to/perf_stat_user_kernel/src/aca_papi_tracer.cpp"
   )
   add_library(aca_profiler STATIC ${ACA_PROFILER_SRCS})
   target_include_directories(aca_profiler PUBLIC "path/to/perf_stat_user_kernel/include")

   if(ACA_ENABLE_USER_EVENTS)
     target_compile_definitions(aca_profiler PUBLIC ACA_ENABLE_USER_EVENTS)
   endif()

   if(ACA_ENABLE_PAPI)
     target_compile_definitions(aca_profiler PUBLIC ACA_ENABLE_PAPI)
     target_include_directories(aca_profiler PRIVATE ${PAPI_INCLUDE_DIRS})
     target_link_libraries(aca_profiler PUBLIC ${PAPI_LIBRARIES})
   endif()
   ```
4. **Link the Target Application**:
   Link the `aca_profiler` target to your main executable or library target to propagate definitions and include paths automatically:
   ```cmake
   target_link_libraries(my_application PRIVATE aca_profiler)
   ```

### 3.2. Sibling Directory Structure

The concrete integration of this profiling module assumes that the profiling scripts repository is cloned as a sibling folder to the target application (e.g. muDock). This folder layout is shown below:

```text
progetto_aca/
├── muDock/                              # muDock main repository
│   ├── CMakeLists.txt                   # Root CMakeLists.txt
│   ├── mudock/
│   │   └── CMakeLists.txt               # Core library CMakeLists.txt
│   └── application/
│       └── CMakeLists.txt               # CLI application CMakeLists.txt
└── profile-scripts_Nedina_Popovschii/   # Profiling scripts repository
    └── cpu/
        └── perf_stat_user_kernel/       # Instrumentation profiling module
            ├── include/
            │   ├── aca_user_events.hpp
            │   └── aca_papi_tracer.hpp
            └── src/
                ├── aca_user_events.cpp
                └── aca_papi_tracer.cpp
```

Note: The directory layout displayed above is a generic example included solely to demonstrate sample execution paths.

### 3.3. Specific Integration in muDock

To automate path discovery across different local workspace clones, we modify the root CMake configuration file [CMakeLists.txt](../../../../muDock/CMakeLists.txt) to automatically locate the profiling directory inside sibling candidate paths:

```cmake
# ##############################################################################
# ### User Events Profiling and PAPI (Perfetto)
# ##############################################################################

if(MUDOCK_ENABLE_USER_EVENTS OR MUDOCK_ENABLE_PAPI)
  # Locate the CPU profiling scripts folder dynamically
  set(ACA_USER_KERNEL_DIR "")
  foreach(candidate 
      "${PROJECT_SOURCE_DIR}/../profile-scripts_Nedina_Popovschii/cpu/perf_stat_user_kernel"
      "${PROJECT_SOURCE_DIR}/../profile-scripts/cpu/perf_stat_user_kernel"
      "${PROJECT_SOURCE_DIR}/perf_stat_user_kernel"
      "${PROJECT_SOURCE_DIR}/cpu/perf_stat_user_kernel"
  )
    if(EXISTS "${candidate}/src/aca_user_events.cpp")
      set(ACA_USER_KERNEL_DIR "${candidate}")
      break()
    endif()
  endforeach()

  if(NOT ACA_USER_KERNEL_DIR)
    message(FATAL_ERROR "Could not find perf_stat_user_kernel directory. Please specify it manually or ensure the profiling scripts repo is cloned as a sibling directory.")
  endif()

  set(ACA_PROFILER_SRCS)
  if(MUDOCK_ENABLE_USER_EVENTS)
    list(APPEND ACA_PROFILER_SRCS "${ACA_USER_KERNEL_DIR}/src/aca_user_events.cpp")
  endif()
  if(MUDOCK_ENABLE_PAPI)
    list(APPEND ACA_PROFILER_SRCS "${ACA_USER_KERNEL_DIR}/src/aca_papi_tracer.cpp")
  endif()

  add_library(aca_profiler STATIC ${ACA_PROFILER_SRCS})
  target_include_directories(aca_profiler PUBLIC "${ACA_USER_KERNEL_DIR}/include")

  if(MUDOCK_ENABLE_USER_EVENTS)
    target_compile_definitions(aca_profiler PUBLIC ACA_ENABLE_USER_EVENTS)
  endif()

  if(MUDOCK_ENABLE_PAPI)
    find_package(PkgConfig REQUIRED)
    pkg_check_modules(PAPI REQUIRED papi)
    target_compile_definitions(aca_profiler PUBLIC ACA_ENABLE_PAPI)
    target_include_directories(aca_profiler PRIVATE ${PAPI_INCLUDE_DIRS})
    target_link_directories(aca_profiler PUBLIC ${PAPI_LIBRARY_DIRS})
    target_link_libraries(aca_profiler PUBLIC ${PAPI_LIBRARIES})
    list(APPEND CMAKE_BUILD_RPATH ${PAPI_LIBRARY_DIRS})
  endif()
endif()
```

Then, modify the core library build file [CMakeLists.txt](../../../../muDock/mudock/CMakeLists.txt) to link the generated static library:

```cmake
# perfetto_aca dependency
if(MUDOCK_ENABLE_USER_EVENTS OR MUDOCK_ENABLE_PAPI)
  target_link_libraries(libmudock PUBLIC aca_profiler)
  if(MUDOCK_ENABLE_USER_EVENTS)
    target_compile_definitions(libmudock PUBLIC ACA_ENABLE_USER_EVENTS)
  endif()
  if(MUDOCK_ENABLE_PAPI)
    target_compile_definitions(libmudock PUBLIC ACA_ENABLE_PAPI)
    target_link_libraries(libmudock PUBLIC ${PAPI_LIBRARIES})
  endif()
endif()
```

---

## 4. Compilation Steps

Profiling requires compilation with debugging symbols enabled to resolve symbols during trace analysis.

### 4.1. General Compilation Guidelines

When compiling any instrumented application, adhere to the following steps:

1. **Enable Debug Symbols and Optimizations**:
   Configure the CMake build type to `RelWithDebInfo` (`-DCMAKE_BUILD_TYPE=RelWithDebInfo`). This is critical because a standard release build excludes debugger information (`-g`), preventing tools like `perf` from mapping performance counters back to C++ source lines.
2. **Configure Kernel Permissions**:
   Before executing the profiling suite, install target performance utilities and configure the Linux kernel to allow unprivileged user access to CPU performance monitoring counters:
   ```bash
   sudo apt install linux-tools-$(uname -r) linux-tools-generic
   sudo sysctl -w kernel.perf_event_paranoid=-1
   ```

### 4.2. Specific Compilation Steps for muDock

To configure and compile the muDock workspace with profiling enabled:

1. **Configure via GCC Compiler**:
   Use GCC for standard profiling runs:
   ```bash
   cd ../muDock
   mkdir -p build && cd build
   cmake .. \
     -DMUDOCK_ENABLE_OMP=ON \
     -DCMAKE_BUILD_TYPE=RelWithDebInfo \
     -DMUDOCK_ENABLE_USER_EVENTS=ON \
     -DMUDOCK_ENABLE_PAPI=ON
   ```
2. **Configure via Clang Compiler**:
   Use Clang to support OpenMP profiling:
   ```bash
   cd ../muDock
   rm -rf build && mkdir build && cd build
   cmake .. \
     -DCMAKE_C_COMPILER=clang \
     -DCMAKE_CXX_COMPILER=clang++ \
     -DMUDOCK_ENABLE_OMP=ON \
     -DCMAKE_BUILD_TYPE=RelWithDebInfo \
     -DMUDOCK_ENABLE_USER_EVENTS=ON \
     -DMUDOCK_ENABLE_PAPI=ON
   ```
3. **Compile the Targets**:
   Run the compilation in parallel:
   ```bash
   make -j$(nproc)
   ```

---

## 5. Execution and Trace Collection

Once the executable is built, you can configure execution options and collect profiling results using environment variables.

### 5.1. General Execution Guide

To configure any instrumented application at runtime, set the following environment variables prior to running the binary:

1. **User Events Variables**:
   1.1. `ACA_TRACE_USER_OUT`: Specifies the absolute or relative path to the output JSON trace file. If empty, the tracer will default to `trace_user_events.json`.
   1.2. `ACA_USER_EVENT_<ID>_NAME`: Overrides the default string label for a specific event ID. For example, `ACA_USER_EVENT_1_NAME="Parsing"` labels event ID 1.
2. **PAPI Profiler Variables**:
   2.1. `ACA_PAPI_EVENTS`: A comma-separated list of hardware performance counters to collect (e.g. `PAPI_TOT_CYC,PAPI_TOT_INS,PAPI_L3_TCM`).
   2.2. `ACA_PAPI_REPORT_OUT`: Specifies the path to the output text report file containing the hardware counter values. If empty, it defaults to `kpi_hotspots.txt`.
   2.3. `ACA_PAPI_KNL_<ID>_NAME`: Overrides the default string label for a specific kernel ID. For example, `ACA_PAPI_KNL_2_NAME="ComputeBound"` labels kernel ID 2.

Example run for a general program named `my_program` using manual exports:

```bash
# Configure environment parameters
export ACA_TRACE_USER_OUT="my_timeline.json"
export ACA_USER_EVENT_1_NAME="Init"
export ACA_USER_EVENT_2_NAME="Process"

export ACA_PAPI_EVENTS="PAPI_TOT_CYC,PAPI_TOT_INS"
export ACA_PAPI_REPORT_OUT="my_metrics.txt"
export ACA_PAPI_KNL_2_NAME="ComputeKernel"

# Execute
./my_program
```

### 5.2. General Script-Based Orchestration

Instead of exporting environment variables manually, you can use the orchestrator shell scripts [run_user_kernel.sh](../scripts/run_user_kernel.sh) and [run_papi.sh](../scripts/run_papi.sh) to handle the variables automatically via command line parameters.

1. **User Events Orchestration**:
   Use [run_user_kernel.sh](../scripts/run_user_kernel.sh) to pass the executable path, target application arguments, output directory, and custom event names:
   ```bash
   ./cpu/perf_stat_user_kernel/scripts/run_user_kernel.sh \
     --exe ./my_program \
     --args "arg1 arg2" \
     --out-dir ./cpu/perf_stat_user_kernel/traces/my_user_events \
     --event-1 "Init" \
     --event-2 "Process"
   ```
2. **PAPI Hotspot Orchestration**:
   Use [run_papi.sh](../scripts/run_papi.sh) to pass the executable path, target application arguments, output directory, custom event names, or specific event presets (such as `ipc`, `cache`, `branch`, or `simd`):
   ```bash
   ./cpu/perf_stat_user_kernel/scripts/run_papi.sh \
     --exe ./my_program \
     --args "arg1 arg2" \
     --out-dir ./cpu/perf_stat_user_kernel/traces/my_papi \
     --events "PAPI_TOT_CYC,PAPI_TOT_INS" \
     --knl-2 "ComputeKernel"
   ```

### 5.3. Concrete Execution Examples with muDock

1. **Manual Export Approach**:
    ```bash
    cd ../muDock

    # Configure User Events Settings
    export ACA_USER_EVENT_1_NAME="PipelineDocking"
    export ACA_TRACE_USER_OUT="traces/trace_user_events.json"

    # Configure PAPI Settings
    export ACA_PAPI_EVENTS="PAPI_TOT_CYC,PAPI_TOT_INS,PAPI_L3_TCM,PAPI_BR_MSP"
    export ACA_PAPI_KNL_1_NAME="CalcEnergy"
    export ACA_PAPI_REPORT_OUT="traces/kpi_hotspots.txt"

    # Run muDock
    ./build/application/muDock \
      --protein data/1fkb/1fkb_protein.pdb \
      --ligand  data/1fkb/ligands100_12col.adtmol2 \
      --use CPP:CPU:0-3 \
      --search genetic \
      --population 100 \
      --generations 100 \
      --seed 42
    ```
2. **Script-Based Parameter Approach**:
    Run the orchestrator scripts directly from the repository root:
    ```bash
    # Run User Events timeline profiling
    ./cpu/perf_stat_user_kernel/scripts/run_user_kernel.sh \
      --exe ../muDock/build/application/muDock \
      --args "--protein ../muDock/data/1fkb/1fkb_protein.pdb --ligand ../muDock/data/1fkb/ligands100_12col.adtmol2 --use CPP:CPU:0-3 --search genetic --population 100 --generations 100 --seed 42" \
      --out-dir cpu/perf_stat_user_kernel/traces/user_events \
      --event-1 "PipelineDocking"

    # Run PAPI hardware counter profiling
    ./cpu/perf_stat_user_kernel/scripts/run_papi.sh \
      --exe ../muDock/build/application/muDock \
      --args "--protein ../muDock/data/1fkb/1fkb_protein.pdb --ligand ../muDock/data/1fkb/ligands100_12col.adtmol2 --use CPP:CPU:0-3 --search genetic --population 100 --generations 100 --seed 42" \
      --out-dir cpu/perf_stat_user_kernel/traces/papi \
      --events "PAPI_TOT_CYC,PAPI_TOT_INS,PAPI_L3_TCM,PAPI_BR_MSP" \
      --knl-1 "CalcEnergy"
    ```

### 5.4. Checking the Trace Results

When the process completes:

1. **Inspect Timelines**: Open `https://ui.perfetto.dev/` in a web browser and upload the generated JSON trace file (e.g. `traces/trace_user_events.json`) to inspect the visual timeline slices.
2. **Inspect Hardware Counters**: Open the text report (e.g. `traces/kpi_hotspots.txt`) in a text editor to view the aggregated hardware PMU values, call counts, and execution duration for the instrumented kernels.
