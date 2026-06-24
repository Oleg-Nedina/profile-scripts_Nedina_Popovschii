# Recap Profilazione muDock — ACA Project
> Aggiornato: 2026-06-21

---

## Panoramica del Progetto

Script di profilazione per **muDock** (molecular docking su CPU), organizzati in tre livelli di dettaglio crescente:

| Livello | Script | Tecnica | Cosa misura |
|---|---|---|---|
| L1 | `cpu_metrics.sh` / `memory_metrics.sh` | `perf stat` | IPC, branch miss, stall, cache miss, TLB |
| L2 | `profile_high_level.sh` | `LD_PRELOAD` | Ciclo di vita dei thread (nascita/morte + sincronizzazione) |
| L3 | `low_level_probe.sh` | `perf probe` (uprobes) | Durata delle singole funzioni C++ più costose |
| All | `full_pipeline.sh` | Tutti e tre | Esecuzione automatica sequenziale di L1→L2→L3 |
| Util | `base_converter.sh` | `perf record` | Campionamento CPU con call stack completo |

Ogni script ha una variante `_generic.sh` senza dipendenze da muDock o da Spack, portabile su cluster/VM/Docker.

---

## Struttura dei File

```
cpu/
├── high_level/
│   ├── profile_high_level.sh       ← L2: LD_PRELOAD con libhigh_level.so
│   ├── high_level_so.cpp           ← sorgente libreria intercettazione (v3)
│   ├── perfetto_preload.cpp        ← SDK Perfetto nativo (--native, ha segfault)
│   └── Makefile
├── low_level/
│   ├── low_level_probe.sh          ← L3: uprobes kernel
│   └── low_level_probe_generic.sh
├── perf_stat/
│   ├── base_converter.sh           ← perf record → JSON Perfetto
│   ├── cpu_metrics.sh              ← L1a: metriche IPC/branch/stall
│   ├── memory_metrics.sh           ← L1b: metriche cache/TLB
│   └── *_generic.sh (x3)
├── perfetto_converters/
│   ├── perf_to_perfetto.py         ← converte perf.data → JSON Perfetto
│   ├── stat_to_perfetto.py         ← converte perf stat → JSON Perfetto
│   └── probe_to_perfetto.py
├── full_pipeline.sh
└── status.md                       ← log degli esiti dei test
```

---

## Stato dei Test

| Script | Stato | Note |
|---|---|---|
| `profile_high_level.sh` (JSON) | ✅ Nominale | Traccia 528K, OTF2 generato |
| `profile_high_level.sh --native` | ❌ Segfault | `libperfetto_preload.so`, exit 139 |
| `low_level_probe.sh --c2c` | ⚠️ Parziale | 1/3 funzioni tracciate (inlining) |
| `base_converter.sh` | ✅ Nominale | 1.1GB perf.data, 136K campioni, JSON 20MB |
| `cpu_metrics.sh` / `memory_metrics.sh` | ✅ Risolto (P1) | Fix percorso PDB |
| `full_pipeline.sh` | ⚠️ Parziale | L1+L2 OK, L3 parziale |

---

## Problemi Riscontrati e Fix Applicati

### ✅ P1 — RISOLTO: `cpu_metrics.sh` / `memory_metrics.sh` crashavano (PDB non trovato)
**Causa**: gli script venivano eseguiti da una directory che non conteneva `data/1fkb/` come percorso relativo.  
**Fix**: eseguire dalla root di muDock, passare il percorso esplicito con `--exe`.

---

### ✅ P2 — RISOLTO: JSON di `cpu_metrics` / `memory_metrics` non si aprivano in Perfetto

**Causa in [`stat_to_perfetto.py`](../profile-scripts_Nedina_Popovschii/cpu/perfetto_converters/stat_to_perfetto.py)**:
- I file contenevano **solo eventi Counter** (`ph: C`). Perfetto UI richiede almeno uno slice di durata (`ph: X/B/E`) per inizializzare la timeline e calcolare il range temporale.
- La chiave radice `"metadata"` non è standard nel formato Trace Event e causava errori nel parser WASM di Perfetto.

**Fix applicato**:
- Aggiunta una **slice sentinella** `ph: X` denominata `"muDock Profiling Session"` che copre l'intera durata della sessione (da `ts=0` a `ts=max`).
- Rimossa la chiave radice `"metadata"` non standard.

**Per rigenerare i JSON**: rieseguire gli script con `--convert-only` o con nuovi run.

---

### ⚠️ P3 — LIMITAZIONE STRUTTURALE: `low_level_probe.sh` traccia solo 1/3 funzioni

**Causa**: muDock è compilato con `-O2`/`RelWithDebInfo`. Il compilatore inlina aggressivamente le funzioni calde (`calc_energy`, costruttori di `autodock_protein`), eliminando i loro entry point fisici dalla tabella dei simboli ELF. `perf probe` non ha un indirizzo a cui agganciarsi.

> **Questa non è una limitazione dello script, ma del binario ottimizzato.**  
> Profilare il codice ottimizzato è l'obiettivo corretto: le funzioni inlinate esistono solo come codice "fuso" nel chiamante.

**Workaround disponibile** (solo se si vuole debuggare la struttura interna):  
```bash
./cpu/perf_stat/base_converter.sh --debug-build   # compila con -Og -fno-inline
./cpu/low_level/low_level_probe.sh                 # ora tutte le funzioni sono tracciabili
```

**Funzione attualmente tracciata con successo**:
- ✅ `mudock::autodock_protein::prepare` (entry probe, ~94% del CPU time)
- ❌ `mudock::calc_energy` (inlinata)
- ❌ `mudock::autodock_protein::autodock_protein` (inlinata/costruttore template)

