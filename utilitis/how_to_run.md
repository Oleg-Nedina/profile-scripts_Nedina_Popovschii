# 🚀 HOW TO RUN — Guida Rapida agli Script

---

## Struttura

```
profile-scripts_Nedina_Popovschii/
├── cpu/
│   ├── base_converter.sh             ← STEP 1: build + perf record + Perfetto JSON
│   ├── base_converter_generic.sh     ← versione generica (qualunque binario)
│   ├── cpu_metrics.sh                ← IPC, branch, stall, CPU utilization (con Perfetto JSON)
│   ├── memory_metrics.sh             ← L1/LLC/TLB miss rate, page faults (con Perfetto JSON)
│   ├── perf_to_perfetto.py           ← convertitore interno
│   ├── stat_to_perfetto.py           ← convertitore metriche perf stat
│   ├── high_level/
│   │   ├── profile_high_level.sh     ← automazione tracciamento thread lifecycle + OTF2
│   │   ├── high_level_to_otf2.py     ← convertitore traccia HL in formato OTF2
│   │   ├── high_level_so.cpp         ← sorgente libreria LD_PRELOAD
│   │   ├── Makefile
│   │   └── libhigh_level.so          ← libreria compilata
│   └── low_level/
│       ├── low_level_probe.sh        ← perf probe mirato (specifico muDock)
│       └── low_level_probe_generic.sh← versione generica (qualunque binario)
└── gpu/
    ├── nvidia/
    │   └── profile.sh           ← profiling NVIDIA con ncu
    └── amd/
        └── profile.sh           ← profiling AMD con rocprof-compute
```

> Tutti gli script salvano automaticamente i propri output (file raw, report testuali, trace JSON e OTF2) all'interno di una cartella `traces/` (es. `muDock/traces/` o secondo il parametro `--out-dir`).

---

## CPU — `base_converter.sh` (base)

### Prerequisiti

- `spack`
- Ambiente Spack `mudock_zen5` cofigurato
- `perf` installato
- `python3` disponibile

### Comando

```bash
./cpu/base_converter.sh
```

### Opzioni

| Opzione | cosa fa |
|---|---|
| *(nessuna)* | Build completo + profiling + conversione + apertura browser |
| `--skip-build` | Salta la compilazione (usa il binario già presente in `build/`) |
| `--convert-only` | Salta build E profiling, converte un `perf.data` già esistente |
| `--clean` | Forza una build pulita (`rm -rf build`) prima di compilare |
| `--population N` | Numero di popolazioni (default: 100) |
| `--generations N` | Numero di generazioni (default: 100) |
| `--no-browser` | Non apre il browser automaticamente |
| `--protein FILE` | File proteina alternativo |
| `--ligand FILE` | File ligando alternativo |

### Output

| File | Descrizione |
|---|---|
| `traces/perf.data` | Dati raw del campionamento |
| `traces/trace_perf.json` | Traccia Perfetto — apri su <https://ui.perfetto.dev/> |

---

## CPU — `high_level` (tracciamento thread lifecycle LD_PRELOAD)

Traccia il **ciclo di vita dei thread** .

Sono disponibili due modalità di tracciamento:

1. **Modalità Native SDK (`--native`) [Consigliata]**: Integra l'SDK ufficiale C++ di Perfetto all'interno della libreria precaricata.
2. **Modalità JSON + OTF2**: Scrive una traccia JSON custom,per esportare o convertire la traccia nel formato **OTF2**.

```bash
./cpu/high_level/profile_high_level.sh --native

./cpu/high_level/profile_high_level.sh 
```

#### Opzioni principali

| Opzione | Default | Descrizione |
|---|---|---|
| `--native` | off | Abilita l'SDK Perfetto nativo in C++ (produce `.pftrace`) |
| `--skip-build` | off | Salta la compilazione di `libhigh_level.so`/`libperfetto_preload.so` |
| `--population N` | 100 | Popolazione per muDock |
| `--generations N` | 100 | Generazioni per muDock |
| `--out-dir DIR` | `traces/` | Directory in cui salvare i risultati |
| `--no-otf2` | off | Salta la conversione in formato OTF2 (solo per traccia JSON) |
| `--no-browser` | off | Non aprire il browser automaticamente |

