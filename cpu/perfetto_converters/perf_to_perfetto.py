#!/usr/bin/env python3
"""
perf_to_perfetto.py — Converte perf.data in un JSON visualizzabile su Perfetto.

Funzionamento:
  1. Esegue `perf script` sul file perf.data (formato standard, senza -F)
  2. Parsa i blocchi di campioni (header + call-stack)
  3. Genera un JSON formato "chrome://tracing" compatibile con ui.perfetto.dev
     - Una lane per ogni thread (TID)
     - Slice sintetici: ogni campione occupa il tempo fino al successivo sullo stesso thread
     - Counter track: numero di thread attivi (mostra il parallelismo reale!)

Utilizzo:
  python3 script/perf_to_perfetto.py [perf.data] [output.json]

Note:
  Per avere simboli C++ risolti, compila con:  -DCMAKE_BUILD_TYPE=RelWithDebInfo
  e registra con:  perf record -g --call-graph dwarf -o perf.data -- <cmd>
"""

import collections
import json
import os
import re
import subprocess
import sys

# ---------------------------------------------------------------------------
# Configurazione — cerca 'perf' in modo portabile
# ---------------------------------------------------------------------------
import shutil
import glob
import platform
import subprocess

def _find_perf() -> str:
    """Cerca il binario perf: linux-tools (versione esatta o recente) -> PATH."""
    uname_r = platform.release()
    # 1. Prova prima la versione esatta per il kernel in linux-tools
    specific_path = f"/usr/lib/linux-tools/{uname_r}/perf"
    if os.path.exists(specific_path) and os.access(specific_path, os.X_OK):
        return specific_path
    
    # 2. Prova altre versioni in linux-tools (dalla più recente)
    candidates = sorted(glob.glob("/usr/lib/linux-tools/*/perf"), reverse=True)
    if candidates:
        for c in candidates:
            if os.path.exists(c) and os.access(c, os.X_OK):
                return c
                
    # 3. Prova perf nel PATH, ma verifica se funziona
    p = shutil.which("perf")
    if p:
        try:
            res = subprocess.run([p, "--version"], capture_output=True, text=True, timeout=2)
            if res.returncode == 0 and "not found" not in res.stderr.lower():
                return p
        except Exception:
            pass
            
    return "perf"

PERF_BIN = _find_perf()

# ---------------------------------------------------------------------------
# Argomenti
# ---------------------------------------------------------------------------
perf_data = sys.argv[1] if len(sys.argv) > 1 else "perf.data"
out_path  = sys.argv[2] if len(sys.argv) > 2 else "trace_perf.json"

if not os.path.exists(perf_data):
    print(f"[ERRORE] File non trovato: {perf_data}", file=sys.stderr)
    sys.exit(1)

print(f"[1/4] Lettura di '{perf_data}' tramite `perf script` ...")

# ---------------------------------------------------------------------------
# Step 1 — Esegui perf script (formato standard, che include call-stack)
# ---------------------------------------------------------------------------
cmd = [PERF_BIN, "script", "-i", perf_data]
result = subprocess.run(cmd, capture_output=True, text=True, errors="replace")

if result.returncode != 0:
    print(f"[ERRORE] perf script fallito:\n{result.stderr}", file=sys.stderr)
    sys.exit(1)

raw_lines = result.stdout.splitlines()
print(f"         {len(raw_lines)} righe ricevute da perf script")

# ---------------------------------------------------------------------------
# Step 2 — Parsing del formato standard di perf script
#
# Il formato standard è:
#   <comm> <pid> <ts>: <period> <event>:
#       <addr> <sym> (<dso>)          ← righe di call-stack (precedute da \t)
#   <blank line>                      ← fine del campione
#
# Esempio:
#   muDock  12345  1.234567:   98257 cycles:P:
#       7fff123abc genetic_algorithm+0x10 (muDock)
#       7fff456def worker::process+0x5  (muDock)
#
# ---------------------------------------------------------------------------
print("[2/4] Parsing dei campioni ...")

# Header di ogni campione (supporta PID/TID, CPU core opzionale [000] e formati cycles/probe)
HEADER_RE = re.compile(
    r"^\s*(\S.*?)\s+(\d+(?:/\d+)?)\s+(?:\[\d+\]\s+)?([\d.]+):\s+(?:.*)$"
)
# Riga di call-stack (inizia con tab o spazi + indirizzo hex)
STACK_RE = re.compile(
    r"^\s+([0-9a-fA-F]+)\s+(.+?)\s+\((.+?)\)\s*$"
)

samples = []
current = None

