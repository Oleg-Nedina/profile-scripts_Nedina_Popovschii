#!/usr/bin/env python3
# =============================================================================
# stat_to_perfetto.py  —  Converte output di `perf stat -I` in JSON Perfetto
# =============================================================================
#
# Utilizzo:
#   python3 stat_to_perfetto.py <perf_stat_raw.txt> <output.json>
#
# Il file di input deve essere generato con:
#   perf stat -I 500 -e evento1,evento2,... --output <file> -- <programma>
#
# Il JSON generato mostra counter track per ogni metrica in Perfetto UI,
# più counter derivati (IPC, miss rate, ecc.) calcolati per ogni slot.
# =============================================================================

import sys
import re
import json
from collections import defaultdict

# ── Mappatura nomi evento → nome leggibile nel trace ──────────────────────────
EVENT_LABELS = {
    "cycles":                    "Cycles",
    "instructions":              "Instructions",
    "branches":                  "Branches",
    "branch-misses":             "Branch Misses",
    "stalled-cycles-frontend":   "Frontend Stalls",
    "context-switches":          "Context Switches",
    "cpu-migrations":            "CPU Migrations",
    "page-faults":               "Page Faults",
    "major-faults":              "Major Page Faults",
    "minor-faults":              "Minor Page Faults",
    "L1-dcache-loads":           "L1-D Loads",
    "L1-dcache-load-misses":     "L1-D Misses",
    "L1-icache-loads":           "L1-I Loads",
    "L1-icache-load-misses":     "L1-I Misses",
    "cache-references":          "LLC References",
    "cache-misses":              "LLC Misses",
    "dTLB-loads":                "dTLB Loads",
    "dTLB-load-misses":          "dTLB Misses",
    "iTLB-loads":                "iTLB Loads",
    "iTLB-load-misses":          "iTLB Misses",
}

# ── Quale "categoria" assegnare ad ogni evento ─────────────────────────────────
EVENT_CATEGORY = {
    "cycles":                    "cpu",
    "instructions":              "cpu",
    "branches":                  "cpu",
    "branch-misses":             "cpu",
    "stalled-cycles-frontend":   "cpu",
    "context-switches":          "os",
    "cpu-migrations":            "os",
    "page-faults":               "memory",
    "major-faults":              "memory",
    "minor-faults":              "memory",
    "L1-dcache-loads":           "memory",
    "L1-dcache-load-misses":     "memory",
    "L1-icache-loads":           "memory",
    "L1-icache-load-misses":     "memory",
    "cache-references":          "memory",
    "cache-misses":              "memory",
    "dTLB-loads":                "memory",
    "dTLB-load-misses":          "memory",
    "iTLB-loads":                "memory",
    "iTLB-load-misses":          "memory",
}

