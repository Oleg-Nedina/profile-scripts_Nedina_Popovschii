# RECAP v1 — Progetto ACA: Profiling di muDock
> **Data ultimo aggiornamento:** 2026-06-16  
> **Autrice:** Nedina Popovschii  
> **Corso:** Architettura dei Calcolatori Avanzata

---

## 🗺️ Struttura del repository

```
profile-scripts_Nedina_Popovschii/
├── cpu/                          ← Strumenti di profiling CPU (Nedina)
│   ├── README.md                 ← Indice generale cartella cpu/
│   ├── perf_stat/                ← Script perf stat: metriche CPU e cache
│   │   ├── README.md             ← Documentazione completa + tabelle metriche
│   │   ├── cpu_metrics.sh               ✅ Hardware fisico
│   │   ├── cpu_metrics_generic.sh       ✅ VM/Docker (fallback software)
│   │   ├── memory_metrics.sh            ✅ Hardware fisico
│   │   ├── memory_metrics_generic.sh    ✅ VM/Docker (fallback software)
│   │   ├── base_converter.sh            ✅ Pipeline build → perf record → Perfetto
│   │   └── base_converter_generic.sh    ✅ Versione portabile
│   ├── low_level/                ← Profiling mirato con uprobes (perf probe)
│   │   ├── README.md             ← Documentazione + caveat (simboli C++, sudo)
│   │   ├── low_level_probe.sh           ✅ Auto-discovery Top-N + probe
│   │   └── low_level_probe_generic.sh   ✅ Versione portabile
│   ├── high_level/               ← Tracciamento thread lifecycle via LD_PRELOAD
│   │   ├── README.md             ← Documentazione architettura + opzioni esecuzione
│   │   ├── high_level_so.cpp            ✅ Libreria → traccia JSON
│   │   ├── perfetto_preload.cpp         ✅ Libreria → traccia nativa SDK (.pftrace)
│   │   ├── high_level_to_otf2.py        ✅ Convertitore JSON → OTF2
│   │   ├── Makefile                     ✅ Compila libhigh_level.so + libperfetto_preload.so
│   │   └── perfetto_sdk/               ← Header-only SDK Perfetto (incluso nel repo)
│   └── perfetto_converters/      ← Convertitori Python: perf output → Perfetto JSON
│       ├── README.md             ← Documentazione input/output/parametri
│       ├── stat_to_perfetto.py          ✅ perf stat -I → counter track JSON
│       ├── perf_to_perfetto.py          ✅ perf.data → slice per thread JSON
│       └── probe_to_perfetto.py         ✅ perf.data (retprobe) → slice con durata reale
│
├── full_pipeline.sh              ✅ Orchestratore 3 livelli (Livello 1+2+3 in sequenza)
├── FULL_PIPELINE.md              ✅ Documentazione full_pipeline.sh (parametri, output, livelli)
└── gpu/                          ← Strumenti GPU (scrittura del professore — riferimento)
    ├── nvidia/                   ← Profiling NVIDIA con Nsight Compute (ncu)
    └── amd/                      ← Profiling AMD con rocprof
```

---

## ✅ Fatto — Sessione 1 (organizzazione iniziale)

### Struttura script CPU (prima della riorganizzazione)
- Scrittura di `cpu_metrics.sh` — misurazione IPC, branch, stall via `perf stat`
- Scrittura di `cpu_metrics_generic.sh` — stessa funzionalità con fallback software per VM/Docker
- Scrittura di `memory_metrics.sh` — misurazione gerarchia cache L1/LLC/TLB via `perf stat`
- Scrittura di `memory_metrics_generic.sh` — con fallback per ambienti virtualizzati
- Scrittura di `base_converter.sh` — pipeline completa build → `perf record` → JSON Perfetto
- Scrittura di `low_level_probe.sh` — discovery Top-N funzioni muDock via `perf probe` + uprobes

