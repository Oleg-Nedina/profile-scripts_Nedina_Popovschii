
---

## Comandi

```bash
# Dalla root di profile-script:

# Pipeline completa 
./full_pipeline.sh

---

##  Parametri di `full_pipeline.sh`

### Configurazione muDock

| Parametro | Default | Descrizione |
|-----------|---------|-------------|
| `--exe PATH` | `./build/application/muDock` | Binario muDock da profilare |
| `--protein PATH` | `data/1fkb/1fkb_protein.pdb` | File proteina |
| `--ligand PATH` | `data/1fkb/1fkb_ligand.mol2` | File ligando |
| `--use DEVICE` | `CPP:CPU:0` | Backend di calcolo muDock |
| `--population N` | `100` | Dimensione popolazione GA |
| `--generations N` | `100` | Numero di generazioni GA |

### Configurazione profiling

| Parametro | Default | Descrizione |
|-----------|---------|-------------|
| `--top N` | `3` | Top-N funzioni per il Livello 3 (uprobes) |
| `--repeat N` | `3` | Numero di repeat per `cpu_metrics.sh` e `memory_metrics.sh` |
| `--warmup N` | `1` | Warmup run ignorati prima dei repeat (riduce rumore cold cache) |
| `--c2c` | off | Abilita analisi False Sharing con `perf c2c` (Livello 3) |

### Controllo flusso

| Parametro | Default | Descrizione |
|-----------|---------|-------------|
| `--out-dir DIR` | `traces/full_pipeline/` | Directory radice di tutti gli output |
| `--skip-l1` | off | Salta Livello 1 (cpu_metrics + memory_metrics) |
| `--skip-l2` | off | Salta Livello 2 (LD_PRELOAD thread lifecycle) |
| `--skip-l3` | off | Salta Livello 3 (uprobes + retprobe) |
| `--no-browser` | off | Non aprire Perfetto nel browser automaticamente |

---

##  Output generati

Tutti i file vengono salvati in sottodirectory di `traces/full_pipeline/`:

```

traces/full_pipeline/
├── l1_cpu/
│   ├── cpu_metrics.txt          ← Report IPC, branch, stall
│   ├── cpu_metrics_raw.txt      ← Output grezzo perf stat
│   ├── cpu_metrics_interval.txt ← Serie temporale (input per Perfetto)
│   ├── cpu_metrics.json         ← Traccia Perfetto (counter track)
│   └── cpu_metrics.csv          ← CSV machine-readable
├── l1_memory/
│   ├── memory_metrics.txt       ← Report L1/LLC/TLB/MPKI
│   ├── memory_metrics.json      ← Traccia Perfetto (counter track)
│   └── memory_metrics.csv
├── l2_threads/
│   └── trace_high_level.json    ← Timeline thread lifecycle (LD_PRELOAD)
└── l3_functions/
    ├── trace_low_level.json     ← Slice con durata reale (retprobe)
    └── c2c_report.txt           ← Report False Sharing (solo con --c2c)

---

## Cosa fa ogni livello

### Livello 1A — CPU Metrics

Esegue `cpu/perf_stat/cpu_metrics.sh` con `--repeat` e `--warmup`.
Misura: IPC, cicli, istruzioni, branch miss rate, frontend stall rate.
Output: `l1_cpu/cpu_metrics.json` (counter track in Perfetto).

### Livello 1B — Memory Metrics

Esegue `cpu/perf_stat/memory_metrics.sh` con `--repeat` e `--warmup`.
Misura: L1-D/L1-I/LLC miss rate, dTLB/iTLB miss rate, MPKI.
Output: `l1_memory/memory_metrics.json` (counter track in Perfetto).

### Livello 2 — Thread Lifecycle

Esegue `cpu/high_level/profile_high_level.sh` (LD_PRELOAD su `libhigh_level.so`).
Se `profile_high_level.sh` non esiste, fa fallback a LD_PRELOAD diretto.
Output: `l2_threads/trace_high_level.json` (timeline thread per thread in Perfetto).

### Livello 3 — Function-wide (uprobes + retprobe)

Esegue `cpu/low_level/low_level_probe.sh`.
Se `traces/perf.data` non esiste, lo genera con un `perf record` automatico.
Output: `l3_functions/trace_low_level.json` (slice con durata reale in Perfetto).

## Prerequisiti

```bash
# perf installato:
sudo apt install linux-tools-$(uname -r) linux-tools-common

# contatori hardware :
sudo sysctl -w kernel.perf_event_paranoid=-1

# app compilato con simboli:
cmake -DCMAKE_BUILD_TYPE=RelWithDebInfo .. && make -j8

# libhigh_level.so compilata (per il Livello 2):
make -C cpu/high_level libhigh_level.so
```

---
