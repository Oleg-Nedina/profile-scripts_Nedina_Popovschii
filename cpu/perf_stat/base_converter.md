# `base_converter.sh` — Documentazione

> **Script:** `cpu/base_converter.sh`  
> **Dipendenze:** `cpu/perf_to_perfetto.py`, `spack`, `perf`, `python3` (rilevate in automatico nella stessa cartella)

---

##  QUICK START & PARAMETRI CLI

### Come lanciare lo script
Eseguire il comando dalla cartella radice del repository `profile-scripts_Nedina_Popovschii`:
```bash
spack env activate mudock_zen5
./cpu/base_converter.sh [opzioni]
```

### Dettaglio dei parametri CLI

| Parametro | Valore di Default | Descrizione e Scopo |
| :--- | :--- | :--- |
| `--clean` | *Disattivato* | Cancella interamente la cartella di build (`rm -rf build`) prima di avviare CMake. **Fondamentale quando si modificano file `.hpp`** per evitare che la compilazione incrementale mantenga simboli obsoleti. |
| `--skip-build` | *Disattivato* | Salta completamente la fase di compilazione CMake/make e riutilizza direttamente il binario preesistente in `build/application/muDock`. Riduce i tempi di attesa se si vuole solo misurare modifiche runtime. |
| `--convert-only` | *Disattivato* | Salta sia la build che l'esecuzione di `perf record`. Esegue unicamente la conversione del file `perf.data` esistente in formato JSON. Utile per ri-generare la traccia variando i parametri del parser. |
| `--no-browser` | *Disattivato* | Registra il profilo e converte la traccia ma evita di avviare il server HTTP locale e di lanciare il browser. Ottimizzato per run non-interattive o ambienti headless (es. nodi di calcolo remoti). |
| `--population N` | `100` | Specifica la dimensione della popolazione per l'Algoritmo Genetico di muDock. Influenza il consumo di memoria e la parallelizzazione OpenMP. |
| `--generations N` | `100` | Specifica il numero di generazioni dell'Algoritmo Genetico. Prolunga o accorcia linearmente la durata del run di profiling. |
| `--protein PATH` | `data/1fkb/1fkb_protein.pdb` | Specifica il percorso del file PDB della proteina target. |
| `--ligand PATH` | `data/1fkb/1fkb_ligand.mol2` | Specifica il percorso del file MOL2 del ligando. |
| `--port N` | `9001` | Configura la porta TCP del mini web server locale (`http.server` in Python) utilizzato per servire la traccia. |
| `-h`, `--help` | — | Mostra la guida all'uso rapido ed esce. |

---

##  CAVEAT DI PROGETTO E SOLUZIONI (PRONTI PER LE SLIDE)

Sezione da inserire nella presentazione finale dell'esame di **Architettura dei Calcolatori Avanzata**:

*   **Slide 1: Perché NON usare Score-P su OpenMP a Grana Fine**
    *   *Caveat*: Score-P applica strumentazione software invasiva (OPARI2) che inserisce hook ad ogni ingresso/uscita di regione parallela. Con cicli OpenMP nidificati molto caldi, l'overhead speso in timer e bookkeeping supera il 95%, bloccando l'applicazione.
    *   *Soluzione*: Svolta verso un **profiling hardware non-invasivo (sampling)** tramite contatori hardware nativi (`perf record` su Zen 5), che riduce l'overhead a meno dell'1%.
*   **Slide 2: Il compromesso RelWithDebInfo**
    *   *Caveat*: La build `Release` ottimizza al massimo (`-O3`) ma elimina tutti i simboli debug (le funzioni nella trace compaiono come `[unknown]`). La build `Debug` mantiene i simboli ma disabilita le ottimizzazioni, falsando i colli di bottiglia reali.
    *   *Soluzione*: Compilazione in **`RelWithDebInfo`** (`-O2 -g` o `-O3 -g`). Mantiene intatte le performance reali ed inserisce le informazioni debug DWARF per risolvere i simboli C++ demangled.
