# `perf_to_perfetto.py` — Documentazione

> **Script:** `cpu/perf_to_perfetto.py`  
> **Autore:** progetto ACA — Profiling & Tracing HPC  
> **Ultimo aggiornamento:** 2026-06-12

---

##  QUICK START & PARAMETRI CLI

### Come lanciare lo script
Eseguire il comando dalla cartella radice del repository `profile-scripts_Nedina_Popovschii`:
```bash
python3 cpu/perf_to_perfetto.py [perf.data] [output.json]
```

### Dettaglio dei parametri CLI

Lo script accetta argomenti posizionali:

| Posizione | Argomento | Valore di Default | Descrizione e Scopo |
| :--- | :--- | :--- | :--- |
| `1` | `perf.data` | `perf.data` | Il file binario contenente i campioni hardware registrati con `perf record`. |
| `2` | `output.json` | `trace_perf.json` | Il file JSON in formato Chromium/Perfetto Trace Event che verrà generato come output. |

---

##  CAVEAT DI PROGETTO E SOLUZIONI (PRONTI PER LE SLIDE)

Sezione da inserire nella presentazione finale dell'esame di **Architettura dei Calcolatori Avanzata**:

*   **Slide 1: Limite di `perf script -F`**
    *   *Caveat*: La prima versione del parser invocava `perf script -F comm,pid,tid,time,sym` per estrarre direttamente i campi di interesse. Tuttavia, se la CPU si trova in regioni prive di simboli risolti o stub dinamici, la colonna `sym` restituiva valori vuoti, rendendo la traccia inutilizzabile.
    *   *Soluzione*: Abbandonato il flag `-F` a favore dell'output multiline dell'intero call-stack di `perf script`. Lo script parsa ricorsivamente lo stack DWARF dall'alto verso il basso per trovare il primo frame utente valido.
*   **Slide 2: Parsing dei Core CPU e delle Probe Dinamiche**
    *   *Caveat*: In sistemi multicore e in particolare con eventi `probe` dinamici, `perf script` include nell'header il core CPU di esecuzione (es. `[006]`) e non include il periodo di campionamento. Questo rompeva le espressioni regolari del parser standard di Perfetto.
    *   *Soluzione*: Riscrittura della regex di matching dell'header per supportare in modo flessibile sia l'ID del core CPU tra parentesi quadre sia il formato eventi probe o cycles (utilizzando gruppi non catturanti `(?:.*)`).

---
cd ~/UNI/progetto_aca/muDock
spack env activate mudock_zen5

/usr/lib/linux-tools/6.8.0-117-generic/perf record \
  -g --call-graph dwarf \
  -o perf.data \
  -- ./build/application/muDock \
       --protein data/1fkb/1fkb_protein.pdb \
       --ligand  data/1fkb/1fkb_ligand.mol2 \
       --use CPP:CPU:0 \
       --population 100 \
       --generations 100

# 2. Converti in JSON Perfetto
python3 script/perf_to_perfetto.py perf.data trace_perf.json

# 3. Apri su Perfetto e trascina il file
xdg-open https://ui.perfetto.dev/
```

### Output atteso a terminale

```
[1/4] Lettura di 'perf.data' tramite `perf script` ...
         182340 righe ricevute da perf script
[2/4] Parsing dei campioni ...
         Campioni totali: 22890
         Campioni con simboli: 21544
[3/4] Costruzione degli eventi Perfetto ...
[4/4] Scrittura di 'trace_perf.json' ...

──────────────────────────────────────────────────────────────
    Trace generata!
      File:     trace_perf.json  (4321 KB)
      Thread:   9
      Campioni: 22890  (con simboli: 21544)
      Durata:   12.34 s

    Apri su:  https://ui.perfetto.dev/
      Trascina: /home/olly/UNI/progetto_aca/muDock/trace_perf.json