### Librerie LD_PRELOAD (`high_level/`)
- `high_level_so.cpp` v1 — catturava solo 1 thread (bug: attendeva ritorno start_routine)
- `high_level_so.cpp` v2 — **registrazione in 2 fasi**: `thread_started()` all'avvio, `flush()` forzato per thread OpenMP che non terminano mai
- Risolto: **segfault** per ordine distruzione oggetti statici C++ → heap singleton `new GlobalRegistry`
- Scrittura di `high_level_to_otf2.py` — conversione JSON → OTF2 (per Vampir/Score-P)

### Convertitori Perfetto
- `stat_to_perfetto.py` — parse di `perf stat -I`, genera counter track (Raw + Derived per ogni slot temporale)
- `perf_to_perfetto.py` — esegue `perf script`, parse stack frames, genera slice per TID

### SDK Perfetto nativo (`perfetto_preload.cpp`)
- Prima implementazione con `libperfetto_preload.so` — buffer 64MB hardcoded, no thread naming

---

## ✅ Fatto — Sessione 2 (riorganizzazione + miglioramenti)

### Riorganizzazione cartella `cpu/`
- Creazione sottocartelle: `perf_stat/`, `perfetto_converters/` (prima tutto in `cpu/` flat)
- Spostamento script negli opportuni sottofolder
- **Aggiornamento di tutti i path interni** (7 file modificati: riferimenti a `stat_to_perfetto.py` e `perf_to_perfetto.py` corretti da percorsi vecchi → `../perfetto_converters/`)
- Creazione `cpu/README.md` — indice generale con quick start e tabella riassuntiva

### Fix `perf_to_perfetto.py`
- Eliminato **PERF_BIN hardcoded** (`/usr/lib/linux-tools/6.8.0-117-generic/perf`)
- Sostituito con rilevamento portabile: `shutil.which("perf")` → glob linux-tools (versione più recente) → fallback

### Miglioramento `perfetto_preload.cpp` (SDK Perfetto nativo)
- **Thread naming** in Perfetto: ogni thread appare con label `Worker-N [TID XXXX]` nella timeline
- **Buffer configurabile** via variabile env `MUDOCK_PERFETTO_BUF_MB` (default 64 MB, max 1024 MB)
- **Flush guard atomico** — evita doppio flush in caso di abort/crash
- **Creazione automatica** della directory di output (non crasha se `traces/` non esiste)
- **Indice progressivo** dei thread per distinguerli nella UI

### Confronto GPU vs CPU
- Analizzata la cartella `gpu/nvidia/profile.sh` (scritta dal professore) come riferimento
- Identificati i punti di forza degli script GPU da adottare nella CPU (vedi sezione "Da fare")
- Identificati i punti in cui gli script CPU sono già superiori agli script GPU

---

## ✅ Fatto — Sessione 4 (priorità alta: retprobe + c2c + full_pipeline)

### 1. Retprobe in `low_level_probe.sh` ✅
- Aggiunto flag `--retprobe` (default: on) e `--no-retprobe` per tornare al comportamento precedente
- Per ogni funzione target: aggiunta **entry probe** (già presente) + **return probe** (`%return`)
- Mappa `entry_event → return_event` costruita a runtime e passata al converter
- Selezione automatica del converter: usa `probe_to_perfetto.py` se ci sono retprobe, altrimenti fallback su `perf_to_perfetto.py`
- Fix portabile di `PERF_BIN` (era ancora hardcoded a `/usr/lib/linux-tools/6.8.0-...`)

### 2. Nuovo `probe_to_perfetto.py` ✅
- Converter specializzato per eventi `perf probe` + retprobe (tipo discreto, non campionato)
- Abbina entry → return per ogni TID usando uno **stack LIFO** (gestisce ricorsione)
- Genera slice Perfetto tipo `X` con `ts` reale e `dur` reale in µs (non stimata)
- Auto-scoperta delle coppie entry/return se `--pair` non specificato (pattern `__return`)
- Statistiche per funzione in `otherData`: `calls`, `mean_us`, `min_us`, `max_us`
- Counter track `active_functions`: quante funzioni sono in esecuzione simultaneamente