for line in raw_lines:
    # Riga vuota = fine del campione corrente
    if line.strip() == "":
        if current is not None:
            samples.append(current)
            current = None
        continue

    # Prova a fare il match con l'header
    hm = HEADER_RE.match(line)
    if hm:
        if current is not None:
            samples.append(current)
        comm_raw, pid_tid, ts_str = hm.groups()
        # pid_tid può essere "pid" oppure "pid/tid"
        if "/" in pid_tid:
            pid_s, tid_s = pid_tid.split("/", 1)
        else:
            pid_s = tid_s = pid_tid
        current = {
            "comm":  comm_raw.strip(),
            "pid":   int(pid_s),
            "tid":   int(tid_s),
            "ts":    float(ts_str) * 1_000_000,  # s → µs
            "stack": [],
        }
        continue

    # Prova a fare il match con una riga di call-stack
    if current is not None:
        sm = STACK_RE.match(line)
        if sm:
            _, sym_raw, dso = sm.groups()
            sym = sym_raw.strip()
            sym = re.sub(r"\+0x[0-9a-fA-F]+", "", sym).strip()
            if sym and sym != "[unknown]":
                current["stack"].append({"sym": sym, "dso": dso})

# Aggiungi l'ultimo campione se il file non termina con riga vuota
if current is not None:
    samples.append(current)

# Scegli il simbolo rappresentativo: il primo NON-kernel dalla cima dello stack
def top_userspace_sym(sample):
    for frame in sample["stack"]:
        dso = frame["dso"]
        if not (dso.startswith("[k") or dso.startswith("[unknown]")):
            return frame["sym"]
    # Fallback: primo simbolo qualsiasi
    if sample["stack"]:
        s = sample["stack"][0]["sym"]
        return s if s else "[unknown]"
    return "[no_stack]"

for s in samples:
    s["sym"] = top_userspace_sym(s)

valid = [s for s in samples if s["sym"] not in ("[unknown]", "[no_stack]")]
print(f"         Campioni totali: {len(samples)}")
print(f"         Campioni con simboli: {len(valid)}")

if not samples:
    print("[ERRORE] Nessun campione parsato. Controlla il formato di perf.data.")
    sys.exit(1)

# Usa tutti i campioni (anche quelli senza simboli, marcandoli come [unknown])
# ma solo se abbiamo almeno qualche campione utente
if len(valid) == 0:
    print("[AVVISO] Nessun simbolo utente trovato.")
    print("         Il binario è stato compilato senza debug info (-g).")
    print("         Ricompila con -DCMAKE_BUILD_TYPE=RelWithDebInfo e")
    print("         registra con:  perf record -g --call-graph dwarf ...")
    print("")
    print("         Genero comunque la traccia con thread-level granularity ...")

# ---------------------------------------------------------------------------
# Step 3 — Costruisci eventi Perfetto
# ---------------------------------------------------------------------------
print("[3/4] Costruzione degli eventi Perfetto ...")

# Normalizza timestamp: t=0 al primo campione
t0 = min(s["ts"] for s in samples)
for s in samples:
    s["ts"] -= t0

# Raggruppa per TID
by_tid: dict = collections.defaultdict(list)
for s in samples:
    by_tid[s["tid"]].append(s)
for tid in by_tid:
    by_tid[tid].sort(key=lambda x: x["ts"])

trace_events = []
pid = samples[0]["pid"]
total_duration = max(s["ts"] for s in samples)

# ── Metadati thread ───────────────────────────────────────────────────────────
for tid, s_list in by_tid.items():
    trace_events.append({
        "ph": "M", "name": "thread_name",
        "pid": pid, "tid": tid,
        "args": {"name": f"{s_list[0]['comm']} [TID {tid}]"},
    })

# ── Slice sintetici per thread ────────────────────────────────────────────────
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

# ── Counter track: thread attivi in parallelo ────────────────────────────────
# Questo è il grafico chiave che mostra il parallelismo reale dell'applicazione
WINDOW_US = 10_000   # un thread è "attivo" se ha avuto un sample negli ultimi 10ms
STEP_US   = 2_000    # aggiorna il contatore ogni 2ms
COUNTER_TID = 0

trace_events.append({
    "ph": "M", "name": "thread_name",
    "pid": pid, "tid": COUNTER_TID,
    "args": {"name": " Thread Attivi (parallelismo)"},
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
# Step 4 — Scrivi il JSON
# ---------------------------------------------------------------------------
print(f"[4/4] Scrittura di '{out_path}' ...")

trace_doc = {
    "traceEvents": trace_events,
    "displayTimeUnit": "us",
    "otherData": {
        "source":    perf_data,
        "generator": "perf_to_perfetto.py",
        "threads":   len(by_tid),
        "samples":   len(samples),
        "tip": "Ricompila con RelWithDebInfo per simboli C++ risolti",
    },
}

with open(out_path, "w") as f:
    json.dump(trace_doc, f, separators=(",", ":"))

size_kb = os.path.getsize(out_path) / 1024
duration_s = total_duration / 1_000_000

print()
print("━" * 62)
print(f"    Trace generata!")
print(f"      File:     {out_path}  ({size_kb:.0f} KB)")
print(f"      Thread:   {len(by_tid)}")
print(f"      Campioni: {len(samples)}  (con simboli: {len(valid)})")
print(f"      Durata:   {duration_s:.2f} s")
print()
print("    Apri su:  https://ui.perfetto.dev/")
print(f"      Trascina: {os.path.abspath(out_path)}")
print()
if len(valid) == 0:
    print("  ️   Simboli non risolti: vedi note sopra per ricompilare.")
print("━" * 62)