──────────────────────────────────────────────────────────────
```

---

## 3. Come funziona

Lo script è diviso in 4 step chiaramente numerati nel codice.

### Step 1 — Esecuzione di `perf script`

```python
cmd = [PERF_BIN, "script", "-i", perf_data]
result = subprocess.run(cmd, capture_output=True, text=True, errors="replace")
```

`perf script` (senza flag `-F`) produce il **formato standard multi-linea**, che include sia l'header di ogni campione sia il call-stack completo. L'output grezzo viene suddiviso in righe (`splitlines()`).

---

### Step 2 — Parsing dei campioni

Il formato standard di `perf script` è strutturato in **blocchi separati da righe vuote**:

```
muDock 12345/12348  1.234567:   98257 cycles:P:
        7fff123abc genetic_algorithm+0x10 (/path/to/muDock)
        7fff456def worker::process+0x5   (/path/to/muDock)
        7fffa1b2c3 __libc_start_main+0x7 (/lib/libc.so)

muDock 12345/12349  1.234623:   97812 cycles:P:
        ...
```

Lo script usa **due espressioni regolari**:

| Regex | Scopo |
|---|---|
| `HEADER_RE` | Estrae `comm`, `pid/tid`, `timestamp` dalla riga di intestazione |
| `STACK_RE` | Estrae `addr`, `symbol`, `dso` da ogni riga di call-stack (preceduta da spazio/tab) |

```python
HEADER_RE = re.compile(
    r"^\s*(\S.*?)\s+(\d+)\s+([\d.]+):\s+\d+\s+\S+:\s*$"
)
STACK_RE = re.compile(
    r"^\s+([0-9a-fA-F]+)\s+(.+?)\s+\((.+?)\)\s*$"
)
```

Per ogni campione viene scelto il **simbolo rappresentativo** tramite `top_userspace_sym()`: il primo frame del call-stack che non appartiene al kernel (`[k...]`) né a DSO sconosciuti. L'offset `+0x...` viene rimosso per leggibilità.

I timestamp vengono normalizzati a `t₀ = 0` sottraendo il timestamp del primo campione.

---

### Step 3 — Costruzione degli eventi Perfetto

A partire dai campioni parsati vengono prodotti **tre tipi di eventi JSON**:

#### 3a. Metadati thread (`ph: "M"`)
Assegnano un nome leggibile a ogni TID nella UI:
```json
{"ph": "M", "name": "thread_name", "pid": 12345, "tid": 12348,
 "args": {"name": "muDock [TID 12348]"}}
```

#### 3b. Slice sintetici per thread (`ph: "X"`)
Ogni campione diventa uno slice che dura fino al campione successivo sullo stesso thread (o 1 ms come fallback per l'ultimo campione):
```python
dur = (s_list[i+1]["ts"] - s["ts"]) if i+1 < len(s_list) else 1_000
```
```json
{"ph": "X", "name": "genetic_algorithm", "cat": "perf_sample",
 "ts": 1234.567, "dur": 56.0, "pid": 12345, "tid": 12348}
```

#### 3c. Counter track parallelismo (`ph: "C"`)
Ogni 2 ms (`STEP_US = 2000`) viene emesso un valore contatore che conta quanti TID hanno avuto almeno un campione negli ultimi 10 ms (`WINDOW_US = 10000`):
```python
active = sum(
    1 for tid, s_list in by_tid.items()
    if any(abs(s["ts"] - t_us) < WINDOW_US for s in s_list)
)
```
```json
{"ph": "C", "name": "active_threads", "pid": 12345, "tid": 0,
 "ts": 6000.0, "args": {"count": 7}}