### 3. Analisi False Sharing `perf c2c` in `low_level_probe.sh` ✅
- Aggiunto flag `--c2c` (default: off): esegue un run aggiuntivo con `perf c2c record`
- Genera `traces/c2c_report.txt` con top cache line sharing e spiegazione colonne (`Lcl Hitm`, `Rmt Hitm`)
- Fallback graceful se l'hardware non supporta `perf c2c` (non crasha lo script)
- Il flag `--c2c` è disponibile anche da `full_pipeline.sh` che lo propaga al livello 3

### 4. `full_pipeline.sh` — Orchestratore completo ✅
File nella root del progetto. Lancia in sequenza:
- **Livello 1A**: `cpu_metrics.sh` → IPC, branch, stall
- **Livello 1B**: `memory_metrics.sh` → cache, TLB, MPKI
- **Livello 2**: `profile_high_level.sh` → thread lifecycle (con fallback LD_PRELOAD diretto)
- **Livello 3**: `low_level_probe.sh` → uprobes + retprobe Top-N funzioni
- Ogni livello ha la propria sottodirectory in `traces/full_pipeline/`
- Flag `--skip-l1/l2/l3` per saltare livelli singoli
- Genera `perf.data` di base automaticamente se non esiste
- Riepilogo finale con tabella di tutti i file generati + dimensioni
- Apre automaticamente Perfetto nel browser con la prima traccia disponibile

---

## ✅ Fatto — Sessione 3 (README specifici + --warmup)

### README specifici per ogni sottocartella (non un unico file generale)
- **`perf_stat/README.md`** — riscritto completamente: come eseguire ogni script (`cpu_metrics`, `memory_metrics`, `base_converter`), tabella di tutti i `--flag` con default, tabella completa di tutte le metriche PMU con soglie critiche di interpretazione
- **`high_level/README.md`** — riscritto: 3 opzioni di esecuzione (Opzione A: JSON leggero, B: SDK nativo `.pftrace`, C: automazione con `profile_high_level.sh`), tabella variabili env separate per le 2 librerie, tabella flag `profile_high_level.sh`
- **`perfetto_converters/README.md`** — riscritto: parametri posizionali di entrambi i `.py`, struttura output Perfetto (counter track vs slice)
- **`low_level/README.md`** — fix path `base_converter.sh` → `perf_stat/base_converter.sh`

### Implementazione `--warmup N` in `cpu_metrics.sh` e `memory_metrics.sh`
Ispirato dal meccanismo `NCU_WARMUP` degli script GPU del professore:
- Aggiunto flag `--warmup N` (default: 0)
- Esegue N run *silenziosi* del binario **prima** dei repeat ufficiali, scartandone i dati
- Scopo: scaldare la cache del sistema ed eliminare il rumore del "cold cache" sul primo run
- Validazione input (`--repeat`, `--warmup`, `--interval` verificati con regex + range check)
- Il report testuale mostra `Repeat: X (warmup: Y)` nell'intestazione

---

## ✅ Fatto — Sessione 5 (bugfix compilazione ed esecuzione + note di analisi)

### 1. Fix compilazione SDK Perfetto nativo (`perfetto_preload.cpp`) ✅
* Risolto l'errore di simbolo mancante inserendo `#include <climits>` per la costante `INT_MAX`.
* Sostituita la chiamata non corretta `perfetto::Track::ThreadScoped()` con `perfetto::ThreadTrack::Current()`, ripristinando il tracciamento dei thread worker OpenMP.

### 2. Risolto il crash del convertitore Python (`perf_to_perfetto.py` e `probe_to_perfetto.py`) ✅
* Eliminata la dipendenza dal wrapper di sistema `/usr/bin/perf` che generava errori legati alla versione specifica del kernel.
* Implementata la ricerca dinamica delle versioni stabili di `perf` sotto `/usr/lib/linux-tools/` (allineando i convertitori con gli script Bash).

