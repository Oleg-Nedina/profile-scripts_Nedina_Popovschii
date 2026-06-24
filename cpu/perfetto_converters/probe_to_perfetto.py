#!/usr/bin/env python3
"""
probe_to_perfetto.py — Converte perf.data con entry+retprobe in Perfetto JSON.

A differenza di perf_to_perfetto.py (che usa campionamento a frequenza fissa),
questo script gestisce eventi DISCRETI di tipo uprobe/retprobe, dove ogni
evento entry segna l'INIZIO e ogni evento return segna la FINE di una chiamata.

Il risultato sono slice Perfetto con durata REALE (ts + dur), non stimate.

Utilizzo:
  python3 probe_to_perfetto.py <perf.data> <output.json> [--pair entry_ev:ret_ev ...]

Argomenti:
  perf.data      File binario generato da perf record con eventi probe
  output.json    File JSON di output per Perfetto
  --pair E:R     Coppia evento entry (E) e return (R) da abbinare.
                 Esempio: --pair probe_muDock:foo:probe_muDock:foo__return
                 Può essere ripetuto per più funzioni.
                 Se non specificato, lo script tenta di abbinare automaticamente
                 eventi con pattern *__return al corrispondente senza __return.

Formato eventi attesi da perf script:
  <comm> <pid>/<tid> [cpu] <ts>: <period> <event>:
      <addr> <sym> (<dso>)

Il timestamp è in secondi con alta precisione (es: 12345.678901234).
"""

import argparse
import collections
import json
import os
import re
import shutil
import glob
import subprocess
import sys
from typing import Dict, List, Optional, Tuple

# ---------------------------------------------------------------------------
# Trova il binario perf in modo portabile
# ---------------------------------------------------------------------------
import platform

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
# Argomenti CLI
# ---------------------------------------------------------------------------
parser = argparse.ArgumentParser(
    description="Converte perf.data con retprobe in slice Perfetto con durata reale."
)
parser.add_argument("perf_data",   nargs="?", default="perf.data",       help="File perf.data di input")
parser.add_argument("output_json", nargs="?", default="trace_probe.json", help="File JSON di output")
parser.add_argument(
    "--pair", action="append", default=[], metavar="ENTRY:RETURN",
    help="Coppia 'evento_entry:evento_return'. Ripetibile per più funzioni."
)
args = parser.parse_args()

perf_data   = args.perf_data
out_path    = args.output_json
pair_specs  = args.pair  # lista di "entry_ev:ret_ev"

if not os.path.exists(perf_data):
    print(f"[ERRORE] File non trovato: {perf_data}", file=sys.stderr)
    sys.exit(1)

# ---------------------------------------------------------------------------
# Costruisci mappa entry_event_name → return_event_name
# ---------------------------------------------------------------------------
# I nomi degli eventi perf probe hanno forma:  probe_muDock:foo
# I nomi retprobe hanno forma:                 probe_muDock:foo__return
# La mappa mette in relazione i due.
entry_to_return: Dict[str, str] = {}

for spec in pair_specs:
    if ":" not in spec:
        print(f"[WARN] Formato --pair non valido (atteso entry:return): {spec}", file=sys.stderr)
        continue
    # Nota: i nomi degli eventi contengono ":" (probe_group:probe_name),
    # quindi usiamo rsplit per dividere sull'ULTIMO ":"
    # ma il formato è "gruppo:entry:gruppo:return" → split su primo : tra i due eventi
    # Usiamo una convenzione più semplice: l'utente passa "group:name:group:retname"
    # oppure  "group:name group:retname" con spazio — ma argparse li mette insieme.
    # Gestiamo: il separatore tra entry e return è il PRIMO ":" che divide esattamente
    # in due metà ciascuna contenente un ":" (formato probe perf).
    parts = spec.split(":")
    if len(parts) == 4:
        # probe_group:entry_name:probe_group:return_name
        entry_ev = f"{parts[0]}:{parts[1]}"
        ret_ev   = f"{parts[2]}:{parts[3]}"
    elif len(parts) == 2:
        # entry_name:return_name (senza gruppo — raro)
        entry_ev, ret_ev = parts
    else:
        print(f"[WARN] --pair non parsabile: {spec}", file=sys.stderr)
        continue
    entry_to_return[entry_ev] = ret_ev
    print(f"[INFO] Pair configurato: {entry_ev!r}  →  {ret_ev!r}")

# ---------------------------------------------------------------------------
# Esegui perf script
# ---------------------------------------------------------------------------
print(f"[1/4] Lettura di '{perf_data}' tramite `perf script` ...")
cmd = [PERF_BIN, "script", "-i", perf_data]
result = subprocess.run(cmd, capture_output=True, text=True, errors="replace")

if result.returncode != 0:
    print(f"[ERRORE] perf script fallito:\n{result.stderr}", file=sys.stderr)
    sys.exit(1)

raw_lines = result.stdout.splitlines()
print(f"         {len(raw_lines)} righe ricevute da perf script")

# ---------------------------------------------------------------------------
# Parsing degli eventi
# ---------------------------------------------------------------------------
print("[2/4] Parsing degli eventi probe/retprobe ...")

