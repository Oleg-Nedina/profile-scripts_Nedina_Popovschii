#!/usr/bin/env python3
import os
import sys
import json
import argparse
import re

def eval_formula(formula, event_map):
    # Sort keys by length descending to prevent substring substitution issues
    expr = formula
    for name, val in sorted(event_map.items(), key=lambda x: len(x[0]), reverse=True):
        expr = re.sub(r'\b' + name + r'\b', str(val), expr)
    try:
        # Safe evaluation context with no builtins except simple arithmetic
        val = eval(expr, {"__builtins__": None}, {})
        return val
    except ZeroDivisionError:
        return 0.0
    except Exception:
        return None

def fmt_ll(v):
    if v is None:
        return "N/A"
    s = str(max(0, int(v)))
    out = []
    n = len(s)
    for i, c in enumerate(s):
        if i > 0 and (n - i) % 3 == 0:
            out.append("'")
        out.append(c)
    return "".join(out)

def get_fallback_template(events):
    # Generate a basic fallback template if no custom preset template is found
    metrics = []
    if "PAPI_TOT_INS" in events and "PAPI_TOT_CYC" in events:
        metrics.append({
            "name": "IPC (Ins/Ciclo)",
            "formula": "PAPI_TOT_INS / PAPI_TOT_CYC",
            "format": "{val:.3f}",
            "thresholds": [
                {"min": 3.5, "tag": "✓ eccellente (Zen5 max ~4)"},
                {"min": 1.0, "tag": "✓ buono"},
                {"min": 0.0, "tag": "⚠ pipeline-bound (< 1.0)"}
            ]
        })
    return {
        "preset_name": "Custom / Event List",
        "metrics": metrics
    }

