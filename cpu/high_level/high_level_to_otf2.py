#!/usr/bin/env python3
# =============================================================================
# high_level_to_otf2.py  —  Converte trace_high_level.json in formato OTF2
# =============================================================================
#
# Il formato OTF2 (Open Trace Format 2) è lo standard HPC per le tracce,
# leggibile da Vampir, Score-P, e altri strumenti professionali.
#
# Utilizzo:
#   python3 high_level_to_otf2.py <trace_high_level.json> <output_dir/>
#
# Output:
#   <output_dir>/traces.otf2   — file ancora principale
#   (sottocartella con anchor e dati binari)
#
# Prerequisiti:
#   pip install otf2 --break-system-packages
#
# Cosa contiene la traccia:
#   - Un Location (thread) per ogni TID presente nella trace JSON
#   - Enter/Leave events per il lifecycle di ogni thread
#   - Metrica: parallel_threads campionato ogni 500µs
# =============================================================================

import json
import sys
import os

try:
    import otf2
except ImportError:
    print("ERRORE: modulo 'otf2' non trovato.", file=sys.stderr)
    print("Installa con: pip install otf2 --break-system-packages", file=sys.stderr)
    sys.exit(1)


def load_trace(json_path: str) -> dict:
    with open(json_path, encoding="utf-8") as f:
        return json.load(f)


def convert(json_path: str, out_dir: str) -> None:
    print(f"[high_level_to_otf2] Lettura: {json_path}", file=sys.stderr)
    trace_data = load_trace(json_path)
    events = trace_data.get("traceEvents", [])

    os.makedirs(out_dir, exist_ok=True)
    anchor = os.path.join(out_dir, "traces.otf2")

    # ── Raccogli thread lifecycle (ph=X) e counter (ph=C) ────────────────────
    thread_slices: dict[int, dict] = {}  # tid → {name, ts, dur, args}
    counters: list[dict] = []            # [{ts, value}]

    for ev in events:
        ph = ev.get("ph", "")
        if ph == "X":
            tid = ev.get("tid", 0)
            thread_slices[tid] = {
                "name": ev.get("name", f"Thread {tid}"),
                "ts":   ev.get("ts", 0),
                "dur":  max(ev.get("dur", 1), 1),
                "args": ev.get("args", {}),
            }
        elif ph == "C" and ev.get("name") == "parallel_threads":
            counters.append({
                "ts":    ev.get("ts", 0),
                "value": ev.get("args", {}).get("count", 0),
            })

    if not thread_slices:
        print("[high_level_to_otf2] ERRORE: nessuna slice thread (ph='X') trovata.", file=sys.stderr)
        sys.exit(1)

    n_threads = len(thread_slices)
    n_counters = len(counters)
    print(f"[high_level_to_otf2] Thread trovati: {n_threads}", file=sys.stderr)
    print(f"[high_level_to_otf2] Campioni counter: {n_counters}", file=sys.stderr)

    # OTF2 usa ticks. timer_resolution = ticks/secondo.
    # I timestamp nel JSON sono in µs → usiamo 1_000_000 ticks/s = 1 tick/µs
    TIMER_RES = 1_000_000  # 1 tick = 1 µs

    # ── Scrittura OTF2 ────────────────────────────────────────────────────────
    with otf2.writer.open(anchor, timer_resolution=TIMER_RES) as writer:

        # Albero di sistema: Cluster → Machine → (Locations)
        root_node = writer.definitions.system_tree_node("Cluster")
        machine_node = writer.definitions.system_tree_node(
            "Machine", parent=root_node
        )

        # Location group = processo muDock
        location_group = writer.definitions.location_group(
            "muDock",
            system_tree_parent=machine_node,
        )

        # Regione che rappresenta la vita attiva del thread
        region_active = writer.definitions.region(
            "thread_active",
            source_file="high_level_so.cpp",
        )

        # ── Definizione metrica parallel_threads ─────────────────────────────
        metric_member = writer.definitions.metric_member(
            "parallel_threads",
            "Active parallel threads",
            otf2.MetricType.OTHER,
            otf2.MetricMode.ABSOLUTE_NEXT,
            otf2.Type.INT64,
            otf2.Base.DECIMAL,
            0,
            "threads",
        )
        metric_class = writer.definitions.metric_class(
            members=(metric_member,),
            occurrence=otf2.MetricOccurrence.SYNCHRONOUS_STRICT,
        )

        # Location dedicata per il counter (thread fittizio TID=0)
        loc_counter = writer.definitions.location(
            "parallel_threads_counter",
            group=location_group,
            type=otf2.LocationType.CPU_THREAD,
        )

        # Crea un Location per ogni thread reale
        tid_to_loc: dict[int, object] = {}
        for tid, info in sorted(thread_slices.items()):
            idx = info["args"].get("index", tid)
            label = f"{info['name']} [TID {tid}]"
            loc = writer.definitions.location(
                label,
                group=location_group,
                type=otf2.LocationType.CPU_THREAD,
            )
            tid_to_loc[tid] = loc

        # ── Scrivi eventi thread ─────────────────────────────────────────────
        for tid, info in sorted(thread_slices.items()):
            loc = tid_to_loc[tid]
            ts_start = info["ts"]               # µs = ticks
            ts_end   = info["ts"] + info["dur"] # µs = ticks

            ew = writer.event_writer_from_location(loc)
            ew.enter(ts_start, region_active)
            ew.leave(ts_end,   region_active)

        # ── Scrivi counter parallel_threads ──────────────────────────────────
        if counters:
            ew_counter = writer.event_writer_from_location(loc_counter)
            for c in sorted(counters, key=lambda x: x["ts"]):
                ew_counter.metric(
                    c["ts"],
                    metric=metric_class,
                    values=(int(c["value"]),),
                )

    print(f"[high_level_to_otf2]  OTF2 scritto: {anchor}", file=sys.stderr)
    print(f"[high_level_to_otf2]   Apri con: vampir {anchor}", file=sys.stderr)
    print(f"[high_level_to_otf2]   Oppure:   otf2-print {anchor} | head -40", file=sys.stderr)


def main():
    if len(sys.argv) < 3:
        print(f"Uso: {sys.argv[0]} <trace_high_level.json> <output_dir/>", file=sys.stderr)
        print("", file=sys.stderr)
        print("Esempio:", file=sys.stderr)
        print(f"  {sys.argv[0]} traces/trace_high_level.json traces/otf2_high_level/", file=sys.stderr)
        sys.exit(1)

    json_path = sys.argv[1]
    out_dir   = sys.argv[2]

    if not os.path.isfile(json_path):
        print(f"ERRORE: file non trovato: {json_path}", file=sys.stderr)
        sys.exit(1)

    convert(json_path, out_dir)


if __name__ == "__main__":
    main()
