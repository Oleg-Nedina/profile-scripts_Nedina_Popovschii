#!/usr/bin/env python3
"""!
@file perf_to_perfetto.py
@brief Converts raw perf.data sampling traces into a Perfetto-compatible JSON timeline.

Operational steps:
  1. Runs `perf script` on the perf.data file (standard format, without -F).
  2. Parses the sample blocks (header + call-stack).
  3. Generates a "chrome://tracing" JSON format compatible with ui.perfetto.dev:
     - One lane per thread (TID).
     - Synthetic slices: each sample occupies time until the next on the same thread.
     - Counter track: number of active threads (shows real-time concurrency).

Usage:
  python3 perf_to_perfetto.py [perf.data] [output.json]

Notes:
  For resolved C++ symbols, compile with: -DCMAKE_BUILD_TYPE=RelWithDebInfo
  and record with: perf record -g --call-graph dwarf -o perf.data -- <cmd>
"""

import collections
import json
import os
import re
import shutil
import glob
import platform
import subprocess
import sys

def _find_perf() -> str:
    """!
    @brief Searches for the perf binary in a portable way.
    
    Checks linux-tools (exact or recent version matching running kernel) and falls back to PATH.
    @return The absolute path to a functional perf binary, or "perf" as a fallback.
    """
    uname_r = platform.release()
    # 1. First, try the exact version matching the running kernel in linux-tools
    specific_path = f"/usr/lib/linux-tools/{uname_r}/perf"
    if os.path.exists(specific_path) and os.access(specific_path, os.X_OK):
        return specific_path
    
    # 2. Try other versions under linux-tools (ordered from newest)
    candidates = sorted(glob.glob("/usr/lib/linux-tools/*/perf"), reverse=True)
    if candidates:
        for c in candidates:
            if os.path.exists(c) and os.access(c, os.X_OK):
                return c
                
    # 3. Try searching perf in PATH, verifying if it is functional
    p = shutil.which("perf")
    if p:
        try:
            res = subprocess.run([p, "--version"], capture_output=True, text=True, timeout=2)
            if res.returncode == 0 and "not found" not in res.stderr.lower():
                return p
        except Exception:
            pass
            
    return "perf"

# Find portable perf binary
PERF_BIN = _find_perf()

# ---------------------------------------------------------------------------
# CLI Arguments
# ---------------------------------------------------------------------------
perf_data = sys.argv[1] if len(sys.argv) > 1 else "perf.data"
out_path  = sys.argv[2] if len(sys.argv) > 2 else "trace_perf.json"

if not os.path.exists(perf_data):
    print(f"[ERROR] File not found: {perf_data}", file=sys.stderr)
    sys.exit(1)

print(f"[1/4] Reading '{perf_data}' using `perf script` ...")

# ---------------------------------------------------------------------------
# Step 1 — Run perf script (standard format including call-stack)
# ---------------------------------------------------------------------------
cmd = [PERF_BIN, "script", "-i", perf_data]
result = subprocess.run(cmd, capture_output=True, text=True, errors="replace")

if result.returncode != 0:
    print(f"[ERROR] perf script failed:\n{result.stderr}", file=sys.stderr)
    sys.exit(1)

raw_lines = result.stdout.splitlines()
print(f"         {len(raw_lines)} lines received from perf script")

# ---------------------------------------------------------------------------
# Step 2 — Parse standard perf script format
#
# Standard format matches:
#   <comm> <pid> <ts>: <period> <event>:
#       <addr> <sym> (<dso>)          <- call-stack lines (prefixed by \t)
#   <blank line>                      <- end of sample block
#
# Example:
#   muDock  12345  1.234567:   98257 cycles:P:
#       7fff123abc genetic_algorithm+0x10 (muDock)
#       7fff456def worker::process+0x5  (muDock)
# ---------------------------------------------------------------------------
print("[2/4] Parsing samples ...")

# Header matching (supports PID/TID, optional CPU core [000] and cycles/probe events)
HEADER_RE = re.compile(
    r"^\s*(\S.*?)\s+(\d+(?:/\d+)?)\s+(?:\[\d+\]\s+)?([\d.]+):\s+(?:.*)$"
)
# Call-stack line matching (starts with spaces/tabs followed by hex address)
STACK_RE = re.compile(
    r"^\s+([0-9a-fA-F]+)\s+(.+?)\s+\((.+?)\)\s*$"
)

samples = []
current = None

for line in raw_lines:
    # Empty line marks the end of the current sample block
    if line.strip() == "":
        if current is not None:
            samples.append(current)
            current = None
        continue

    # Attempt to match sample header
    hm = HEADER_RE.match(line)
    if hm:
        if current is not None:
            samples.append(current)
        comm_raw, pid_tid, ts_str = hm.groups()
        # pid_tid can be "pid" or "pid/tid"
        if "/" in pid_tid:
            pid_s, tid_s = pid_tid.split("/", 1)
        else:
            pid_s = tid_s = pid_tid
        current = {
            "comm":  comm_raw.strip(),
            "pid":   int(pid_s),
            "tid":   int(tid_s),
            "ts":    float(ts_str) * 1_000_000,  # s -> us
            "stack": [],
        }
        continue

    # Attempt to match call-stack frame line
    if current is not None:
        sm = STACK_RE.match(line)
        if sm:
            _, sym_raw, dso = sm.groups()
            sym = sym_raw.strip()
            sym = re.sub(r"\+0x[0-9a-fA-F]+", "", sym).strip()
            if sym and sym != "[unknown]":
                current["stack"].append({"sym": sym, "dso": dso})