# Regex header: comm  pid/tid  [cpu]  timestamp:  period  event_name:
HEADER_RE = re.compile(
    r"^\s*(\S.*?)\s+(\d+(?:/\d+)?)\s+(?:\[\d+\]\s+)?([\d.]+):\s+"
    r"(?:\d+\s+)?([\w:]+?):\s*$"
)

ProbeEvent = collections.namedtuple("ProbeEvent", ["comm", "pid", "tid", "ts_us", "event"])

probe_events: List[ProbeEvent] = []
current_header: Optional[ProbeEvent] = None

for line in raw_lines:
    if line.strip() == "":
        current_header = None
        continue

    hm = HEADER_RE.match(line)
    if hm:
        comm_raw, pid_tid, ts_str, event_name = hm.groups()
        if "/" in pid_tid:
            pid_s, tid_s = pid_tid.split("/", 1)
        else:
            pid_s = tid_s = pid_tid
        ev = ProbeEvent(
            comm=comm_raw.strip(),
            pid=int(pid_s),
            tid=int(tid_s),
            ts_us=float(ts_str) * 1_000_000,
            event=event_name.strip(),
        )
        probe_events.append(ev)
        current_header = ev
        continue

print(f"         Totale eventi parsati: {len(probe_events)}")

# ---------------------------------------------------------------------------
# Auto-scoperta coppie entry→return se non specificate con --pair
# ---------------------------------------------------------------------------
all_event_names = set(e.event for e in probe_events)
print(f"         Nomi eventi trovati: {sorted(all_event_names)}")

if not entry_to_return:
    print("[INFO] --pair non specificati: tentativo di auto-abbinamento ...")
    for ev_name in sorted(all_event_names):
        if "__return" in ev_name:
            continue
        # Cerca il corrispettivo return: stesso nome + __return
        ret_name = ev_name + "__return"
        if ret_name in all_event_names:
            entry_to_return[ev_name] = ret_name
            print(f"[INFO] Auto-pair: {ev_name!r}  →  {ret_name!r}")

if not entry_to_return:
    print("[WARN] Nessuna coppia entry/return trovata.", file=sys.stderr)
    print("       Generazione traccia con eventi istantanei (nessuna durata reale).", file=sys.stderr)

# Costruisci set dei nomi evento return (per filtraggio)
return_event_names = set(entry_to_return.values())

# ---------------------------------------------------------------------------
# Abbinamento entry → return per costruire slice con durata reale
# ---------------------------------------------------------------------------
print("[3/4] Abbinamento entry/return e costruzione slice Perfetto ...")

# Struttura: per ogni TID, stack di eventi entry aperti (per funzione)
# open_calls[tid][entry_event_name] = stack di ts_us (LIFO, per ricorsione)
open_calls: Dict[int, Dict[str, List[float]]] = collections.defaultdict(
    lambda: collections.defaultdict(list)
)

Slice = collections.namedtuple(
    "Slice", ["comm", "pid", "tid", "ts_us", "dur_us", "func_name", "event"]
)
slices: List[Slice] = []

# Per la traccia istantanea (entry senza return abbinato)
instant_events: List[ProbeEvent] = []

# Mappa return_event → entry_event (inversa)
return_to_entry: Dict[str, str] = {v: k for k, v in entry_to_return.items()}

for ev in probe_events:
    if ev.event in entry_to_return:
        # Evento di ENTRY: apre una slice (push sullo stack LIFO)
        open_calls[ev.tid][ev.event].append(ev.ts_us)

    elif ev.event in return_to_entry:
        # Evento di RETURN: chiude la slice più recente per questo TID + funzione
        entry_ev_name = return_to_entry[ev.event]
        stack = open_calls[ev.tid].get(entry_ev_name, [])
        if stack:
            entry_ts = stack.pop()
            dur_us = ev.ts_us - entry_ts
            # Ricava il nome leggibile della funzione dal nome dell'evento
            # es: "probe_muDock:_ZN6mudock7prepare..." → "prepare" (fallback: nome evento)
            func_display = entry_ev_name.split(":")[-1] if ":" in entry_ev_name else entry_ev_name
            slices.append(Slice(
                comm=ev.comm,
                pid=ev.pid,
                tid=ev.tid,
                ts_us=entry_ts,
                dur_us=max(dur_us, 0.001),   # evita durate negative/zero
                func_name=func_display,
                event=entry_ev_name,
            ))
        else:
            # Return senza entry (può capitare al primo evento dopo il boot della probe)
            pass

    else:
        # Evento non classificato come entry né return → trattalo come istantaneo
        instant_events.append(ev)

print(f"         Slice con durata reale generate: {len(slices)}")
print(f"         Entry aperte (non chiuse):       {sum(len(v) for d in open_calls.values() for v in d.values())}")
print(f"         Eventi istantanei (non abbinati): {len(instant_events)}")

# ---------------------------------------------------------------------------
# Costruzione eventi Perfetto
# ---------------------------------------------------------------------------
trace_events = []

