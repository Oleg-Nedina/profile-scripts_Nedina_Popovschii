# Writing Rules, Guidelines, and Progress Summary

This document consolidates all styling guidelines, script portability rules, architectural decisions, completed work, and pending items identified during the profiling session.

---

## 1. General Rules for Guides, Readmes, and Documentation

1. **Absence of Emojis**: Emojis must not be used in any files, including C++ source code comments, shell scripts, console log statements, generated reports, or markdown documentation.
2. **Absence of Bulleted Lists**: Bullet points (using asterisks or dashes) are forbidden in all documentation. Use numbered lists, tables, descriptive paragraphs, or bold headers instead.
3. **Directory Tree Diagram Clarification**: Whenever directory tree diagrams are included in guides or READMEs, state explicitly that the folder layout is a generic example included solely to demonstrate sample execution paths.
4. **Markdown File Links**: Every reference to a script, configuration, or guide file must include a clickable absolute Markdown link using the `file://` scheme. Do not wrap the link text in backticks.
5. **English Language**: All code source comments, scripts, tool manuals, and generated report outputs must be written in English.

---

## 2. Guidelines for Profiling Scripts and Utilities

1. **Application Independence (Agnostic Design)**: Orchestrator scripts must be agnostic of the target program. They must not assume hardcoded fallback paths or target-specific arguments. Executables and their parameters must be supplied via command line arguments (`--exe` and `--args`).
2. **Nested Output Organization**: Scripts that produce multiple output files must place them in a dedicated subdirectory inside the traces folder (e.g. `cpu/perf_stat/traces/cpu_metrics/` or `cpu/perf_stat_user_kernel/traces/papi/`).
3. **Log Handling and Filtering**: Standard and error outputs of target binaries must be redirected to a dedicated log file (e.g. `cpu/perf_stat/logs/cpu_metrics.log`). Output lines containing repeating ligand computation updates (e.g. lines with `1fkb_ligand` or `ligand`) must be filtered out (using `grep -v`) to keep logs compact.
4. **Portability of `perf` Search**: Scripts must locate the Linux `perf` utility dynamically, looking into system paths such as `/usr/lib/linux-tools/$(uname -r)/perf` and testing executable functionality with `--version` before run.
5. **Portability of Home and System Paths**: Hardcoded paths to home directories, local systems, or hardcoded personal setups are strictly prohibited inside scripts.
6. **No Simulated Data**: All measurements must query real kernel counters. In case virtualization environments (like Docker) lack access to hardware PMU counters, scripts must fallback gracefully and print `N/A`.
7. **Double Instrumentation Export**: When both PAPI and User Events are compiled into a binary, both instrumentation libraries initialize. Script orchestrators must export both `ACA_TRACE_USER_OUT` and `ACA_PAPI_REPORT_OUT` variables to direct outputs into their correct subdirectories and keep the repository root clean.

---

## 3. Guidelines for Examples and Testing datasets

1. **High-Column Ligands**: Always use the 12-column ligand file (`ligands100_12col.adtmol2`) in command examples rather than simpler datasets.
2. **Target Application Demos**: Provide fully working command line templates targeting `muDock` compiled under sibling directories so the user can easily reproduce the profiling workflow.

---

## 4. Completed Work

1. **Nested Traces Directories**: Rearranged script outputs to store traces inside local subfolders (`cpu/perf_stat/traces/...` and `cpu/perf_stat_user_kernel/traces/...`), keeping the repository root completely clean.
2. **Double Instrumentation Variable Export**: Configured all orchestrator shell scripts (`run_papi.sh`, `run_user_kernel.sh`, `run_hpctoolkit.sh`) to export output path variables for both PAPI and User Events, preventing root directory clutter.
3. **Hpcprof Instrumentation Fix**: Removed the unsupported `-I` flag from the `hpcprof` command line in `run_hpctoolkit.sh`, allowing symbols to resolve automatically via DWARF structures.
4. **PAPI Formatter Fix**: Rectified `format_papi_report.py` to parse keys according to the C++ JSON schema (using `total_calls` instead of the incorrect `call_count`).
5. **Guides Synchronization**: Checked and updated all tool guides (`guide_base_converter.md`, `guide_cpu_metrics.md`, `guide_memory_metrics.md`, `guide_run_papi.md`, `guide_run_user_kernel.md`, `guide_run_hpctoolkit.md`) to reflect correct output folders and documented all system/library dependencies.
6. **Mini READMEs**: Generated concise, dependency-focused README files for both `cpu/perf_stat/` and `cpu/perf_stat_user_kernel/` directories.
7. **Doxygen Comments Formatting**: Rewrote all C++ file comments in the `src/` and `include/` folders of `cpu/perf_stat_user_kernel/` in professional English Doxygen format, removing all inline/middle comments.
8. **Hpcviewer Manuals Translation**: Translated `GUIDA_COMPLETA_PROFILING.md`, `GUIDA_HPCVIEWER.md`, and `ROADMAP_HPC.md` into English and removed emojis.

---
