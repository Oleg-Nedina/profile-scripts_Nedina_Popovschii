#!/usr/bin/env python3
# =============================================================================
# otf2_to_perfetto.py  —  Converte traccia Score-P OTF2 in Perfetto JSON
# =============================================================================
#
# Legge il file traces.otf2 generato da Score-P e produce un file JSON
# compatibile con il formato Trace Event (Chromium/Perfetto), visualizzabile
# direttamente su https://ui.perfetto.dev/
#
# Utilizzo:
#   python3 otf2_to_perfetto.py <traces.otf2> <output.json>
#
# Prerequisiti:
#   pip install otf2 --break-system-packages
#
# Cosa contiene la traccia convertita:
#   - Slice (ph:"X") per ogni regione OpenMP (parallel, workshare, barrier, ecc.)
#   - Slice (ph:"X") per ogni thread lifecycle (begin → end)
#   - Metadata (ph:"M") per i nomi dei thread nella UI
# =============================================================================

import sys
import os
import json

try:
    import otf2
except ImportError:
    print("ERRORE: modulo 'otf2' non trovato.", file=sys.stderr)
    print("Installa con: pip install otf2 --break-system-packages", file=sys.stderr)
    sys.exit(1)


def ticks_to_us(ticks: int, timer_resolution: int) -> float:
    """Converte ticks OTF2 in microsecondi."""
    return (ticks / timer_resolution) * 1_000_000