---

### ✅ P4 — RISOLTO: traccia `high_level` mostrava solo nascita/morte thread (fix v3 + v4)

**Causa originale**: [`high_level_so.cpp`](../profile-scripts_Nedina_Popovschii/cpu/high_level/high_level_so.cpp) intercettava solo `pthread_create`.

**Fix v3**: Aggiunti hook `pthread_mutex_lock`, `pthread_barrier_wait`, `pthread_cond_wait`.

**Fix v4 (aggiuntivo — risolve bug OpenMP)**: Tre problemi identificati e corretti:

#### Problema A — libgomp NON chiama `pthread_barrier_wait`
GCC OpenMP (libgomp) implementa le proprie barriere internamente tramite futex/spin, senza mai chiamare la POSIX `pthread_barrier_wait`. L'hook esiste ma non viene mai triggerato da muDock. Le barriere OpenMP implicite (`#pragma omp parallel for`) si traducono in `pthread_cond_wait` nel pool di thread → hook corretto è `cond_wait`.

#### Problema B — Race condition al flush sui `live_bufs`
I thread del pool OpenMP (vivi al momento del flush) continuavano a scrivere sui propri buffer `tl_sync_events` mentre `flush()` li leggeva → **undefined behaviour**.

**Fix**: aggiunto `static std::atomic<bool> g_flushing{false}`:
- Ogni hook controlla `g_flushing` in ingresso e passa direttamente al codice originale se `true`
- `flush()` setta `g_flushing = true` + aspetta 1ms prima di leggere i `live_bufs`
- La finestra di UB si riduce a quella dei hook già entrati al momento del set

#### Problema C — Registrazione tardiva del buffer (doppia o mancata)
Ogni hook usava una propria `static thread_local bool registered` → possibilità di doppia registrazione + mancata registrazione per thread del pool che entrano subito in `cond_wait`.

**Fix**: sostituito con un unico `static thread_local bool tl_buf_registered` condiviso tra tutti gli hook, e la registrazione avviene ora in `hl_thread_entry` (immediatamente all'avvio del thread, prima che qualsiasi hook possa sparare).

| Hook intercettato | Evento emesso | Cosa rivela |
|---|---|---|
| `pthread_mutex_lock` | `slice "mutex"` | Contesa su lock tra thread |
| `pthread_barrier_wait` | `slice "barrier"` | Barriere POSIX esplicite (non OpenMP) |
| `pthread_cond_wait` | `slice "cond_wait"` | Thread pool dormiente + barriere OpenMP implicite |

**Per applicare**: la libreria è già stata ricompilata con `make`. Rieseguire `profile_high_level.sh --skip-build`.

---

### 🔴 P5 — APERTO: Segfault con `profile_high_level.sh --native`

**Causa probabile**: `libperfetto_preload.so` intercetta `pthread_create`. L'SDK nativo C++ di Perfetto crea internamente thread di servizio tramite `pthread_create`. Questo genera una ricorsione nell'inizializzazione dell'SDK prima che sia completamente pronto, causando crash per:
- Stack overflow da ricorsione infinita, oppure
- Accesso a strutture dati Perfetto non ancora inizializzate (null pointer deref)

**Impatto**: basso — la modalità `--native` è alternativa alla versione JSON già funzionante.  
**Soluzione teorica**: aggiungere un guard `thread_local` in `perfetto_preload.cpp` per evitare di intercettare i thread interni di Perfetto (identici a quanto fatto in P4).

---

## Cosa Mostra Ogni Traccia in Perfetto UI

| File JSON | Aperto su Perfetto | Cosa si vede |
|---|---|---|
| `trace_high_level.json` | ✅ | Timeline per thread: Running (verde), mutex (rosso), barrier (blu), cond_wait (giallo) |
| `trace_perf.json` | ✅ | Call stack per thread campionati ogni ~100µs: flame graph temporale con tutti i simboli C++ |
| `trace_low_level.json` | ✅ | Durata precisa di `prepare` con timestamp kernel-level |
| `cpu_metrics.json` | ✅ (dopo P2) | Counter: IPC, branch miss %, frontend stall % nel tempo |
| `memory_metrics.json` | ✅ (dopo P2) | Counter: L1/LLC/TLB miss rate nel tempo |

---

## Metriche Chiave dell'Esecuzione (pop=100, gen=100, 1fkb)

| Metrica | Valore | Interpretazione |
|---|---|---|
| Tempo totale | ~3.17s | Run stabile (±0.34%) |
| IPC | 1.989 | Vicino al massimo (2.0), pipeline ben utilizzata |
| Branch miss rate | 0.19% | Ottimo (soglia critica: >5%) |
| Frontend stall | 0.95% | Basso (soglia critica: >20%) |
| L1-D miss rate | 4.54% | Accettabile |
| LLC miss rate | 0.38% | Ottimo — working set entra in L3 |
| dTLB miss rate | 4.80% | Attenzione — accessi su molte pagine |
| Thread CPU time | ~94% su `prepare` | Funzione dominante nel profilo |

---

## Prossimi Passi Suggeriti

1. **Rieseguire** `profile_high_level.sh --skip-build` dopo aver ricompilato `libhigh_level.so` (P4)
2. **Verificare** che `cpu_metrics.json` e `memory_metrics.json` si aprano correttamente (P2)
3. **(Opzionale) Risolvere P5**: aggiungere guard in `perfetto_preload.cpp` per la modalità `--native`
4. **(Futuro)** Aumentare frequenza di campionamento in `base_converter.sh` (`-F 9999`) per catturare funzioni più brevi nel flame graph
