
> **Da eseguire:** dopo `base_converter.sh` (che genera il `perf.data` di base)  
> **Richiede:** `sudo` per inserire probe nel kernel tracefs

---

## Come eseguire

```bash
# Dalla root di profile-scripts:

# Esecuzione 
./cpu/low_level/low_level_probe.sh 

```

---

## Parametri di `low_level_probe.sh`

| Parametro | Default | Descrizione |
|-----------|---------|-------------|
| `--top N` | `3` | Numero di funzioni calde nel namespace `mudock::` da scoprire e tracciare |
| `--perf-data FILE` | `traces/perf.data` | File `perf.data` di input (generato da `base_converter.sh`) |
| `--output FILE` | `traces/trace_low_level.json` | Traccia Perfetto di output |
| `--population N` | `100` | Dimensione popolazione GA di muDock |
| `--generations N` | `100` | Numero di generazioni GA di muDock |
| `--retprobe` | **on** | Abilita le return probe: misura la **durata reale** di ogni chiamata (slice con `ts`+`dur`) |
| `--no-retprobe` | — | Disabilita le return probe, usa solo entry probe (eventi istantanei) |
| `--c2c` | off | Esegui anche analisi **False Sharing** con `perf c2c record/report` |
| `--c2c-out FILE` | `traces/c2c_report.txt` | File di output del report False Sharing |

> **Nota su `--retprobe` (default: on):** per ogni funzione target viene aggiunta sia una **entry probe** (ingresso funzione) sia una **return probe** (`%return`). Il converter `probe_to_perfetto.py` abbina le coppie per ogni thread e genera slice Perfetto con durata reale in µs. Se la return probe non è supportata (funzioni inline/template), lo script fa fallback graceful alla sola entry probe senza interrompere il run.

> **Nota su `--c2c`:** esegue un secondo run del binario con `perf c2c record`. Alcuni hardware non supportano gli eventi necessari (`mem_trans_retired`). Se il comando fallisce, lo script lo segnala con un avviso ma non crasha.

---

##  File nella cartella

| File | Descrizione |
|------|-------------|
| `low_level_probe.sh` | Script principale (hardware fisico) |
| `low_level_probe_generic.sh` | Versione con fallback per VM/Docker |
| `README.md` | Questo file |

---

## Funzionamento — Step by Step

### Step 1 — Discovery automatica delle Top-N funzioni

Esegue `perf report --stdio` sul `perf.data` di input e parsa l'output:

Vengono incluse solo le funzioni nel namespace `mudock::`, escluse quelle contenenti `clone`, `start_thread`, `__libc`.

### Step 2 — Aggiunta uprobes (entry) + retprobe (return)

Per ogni funzione trovata:

```bash
# Entry probe (ingresso funzione)
sudo perf probe --exec ./build/application/muDock --add "_Zmangled_name"

# Return probe (uscita funzione) — solo con --retprobe
sudo perf probe --exec ./build/application/muDock --add "_Zmangled_name%return"
```

Lo script trova il nome mangled tramite `nm + c++filt`. Se la return probe fallisce (funzione inline/template), continua con la sola entry.

### Step 3 — Esecuzione muDock con probe attive

```bash
sudo perf record -g \
  -e probe_muDock:funzione1 \
  -e probe_muDock:funzione1__return \
  -e probe_muDock:funzione2 \
  -o traces/perf_low_level.data \
  -- ./build/application/muDock ...
```

`perf record` viene eseguito con `sudo` perché il tracefs richiede permessi root. Subito dopo, `sudo chown` ripristina la proprietà del file all'utente corrente.

### Step 4 — Conversione in Perfetto JSON

Se le retprobe sono attive → usa **`probe_to_perfetto.py`** (slice con durata reale):  
Se solo entry probe → usa **`perf_to_perfetto.py`** (slice campionate).

```bash
# Automatico — scelto dallo script in base alle probe disponibili
python3 cpu/perfetto_converters/probe_to_perfetto.py \
    traces/perf_low_level.data \
    traces/trace_low_level.json
```