def convert(otf2_path: str, json_path: str) -> None:
    print(f"[otf2_to_perfetto] Lettura: {otf2_path}", file=sys.stderr)

    events = []
    # Mappa location_ref → (name, pid, tid) costruita dalla definizione
    loc_info: dict[int, dict] = {}
    t0_ticks: int | None = None
    timer_res: int = 1_000_000_000  # default: ns

    with otf2.reader.open(otf2_path) as trace:
        timer_res = trace.timer_resolution
        pid = os.getpid()  # usiamo il PID del converter come PID Perfetto

        # ── Raccogli info sulle location (= thread) ───────────────────────────
        for loc in trace.definitions.locations:
            loc_ref  = loc._ref
            loc_name = str(loc.name)
            # Ogni location appartiene a un location_group (= processo)
            group_name = str(loc.group.name) if loc.group else "muDock"
            loc_info[loc_ref] = {
                "name":  loc_name,
                "group": group_name,
            }

        # ── Mappa region_ref → nome regione ──────────────────────────────────
        region_names: dict[int, str] = {}
        for region in trace.definitions.regions:
            region_names[region._ref] = str(region.name)

        # ── Leggi gli eventi per ogni location ───────────────────────────────
        # Usiamo un dizionario per tenere traccia degli enter aperti per ogni
        # coppia (location, region) in modo da poter emettere slice complete
        open_enters: dict[tuple[int, int], int] = {}  # (loc_ref, region_ref) → ts_enter_ticks

        # Raccogliamo tutti gli eventi e li processiamo dopo per trovare t0
        raw_events: list[tuple] = []

        for location, event in trace.events:
            loc_ref = location._ref
            ts = event.time

            if t0_ticks is None:
                t0_ticks = ts
            else:
                t0_ticks = min(t0_ticks, ts)

            if isinstance(event, otf2.events.Enter):
                region_ref = event.region._ref
                raw_events.append(("enter", loc_ref, ts, region_ref))
            elif isinstance(event, otf2.events.Leave):
                region_ref = event.region._ref
                raw_events.append(("leave", loc_ref, ts, region_ref))

    if t0_ticks is None:
        print("[otf2_to_perfetto] ERRORE: nessun evento trovato nella traccia.", file=sys.stderr)
        sys.exit(1)

    # ── Emetti gli eventi Perfetto ─────────────────────────────────────────────
    # Mappa location → tid progressivo (Perfetto usa interi per i tid)
    loc_to_tid: dict[int, int] = {}
    tid_counter = 1

    # Stack per accoppiare enter/leave per ogni location
    enter_stack: dict[int, list[tuple[int, int]]] = {}  # loc_ref → [(ts, region_ref), ...]

    for ev_type, loc_ref, ts_ticks, region_ref in raw_events:
        if loc_ref not in loc_to_tid:
            loc_to_tid[loc_ref] = tid_counter
            tid_counter += 1

        tid = loc_to_tid[loc_ref]
        ts_us = ticks_to_us(ts_ticks - t0_ticks, timer_res)
        region_name = region_names.get(region_ref, f"region_{region_ref}")

        if ev_type == "enter":
            if loc_ref not in enter_stack:
                enter_stack[loc_ref] = []
            enter_stack[loc_ref].append((ts_ticks, region_ref))

        elif ev_type == "leave":
            stack = enter_stack.get(loc_ref, [])
            if stack:
                enter_ts_ticks, enter_region_ref = stack.pop()
                enter_ts_us = ticks_to_us(enter_ts_ticks - t0_ticks, timer_res)
                dur_us = ticks_to_us(ts_ticks - enter_ts_ticks, timer_res)
                enter_name = region_names.get(enter_region_ref, f"region_{enter_region_ref}")

                if dur_us > 0:
                    events.append({
                        "ph":   "X",
                        "name": enter_name,
                        "cat":  _categorize(enter_name),
                        "ts":   enter_ts_us,
                        "dur":  dur_us,
                        "pid":  pid,
                        "tid":  tid,
                    })

    # ── Metadata: nomi dei thread ─────────────────────────────────────────────
    for loc_ref, tid in loc_to_tid.items():
        info = loc_info.get(loc_ref, {})
        thread_name = info.get("name", f"Thread {tid}")
        events.append({
            "ph":   "M",
            "name": "thread_name",
            "pid":  pid,
            "tid":  tid,
            "args": {"name": thread_name},
        })
        # Ordina i thread nella UI in base al loro indice
        events.append({
            "ph":   "M",
            "name": "thread_sort_index",
            "pid":  pid,
            "tid":  tid,
            "args": {"sort_index": tid},
        })

    # ── Scrivi il JSON ────────────────────────────────────────────────────────
    output = {
        "traceEvents":   events,
        "displayTimeUnit": "us",
    }

    os.makedirs(os.path.dirname(os.path.abspath(json_path)), exist_ok=True)
    with open(json_path, "w", encoding="utf-8") as f:
        json.dump(output, f, separators=(",", ":"))

    size_kb = os.path.getsize(json_path) // 1024
    print(f"[otf2_to_perfetto]  JSON scritto: {json_path} ({size_kb} KB, {len(events)} eventi)",
          file=sys.stderr)
    print(f"[otf2_to_perfetto]   Carica su: https://ui.perfetto.dev/", file=sys.stderr)


def _categorize(name: str) -> str:
    """Assegna una categoria Perfetto leggibile in base al nome della regione Score-P."""
    n = name.lower()
    if "barrier"    in n: return "omp_sync"
    if "parallel"   in n: return "omp_parallel"
    if "loop"       in n: return "omp_work"
    if "single"     in n: return "omp_work"
    if "workshare"  in n: return "omp_work"
    if "task"       in n: return "omp_task"
    if "thread"     in n: return "thread_lifecycle"
    if "wait"       in n: return "omp_sync"
    if "idle"       in n: return "omp_idle"
    return "scorep"


def main():
    if len(sys.argv) < 3:
        print(f"Uso: {sys.argv[0]} <traces.otf2> <output.json>", file=sys.stderr)
        print("", file=sys.stderr)
        print("Esempio:", file=sys.stderr)
        print(f"  {sys.argv[0]} traces/scorep_trace/traces.otf2 traces/scorep_perfetto.json",
              file=sys.stderr)
        sys.exit(1)

    otf2_path = sys.argv[1]
    json_path  = sys.argv[2]

    if not os.path.isfile(otf2_path):
        print(f"ERRORE: file non trovato: {otf2_path}", file=sys.stderr)
        sys.exit(1)

    convert(otf2_path, json_path)


if __name__ == "__main__":
    main()