```

---

### Step 4 — Scrittura del JSON

Il documento finale viene serializzato con `json.dump(..., separators=(",", ":"))` (formato compatto, senza spazi) per ridurre la dimensione del file.

---

## 4. Formato output

### Struttura generale

```json
{
  "traceEvents": [ ... ],
  "displayTimeUnit": "us",
  "otherData": {
    "source":    "perf.data",
    "generator": "perf_to_perfetto.py",
    "threads":   9,
    "samples":   22890,
    "tip":       "Ricompila con RelWithDebInfo per simboli C++ risolti"
  }
}
```

### Riepilogo tipi di evento in `traceEvents`

| `ph` | Nome evento | Asse Y in Perfetto | Descrizione |
|---|---|---|---|
| `"M"` | `thread_name` | — | Metadato: assegna nome a PID/TID |
| `"X"` | `<symbol>` | Lane per TID | Slice sintetico: campione CPU campionato |
| `"C"` | `active_threads` | Counter track (TID 0) | Numero di thread attivi nel tempo |

### Coordinate temporali

Tutte le timestamp usano **microsecondi (µs)**, con `t₀ = 0` al primo campione. L'unità è dichiarata nel campo `displayTimeUnit: "us"`.

### Thread lanes vs Counter track

```
Perfetto UI
┌──────────────────────────────────────────────────────────┐
│  Thread Attivi (parallelismo)  [counter — TID 0]       │
│  8 ████████████████████████████████████████              │
│  4 ████████                                              │
│  0 ──────────────────────────────────────────────────    │
├──────────────────────────────────────────────────────────┤
│ muDock [TID 12348]  [slice lane]                         │
│  [genetic_alg..][worker::pro..][__libc..][genetic..]     │
│ muDock [TID 12349]  [slice lane]                         │
│  [worker::process][worker::process][worker::process]     │
│ ...                                                      │
└──────────────────────────────────────────────────────────┘
```

---

## 5. Problemi incontrati e soluzioni

### Problema 1 — Parser con `-F comm,pid,tid,time,sym` produceva simboli vuoti

**Descrizione:**  
Il primo approccio usava `perf script` con il flag `-F` per selezionare colonne specifiche:

```bash
perf script -F comm,pid,tid,time,sym -i perf.data
```

Questo produceva righe del tipo:

```
muDock 12345/12348 1.234567 genetic_algorithm
muDock 12345/12348 1.234623
muDock 12345/12349 1.234701
```

La colonna `sym` era **quasi sempre vuota** perché il campo `sym` nel formato `-F` risolve solo il simbolo del campione corrente (l'indirizzo del PC), non dell'intero call-stack. Quando il profilo era stato registrato senza `--call-graph dwarf`, il PC cadeva in codice JIT o in stub di libreria privi di simboli, rendendo `sym` inutilizzabile.

**Soluzione:**  
Abbandonare `-F` e usare il **formato standard multi-linea** di `perf script` (senza argomenti aggiuntivi), che include l'intero call-stack. Anche con un singolo frame risolto è possibile estrarre un simbolo significativo scorrendo lo stack dal top verso il bottom.

```python
#  Approccio fallito
cmd = [PERF_BIN, "script", "-F", "comm,pid,tid,time,sym", "-i", perf_data]

#  Approccio corretto
cmd = [PERF_BIN, "script", "-i", perf_data]
```

---

### Problema 2 — Il binario in Release non aveva simboli debug

**Descrizione:**  
Con la build standard (`-DCMAKE_BUILD_TYPE=Release`), il compilatore strippava tutti i simboli debug. `perf script` produceva call-stack con frame `[unknown]` o indirizzi esadecimali grezzi, rendendo la traccia Perfetto illeggibile (tutti gli slice comparivano come `[unknown]`).

**Soluzione:**  
Ricompilare muDock con **`RelWithDebInfo`**, che mantiene le ottimizzazioni del compilatore (`-O2`) ma aggiunge le informazioni DWARF (`-g`) necessarie per il demangling dei simboli:

```bash
$(spack location -i cmake@3.31.11)/bin/cmake .. \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \          # ← chiave
  -DCMAKE_CXX_COMPILER=g++-14 \
  ...
```

E registrare con `--call-graph dwarf` per garantire che il call-stack sia completo anche con frame pointer ottimizzati via inlining:

```bash
perf record -g --call-graph dwarf -o perf.data -- ./build/application/muDock ...
```

Lo script emette un avviso esplicito se non trova simboli utente:

```
[AVVISO] Nessun simbolo utente trovato.
         Il binario è stato compilato senza debug info (-g).
         Ricompila con -DCMAKE_BUILD_TYPE=RelWithDebInfo e
         registra con:  perf record -g --call-graph dwarf ...