### Step 5 (opzionale) — Analisi False Sharing con `perf c2c`

```bash
sudo perf c2c record -o traces/perf_c2c.data -- ./build/application/muDock ...
perf c2c report -i traces/perf_c2c.data --stdio > traces/c2c_report.txt
```

Il report mostra le cache line più contese tra thread (colonne `Lcl Hitm` = false sharing locale, `Rmt Hitm` = false sharing cross-socket).

---

## in Perfetto

### Con `--retprobe` (default)

| Elemento | Tipo Perfetto | Descrizione |
|----------|--------------|-------------|
| **Slice per funzione** | `ph: "X"` | Durata **reale** di ogni singola invocazione: da ingresso (`entry probe`) a uscita (`retprobe`) |
| **Funzioni attive** | `ph: "C"` | Counter: quante funzioni sono in esecuzione contemporaneamente |

In `otherData` della traccia sono presenti anche le **statistiche per funzione**: `calls`, `mean_us`, `min_us`, `max_us`.

### Con `--no-retprobe`

| Elemento | Tipo Perfetto | Descrizione |
|----------|--------------|-------------|
| **Evento istantaneo** | `ph: "i"` | Un punto per ogni chiamata alla funzione; nessuna informazione sulla durata |
| **Slice campionate** | `ph: "X"` | Durata stimata (fino al campione successivo sullo stesso thread) |

---

## File di output generati

| File | Descrizione |
|------|-------------|
| `traces/perf_low_level.data` | Raw data perf con eventi probe+retprobe |
| `traces/trace_low_level.json` | **Traccia Perfetto** con slice a durata reale |
| `traces/perf_c2c.data` | Raw data perf c2c (solo con `--c2c`) |
| `traces/c2c_report.txt` | Report False Sharing testuale (solo con `--c2c`) |

---

## Caveat e prerequisiti

### Permessi

`perf probe` e `perf record` (con probe attive) richiedono `sudo`.

```bash
# Sblocca contatori hardware (una volta per sessione)
sudo sysctl -w kernel.perf_event_paranoid=-1
```

### Simboli C++ e build type

Usare sempre la build **`RelWithDebInfo`** (`-O2 -g`):

- Con `-O3`/`Release` le funzioni brevi vengono inlinate e spariscono dal binario → probe impossibili.
- Con `RelWithDebInfo` i simboli sono preservati e `nm + c++filt` funziona correttamente.

```bash
# Compilare muDock con simboli:
cmake -DCMAKE_BUILD_TYPE=RelWithDebInfo .. && make -j8
```

### Probe orfane

Se lo script viene interrotto prima della pulizia finale:

```bash
# Elenca probe attive:
perf probe --list
# Rimuovi tutte:
sudo perf probe --del 'probe_muDock:*'
```

> [!WARNING]
> Probe orfane su un binario ricompilato puntano ad indirizzi non più validi e possono causare comportamenti imprevedibili.

### Funzioni template/inline

Le funzioni template C++ (molto comuni in codice HPC) producono simboli deboli (`W`) o cloni inline che `perf probe` non riesce ad agganciare. Lo script salta questi simboli e procede con quelli validi, stampando un avviso.

---

##  Perché `perf probe` e non `LD_PRELOAD`

`LD_PRELOAD` funziona solo per simboli nella PLT (funzioni di librerie dinamiche `.so`). Le funzioni `mudock::` sono **compilate staticamente** nell'eseguibile e non passano dalla PLT → non intercettabili con LD_PRELOAD.

`perf probe` inserisce un breakpoint software (`INT3`) direttamente nell'indirizzo della funzione nel processo in esecuzione, funzionando su qualsiasi simbolo indipendentemente dal tipo di linking.

| Tecnica | Funzioni `.so` | Funzioni statiche |
|---------|---------------|-------------------|
| `LD_PRELOAD` |  |  |
| `perf probe` |  |  |

---

*Documentazione progetto ACA — Profiling e Tracing HPC*