---

### Esecuzione Manuale

#### Compilazione

```bash
cd ./cpu/high_level
make clean && make
# Output: libhigh_level.so e libperfetto_preload.so
```

#### Esecuzione muDock con la libreria iniettata

##### Per il Perfetto Native SDK

```bash
# Dalla root di muDock:
LD_PRELOAD=<REPO>/cpu/high_level/libperfetto_preload.so \
MUDOCK_TRACE_PERFETTO_OUT=traces/muDock.pftrace \
./build/application/muDock --protein data/1fkb/1fkb_protein.pdb --ligand data/1fkb/1fkb_ligand.mol2 --use CPP:CPU:0
```

##### Per la traccia JSON (e OTF2)

```bash
LD_PRELOAD=<REPO>/cpu/high_level/libhigh_level.so \
MUDOCK_TRACE_HL_OUT=traces/trace_high_level.json \
./build/application/muDock --protein data/1fkb/1fkb_protein.pdb --ligand data/1fkb/1fkb_ligand.mol2 --use CPP:CPU:0

# Conversione OTF2 manuale:
python3 <REPO>/cpu/high_level/high_level_to_otf2.py traces/trace_high_level.json traces/otf2_high_level/
```

---

### Output Generati (in `traces/`)

| File / Directory | Descrizione | dove aprire |
|---|---|---|
| `traces/muDock.pftrace` | Traccia binaria nativa di Perfetto (modalità `--native`) | <https://ui.perfetto.dev/> |
| `traces/trace_high_level.json` | Traccia Perfetto in formato JSON | <https://ui.perfetto.dev/> |
| `traces/otf2_high_level/` | Archivio in formato standard OTF2 (per Vampir) | Vampir o simili |

---

## CPU — `low_level_probe.sh`

Profiling **mirato** sulle funzioni più costose, usando `perf probe` (uprobes).

> **Prerequisito:** `perf.data` già esistente (generato da `base_converter.sh`).  
> Richiede `sudo` per aggiungere le probe nel kernel.

```bash
# Sblocca i contatori hardware
sudo sysctl -w kernel.perf_event_paranoid=-1
```

### Comando

```bash
./cpu/low_level/low_level_probe.sh
```

Lo script:

1. Legge il `perf.data` esistente e trova le Top-3 funzioni muDock per % CPU
2. Aggiunge uprobes dinamiche su quelle funzioni
3. Riesegue muDock con le probe attive
4. Converte il risultato in `trace_low_level.json`

### Opzioni

| Opzione | Default | Descrizione |
|---|---|---|
| `--top N` | `3` | Numero di funzioni da tracciare |
| `--perf-data FILE` | `traces/perf.data` | File perf.data da analizzare |
| `--output FILE` | `traces/trace_low_level.json` | File di output JSON |
| `--population N` | `100` | Popolazioni per il re-run di muDock |
| `--generations N` | `100` | Generazioni per il re-run di muDock |

### Output

| File | Descrizione |
|---|---|
| `traces/perf_low_level.data` | Raw data con eventi probe |
| `traces/trace_low_level.json` | Traccia Perfetto — aprire su <https://ui.perfetto.dev/> |

---

## CPU — `cpu_metrics.sh` (IPC, branch, stall)

Misura metriche di efficienza della CPU tramite **`perf stat`**: IPC, cicli, istruzioni, branch misprediction, frontend stalls, CPU utilization, context switch.

### Comando

```bash
./cpu/cpu_metrics.sh --exe /path/to/binary
```

### Opzioni

| Opzione | Default | Descrizione |
|---|---|---|
| `--exe PATH` | — | **Obbligatorio.** Eseguibile da profilare |
| `--args "..."` | — | Argomenti da passare al binario |
| `--output FILE` | `traces/cpu_metrics.txt` | File di testo con il report |
| `--out-dir DIR` | `traces/` | Directory in cui salvare tutti gli output |
| `--repeat N` | `1` | Ripete N volte e fa la media |
| `--interval MS` | 500 | Intervallo di campionamento in ms per Perfetto |
| `--csv` | off | Salva anche `traces/cpu_metrics.csv` |
| `--no-perfetto` | off | Non generare il file JSON per Perfetto |