# Append last sample if file did not end with an empty line
if current is not None:
    samples.append(current)

def top_userspace_sym(sample: dict) -> str:
    """!
    @brief Extracts the first non-kernel userspace symbol from the stack trace.
    @param sample The sample dictionary containing stack entries.
    @return The symbol name, or a fallback string if no symbol is resolved.
    """
    for frame in sample["stack"]:
        dso = frame["dso"]
        if not (dso.startswith("[k") or dso.startswith("[unknown]")):
            return frame["sym"]
    # Fallback: first available symbol
    if sample["stack"]:
        s = sample["stack"][0]["sym"]
        return s if s else "[unknown]"
    return "[no_stack]"

# Extract representative symbol for each sample
for s in samples:
    s["sym"] = top_userspace_sym(s)

valid = [s for s in samples if s["sym"] not in ("[unknown]", "[no_stack]")]
print(f"         Total samples: {len(samples)}")
print(f"         Samples with symbols: {len(valid)}")

if not samples:
    print("[ERROR] No samples parsed. Please check the perf.data format.")
    sys.exit(1)

if len(valid) == 0:
    print("[WARNING] No user symbols found.")
    print("         The binary was compiled without debug info (-g).")
    print("         Recompile with -DCMAKE_BUILD_TYPE=RelWithDebInfo and")
    print("         record with:  perf record -g --call-graph dwarf ...")
    print("")
    print("         Generating trace with thread-level granularity anyway ...")

# ---------------------------------------------------------------------------
# Step 3 — Build Perfetto Trace Events
# ---------------------------------------------------------------------------
print("[3/4] Building Perfetto events ...")

# Normalize timestamps: t=0 at first sample
t0 = min(s["ts"] for s in samples)
for s in samples:
    s["ts"] -= t0

# Group samples by Thread ID (TID)
by_tid = collections.defaultdict(list)
for s in samples:
    by_tid[s["tid"]].append(s)
for tid in by_tid:
    by_tid[tid].sort(key=lambda x: x["ts"])

trace_events = []
pid = samples[0]["pid"]
total_duration = max(s["ts"] for s in samples)

# Thread metadata
for tid, s_list in by_tid.items():
    trace_events.append({
        "ph": "M", "name": "thread_name",
        "pid": pid, "tid": tid,
        "args": {"name": f"{s_list[0]['comm']} [TID {tid}]"},
    })

# Synthetic thread slices
for tid, s_list in by_tid.items():
    for i, s in enumerate(s_list):
        dur = (s_list[i+1]["ts"] - s["ts"]) if i+1 < len(s_list) else 1_000
        trace_events.append({
            "ph":   "X",
            "name": s["sym"],
            "cat":  "perf_sample",
            "ts":   round(s["ts"], 3),
            "dur":  max(round(dur, 3), 1),
            "pid":  pid,
            "tid":  tid,
        })

# Concurrency counter track (number of active threads)
WINDOW_US = 10_000   # Thread is considered active if sampled within the last 10ms
STEP_US   = 2_000    # Update counter track every 2ms
COUNTER_TID = 0

trace_events.append({
    "ph": "M", "name": "thread_name",
    "pid": pid, "tid": COUNTER_TID,
    "args": {"name": " Active Threads (concurrency)"},
})

t_us = 0.0
while t_us <= total_duration:
    active = sum(
        1 for tid, s_list in by_tid.items()
        if any(abs(s["ts"] - t_us) < WINDOW_US for s in s_list)
    )
    trace_events.append({
        "ph": "C", "name": "active_threads",
        "pid": pid, "tid": COUNTER_TID,
        "ts": round(t_us, 3),
        "args": {"count": active},
    })
    t_us += STEP_US

# ---------------------------------------------------------------------------
# Step 4 — Write JSON Trace File
# ---------------------------------------------------------------------------
print(f"[4/4] Writing '{out_path}' ...")

trace_doc = {
    "traceEvents": trace_events,
    "displayTimeUnit": "us",
    "otherData": {
        "source":    perf_data,
        "generator": "perf_to_perfetto.py",
        "threads":   len(by_tid),
        "samples":   len(samples),
        "tip": "Recompile with RelWithDebInfo for resolved C++ symbols",
    },
}

with open(out_path, "w") as f:
    json.dump(trace_doc, f, separators=(",", ":"))

size_kb = os.path.getsize(out_path) / 1024
duration_s = total_duration / 1_000_000

print()
print("━" * 62)
print(f"    Trace generated successfully!")
print(f"      File:     {out_path}  ({size_kb:.0f} KB)")
print(f"      Threads:  {len(by_tid)}")
print(f"      Samples:  {len(samples)}  (with symbols: {len(valid)})")
print(f"      Duration: {duration_s:.2f} s")
print()
print("    Open at:  https://ui.perfetto.dev/")
print(f"      Drag:     {os.path.abspath(out_path)}")
print()
if len(valid) == 0:
    print("  ⚠️   Unresolved symbols: see notes above on how to recompile.")
print("━" * 62)