def main():
    parser = argparse.ArgumentParser(description="Format PAPI JSON profile output into structured reports.")
    parser.add_argument("--json", required=True, help="Path to input JSON file from C++ tracer")
    parser.add_argument("--preset", required=True, help="Preset name (ipc, cache, branch, simd, full, custom)")
    parser.add_argument("--templates-dir", default="preset_template", help="Directory containing preset JSON templates")
    parser.add_argument("--out", required=True, help="Path to write the formatted text report")

    args = parser.parse_args()

    # Load JSON data
    try:
        with open(args.json, "r") as f:
            data = json.load(f)
    except Exception as e:
        print(f"[format_report] Errore nel caricamento del file JSON '{args.json}': {e}", file=sys.stderr)
        sys.exit(1)

    events = data.get("events", [])
    hardware = data.get("hardware", {})
    kernels = data.get("kernels", [])

    # Load Template
    template = None
    if args.preset.lower() != "custom":
        template_path = os.path.join(args.templates_dir, f"{args.preset.lower()}.json")
        if os.path.exists(template_path):
            try:
                with open(template_path, "r") as f:
                    template = json.load(f)
            except Exception as e:
                print(f"[format_report] Warning: Errore nel caricare il template {template_path}: {e}", file=sys.stderr)

    if template is None:
        template = get_fallback_template(events)

    # Begin formatting report
    lines = []
    lines.append("="*80)
    lines.append("       REPORT METRICHE HARDWARE PAPI — KERNEL-LEVEL PROFILING")
    lines.append("="*80)
    lines.append(f"  Hardware : {hardware.get('model', 'N/A')}")
    lines.append(f"  PAPI     : {hardware.get('papi_version', 'N/A')}")
    lines.append(f"  Preset   : {template.get('preset_name', 'N/A')}")
    lines.append(f"  Contatori: " + ", ".join(events))
    lines.append("="*80)
    lines.append("")

    for k in kernels:
        lines.append("┌" + "─"*78 + "┐")
        title = f"  KERNEL {k.get('id')}: {k.get('name')}"
        lines.append(f"│{title:<78}│")
        lines.append("├" + "─"*78 + "┤")
        
        # 1. SEZIONE GLOBALE
        lines.append("│  1. SEZIONE GLOBALE (Aggregata per tutti i thread)                           │")
        lines.append(f"│      Invocazioni:                                    {k.get('total_calls'):<24}│")
        time_ms = k.get("total_time_us", 0) / 1000.0
        lines.append(f"│      Tempo totale (ms):                            {time_ms:<26.2f}│")
        lines.append(f"│      Thread partecipanti:                             {k.get('thread_count'):<23}│")
        lines.append("│                                                                              │")
        lines.append("│  Contatori Hardware (Grezzi):                                                │")
        
        # Mapping events to aggregate values
        agg_vals = k.get("aggregated_counters", [])
        event_map = {}
        for idx, val in enumerate(agg_vals):
            if idx < len(events):
                event_map[events[idx]] = val
                lbl = f"      {events[idx]}:"
                val_str = fmt_ll(val)
                lines.append(f"│{lbl:<38} {val_str:>38} │")
                
        # Fill missing requested events if any
        for ev in events:
            if ev not in event_map:
                event_map[ev] = 0

        # Derived metrics
        derived_lines = []
        for m in template.get("metrics", []):
            formula = m.get("formula", "")
            # Find required events
            req_events = re.findall(r'\bPAPI_[A-Z0-9_]+\b', formula)
            if all(r in event_map for r in req_events):
                val = eval_formula(formula, event_map)
                if val is not None:
                    fmt_str = m.get("format", "{val}")
                    formatted_val = fmt_str.format(val=val)
                    tag = ""
                    for th in m.get("thresholds", []):
                        if val >= th.get("min", 0.0):
                            tag = "  " + th.get("tag", "")
                            break
                    derived_lines.append(f"      {m.get('name'):<30} : {formatted_val:<12}{tag}")

        if derived_lines:
            lines.append("│                                                                              │")
            lines.append("│  Metriche Derivate:                                                          │")
            for dl in derived_lines:
                lines.append(f"│{dl:<78}│")

        # 2. SOTTOSEZIONE PER THREAD
        lines.append("├" + "─"*78 + "┤")
        lines.append("│  2. SOTTOSEZIONE PER THREAD (Dettaglio per singolo thread)                   │")
        
        threads = k.get("threads", [])
        for t_idx, t in enumerate(threads):
            if t_idx > 0:
                lines.append("│  " + "-"*74 + "  │")
            t_tid = t.get("tid")
            t_calls = t.get("calls")
            t_time_ms = t.get("time_us", 0) / 1000.0
            
            lines.append(f"│  Thread TID {t_tid:<65}│")
            lines.append(f"│      Invocazioni: {t_calls:<15} Tempo (ms): {t_time_ms:<32.2f}│")
            lines.append("│      Contatori Hardware (Grezzi):                                            │")
            
            t_vals = t.get("counters", [])
            t_event_map = {}
            for idx, val in enumerate(t_vals):
                if idx < len(events):
                    t_event_map[events[idx]] = val
                    lbl = f"          {events[idx]}:"
                    val_str = fmt_ll(val)
                    lines.append(f"│{lbl:<38} {val_str:>38} │")

            # Fill missing requested events for thread map
            for ev in events:
                if ev not in t_event_map:
                    t_event_map[ev] = 0

            # Thread derived metrics
            t_derived_lines = []
            for m in template.get("metrics", []):
                formula = m.get("formula", "")
                req_events = re.findall(r'\bPAPI_[A-Z0-9_]+\b', formula)
                if all(r in t_event_map for r in req_events):
                    val = eval_formula(formula, t_event_map)
                    if val is not None:
                        fmt_str = m.get("format", "{val}")
                        formatted_val = fmt_str.format(val=val)
                        tag = ""
                        for th in m.get("thresholds", []):
                            if val >= th.get("min", 0.0):
                                tag = "  " + th.get("tag", "")
                                break
                        t_derived_lines.append(f"          {m.get('name'):<30} : {formatted_val:<12}{tag}")

            if t_derived_lines:
                lines.append("│      Metriche Derivate:                                                      │")
                for tdl in t_derived_lines:
                    lines.append(f"│{tdl:<78}│")

        lines.append("└" + "─"*78 + "┘")
        lines.append("")

    # Write output file
    try:
        os.makedirs(os.path.dirname(args.out), exist_ok=True)
        with open(args.out, "w") as f:
            f.write("\n".join(lines) + "\n")
        print(f"[format_report] ✓ Report formattato salvato in: {args.out}")
    except Exception as e:
        print(f"[format_report] Errore nello scrivere il file di report '{args.out}': {e}", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()
