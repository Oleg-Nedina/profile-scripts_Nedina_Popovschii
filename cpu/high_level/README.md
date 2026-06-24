# `high_level/` — Tracciamento Thread Lifecycle via LD_PRELOAD

Due librerie intercettano `pthread_create` senza modificare il codice sorgente di muDock,  
generando una timeline del ciclo di vita dei thread visualizzabile su [ui.perfetto.dev](https://ui.perfetto.dev/).

---

## Script e file

| File | Descrizione |
|------|-------------|
| `profile_high_level.sh` | Script di automazione completo (compila, esegue, converte) |
| `high_level_so.cpp` | Libreria `libhigh_level.so` — traccia JSON leggera |
| `perfetto_preload.cpp` | Libreria `libperfetto_preload.so` — traccia nativa SDK Perfetto (`.pftrace`) |
| `high_level_to_otf2.py` | Convertitore JSON → OTF2 (per Vampir/Score-P) |
| `Makefile` | Compila entrambe le `.so` |

---

## run

### `libhigh_level.so` (JSON)

```bash
# 1. Compila
cd ./profile-scripts_Nedina_Popovschii/cpu/high_level
make libhigh_level.so

# 2.  muDock con la libreria precaricata
cd ~/UNI/progetto_aca/muDock
LD_PRELOAD=../profile-scripts_Nedina_Popovschii/cpu/high_level/libhigh_level.so \
MUDOCK_TRACE_HL_OUT=traces/trace_high_level.json \
./build/application/muDock \
    --protein data/1fkb/1fkb_protein.pdb \
    --ligand  data/1fkb/1fkb_ligand.mol2 \
    --use CPP:CPU:0 \
    --population 100 \
    --generations 100

# 3.  traccia su Perfetto
# → https://ui.perfetto.dev/  , carica traces/trace_high_level.json
```

### `libperfetto_preload.so` (SDK)

```bash
# 1. Compila la libreria
cd ./profile-scripts_Nedina_Popovschii/cpu/high_level
make libperfetto_preload.so

# 2. Esegui con il buffer configurabile
cd ~/UNI/progetto_aca/muDock
LD_PRELOAD=../profile-scripts_Nedina_Popovschii/cpu/high_level/libperfetto_preload.so \
MUDOCK_TRACE_PERFETTO_OUT=traces/muDock.pftrace \
MUDOCK_PERFETTO_BUF_MB=128 \
./build/application/muDock \
    --protein data/1fkb/1fkb_protein.pdb \
    --ligand  data/1fkb/1fkb_ligand.mol2 \
    --use CPP:CPU:0 \
    --population 100 \
    --generations 100

# 3. Apri la traccia su Perfetto
# → Vai su https://ui.perfetto.dev/ e carica traces/muDock.pftrace
```

### `profile_high_level.sh` (SCRIPT)

```bash
# Dalla root di profile-scripts:

# libhigh_level.so (JSON)
./cpu/high_level/profile_high_level.sh --population 100 --generations 100

# libperfetto_preload.so (SDK nativo) (NON VA é DA SISTEMARE)
./cpu/high_level/profile_high_level.sh --native --population 100 --generations 100
```

---

## Parametri di `profile_high_level.sh`

| Parametro | Default | Descrizione |
|-----------|---------|-------------|
| `--native` | off | Usa `libperfetto_preload.so` (SDK Perfetto nativo) invece di `libhigh_level.so` |
| `--skip-build` | off | Salta la compilazione delle `.so` (usa quelle già compilate) |
| `--population N` | `100` | Dimensione della popolazione per il GA di muDock |
| `--generations N` | `100` | Numero di generazioni per il GA di muDock |
| `--out-dir DIR` | `traces/` | Directory di output per la traccia generata |
| `--no-otf2` | off | Disabilita la conversione OTF2 (solo per traccia JSON) |
| `--no-browser` | off | Non aprire il browser automaticamente dopo l'esecuzione |
| `--port PORT` | `9002` | Porta del server HTTP locale per il caricamento automatico in Perfetto |

---

## Variabili d'ambiente per `libhigh_level.so`

| Variabile | Default | Descrizione |
|-----------|---------|-------------|
| `LD_PRELOAD` | — | Percorso assoluto/relativo di `libhigh_level.so` |
| `MUDOCK_TRACE_HL_OUT` | `trace_high_level.json` | Percorso del file JSON di output |

## Variabili d'ambiente per `libperfetto_preload.so`

| Variabile | Default | Descrizione |
|-----------|---------|-------------|
| `LD_PRELOAD` | — | Percorso assoluto/relativo di `libperfetto_preload.so` |
| `MUDOCK_TRACE_PERFETTO_OUT` | `traces/muDock.pftrace` | Percorso del file `.pftrace` di output |
| `MUDOCK_PERFETTO_BUF_MB` | `64` | Dimensione del buffer di tracciamento in MB (max 1024) |

---

## traccia Perfetto

| Elemento | Tipo Perfetto | Descrizione |
|----------|--------------|-------------|
| **Slice per thread** | `ph: "X"` | Durata vita thread dalla schedulazione alla terminazione |
| **thread_spawn** | `ph: "i"` | Evento istantaneo sul thread creante al momento di `pthread_create` |
| **Nome thread** | `ph: "M"` | Label `Worker-N [TID XXXX]` assegnata a ogni lane nella timeline |
| **parallel_threads** | `ph: "C"` | Counter che mostra quanti thread sono attivi in parallelo ogni 500µs

---

## CAVEAT DI PROGETTO E SOLUZIONI (PRONTI PER LE SLIDE)

* **Perché LD_PRELOAD non catturava i thread OpenMP (v1)**
  * *Caveat*: I thread del pool OpenMP rimangono bloccati all'interno della barriera interna di OpenMP e non ritornano mai dalla loro `start_routine` originaria. La prima versione (v1) registrava il timestamp solo al ritorno della routine, lasciando i thread worker invisibili nella traccia.
  * *Soluzione*: Registrazione in due fasi distinte. Fase 1: intercettazione immediata all'avvio della funzione trampolino. Fase 2: forzatura manuale della chiusura del timestamp al momento del `flush` (destructor statico della libreria), mappando accuratamente l'attività dei thread.
* **Segfault e Ordine di Distruzione Statico in C++**
  * *Caveat*: In C++, gli oggetti statici globali vengono distrutti in ordine inverso di costruzione (LIFO) all'uscita dal processo. Se il manager del tracciamento è un oggetto statico, rischia di essere distrutto *prima* della terminazione dei worker thread, causando use-after-free e segfault improvvisi.
  * *Soluzione*: Allocazione forzata del singleton di registro sull'heap (`new GlobalRegistry`) anziché come oggetto statico. In questo modo sopravvive intatto all'intera fase di teardown dell'applicazione (intentional heap leak, pulito automaticamente dal kernel al termine del processo).

---

---

## Architettura interna

### Pattern ThreadWrapper (funzione trampolino)

Il meccanismo centrale è l'inserimento di una **funzione intermedia** (`hl_thread_entry`) tra `pthread_create` e la `start_routine` originale dell'applicazione.

```
Applicazione (muDock)
        │
         chiama pthread_create(…, real_fn, real_arg)
┌───────────────────┐
│  hook pthread_create  │  ← questo hook sostituisce la funzione di libreria
│  1. registra ts_created, creator_tid           │
│  2. alloca ThreadWrapper{real_fn, real_arg}    │
│  3. chiama real_pthread_create(…, hl_thread_entry, wrapper) │
│  4. chiama g_reg->create(handle, …)            │
└───────────────────┘
        │
         il kernel schedula il nuovo thread
┌───────────────────┐
│   hl_thread_entry(wrapper)   │  ← funzione trampolino
│  1. estrae real_fn, real_arg, handle dalla struct │
│  2. chiama g_reg->thread_started(…)            │
│  3. chiama real_fn(real_arg)  ← codice originale │
│  4. chiama g_reg->thread_ended(…)              │
└───────────────────┘
```

**Perché serve il trampolino?**  
`pthread_create` accetta solo una `start_routine` e un singolo `void* arg`. Non esiste un modo standard per passare metadati aggiuntivi (come il `pthread_t handle`) al nuovo thread senza wrappare la chiamata. La struct `ThreadWrapper` trasporta il puntatore alla funzione originale, l'argomento originale e l'handle del thread in un unico `void*`.

### GlobalRegistry — heap singleton

```cpp
// In high_level_so.cpp
static GlobalRegistry* g_reg = nullptr;

__attribute__((constructor))
static void hl_init() {
    g_reg = new GlobalRegistry();   // allocato sull'heap
}
```

Il registro è un **puntatore a heap**, non un oggetto statico di durata globale. Questo è intenzionale:

> **Problema dell'ordine di distruzione degli oggetti C++:**  
> Quando un processo termina, il runtime C++ distrugge gli oggetti statici in ordine LIFO (inverso rispetto alla costruzione). Se `GlobalRegistry` fosse uno `static` globale, la sua distruzione potrebbe avvenire **prima** dei destructor di altri oggetti statici del programma principale (es. pool OpenMP, stream di file). Questo causerebbe use-after-free o deadlock.  
> Allocando sull'heap e usando un puntatore, l'oggetto sopravvive finché il destructor `hl_fini` (marcato `__attribute__((destructor))`) non chiama esplicitamente `flush()`. Il puntatore stesso non viene mai `delete`-ato: la memoria viene rilasciata dal kernel al termine del processo.

### Registrazione in 2 fasi

La raccolta dei dati è divisa in **3 operazioni** (conceptualmente 2 fasi), ciascuna protetta da mutex:

| Fase | Dove | Cosa viene registrato |
|------|------|-----------------------|
| **`create()`** | Nel thread **chiamante**, dentro l'hook `pthread_create` | `ts_created`, `creator_tid`, indice progressivo |
| **`thread_started()`** | Nel **nuovo thread**, all'avvio di `hl_thread_entry` | `tid` (kernel TID reale), `ts_start` |
| **`thread_ended()`** | Nel **nuovo thread**, al ritorno di `real_fn` | `ts_end` |

Questa separazione è necessaria perché il **kernel TID** (`gettid()`) è disponibile solo dall'interno del thread stesso, non da chi lo ha creato. Il `pthread_t` handle (userspace) è invece disponibile subito dopo `pthread_create` nel thread chiamante.

```
Thread chiamante:   create() ──────────────────────────────────────────────
                                   ↓ nuovo thread schedulato
Nuovo thread:                  thread_started() ──── real_fn() ──── thread_ended()
```

### Thread ancora vivi al flush (pool OpenMP)

I thread del pool OpenMP vengono creati una volta sola e **non terminano mai** durante l'esecuzione normale: rimangono bloccati su una barrier in attesa di nuove task, e vengono terminati dal SO solo al termine del processo.

Al momento del flush (`hl_fini`), il registro contiene questi thread nella mappa `records` (in-flight). La libreria li gestisce così:

```cpp
// In GlobalRegistry::flush()
int64_t now = now_us();
for (auto& [handle, rec] : records) {
    if (rec.ts_start > 0) {   // solo se sono effettivamente partiti
        rec.ts_end = now;     // forza la chiusura con il timestamp corrente
        completed.push_back(rec);
    }
}
```

Nella trace Perfetto questi thread appariranno come **slice che terminano all'ultimo timestamp** dell'esecuzione, il che è la rappresentazione più accurata possibile: erano effettivamente attivi (o in attesa) per tutta la durata del programma.

---

## Formato output — JSON Perfetto

Il file JSON segue il formato **Trace Event Format** di Chromium/Perfetto (`displayTimeUnit: "us"`). Tutti i timestamp sono relativi al `ts_created` minimo osservato (`t0`), quindi la traccia inizia sempre a `t=0`.

### Struttura generale

```json
{
  "traceEvents": [
    // ... array di eventi ...
  ],
  "displayTimeUnit": "us"
}
```

### Tipi di evento generati

#### Slice di lifecycle (`ph: "X"`)

Un evento per ogni thread, rappresenta la durata dalla schedulazione al termine.

```json
{
  "ph":   "X",
  "name": "Thread 3",
  "cat":  "thread_lifecycle",
  "ts":   12450,
  "dur":  984321,
  "pid":  <PID processo>,
  "tid":  <kernel TID del thread>,
  "args": {
    "index":         3,
    "creator_tid":   <TID di chi ha chiamato pthread_create>,
    "spawn_delay_us": 42
  }
}
```

| Campo | Significato |
|-------|-------------|
| `ts` | Inizio della slice (µs da t0) = `ts_start - t0` |
| `dur` | Durata della slice (µs) = `ts_end - ts_start` |
| `spawn_delay_us` | Latenza di schedulazione = `ts_start - ts_created` |

#### Evento istantaneo di spawn (`ph: "i"`)

Appare sul **thread creante** al momento della chiamata a `pthread_create`. Permette di vedere visivamente chi ha generato quale thread.

```json
{
  "ph":  "i",
  "name": "thread_spawn",
  "cat":  "thread_lifecycle",
  "ts":   12408,
  "pid":  <PID>,
  "tid":  <TID del creante>,
  "s":    "t"
}
```

#### Metadata nomi thread (`ph: "M"`)

Assegna un nome leggibile a ogni TID nella UI di Perfetto.

```json
{
  "ph":   "M",
  "name": "thread_name",
  "pid":  <PID>,
  "tid":  <kernel TID>,
  "args": { "name": "Thread 3 [TID 12345]" }
}
```

#### Counter di parallelismo (`ph: "C"`)

Campiona ogni **500 µs** il numero di thread attivi in parallelo, generando un grafico a linea in Perfetto.

```json
{
  "ph":   "C",
  "name": "parallel_threads",
  "pid":  <PID>,
  "tid":  0,
  "ts":   <t campionamento>,
  "args": { "count": 5 }
}
```

---

## Caveat e limiti

> [!WARNING]
> **LD_PRELOAD intercetta solo librerie dinamiche.**  
> Il meccanismo `LD_PRELOAD` funziona sostituendo i simboli nel linker dinamico. Se `pthread_create` è **linkata staticamente** nel binario (cosa rara ma possibile con `-static`), l'hook **non ha effetto** e i thread non vengono catturati.

> [!WARNING]
> **I thread del pool OpenMP non terminano naturalmente.**  
> I worker thread di OpenMP vengono creati all'inizio e rimangono bloccati su barrier per tutta la vita del programma. La loro `ts_end` viene impostata artificialmente al momento del flush. Le slice nella traccia avranno quindi una durata pari all'intera esecuzione del programma, non alla durata delle singole task parallele.

> [!NOTE]
> **Thread creati prima del caricamento della `.so`.**  
> Il linker dinamico carica `libhigh_level.so` e chiama `hl_init()` come parte dell'inizializzazione del processo, **prima del `main()`**. Tuttavia, thread eventualmente creati dal runtime del linker stesso o da librerie con costruttori statici precedenti **non vengono catturati**, perché il registry non è ancora inizializzato.

> [!NOTE]
> **Overhead del mutex.**  
> Le chiamate `thread_started()` e `thread_ended()` acquisiscono un mutex. Poiché la creazione/terminazione dei thread è un evento **raro** rispetto al lavoro computazionale, questo overhead è assolutamente trascurabile sull'esecuzione totale. L'unico potenziale collo di bottiglia è il momento del flush, che avviene una sola volta al termine.

---

## Problemi incontrati e soluzioni

### Prima versione: catturava solo 1 thread

**Problema:** La versione v1 della libreria registrava `ts_start` e `ts_end` **solo quando la `start_routine` ritornava**. Il thread worker principale di muDock ritorna normalmente, quindi veniva catturato. I **thread del pool OpenMP non ritornano mai** (sono bloccati sulla barrier interna di OpenMP): nessuno di loro veniva mai aggiunto ai `completed`, e la trace mostrava un solo thread.

**Soluzione (v2):** La registrazione è stata spostata all'**inizio di `hl_thread_entry`** (registrazione immediata), separando `thread_started()` da `thread_ended()`. I thread che non terminano vengono chiusi forzatamente nel metodo `flush()` con il timestamp del momento del flush, che rappresenta fedelmente la realtà: erano ancora vivi fino all'ultimo istante.

```diff
- // v1: si aspettava il ritorno della start_routine
- void* result = real_fn(real_arg);
- g_reg->record_thread(handle, tid, ts_start, now_us());

+ // v2: registrazione immediata all'avvio
+ g_reg->thread_started(handle, my_tid, ts_start);
+ void* result = real_fn(real_arg);
+ g_reg->thread_ended(handle, now_us());  // non raggiunto da OpenMP pool
```

### Segfault alla prima sessione (build incrementale)

**Problema:** Durante la prima integrazione, l'esecuzione terminava con un **segfault** non riproducibile su clean build. La causa era che `trace.hpp` (un precedente sistema di tracing) era ancora compilata **staticamente** dentro il binario di muDock dalla build incrementale. I costruttori/destructor statici di entrambi i sistemi di tracing si eseguivano in ordine non deterministico, causando use-after-free.

**Soluzione:** È **obbligatorio** eseguire una **clean build** del progetto principale dopo qualsiasi modifica agli header che definiscono oggetti statici globali:

```bash
cd ~/UNI/progetto_aca/muDock
rm -rf build && mkdir build && cd build
# ... seguito dalla procedura di configurazione CMake standard
make -j 8
```

> [!CAUTION]
> Non usare mai build incrementali (`make` senza `rm -rf build`) quando si modificano header che contengono oggetti statici o singleton. Il problema può essere silente (nessun warning) e manifestarsi solo in race condition rare.

---

## Possibili miglioramenti futuri

| Miglioramento | Descrizione | Impatto |
|---------------|-------------|---------|
| **Hook `pthread_setname_np`** | Intercettare anche la funzione di impostazione del nome thread per catturare automaticamente i nomi dei thread OpenMP (es. `"omp_thread_3"`) e usarli nei metadata Perfetto invece di `"Thread N"`. | Alto: migliora leggibilità della trace |
| **Hook `pthread_join`** | Registrare le chiamate a `pthread_join` per tracciare le **dipendenze tra thread** (chi aspetta chi) ed emetterle come frecce di flusso (`ph: "f"`) in Perfetto. | Medio: aggiunge informazioni di sincronizzazione |
| **`thread_local` per ridurre la contesa** | Usare un buffer `thread_local` per accumulare gli eventi localmente e flusharli sul registro globale solo al termine del thread. Utile se il numero di thread creati fosse nell'ordine dei migliaia. | Basso (per muDock, alto per workload con molti thread brevi) |
| **Output in formato OTF2** | Sostituire o affiancare il JSON Perfetto con il formato **OTF2** (Open Trace Format 2), leggibile da strumenti HPC come **Vampir** e **Score-P**. OTF2 è più compatto e scalabile per trace con milioni di eventi. | Alto per analisi HPC avanzata |
| **Cattura `spawn_delay` per task OpenMP** | Hookkare anche le primitive OpenMP interne (es. tramite `OMPT` — OpenMP Tools Interface) per distinguere i task all'interno del pool invece di vedere il pool come un unico thread monolitico. | Alto: fornisce granularità sul parallelismo reale delle task |

---

*Documentazione generata per il Progetto ACA — Profiling e Tracing HPC*  
*Ultima modifica: 2026-06-12*