*   **Slide 3: OS Kernel Paranoid Guard**
    *   *Caveat*: I sistemi Ubuntu moderni bloccano l'accesso ai Performance Monitoring Counters (PMC) agli utenti non-root (`perf_event_paranoid` impostato a `4`).
    *   *Soluzione*: Sblocco dinamico del kernel a runtime via `sysctl -w kernel.perf_event_paranoid=-1` (integrato in modo trasparente nello script).
*   **Slide 4: Mixed Content Security Policy nei Browser**
    *   *Caveat*: Perfetto UI è servito via HTTPS (`https://ui.perfetto.dev`), mentre la traccia locale viene servita da `http://localhost`. I browser moderni bloccano il mixed content per motivi di sicurezza.
    *   *Soluzione*: Servire la traccia tramite un server HTTP Python dedicato e abilitare l'eccezione localhost (`chrome://flags/#unsafely-treat-insecure-origin-as-secure`) o usare browser più permissivi (Firefox).

---

## 1. Scopo

`base_converter.sh` è la pipeline principale di profilazione hardware di muDock. Con un solo comando esegue in sequenza tre operazioni:

1. **Build** del binario muDock in modalità `RelWithDebInfo` (ottimizzazioni attive + simboli debug)
2. **Registrazione hardware** tramite `perf record` con risoluzione completa dello stack (`--call-graph dwarf`)
3. **Conversione e visualizzazione**: converte il file `perf.data` grezzo in una traccia JSON compatibile con [Perfetto UI](https://ui.perfetto.dev), avvia un server HTTP locale e apre automaticamente il browser

L'obiettivo è ridurre il ciclo *modifica → misura → analisi* a un unico invocation senza dover ricordare flag di compilazione, percorsi spack o URL di Perfetto.

Lo script rileva automaticamente se la directory del codice sorgente di `muDock` si trova a fianco della cartella del repository `profile-scripts_Nedina_Popovschii` (in `../../muDock`), consentendo di avviare il profiling senza inquinare il sorgente dell'applicazione.

---

## 2. Come si usa

```bash
# Dalla root del repository profile-scripts_Nedina_Popovschii:
./cpu/base_converter.sh [opzioni]
```

### Opzioni disponibili

| Opzione | Default | Descrizione |
|---|---|---|
| `--clean` | off | Forza una build pulita (`rm -rf build`) prima di compilare |
| `--skip-build` | off | Salta la compilazione; usa il binario già presente in `build/application/muDock` |
| `--convert-only` | off | Salta build **e** esecuzione perf; converte il `perf.data` già esistente |
| `--no-browser` | off | Non avvia il server HTTP né apre il browser |
| `--population N` | `100` | Numero di popolazioni passato a muDock |
| `--generations N` | `100` | Numero di generazioni passato a muDock |
| `--protein PATH` | `data/1fkb/1fkb_protein.pdb` | Path al file proteina `.pdb` |
| `--ligand PATH` | `data/1fkb/1fkb_ligand.mol2` | Path al file ligando `.mol2` |
| `--port N` | `9001` | Porta del server HTTP locale |
| `-h`, `--help` | — | Mostra l'intestazione di aiuto dello script |

### Esempi pratici

```bash
# Pipeline completa con parametri di default
./cpu/base_converter.sh

# Build pulita con run più lunga (500 generazioni)
./cpu/base_converter.sh --clean --generations 500

# Solo ri-conversione dell'ultima traccia senza rieseguire muDock
./cpu/base_converter.sh --convert-only

# Profilazione senza aprire il browser (utile su server headless)
./cpu/base_converter.sh --no-browser

# Usa il binario già compilato, ri-esegue solo perf + conversione
./cpu/base_converter.sh --skip-build --population 50

# Proteina diversa da 1fkb, porta HTTP personalizzata
./cpu/base_converter.sh \
  --protein data/altra/proteina.pdb \
  --ligand  data/altra/ligando.mol2 \
  --port 9090
```

### File di output

| File | Descrizione |
|---|---|
| `perf.data` | Dati raw del campionamento hardware prodotti da `perf record` |
| `trace_perf.json` | Traccia in formato Perfetto JSON, pronta per la visualizzazione |

---

## 3. Come funziona internamente

Lo script è strutturato in **tre step** espliciti, con messaggi colorati e numerati a schermo.

### Step 1 — Build (`RelWithDebInfo`)

```
SKIP_BUILD=0 → attiva spack env → cmake + make -j8
```

- Attiva l'ambiente Spack `mudock_zen5` con `eval "$(spack env activate --sh ...)"`.
- Se `--clean` è attivo, cancella l'intera cartella `build/` prima di procedere.
- Inietta degli stub CMake anti-CUDA (`fake_cmake/FindCUDAToolkit.cmake`) per evitare che CMake cerchi il toolkit CUDA assente.
- Esegue `cmake` puntando a GCC 14, OpenMP, Google Highway (`native` target) e Boost/OpenBabel da Spack.
- Compila con `make -j8`; l'output è filtrato per mostrare solo errori e avanzamento `[N%]`.

### Step 2 — `perf record`

```
CONVERT_ONLY=0 → controllo paranoia → perf record -g --call-graph dwarf
```

- Legge `/proc/sys/kernel/perf_event_paranoid`; se il valore è > 0 esegue `sudo sysctl -w kernel.perf_event_paranoid=-1` per sbloccare temporaneamente i contatori hardware.
- Lancia muDock attraverso `perf record` con i flag `-g --call-graph dwarf` e salva il risultato in `perf.data`.
- Al termine stampa la dimensione del file prodotto.

### Step 3 — Conversione e apertura browser

```
perf_to_perfetto.py → http.server → xdg-open / google-chrome / firefox
```

- Invoca `script/perf_to_perfetto.py` che legge `perf.data` (tramite `perf script`) e produce `trace_perf.json`.
- Termina eventuali processi che già occupano la porta configurata (`lsof -ti tcp:PORT | xargs kill -9`).
- Avvia `python3 -m http.server PORT --directory <mudock_root>` in background.
- Costruisce l'URL Perfetto con il parametro `url` precompilato:
  ```
  https://ui.perfetto.dev/#!/?url=http://localhost:9001/trace_perf.json
  ```
- Prova ad aprire il browser nell'ordine: `xdg-open` → `google-chrome` → `chromium-browser` → `firefox`.

---

## 4. Perché `RelWithDebInfo`?

La modalità di build standard usata nello sviluppo muDock è `Release` (flag `-O3`), che produce codice velocissimo ma rimuove tutte le informazioni di debug: i simboli delle funzioni vengono eliminati o inlinati, rendendo impossibile per `perf` risolvere gli indirizzi IP in nomi di funzioni significativi.

`RelWithDebInfo` applica le stesse ottimizzazioni di `Release` (`-O2` in CMake di default, `-O3` se configurato) ma aggiunge `-g` alla compilazione, che mantiene le **DWARF debug info** nell'ELF senza influenzare le prestazioni a runtime.

> **Il compromesso:** il binario è leggermente più grande su disco (~10–20%) e la compilazione richiede qualche secondo in più, ma le prestazioni di esecuzione sono praticamente identiche a `Release`. Il vantaggio è enorme: `perf report` e Perfetto mostrano nomi di funzione reali, file sorgente e numeri di riga invece di indirizzi esadecimali anonimi.

---

## 5. Perché `--call-graph dwarf`?

`perf record` offre tre modalità per registrare lo stack delle chiamate:

| Modalità | Come funziona | Limitazioni |
|---|---|---|
| `fp` (frame pointer) | Segue il registro `rbp` | Richiede che il codice sia compilato con `-fno-omit-frame-pointer`; GCC/Clang lo omettono per default con `-O2`+ |
| `lbr` (Last Branch Record) | Usa l'hardware LBR della CPU | Stack depth limitata (≤32 frame), non disponibile su tutte le CPU |
| `dwarf` | Legge la sezione `.debug_frame` / `.eh_frame` dell'ELF | Overhead di copia stack ≈2 KB per campione, ma funziona sempre |

Con `RelWithDebInfo` e GCC ottimizzato, il frame pointer non è garantito. La modalità `dwarf` è l'unica che produce **call-chain complete e corrette** in questa configurazione, a costo di un file `perf.data` più grande (tipicamente 2–5× rispetto a `fp`).

Il flag `-g` (equivalente a `--call-graph`) abilita la raccolta dello stack; `--call-graph dwarf` specifica il meccanismo preciso.

---

## 6. Apertura automatica di Perfetto

Perfetto UI è una Single Page App servita da `https://ui.perfetto.dev`. Per caricare un file locale senza caricamento manuale, lo script sfrutta un parametro speciale dell'URL:

```
https://ui.perfetto.dev/#!/?url=http://localhost:9001/trace_perf.json
```

Quando Perfetto UI avvia, legge il parametro `url` dalla query string e scarica la traccia dalla URL specificata. Questo permette di **pre-caricare automaticamente** il file JSON generato dallo script.

Per rendere il file accessibile da quella URL, lo script avvia un mini-server HTTP:

```bash
python3 -m http.server 9001 --directory ~/UNI/progetto_aca/muDock &
```

Questo server serve tutti i file nella directory radice del progetto sulla porta locale 9001. La traccia diventa così raggiungibile all'indirizzo `http://localhost:9001/trace_perf.json`.

> **Nota sul ciclo di vita del server:** il processo `http.server` resta attivo in background dopo il completamento dello script. Il PID viene stampato a schermo per permettere di terminarlo manualmente con `kill <PID>`.

---

## 7. Problemi incontrati e soluzioni

### 7.1 `perf_event_paranoid` bloccava i contatori hardware

**Sintomo:** `perf record` restituiva errori del tipo `Permission denied` o produceva una traccia vuota/parziale con soli eventi software.

**Causa:** Il kernel Linux espone `/proc/sys/kernel/perf_event_paranoid` come guardia di sicurezza. Con valore `≥1`, gli utenti non-root non possono accedere ai Performance Monitoring Counters (PMC) hardware.

**Soluzione adottata nello script:**
```bash
PARANOIA=$(cat /proc/sys/kernel/perf_event_paranoid)
if [[ "${PARANOIA}" -gt 0 ]]; then
  sudo sysctl -w kernel.perf_event_paranoid=-1
fi
```
Lo sblocco è **temporaneo** (ripristinato al riavvio). Per renderlo permanente aggiungere `kernel.perf_event_paranoid=-1` a `/etc/sysctl.conf`.

> ️ **Attenzione:** Il valore `-1` disabilita completamente il controllo. In ambienti condivisi o di produzione usare `0` (contatori hardware per utenti normali) invece di `-1`.

---

### 7.2 Il browser non supportava il mixed content (HTTP da HTTPS)

**Sintomo:** Perfetto UI (servita via HTTPS) tentava di scaricare la traccia da `http://localhost` (HTTP), e il browser bloccava la richiesta con un errore di **mixed content** (`Mixed Content: The page was loaded over HTTPS, but requested an insecure resource`).

**Causa:** I browser moderni bloccano per default le richieste HTTP originate da pagine HTTPS (policy di sicurezza mixed content), anche quando la risorsa è su `localhost`.

**Workaround — eccezione localhost in Chrome/Chromium:**

1. Aprire `chrome://flags/#unsafely-treat-insecure-origin-as-secure`
2. Aggiungere `http://localhost:9001` alla lista
3. Riavviare il browser

In alternativa, lanciare Chrome con il flag:
```bash
google-chrome --allow-running-insecure-content --disable-web-security \
  "https://ui.perfetto.dev/#!/?url=http://localhost:9001/trace_perf.json"
```

> **Nota:** Perfetto UI gestisce già `localhost` come "secure context" nelle versioni recenti (dalla fine del 2023). Se il problema persiste, aggiornare il browser o usare Firefox che è generalmente più permissivo su `localhost`.

---

### 7.3 Build incrementale non ricompilava i file dipendenti da `worker.hpp`

**Sintomo:** Dopo aver modificato `worker.hpp`, la build incrementale (`make -j8` senza `--clean`) completava in pochi secondi senza ricompilare le translation unit che includevano quell'header. La traccia risultante mostrava ancora il comportamento pre-modifica.

**Causa:** CMake/Make traccia le dipendenze tra sorgenti e header tramite i file `.d` generati dal compilatore (flag `-MD`). In alcune configurazioni, specialmente con header di sistema o quando i path cambiano tra build Spack, la dipendenza non veniva registrata correttamente.

**Soluzione adottata:** Usare sempre `--clean` quando si modificano file header:

```bash
./script/base_converter.sh --clean
```

Questo garantisce che `rm -rf build` elimini tutti i file `.o` e le dipendenze obsolete, forzando una ricompilazione completa.

>  **Tip:** Se si vogliono evitare clean build complete, è possibile cancellare selettivamente solo gli oggetti coinvolti:
> ```bash
> find build -name "*.o" | xargs rm -f && make -j8
> ```
> Tuttavia per sicurezza la clean build rimane la soluzione consigliata quando si modificano header condivisi.

---

## 8. Possibili miglioramenti futuri & Roadmap Cache/Memoria

| Categoria | Miglioramento | Descrizione e Dettagli d'Implementazione (ACA) |
|---|---|---|
|  **Cache Profiling** | **`--event` per scegliere l'evento perf** | Aggiungere un parametro `--event EVENT` per consentire di passare a `perf record -e` i contatori PMU per l'analisi delle gerarchie di memoria di Zen 5:<br>• `L1-dcache-load-misses` (inefficienze a grana fine)<br>• `l2_cache_misses.from_l2_cache` (misses sul secondo livello)<br>• `LLC-load-misses` o `cache-misses` (accessi forzati alla DRAM, alta latenza). |
|  **Memory Latency** | **Integrazione con `perf mem`** | Implementare un flag `--mem-lat` che esegua `perf mem record -- ./build/application/muDock`. Permette di raccogliere e mappare i campioni di accesso alla memoria indicando la latenza in cicli di clock e la sorgente dell'accesso (L1, L2, L3, DRAM locale, DRAM remota NUMA), localizzando gli accessi lenti. |
|  **Cache Contention** | **Analisi False Sharing via `perf c2c`** | Implementare l'integrazione con il tool `perf c2c` (Cache-to-Cache) per tracciare la contesa delle linee di cache (cache lines) tra i thread OpenMP. Il False Sharing (thread diversi che modificano variabili diverse sulla stessa cache line da 64 byte) causa continui invalidamenti di cache (HITM - Hit Modified) e crolli prestazionali. |
|  **Bandwidth** | **Memory Bandwidth Counters** | Tracciare eventi del Northbridge/Data Fabric per misurare la banda di memoria occupata in GB/s durante l'esecuzione dell'algoritmo di docking molecolare. |
| ️ **System** | **Supporto multi-run per statistiche** | Un parametro `--runs N` che esegue la pipeline N volte, raccoglie le metriche e calcola media/deviazione standard per ridurre la varianza da OS jitter. |
|  **Visual** | **Integrazione con Flame Graph** | Dopo la conversione, generare automaticamente uno SVG FlameGraph tramite [`flamegraph.pl`](https://github.com/brendangregg/FlameGraph) come alternativa leggera a Perfetto UI. |
|  **Data** | **Output su cartella timestampata** | Invece di sovrascrivere sempre `perf.data` e `trace_perf.json`, salvare ogni run in una cartella `runs/runs_YYYYMMDD_HHMMSS/` per conservare la storia delle misurazioni. |
|  **Hardware** | **Parametro `--device`** | Esporre l'opzione `--use` di muDock (attualmente hardcoded a `CPP:CPU:0`) per testare facilmente backend diversi. |

---

*Documentazione generata il 2026-06-12. Fare riferimento al file sorgente [`base_converter.sh`](./base_converter.sh) per la versione più aggiornata dello script.*