### Output (in `traces/` o `--out-dir`)

| File | Descrizione |
|---|---|
| `cpu_metrics.txt` | Report formattato con IPC, branch miss rate, stall rate, CPU utilization |
| `cpu_metrics_raw.txt` | Output grezzo di `perf stat` (totali) |
| `cpu_metrics_interval.txt` | Output grezzo di `perf stat -I` (serie temporale) |
| `cpu_metrics.json` | **Traccia Perfetto** —  <https://ui.perfetto.dev/> |
| `cpu_metrics.csv` | (con `--csv`) Dati machine-readable |

### Metriche misurate

| Metrica | Significato |
|---|---|
| IPC | Instructions Per Cycle — efficienza pipeline |
| Branch miss rate | % predizioni sbagliate sul totale branch |
| Frontend stall rate | % cicli bloccati nel fetch/decode |
| CPUs utilized | Parallelismo effettivo |
| Context switches | Quante volte il SO ha preemptato il processo |

---

## CPU — `memory_metrics.sh` (L1, LLC, TLB)

Misura la **gerarchia di memoria** tramite `perf stat`: L1-D, L1-I, LLC (L3), dTLB, iTLB miss rate, page faults, MPKI ed evolve la gerarchia in serie temporale.

### Comando

```bash
./cpu/memory_metrics.sh --exe /path/to/binary
```

### Opzioni

| Opzione | Default | Descrizione |
|---|---|---|
| `--exe PATH` | — | **Obbligatorio.** Eseguibile da profilare |
| `--args "..."` | — | Argomenti da passare al binario |
| `--output FILE` | `traces/memory_metrics.txt` | File di testo con il report |
| `--out-dir DIR` | `traces/` | Directory in cui salvare tutti gli output |
| `--repeat N` | `1` | Ripete N volte e fa la media |
| `--interval MS` | 500 | Intervallo di campionamento in ms per Perfetto |
| `--csv` | off | Salva anche `traces/memory_metrics.csv` |
| `--no-perfetto` | off | Non generare il file JSON per Perfetto |

```bash
# Eseguifd prima cpu_metrics (così memory_metrics calcola anche MPKI)
./cpu/cpu_metrics.sh     --exe ./myapp
./cpu/memory_metrics.sh  --exe ./myapp --csv
```

### Output (in `traces/` o `--out-dir`)

| File | Descrizione |
|---|---|
| `memory_metrics.txt` | Report con hit/miss rate per ogni livello della gerarchia |
| `memory_metrics_raw.txt` | Output grezzo di `perf stat` (totali) |
| `memory_metrics_interval.txt` | Output grezzo di `perf stat -I` (serie temporale) |
| `memory_metrics.json` | **Traccia Perfetto** — aprilo su <https://ui.perfetto.dev/> |
| `memory_metrics.csv` | (con `--csv`) Dati machine-readable |

### Metriche misurate

| Metrica | Significato |
|---|---|
| L1-D miss rate | % accessi dati che mancano la L1 (32 KB) |
| L1-I miss rate | % fetch istruzioni che mancano la L1-I |
| LLC miss rate | % accessi che vanno in RAM (working set > L3) |
| MPKI | LLC Misses Per Kilo-Instruction (< 5 = buono, > 10 = memory-bound) |
| dTLB miss rate | % accessi con page walk data (troppe pagine distinte) |
| iTLB miss rate | % fetch con page walk istruzioni |
| Major page faults | Accessi a dati non ancora caricati da disco |

---

# comano per usare perf

sudo apt install linux-tools-$(uname -r) linux-tools-generic

```

### `perf_event_paranoid` per bloccare i contatori hardware e usare i contatori

```bash
sudo sysctl -w kernel.perf_event_paranoid=-1
```