```

---

### Problema 3 — Fallimento nel parsing degli eventi probe e con CPU core indicati in `perf script`

**Descrizione:**  
Durante il tracciamento di eventi probe dinamici, `perf script` produceva righe di intestazione del tipo:
```text
muDock  104334 [006] 135071.316429: probe_muDock:_ZN6mudock16autodock_protein7prepareEv: (5e6988380bc0)
```
La regex originale di matching dell'header era:
```python
HEADER_RE = re.compile(r"^\s*(\S.*?)\s+(\d+)\s+([\d.]+):\s+\d+\s+\S+:\s*$")
```
Questo causava due errori bloccanti:
1. La presenza del core CPU `[006]` racchiuso tra parentesi quadre impediva il matching della riga.
2. Il formato dell'evento probe (privo di un periodo intero e con parentesi tonde finali) non corrispondeva alla parte finale `\s+\d+\s+\S+:\s*$`.
Lo script quindi ignorava l'intero file, restituendo zero campioni parsati e crashando.

**Soluzione:**  
La regex è stata riscritta per essere estremamente flessibile e tollerante:
```python
HEADER_RE = re.compile(r"^\s*(\S.*?)\s+(\d+(?:/\d+)?)\s+(?:\[\d+\]\s+)?([\d.]+):\s+(?:.*)$")
```
La nuova regex gestisce:
- PID o PID/TID (es. `12345/12348` o `104334`).
- L'indicazione opzionale del core CPU (es. `[006]`).
- Qualsiasi formato finale dell'evento (utilizzando un gruppo non catturante `(?:.*)` in coda), garantendo la compatibilità sia per il campionamento standard `cycles` sia per gli eventi `probe` dinamici.

---

## 6. Possibili miglioramenti

| Priorità | Miglioramento | Dettaglio |
|---|---|---|
|  Alta | **Supporto OTF2** | Emettere il formato OTF2 (Open Trace Format 2) tramite la libreria `otf2` Python. OTF2 è lo standard de-facto in ambito HPC (usato da Score-P, Vampir) e supporta tracce di miliardi di eventi in modo compresso e scalabile. |
|  Alta | **Demangling C++ nativo** | Applicare `c++filt` (o la libreria `cxxfilt`) ai simboli raw per ottenere nomi leggibili (`worker::process(int)` invece di `_ZN6worker7processEi`). |
|  Media | **Filtro per DSO** | Aggiungere un argomento CLI `--dso muDock` per includere solo i frame appartenenti al binario principale, escludendo librerie di sistema e OpenMP runtime. |
|  Media | **Flame graph aggregato** | Generare un secondo file SVG con il flame graph aggregato (usando `flamegraph.pl` o la libreria Python `flameprof`) dalla stessa struttura di call-stack già parsata. |
|  Media | **Campionamento adattivo del counter** | Sostituire la finestra fissa di 10 ms con un approccio basato sugli intervalli reali tra campioni, eliminando i falsi positivi di thread "attivi" vicino ai bordi della finestra. |
|  Bassa | **Supporto `perf.data` remoto** | Aggiungere la possibilità di leggere un `perf.data` generato su un nodo HPC remoto (diversa architettura), invocando `perf script --input=perf.data --symfs=/path/to/remote/root`. |
|  Bassa | **Istogramma simboli** | Stampare a fine conversione una tabella `Top-N simboli per % di tempo campionato`, simile a `perf report --stdio`, per un quick summary senza aprire Perfetto. |

---

## Riferimenti

- [Perfetto Trace Format](https://perfetto.dev/docs/reference/trace-format) — documentazione del formato JSON `chrome://tracing`
- [linux perf wiki](https://perf.wiki.kernel.org/) — manuale di `perf record` e `perf script`
- [OTF2 library](https://www.vi-hps.org/projects/score-p/) — per un futuro upgrade del formato di output