### 3. Note e limitazioni di analisi documentate ✅
* **SDK Nativo (`LD_PRELOAD`):** Chiarito che l'SDK nativo via `LD_PRELOAD` può intercettare solo la creazione dei thread (`pthread_create`). Senza modificare il codice sorgente di `muDock` (es. inserendo macro `TRACE_EVENT`), mostrerà solo la barra intera di esecuzione del thread ("Thread Execution") senza sotto-funzioni.
* **Uprobes/Retprobes (Livello 3):** Documentato il motivo dei fallimenti delle probe su funzioni `inline` (come `calc_energy` ottimizzata a `-O2`) e costruttori con multipli entry point. In questi casi, lo script ricade correttamente sul campionamento CPU generico.

---

## 🔲 Da fare — Priorità alta

> [!NOTE]
> **Tutte le priorità alte sono state implementate nella Sessione 4.**

~~1. Retprobes in `low_level_probe.sh`~~ → ✅ Implementato (flag `--retprobe`)
~~2. Analisi False Sharing con `perf c2c`~~ → ✅ Implementato (flag `--c2c`)
~~3. Script unificato `full_pipeline.sh`~~ → ✅ Implementato (root del progetto)

---

## 🔲 Da fare — Priorità media

### 4. `--warmup N` anche in `cpu_metrics_generic.sh` e `memory_metrics_generic.sh`
**Cosa:** Replicare la stessa logica warmup implementata nei file "standard" anche nelle versioni `_generic` (che hanno un sistema di fallback diverso).  
**Perché:** Uniformità di interfaccia tra tutte le versioni dello stesso script.

### 5. Hook `pthread_setname_np` in `high_level_so.cpp`
**Cosa:** Intercettare anche `pthread_setname_np` tramite LD_PRELOAD per catturare i nomi che OpenMP/applicazione assegna ai thread worker.  
**Perché:** Attualmente i thread nel JSON appaiono come `Thread 1`, `Thread 2` ecc. Con il nome reale (es. `omp_thread_3`) la traccia è molto più leggibile.

### 6. Hook `pthread_join` in `high_level_so.cpp`
**Cosa:** Registrare le chiamate a `pthread_join` per tracciare le **dipendenze tra thread** (chi aspetta chi) come frecce di flusso (`ph: "f"`) in Perfetto.  
**Perché:** Rende visibile la struttura fork/join del parallelismo OpenMP sulla timeline.

### 7. `--force` / `.stamp` file per saltare la raccolta dati
**Cosa:** Aggiungere la possibilità di saltare la raccolta perf stat se i file raw esistono già (usando un `.stamp` file), ispirato dagli script GPU.  
**Perché:** Evita di rieseguire il binario quando si vuole solo rigenerare il JSON Perfetto o il report con parametri diversi.

---

## 🔲 Da fare — Priorità bassa

### 8. Output PDF statico con matplotlib
**Cosa:** Aggiungere un convertitore Python (`stat_to_pdf.py`) che produce grafici statici (serie temporali, istogrammi) dai file `*_interval.txt`.  
**Perché:** Utile per report e slide di presentazione, dove non si può aprire Perfetto.  
**Ispirazione:** Pipeline gnuplot degli script GPU del professore.

### 9. Output in formato OTF2 per Vampir/Score-P
**Cosa:** Completare/migliorare `high_level_to_otf2.py` per produrre trace OTF2 valide.  
**Perché:** OTF2 è lo standard HPC per trace ad alta scalabilità, leggibile da strumenti professionali (Vampir, Score-P, TAU).

### 10. Supporto OMPT (OpenMP Tools Interface)
**Cosa:** Hookkare le primitive OpenMP interne tramite OMPT per distinguere le singole task parallele dentro il pool di thread.  
**Perché:** Attualmente i thread del pool OpenMP appaiono come un'unica slice che dura tutta l'esecuzione. Con OMPT si vedrebbero le singole task (fork, barrier, task).

