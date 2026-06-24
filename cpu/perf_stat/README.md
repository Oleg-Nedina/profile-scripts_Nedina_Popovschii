# `perf_stat/` — Analisi Metriche CPU e Memoria

Script per misurare metriche hardware (IPC, cache, TLB) via **`perf stat`**.  
Ogni script produce un report testuale + traccia JSON per [ui.perfetto.dev](https://ui.perfetto.dev/).

---

## Script disponibili

| File | Cosa misura | Quando usarlo |
|------|-------------|---------------|
| `cpu_metrics.sh` | IPC, branch, stall, context-switch | Hardware fisico, bare-metal |
| `cpu_metrics_generic.sh` | Stesse metriche + fallback software | VM, Docker, cloud |
| `memory_metrics.sh` | L1/L2/LLC/TLB miss rate, MPKI | Hardware fisico, bare-metal |
| `memory_metrics_generic.sh` | Stesse metriche + fallback software | VM, Docker, cloud |
| `base_converter.sh` | Pipeline completa: build → perf record → Perfetto | Primo run completo |
| `base_converter_generic.sh` | Come sopra, portabile | VM, primo run |

---

## Come eseguire

> **Prerequisito:** il binario da profilare deve già esistere.

### `cpu_metrics.sh` — Metriche CPU

```bash
# Dalla root del progetto muDock:
./profile-scripts_Nedina_Popovschii/cpu/perf_stat/cpu_metrics.sh \
    --exe <app>
```

### `memory_metrics.sh` — Metriche Cache e TLB

```bash
./profile-scripts_Nedina_Popovschii/cpu/perf_stat/memory_metrics.sh \
    --exe <app>
```

### `base_converter.sh`

```bash
./profile-scripts_Nedina_Popovschii/cpu/perf_stat/base_converter.sh \

```

---

## Parametri di `cpu_metrics.sh` e `memory_metrics.sh`

| Parametro | Default | Obbligatorio | Descrizione |
|-----------|---------|:------------:|-------------|
| `--exe PATH` | — | si | Percorso al binario da profilare |
| `--args "..."` | — | — | Argomenti da passare al binario (tra virgolette) |
| `--out-dir DIR` | `./traces/` | — | Directory dove salvare tutti i file di output |
| `--output FILE` | `traces/<nome>.txt` | — | Percorso custom per il report testuale |
| `--repeat N` | `1` | — | Esegue N volte e fa la media dei contatori |
| `--warmup N` | `0` | — | Scarta le prime N misurazioni (riduce rumore da cache fredda) |
| `--interval MS` | `500` | — | Intervallo di campionamento in ms per la serie temporale Perfetto |
| `--csv` | off | — | Salva anche un file `.csv` machine-readable |
| `--no-perfetto` | off | — | Disabilita la generazione del JSON Perfetto |

> **Nota su `--warmup`:** Se `--repeat 5 --warmup 2`, vengono eseguite 5 run, le prime 2 vengono scartate e la media è calcolata sulle ultime 3. Utile per eliminare l'effetto cache fredda sul primo run.

---

## Parametri di `base_converter.sh`

| Parametro | Default | Descrizione |
|-----------|---------|-------------|
| `--population N` | `100` | Dimensione della popolazione per il GA di muDock |
| `--generations N` | `100` | Numero di generazioni per il GA |
| `--skip-build` | off | Salta la compilazione (usa il binario esistente) |
| `--convert-only` | off | Salta build E esecuzione, converte solo perf.data esistente |
| `--clean` | off | Forza una clean build (cancella la cartella build/) |
| `--no-browser` | off | Non aprire il browser automaticamente |

---

## Metriche misurate

### `cpu_metrics.sh` — Contatori PMU CPU

| Metrica | Evento `perf` | Cosa indica | Soglia critica |
|---------|---------------|-------------|----------------|
| **IPC** | `instructions / cycles` | Istruzioni eseguite per ciclo di clock. Valore alto = pipeline efficiente | < 1.0 |
| **Cycles** | `cycles` | Cicli di clock totali dell'applicazione | — |
| **Instructions** | `instructions` | Istruzioni macchina eseguite | — |
| **Branches** | `branches` | Salti condizionali/incondizionali totali | — |
| **Branch Misses** | `branch-misses` | Branch predetti male dal predittore hardware → pipeline flush | > 5% |
| **Branch Miss Rate** | derivato | `branch-misses / branches × 100` | > 10% |
| **Frontend Stalls** | `stalled-cycles-frontend` | Cicli persi nel fetch/decode istruzioni (I-cache miss, branch pred) | > 20% |
| **Frontend Stall Rate** | derivato | `stalled-cycles-frontend / cycles × 100` | — |
| **Context Switches** | `context-switches` | Quante volte il SO ha preemptato il processo | Alto |
| **CPU Migrations** | `cpu-migrations` | Quante volte il processo è stato migrato su un altro core | > 10 |
| **Page Faults** | `page-faults` | Fault di paginazione totali (minor + major) | — |

### `memory_metrics.sh` — Gerarchia Cache e TLB

| Metrica | Evento `perf` | Cosa indica | Soglia critica |
|---------|---------------|-------------|----------------|
| **L1-D Loads** | `L1-dcache-loads` | Accessi totali alla cache L1 dati | — |
| **L1-D Misses** | `L1-dcache-load-misses` | Miss in L1-D → promozione a L2 | — |
| **L1-D Miss Rate** | derivato | `misses / loads × 100` | > 10% |
| **L1-D Hit Rate** | derivato | `(1 - miss_rate) × 100` | < 90% |
| **L1-I Loads** | `L1-icache-loads` | Accessi alla cache L1 istruzioni | — |
| **L1-I Misses** | `L1-icache-load-misses` | Miss in L1-I → stall frontend | — |
| **LLC References** | `cache-references` | Accessi alla Last Level Cache (L3) | — |
| **LLC Misses** | `cache-misses` | Miss in LLC → accesso a RAM (latenza ~100ns) | — |
| **LLC Miss Rate** | derivato | `LLC-misses / LLC-refs × 100` | > 10% |
| **MPKI** | derivato | Miss Per Kilo Instructions: `LLC-misses / instructions × 1000`. Applicazione memory-bound se alto | > 10 |
| **dTLB Loads** | `dTLB-loads` | Lookup nel Translation Lookaside Buffer dati | — |
| **dTLB Misses** | `dTLB-load-misses` | Miss nel dTLB → page-walk hardware (centinaia di cicli) | — |
| **dTLB Miss Rate** | derivato | `dTLB-misses / dTLB-loads × 100` | > 1% |
| **iTLB Loads** | `iTLB-loads` | Lookup nel TLB istruzioni | — |
| **iTLB Misses** | `iTLB-load-misses` | Miss nel iTLB (codice sparso in memoria) | — |
| **Page Faults (Major)** | `major-faults` | Fault che richiedono I/O da disco. Processo non residente in RAM | > 0 |
| **Page Faults (Minor)** | `minor-faults` | Fault senza I/O: mapping nuovo, Copy-on-Write | — |

---

## File di output generati

Per ogni script, nella directory `--out-dir` (default `./traces/`):

| File | Descrizione |
|------|-------------|
| `cpu_metrics.txt` | Report testuale formattato (box ASCII con soglie interpretazione) |
| `cpu_metrics_raw.txt` | Output grezzo totale di `perf stat` (tutti i valori, una riga per evento) |
| `cpu_metrics_interval.txt` | Output grezzo con `-I <ms>` (serie temporale, usato per Perfetto) |
| `cpu_metrics.json` | **Traccia Perfetto** con counter track per ogni evento + metriche derivate |
| `cpu_metrics.csv` | CSV machine-readable (solo con `--csv`) |

*(Stessa struttura per `memory_metrics.*`)*

---

## Requisiti

```bash
# Installa perf (Ubuntu/Debian):
sudo apt install linux-tools-$(uname -r) linux-tools-common

# Sblocca i contatori hardware (richiesto una volta per sessione):
sudo sysctl -w kernel.perf_event_paranoid=-1
```

---

## Come vengono calcolate le metriche? (Calcoli reali vs Mocking)

Gli script **calcolano realmente tutte le metriche** e **non fanno finta (nessun mocking)**.

Le misurazioni si basano sull'interfaccia ufficiale del kernel Linux per l'accesso ai contatori di performance hardware e software. Ecco il dettaglio di come funziona il meccanismo e come vengono calcolati i valori:

### 1. Rilevazione reale tramite `perf stat`

Gli script eseguono il binario target sotto il tool di sistema di Linux **`perf stat`**, configurato con l'opzione `-e` per ascoltare specifici eventi fisici e software:

* **Contatori Hardware (PMC - Performance Monitoring Counters):** I registri interni della CPU tengono traccia fisica di eventi come cicli di clock (`cycles`), istruzioni ritirate (`instructions`), salti (`branches`), salti errati (`branch-misses`), accessi e miss alle cache (L1-D, L1-I, L3/LLC) e lookup al TLB (dTLB, iTLB).
* **Contatori Software del Kernel:** Eventi gestiti dal sistema operativo come cambi di contesto (`context-switches`), migrazioni di CPU (`cpu-migrations`) e page fault (`page-faults`, `major-faults`, `minor-faults`).

### 2. Doppia esecuzione per Tracing e Medie

Gli script eseguono due passaggi distinti per raccogliere i dati senza interferenze reciproche:

1. **Serie temporale (`-I <interval_ms>`):** Raccoglie campionamenti periodici reali a intervalli regolari (es. ogni 500ms). I dati ottenuti vengono poi convertiti nello script `stat_to_perfetto.py` in formato JSON per essere visualizzati graficamente come timeline su [Perfetto UI](https://ui.perfetto.dev/).
2. **Totali mediati (`--repeat <N>`):** Esegue il binario per un numero $N$ di volte per calcolare una media cumulativa precisa, eliminando il rumore statistico. Se è attivo il `--warmup`, le prime esecuzioni vengono scartate per evitare l'effetto cache fredda.

### 3. Parsing ed estrazione

L'output testuale generato da `perf stat` viene intercettato dagli script, salvato in file temporanei, e processato tramite utility standard di Linux (`grep` e `awk`):

* I valori grezzi vengono isolati rimuovendo virgole o formattazioni di testo.
* Le metriche di alto livello o derivate vengono calcolate a partire dai contatori grezzi tramite formule matematiche all'interno di blocchi `awk`.

Le formule utilizzate per le metriche derivate sono:

* **IPC (Instructions Per Cycle):** $\text{IPC} = \frac{\text{instructions}}{\text{cycles}}$ (Indica quante istruzioni la CPU riesce a completare in media per ogni ciclo di clock).
* **Branch Miss Rate:** $\text{Branch Miss Rate} = \frac{\text{branch-misses}}{\text{branches}} \times 100$
* **Frontend Stall Rate:** $\text{Frontend Stall Rate} = \frac{\text{stalled-cycles-frontend}}{\text{cycles}} \times 100$
* **Cache Miss Rate (L1-D, L1-I, LLC):** $\text{Miss Rate} = \frac{\text{load-misses}}{\text{loads}} \times 100$
* **LLC MPKI (LLC Misses Per Kilo-Instructions):** $\text{MPKI} = \frac{\text{cache-misses}}{\text{instructions}} \times 1000$ (Misura quante volte l'applicazione deve accedere alla memoria RAM fisica ogni 1000 istruzioni).

### 4. Gestione Portabilità nei file `*_generic.sh`

Nelle macchine virtuali (VM), all'interno di container Docker o in cloud provider, l'accesso ai contatori hardware (PMU) potrebbe essere disabilitato o limitato dal sistema di virtualizzazione.

* Gli script generici (`cpu_metrics_generic.sh` e `memory_metrics_generic.sh`) eseguono un **pre-screening adattivo** provando a lanciare comandi di test per ogni evento desiderato.
* Se l'hardware non supporta gli eventi PMC fisici, lo script non inventa dati finti ma **attiva un fallback software** mostrando solo le metriche di sistema fornite dal kernel (es. page-faults e context switches) e contrassegnando le metriche hardware mancanti come **`N/A`** (Not Available), garantendo così trasparenza e correttezza scientifica delle misure.

---

*Documentazione progetto ACA — Profiling e Tracing HPC*

  echo "║  INTERPRETAZIONE RAPIDA                                          ║"
  echo "║                                                                  ║"
  echo "║  IPC > 2.0  → buona efficienza pipeline                         ║"
  echo "║  IPC < 1.0  → collo di bottiglia (memoria, branch, stall)       ║"
  echo "║  Branch miss > 5%  → ottimizzare predittori/branch              ║"
  echo "║  Frontend stall > 20% → fetch/decode limitante                  ║"
  echo "║                                                                  ║"

  echo "║  INTERPRETAZIONE RAPIDA                                          ║"
  echo "║                                                                  ║"
  echo "║  L1-D miss > 10% → working set non entra in L1 (32KB)          ║"
  echo "║  LLC miss  > 10% → working set non entra in L3, accessi a RAM  ║"
  echo "║  MPKI > 10        → applicazione memory-bound                   ║"
  echo "║  dTLB miss > 1%  → accessi sparsi su molte pagine (>128)       ║"
  echo "║  Major faults > 0 → accessi a dati non ancora in RAM           ║"
  echo "║                                                                  ║"
  echo "╠═══════════════════════════════════════════════════════════════════╣"
