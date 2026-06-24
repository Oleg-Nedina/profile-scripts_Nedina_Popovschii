# `perfetto_converters/` — Convertitori verso il formato Perfetto

Script Python che convertono output di `perf` in formato **JSON Perfetto**,
visualizzabile su <https://ui.perfetto.dev/>.

---

## File

| File | Input | Output | Usato da |
|------|-------|--------|----------|
| `stat_to_perfetto.py` | File `perf stat -I` (serie temporale) | `.json` con counter track | `cpu_metrics.sh`, `memory_metrics.sh` |
| `perf_to_perfetto.py` | File binario `perf.data` (campionamento) | `.json` con slice per thread | `base_converter.sh` |
| `probe_to_perfetto.py` | File binario `perf.data` (eventi probe+retprobe) | `.json` con slice a durata reale | `low_level_probe.sh` |

---

> **Nota:** questi script vengono chiamati automaticamente dagli script `.sh` genitori.

### `stat_to_perfetto.py` — da `perf stat -I` a Perfetto

```bash

python3 cpu/perfetto_converters/stat_to_perfetto.py \
    <file_perf_stat_interval.txt> \
    <output.json>

```

**Parametri posizionali:**

| Posizione | Descrizione |
|-----------|-------------|
| `argv[1]` | File di input generato da `perf stat -I <ms> --output <file>` |
| `argv[2]` | File `.json` di output per Perfetto |

---

### `perf_to_perfetto.py` — da `perf.data` (campionamento) a Perfetto

```bash

python3 cpu/perfetto_converters/perf_to_perfetto.py \
    <perf.data> \
    <output.json>

```

**Parametri posizionali:**

| Posizione | Default | Descrizione |
|-----------|---------|-------------|
| `argv[1]` | `perf.data` | File binario generato da `perf record -g --call-graph dwarf` |
| `argv[2]` | `trace_perf.json` | File `.json` di output per Perfetto |

**Prerequisiti per simboli C++ leggibili:**

```bash
# Compilare muDock con debug info:
cmake -DCMAKE_BUILD_TYPE=RelWithDebInfo ..
make -j8

# Registrare con call-graph:
perf record -g --call-graph dwarf -o traces/perf.data -- ./build/application/muDock ...
```

---

### `probe_to_perfetto.py` — da `perf.data` (retprobe) a slice con durata reale

Converter specializzato per `perf.data` generato con eventi **uprobe + retprobe**.
A differenza di `perf_to_perfetto.py` (campionamento a frequenza fissa), questo script gestisce
eventi **discreti**: ogni `entry` segna l'inizio, ogni `return` segna la fine di una chiamata.

```bash
# Utilizzo base (auto-scoperta delle coppie entry/return):
python3 cpu/perfetto_converters/probe_to_perfetto.py \
    <perf.data> \
    <output.json>

# Con coppia esplicita entry→return:
python3 cpu/perfetto_converters/probe_to_perfetto.py \
    traces/perf_low_level.data \
    traces/trace_low_level.json \
    --pair probe_muDock:prepare:probe_muDock:prepare__return

# Con più coppie:
python3 cpu/perfetto_converters/probe_to_perfetto.py \
    traces/perf_low_level.data \
    traces/trace_low_level.json \
    --pair probe_muDock:foo:probe_muDock:foo__return \
    --pair probe_muDock:bar:probe_muDock:bar__return
```

**Argomenti:**

| Argomento | Posizione/Flag | Default | Descrizione |
|-----------|---------------|---------|-------------|
| `perf_data` | posizione 1 | `perf.data` | File binario con eventi probe+retprobe |
| `output_json` | posizione 2 | `trace_probe.json` | File `.json` di output per Perfetto |
| `--pair ENTRY:RETURN` | flag ripetibile | auto | Coppia `gruppo:nome_entry:gruppo:nome_return`. Se omesso, abbina automaticamente tutti gli eventi con pattern `__return` al corrispondente senza `__return` |

> **Auto-scoperta:** senza `--pair`, lo script cerca eventi con nome `*__return` e li abbina automaticamente a `*` (stesso nome senza suffisso). Questo è il comportamento standard quando chiamato da `low_level_probe.sh`.

---

## Cosa producono nella UI di Perfetto

### `stat_to_perfetto.py` — Counter Track

Genera due gruppi di tracce (PID separati per leggibilità):

| Gruppo | Cosa contiene |
|--------|---------------|
| **Raw Counters** | Un counter per ogni evento `perf` grezzo (cycles, instructions, branch-misses, cache-misses, …), campionato ogni `--interval` ms |
| **Derived Metrics** | Metriche calcolate per ogni slot temporale: IPC, Branch Miss %, Frontend Stall %, L1-D Miss %, LLC Miss %, dTLB Miss % |

All'interno di ogni gruppo, gli eventi sono raggruppati per categoria:

- **CPU** — cycles, instructions, branches, stalls
- **Memory** — cache/TLB events
- **OS** — context-switches, migrations

### `perf_to_perfetto.py` — Slice per Thread (campionamento)

| Elemento | Descrizione |
|----------|-------------|
| **Slice per TID** | Ogni campione occupa il tempo fino al campione successivo sullo stesso thread. Il nome è il primo simbolo userspace nello stack |
| **Counter `active_threads`** | Campionato ogni 2ms: quanti thread hanno avuto un sample negli ultimi 10ms |

### `probe_to_perfetto.py` — Slice con durata reale (retprobe)

| Elemento | Tipo | Descrizione |
|----------|------|-------------|
| **Slice per funzione** | `ph: "X"` | Durata **reale** in µs: da `entry probe` (ingresso) a `retprobe` (uscita). Ogni rettangolo nella timeline è il tempo effettivo di una singola chiamata |
| **Evento istantaneo** | `ph: "i"` | Entry probe senza retprobe abbinata (funzione inline/template non supportata) |
| **Counter `active_functions`** | `ph: "C"` | Quante funzioni sono in esecuzione simultaneamente, campionato ogni 1ms |
| **Statistiche in `otherData`** | — | Per ogni funzione: `calls`, `mean_us`, `min_us`, `max_us` |

---

## Requisiti

```bash
# Solo Python 3 standard library — nessuna dipendenza esterna
python3 --version   # ≥ 3.7

# perf deve essere installato (usato da perf_to_perfetto.py e probe_to_perfetto.py):
sudo apt install linux-tools-$(uname -r)
```

---
