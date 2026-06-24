# `cpu/` — Strumenti di Profiling CPU

Questa cartella contiene tutti gli script e le librerie per il profiling della CPU del progetto **muDock** (ACA — Architettura dei Calcolatori Avanzata).

---

##  Struttura della cartella

```
cpu/
├── perf_stat/              ← Script perf stat: CPU/memoria su HW fisico e VM
│   ├── README.md           ←  Documentazione dettagliata + tabelle metriche
│   ├── cpu_metrics.sh               # IPC, branch, stall (hardware)
│   ├── cpu_metrics_generic.sh       # Come sopra, con fallback VM/Docker
│   ├── memory_metrics.sh            # L1/LLC/TLB cache (hardware)
│   ├── memory_metrics_generic.sh    # Come sopra, con fallback VM/Docker
│   ├── base_converter.sh            # Pipeline build → perf record → Perfetto
│   └── base_converter_generic.sh    # Versione portabile di base_converter
│
├── low_level/              ← Profiling mirato con perf probe (uprobes dinamici)
│   ├── README.md           ←  Documentazione + workflow uprobes
│   ├── low_level_probe.sh           # Auto-discovery Top-N funzioni + probe
│   └── low_level_probe_generic.sh   # Versione generica/portabile
│
├── high_level/             ← Tracciamento lifecycle thread via LD_PRELOAD
│   ├── README.md           ←  Documentazione dettagliata architettura
│   ├── profile_high_level.sh        # Automazione pipeline completa
│   ├── high_level_so.cpp            # Libreria LD_PRELOAD (JSON trace)
│   ├── perfetto_preload.cpp         # Libreria LD_PRELOAD (SDK Perfetto nativo)
│   ├── high_level_to_otf2.py        # Convertitore JSON → OTF2
│   ├── Makefile                     # Compila libhigh_level.so e libperfetto_preload.so
│   └── perfetto_sdk/               # Header SDK Perfetto (solo-header)
│
└── perfetto_converters/    ← Convertitori Python verso il formato Perfetto JSON
    ├── README.md           ←  Documentazione formato input/output
    ├── stat_to_perfetto.py          # perf stat -I  →  JSON Perfetto (counter track)
    └── perf_to_perfetto.py          # perf.data     →  JSON Perfetto (slice + thread)
```

---

##  Quick Start

### 1. Pipeline CPU completa (raccomandata per iniziare)

```bash
# Dalla root del progetto muDock:
./profile-scripts_Nedina_Popovschii/cpu/perf_stat/base_converter.sh \
    --population 100 --generations 100
# → Apre automaticamente la traccia in Perfetto
```

### 2. Solo metriche IPC / branch / stall

```bash
./cpu/perf_stat/cpu_metrics.sh --exe ./build/application/muDock \
    --args "--protein data/1fkb/1fkb_protein.pdb --ligand data/1fkb/1fkb_ligand.mol2 --use CPP:CPU:0" \
    --repeat 3 --csv
```

### 3. Solo metriche cache / TLB

```bash
./cpu/perf_stat/memory_metrics.sh --exe ./build/application/muDock \
    --args "--protein data/1fkb/1fkb_protein.pdb --ligand data/1fkb/1fkb_ligand.mol2 --use CPP:CPU:0"
```

### 4. Thread lifecycle (LD_PRELOAD)

```bash
# Opzione A: trace JSON leggero
./cpu/high_level/profile_high_level.sh --population 100 --generations 100

# Opzione B: traccia nativa .pftrace (SDK Perfetto)
./cpu/high_level/profile_high_level.sh --native --population 100 --generations 100
```

### 5. Profiling low-level con uprobes (Top-N funzioni)

```bash
# Richiede perf.data esistente (generato da base_converter.sh)
./cpu/low_level/low_level_probe.sh --top 5
```

---

##  Cosa misura ogni strumento

| Strumento | Livello | Metriche chiave | Output |
|-----------|---------|-----------------|--------|
| `cpu_metrics.sh` | Hardware PMU | IPC, branch miss%, frontend stall% | `.txt`, `.json`, `.csv` |
| `memory_metrics.sh` | Hardware PMU | L1/LLC miss rate, MPKI, TLB miss | `.txt`, `.json`, `.csv` |
| `low_level_probe.sh` | Kernel uprobes | Hotspot funzioni, call-stack | `.json` (Perfetto) |
| `high_level_so` | Userspace (LD_PRELOAD) | Thread lifecycle, parallelismo | `.json` (Perfetto) |
| `perfetto_preload` | SDK Perfetto nativo | Thread lifecycle, counter | `.pftrace` |

---

##  Requisiti

| Tool | Installazione | Richiesto da |
|------|-------------|-------------|
| `perf` | `sudo apt install linux-tools-$(uname -r)` | Tutti gli script perf_stat + low_level |
| `python3` | Preinstallato | Conversione Perfetto JSON |
| `g++ ≥ 7` | `sudo apt install g++` | Compilazione libhigh_level.so |
| `sudo` | — | Sblocco `perf_event_paranoid`, uprobes |

---

##  Visualizzazione risultati

Tutti i file `.json` e `.pftrace` generati possono essere aperti su:

> **https://ui.perfetto.dev/**

Trascina il file nella finestra del browser per visualizzare la timeline.

---

*Documentazione progetto ACA — Profiling e Tracing HPC*  
*Ultima modifica: 2026-06-16*