---

## 📊 Confronto CPU vs GPU (riferimento professore)

| Feature | Script CPU (nostri) | Script GPU (professore) | Note |
|---------|---------------------|------------------------|------|
| Banner visivo all'avvio | ✅ Sì | ❌ No | Vantaggio CPU |
| Interpretazione soglie | ✅ Sì (IPC, miss%) | ❌ Solo dati grezzi | Vantaggio CPU |
| Fallback VM/Docker | ✅ `*_generic.sh` | ❌ No | Vantaggio CPU |
| Output interattivo (Perfetto) | ✅ `.json` + `.pftrace` | ❌ No | Vantaggio CPU |
| Thread tracking (LD_PRELOAD) | ✅ Sì | ❌ No | Vantaggio CPU |
| CSV export | ✅ `--csv` | ❌ No | Vantaggio CPU |
| Durata reale funzioni (retprobe)| ✅ `--retprobe` *(nuovo)* | ❌ No | Vantaggio CPU |
| Analisi False Sharing | ✅ `--c2c` *(nuovo)* | ❌ No | Vantaggio CPU |
| Pipeline orchestrata | ✅ `full_pipeline.sh` *(nuovo)* | ❌ No | Vantaggio CPU |
| Warmup discard | ✅ `--warmup N` | ✅ `NCU_WARMUP` | Parità |
| Repeat / media N run | ✅ `--repeat N` | ✅ `NCU_RUNS=N` | Parità |
| Multi-target (`all`/`cpu`/`mem`) | ❌ No | ✅ Sì | Da fare CPU |
| Cache run esistente (`.stamp`) | ❌ No | ✅ Sì | Da fare CPU |
| Output statico PDF/PS | ❌ No | ✅ gnuplot → PDF | Da fare CPU |

---

## 🔗 File di riferimento chiave

| File | Descrizione |
|------|-------------|
| [`full_pipeline.sh`](full_pipeline.sh) | **Orchestratore completo** — lancia tutti e 3 i livelli in sequenza |
| [`cpu/perf_stat/cpu_metrics.sh`](cpu/perf_stat/cpu_metrics.sh) | Livello 1A — IPC, branch, stall |
| [`cpu/perf_stat/memory_metrics.sh`](cpu/perf_stat/memory_metrics.sh) | Livello 1B — cache, TLB, MPKI |
| [`cpu/high_level/high_level_so.cpp`](cpu/high_level/high_level_so.cpp) | Livello 2 — LD_PRELOAD thread lifecycle (JSON) |
| [`cpu/high_level/perfetto_preload.cpp`](cpu/high_level/perfetto_preload.cpp) | Livello 2 — LD_PRELOAD thread lifecycle (SDK nativo) |
| [`cpu/low_level/low_level_probe.sh`](cpu/low_level/low_level_probe.sh) | Livello 3 — uprobes + retprobe + c2c |
| [`cpu/perfetto_converters/stat_to_perfetto.py`](cpu/perfetto_converters/stat_to_perfetto.py) | Converter: `perf stat -I` → counter track JSON |
| [`cpu/perfetto_converters/perf_to_perfetto.py`](cpu/perfetto_converters/perf_to_perfetto.py) | Converter: `perf.data` campionamento → slice JSON |
| [`cpu/perfetto_converters/probe_to_perfetto.py`](cpu/perfetto_converters/probe_to_perfetto.py) | Converter: `perf.data` retprobe → slice con durata reale |
| [`roadmap_da_fare.md`](roadmap_da_fare.md) | Architettura a 3 livelli (System/Process/Function) |
| [`gpu/nvidia/profile.sh`](gpu/nvidia/profile.sh) | Riferimento professore — pipeline GPU con ncu |

---

*Recap generato il 2026-06-16 — Progetto ACA Università*