def parse_perf_stat(filepath: str) -> dict[float, dict[str, float]]:
    """
    Legge un file perf stat -I e ritorna:
       { timestamp_s: { event_name: value, ... }, ... }
    I valori '<not counted>' vengono saltati.
    """
    # Regex: <ts> <count|'<not counted>'> [unit] <event_name>
    line_re = re.compile(
        r"^\s*"
        r"(?P<ts>\d+\.\d+)"          # timestamp
        r"\s+"
        r"(?P<raw>[^#\n]+?)"          # count + event (tutto prima del commento #)
        r"\s*(?:#.*)?$"              # eventuale commento # ...
    )
    # Regex per estrarre count e nome evento dal gruppo "raw"
    count_re = re.compile(
        r"^(?P<count>[\d,]+|<not counted>|<NA>)"
        r"\s*"
        r"(?P<unit>[a-zA-Z/]+\s+)?"  # unità opzionale (ns, msec...)
        r"(?P<event>\S+)"            # nome evento
    )

    slots: dict[float, dict[str, float]] = defaultdict(dict)

    with open(filepath, encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.rstrip()
            if not line or line.startswith("#"):
                continue
            m = line_re.match(line)
            if not m:
                continue
            ts = float(m.group("ts"))
            raw = m.group("raw").strip()
            c = count_re.match(raw)
            if not c:
                continue
            count_str = c.group("count").replace(",", "")
            event = c.group("event").strip()
            if count_str in ("<not", "<NA>", "not"):
                continue
            try:
                value = float(count_str)
            except ValueError:
                continue
            slots[ts][event] = value

    return slots


def compute_derived(slots: dict[float, dict[str, float]]) -> dict[float, dict[str, float]]:
    """
    Aggiunge metriche derivate per ogni slot:
    IPC, branch miss %, frontend stall %, L1-D/L1-I/LLC/dTLB/iTLB miss %
    """
    derived: dict[float, dict[str, float]] = defaultdict(dict)

    def pct(num, den):
        return (num / den * 100.0) if den > 0 else 0.0

    for ts, ev in slots.items():
        # IPC
        if "cycles" in ev and "instructions" in ev:
            derived[ts]["IPC"] = ev["instructions"] / ev["cycles"] if ev["cycles"] > 0 else 0.0

        # Branch miss %
        if "branch-misses" in ev and "branches" in ev:
            derived[ts]["Branch Miss %"] = pct(ev["branch-misses"], ev["branches"])

        # Frontend stall %
        if "stalled-cycles-frontend" in ev and "cycles" in ev:
            derived[ts]["Frontend Stall %"] = pct(ev["stalled-cycles-frontend"], ev["cycles"])

        # L1-D miss %
        if "L1-dcache-load-misses" in ev and "L1-dcache-loads" in ev:
            derived[ts]["L1-D Miss %"] = pct(ev["L1-dcache-load-misses"], ev["L1-dcache-loads"])

        # L1-I miss %
        if "L1-icache-load-misses" in ev and "L1-icache-loads" in ev:
            derived[ts]["L1-I Miss %"] = pct(ev["L1-icache-load-misses"], ev["L1-icache-loads"])

        # LLC miss %
        if "cache-misses" in ev and "cache-references" in ev:
            derived[ts]["LLC Miss %"] = pct(ev["cache-misses"], ev["cache-references"])

        # dTLB miss %
        if "dTLB-load-misses" in ev and "dTLB-loads" in ev:
            derived[ts]["dTLB Miss %"] = pct(ev["dTLB-load-misses"], ev["dTLB-loads"])

        # iTLB miss %
        if "iTLB-load-misses" in ev and "iTLB-loads" in ev:
            derived[ts]["iTLB Miss %"] = pct(ev["iTLB-load-misses"], ev["iTLB-loads"])

    return derived


def build_perfetto_json(
    slots: dict[float, dict[str, float]],
    derived: dict[float, dict[str, float]],
    source_file: str,
) -> dict:
    """
    Costruisce il dizionario JSON nel formato Perfetto Trace Event.
    Ogni metrica diventa un counter track.
    Le metriche derivate (IPC, miss %) vanno su un PID separato per leggibilità.
    """
    events = []

    # PID convenzionali per separare i gruppi nella UI
    PID_RAW     = 1   # contatori hardware grezzi
    PID_DERIVED = 2   # metriche derivate (IPC, miss %)

    # Calcola la durata totale in microsecondi (necessaria per la slice sentinella)
    all_ts = sorted(slots.keys())
    max_ts_us = int(all_ts[-1] * 1_000_000) if all_ts else 1_000_000

    # ── Slice sentinella: definisce il range temporale per Perfetto UI ──────
    # Senza almeno un evento ph:X/B/E, Perfetto non riesce ad inizializzare
    # la timeline e mostra una schermata vuota anche con soli Counter events.
    events.append({
        "ph": "X",
        "name": "muDock Profiling Session",
        "cat": "profiling",
        "pid": PID_RAW,
        "tid": 0,
        "ts": 0,
        "dur": max_ts_us,
        "args": {"source": source_file}
    })

    # ── Metadati PID/TID ────────────────────────────────────────────────────
    events.append({
        "ph": "M", "name": "process_name",
        "pid": PID_RAW, "tid": 0,
        "args": {"name": "️  Raw Counters (perf stat)"}
    })
    events.append({
        "ph": "M", "name": "process_name",
        "pid": PID_DERIVED, "tid": 0,
        "args": {"name": " Derived Metrics"}
    })
    events.append({
        "ph": "M", "name": "thread_name",
        "pid": PID_RAW, "tid": 0,
        "args": {"name": " Session Span"}
    })

    # Raggruppa gli eventi raw per categoria → TID diverso
    category_tid = {}
    tid_counter = 1
    for event in sorted({e for slot in slots.values() for e in slot}):
        cat = EVENT_CATEGORY.get(event, "other")
        if cat not in category_tid:
            category_tid[cat] = tid_counter
            tid_counter += 1
            cat_label = {"cpu": " CPU", "memory": " Memory", "os": " OS"}.get(cat, cat)
            events.append({
                "ph": "M", "name": "thread_name",
                "pid": PID_RAW, "tid": category_tid[cat],
                "args": {"name": cat_label}
            })

    # Raggruppa le metriche derivate per tipo → TID diverso
    derived_tid = {}
    for name in sorted({m for slot in derived.values() for m in slot}):
        if name not in derived_tid:
            derived_tid[name] = tid_counter
            tid_counter += 1
            events.append({
                "ph": "M", "name": "thread_name",
                "pid": PID_DERIVED, "tid": derived_tid[name],
                "args": {"name": name}
            })

    # ── Slices per ogni intervallo di campionamento — raw ───────────────────
    # Usiamo ph:X (slice di durata) invece di ph:C (counter) perché
    # Perfetto.dev da file locale non renderizza i counter come grafici.
    # Le slices appaiono come barre colorate con il valore nel tooltip.
    sorted_ts = sorted(slots.keys())
    for i, ts_s in enumerate(sorted_ts):
        ts_us = int(ts_s * 1_000_000)
        # La durata di ogni slice è l'intervallo fino al prossimo campione (o 500ms di default)
        if i + 1 < len(sorted_ts):
            dur_us = int((sorted_ts[i + 1] - ts_s) * 1_000_000)
        else:
            dur_us = 500_000  # ultimo slot: 500ms di default
        if dur_us <= 0:
            dur_us = 1

        for event, value in slots[ts_s].items():
            label = EVENT_LABELS.get(event, event)
            cat   = EVENT_CATEGORY.get(event, "other")
            tid   = category_tid.get(cat, 0)
            events.append({
                "ph": "X",
                "name": label,
                "cat": cat,
                "pid": PID_RAW,
                "tid": tid,
                "ts": ts_us,
                "dur": dur_us,
                "args": {"value": value, "t_s": round(ts_s, 3)}
            })

    # ── Slices per ogni intervallo — derived ──────────────────────────────────
    sorted_ts_d = sorted(derived.keys())
    for i, ts_s in enumerate(sorted_ts_d):
        ts_us = int(ts_s * 1_000_000)
        if i + 1 < len(sorted_ts_d):
            dur_us = int((sorted_ts_d[i + 1] - ts_s) * 1_000_000)
        else:
            dur_us = 500_000
        if dur_us <= 0:
            dur_us = 1

        for metric, value in derived[ts_s].items():
            tid = derived_tid.get(metric, 0)
            events.append({
                "ph": "X",
                "name": metric,
                "cat": "derived",
                "pid": PID_DERIVED,
                "tid": tid,
                "ts": ts_us,
                "dur": dur_us,
                "args": {"value": round(value, 4), "t_s": round(ts_s, 3)}
            })

    return {
        "traceEvents": events,
        "displayTimeUnit": "us"
    }


def main():
    if len(sys.argv) < 3:
        print(f"Uso: {sys.argv[0]} <perf_stat_raw.txt> <output.json>", file=sys.stderr)
        sys.exit(1)

    in_file  = sys.argv[1]
    out_file = sys.argv[2]

    print(f"[stat_to_perfetto] Lettura: {in_file}", file=sys.stderr)
    slots = parse_perf_stat(in_file)

    if not slots:
        print("[stat_to_perfetto] ERRORE: nessun dato trovato nel file.", file=sys.stderr)
        print("  Assicurati che il file sia generato con: perf stat -I <ms> ...", file=sys.stderr)
        sys.exit(1)

    derived = compute_derived(slots)

    n_slots  = len(slots)
    n_events = sum(len(v) for v in slots.values())
    n_der    = sum(len(v) for v in derived.values())

    print(f"[stat_to_perfetto] Slot temporali: {n_slots}", file=sys.stderr)
    print(f"[stat_to_perfetto] Campioni raw:   {n_events}", file=sys.stderr)
    print(f"[stat_to_perfetto] Metriche deriv: {n_der}", file=sys.stderr)

    trace = build_perfetto_json(slots, derived, in_file)

    with open(out_file, "w", encoding="utf-8") as f:
        json.dump(trace, f, separators=(",", ":"))

    print(f"[stat_to_perfetto] Scritto: {out_file}", file=sys.stderr)


if __name__ == "__main__":
    main()