# Normalizza t=0 al primo evento
all_ts = [s.ts_us for s in slices] + [e.ts_us for e in instant_events]
if not all_ts:
    print("[ERRORE] Nessun evento da visualizzare.", file=sys.stderr)
    sys.exit(1)

t0 = min(all_ts)
total_duration = max(all_ts) - t0

pid = slices[0].pid if slices else (instant_events[0].pid if instant_events else 0)

# Raggruppa TID per metadati
all_tids: Dict[int, str] = {}
for s in slices:
    all_tids[s.tid] = s.comm
for e in instant_events:
    all_tids[e.tid] = e.comm

# ── Metadati nome thread ───────────────────────────────────────────────────────
for tid, comm in sorted(all_tids.items()):
    trace_events.append({
        "ph": "M", "name": "thread_name",
        "pid": pid, "tid": tid,
        "args": {"name": f"{comm} [TID {tid}]"},
    })

# ── Slice con durata reale (da entry + retprobe) ───────────────────────────────
for s in slices:
    trace_events.append({
        "ph":   "X",
        "name": s.func_name,
        "cat":  "retprobe",
        "ts":   round(s.ts_us - t0, 3),
        "dur":  round(s.dur_us, 3),
        "pid":  s.pid,
        "tid":  s.tid,
        "args": {"event": s.event, "dur_us": round(s.dur_us, 3)},
    })

# ── Eventi istantanei (entry probe senza retprobe abbinato) ───────────────────
for e in instant_events:
    func_display = e.event.split(":")[-1] if ":" in e.event else e.event
    trace_events.append({
        "ph":  "i",
        "name": func_display,
        "cat": "probe_entry",
        "ts":  round(e.ts_us - t0, 3),
        "pid": e.pid,
        "tid": e.tid,
        "s":   "t",   # scope: thread
        "args": {"event": e.event},
    })

# ── Counter: quante funzioni sono "in esecuzione" in ogni istante ─────────────
# Basato sulle slice reali: conta le slice aperte a ogni step temporale
COUNTER_TID = 0
STEP_US = 1_000  # ogni 1ms

trace_events.append({
    "ph": "M", "name": "thread_name",
    "pid": pid, "tid": COUNTER_TID,
    "args": {"name": " Funzioni attive (retprobe)"},
})

if slices:
    t_us = 0.0
    while t_us <= total_duration:
        abs_t = t_us + t0
        active = sum(
            1 for s in slices
            if s.ts_us <= abs_t <= s.ts_us + s.dur_us
        )
        trace_events.append({
            "ph": "C", "name": "active_functions",
            "pid": pid, "tid": COUNTER_TID,
            "ts": round(t_us, 3),
            "args": {"count": active},
        })
        t_us += STEP_US

# ── Statistiche per funzione ──────────────────────────────────────────────────
func_stats: Dict[str, List[float]] = collections.defaultdict(list)
for s in slices:
    func_stats[s.func_name].append(s.dur_us)

# ---------------------------------------------------------------------------
# Scrivi il JSON
# ---------------------------------------------------------------------------
print(f"[4/4] Scrittura di '{out_path}' ...")

# Prepara statistiche per otherData
stats_summary = {}
for fname, durs in func_stats.items():
    if durs:
        stats_summary[fname] = {
            "calls":     len(durs),
            "total_us":  round(sum(durs), 3),
            "mean_us":   round(sum(durs) / len(durs), 3),
            "min_us":    round(min(durs), 3),
            "max_us":    round(max(durs), 3),
        }

trace_doc = {
    "traceEvents": trace_events,
    "displayTimeUnit": "us",
    "otherData": {
        "source":      perf_data,
        "generator":   "probe_to_perfetto.py",
        "mode":        "retprobe (real duration)" if entry_to_return else "instant events",
        "slices":      len(slices),
        "instant":     len(instant_events),
        "func_stats":  stats_summary,
        "tip": "Slice generate da entry+retprobe: durata = tempo reale di ogni chiamata.",
    },
}

with open(out_path, "w") as f:
    json.dump(trace_doc, f, separators=(",", ":"))

size_kb = os.path.getsize(out_path) / 1024
duration_s = total_duration / 1_000_000

print()
print("━" * 66)
print(f"    Trace retprobe generata!")
print(f"      File:     {out_path}  ({size_kb:.0f} KB)")
print(f"      Slice:    {len(slices)} con durata reale  +  {len(instant_events)} istantanei")
print(f"      Durata:   {duration_s:.2f} s")
print()
if func_stats:
    print("    Statistiche per funzione:")
    for fname, st in stats_summary.items():
        print(f"      {fname:40s}  calls={st['calls']:4d}  "
              f"mean={st['mean_us']:10.1f}µs  "
              f"max={st['max_us']:10.1f}µs")
print()
print("    Apri su:  https://ui.perfetto.dev/")
print(f"      Trascina: {os.path.abspath(out_path)}")
print()
print("    Ogni slice rappresenta la durata REALE di una singola chiamata.")
print("      L'altezza visiva nella timeline corrisponde al tempo effettivo.")
print("━" * 66)
