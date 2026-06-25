# Stato dei Test di Profilazione

In questo file terremo traccia dei test eseguiti e dei relativi esiti (se nominali o con anomalie/problemi).

| Script | Stato | Dettagli / Problemi riscontrati |
|---|---|---|
| `profile_high_level.sh` (con `--no-otf2`) | **Nominale** | Esecuzione completata con successo in 3.25s. Traccia JSON creata correttamente (528K). Conversione OTF2 saltata come da opzioni. |
| `profile_high_level.sh` (con conversione OTF2) | **Nominale** | Esecuzione completata con successo in 3.32s. Traccia JSON (532K) e file OTF2 (`traces.otf2` con 16 thread e 5937 campioni) generati correttamente. |
| `profile_high_level.sh` (con `--native`) | **Errore** | **Segmentation fault (core dumped)** riscontrato alla riga 161 del file di scripting durante lo STEP 2 (esecuzione con `libperfetto_preload.so`). Exit code: 139. |
| `low_level_probe.sh` (con `--c2c`) | **Nominale con Limitazioni** | Pipeline completata. Solo **1 su 3 funzioni target** (`prepare`, solo entry probe) è stata tracciata con successo. Le altre probe sono fallite (simboli non trovati o inline). Report False Sharing `c2c_report.txt` e traccia Perfetto JSON generati correttamente. |
| `base_converter.sh` | **Nominale** | Esecuzione e build completate con successo. Registrato 1.1GB di campionamento raw (`perf.data`). Traccia JSON (`trace_perf.json`, 20MB) generata con successo (17 thread, 136044 campioni) in 3.20s. Server HTTP avviato su porta 9001. |
| `cpu_metrics.sh` | **Errore (muDock abortito)** | L'eseguibile `muDock` è terminato con `std::runtime_error` ("pdb Parser failed, look to logs for details") perché non ha trovato il file pdb. Le metriche raccolte e i JSON si riferiscono all'esecuzione fallita. |
| `memory_metrics.sh` | **Errore (muDock abortito)** | Stesso errore di `cpu_metrics.sh`: `muDock` è abortito subito con `std::runtime_error` ("pdb Parser failed") per mancanza del file pdb. |
| `full_pipeline.sh` (con `--skip-build`) | **Nominale con Limitazioni** | Esecuzione completata con successo in 2m 3s. Livello 1 (CPU/Memory metrics) e Livello 2 (LD_PRELOAD JSON) completati correttamente. Il Livello 3 (uprobes) ha mostrato errori/avvisi nell'inserimento di 2 su 3 probe per via di simboli ottimizzati/inline. |

## Analisi dei Problemi e Possibili Cause

### 1. Segmentation Fault con `--native` (`libperfetto_preload.so`)
Durante lo STEP 2 di `profile_high_level.sh --native`, l'esecuzione di `muDock` fallisce con **Segmentation Fault** (exit code 139). Le cause più probabili sono:

*   **Ricorsione Infinita nell'Intercettazione dei Thread**: La libreria `libperfetto_preload.so` intercetta la funzione `pthread_create`. Tuttavia, l'SDK nativo C++ di Perfetto crea internamente i propri thread di servizio (per la gestione dell'IPC e del tracciamento in background). Quando Perfetto chiama `pthread_create` per i suoi thread di servizio, la nostra libreria intercetta la chiamata e tenta di registrare eventi tramite le API di Perfetto. Se questo accade prima che l'SDK sia del tutto inizializzato o se genera una chiamata ricorsiva infinita (l'inizializzazione dei thread di Perfetto che intercetta se stessa), si verifica un crash per stack overflow o dereferenziazione di puntatori nulli.
*   **Ordine di Inizializzazione dei Costruttori Statici**: Perfetto richiede un ciclo di vita controllato delle variabili globali e dei thread. Con `LD_PRELOAD`, l'inizializzazione della libreria precaricata avviene molto presto nel ciclo di vita del processo. Se l'inizializzazione dell'SDK nativo di Perfetto avviene durante l'esecuzione dei costruttori statici di `libperfetto_preload.so`, potrebbe accedere a parti di runtime C++ (es. thread local storage o runtime di allocazione) non ancora completamente configurati dall'eseguibile principale.
*   **Disallineamento ABI tra Compilatori**: Se la libreria precaricata, le librerie statiche dell'SDK Perfetto e il binario principale `muDock` sono compilati con compilatori diversi o standard C++ disallineati, le differenze nel layout di memoria degli oggetti di sincronizzazione dei thread (es. `std::mutex`, `std::thread`) possono causare corruzione di memoria.

### 2. Warning ed Errori in Step 2/4 di `low_level_probe.sh` / `full_pipeline.sh` (uprobes)
Nello Step 2/4 (Livello 3), l'inserimento delle sonde dinamiche con `perf probe` restituisce errori per quasi tutte le funzioni calde (`calc_energy`, `autodock_protein` e la retprobe di `prepare`). Le cause principali sono:

*   **Inlining del Compilatore (Ottimizzazioni aggressive)**: MuDock è compilato in modalità ottimizzata (`RelWithDebInfo`, tipicamente `-O2` o `-O3`). Il compilatore inietta (inlines) il codice di funzioni calde e brevi (come `calc_energy` o i costruttori) direttamente all'interno delle funzioni chiamanti per evitare l'overhead di chiamata. Poiché il codice della funzione non esiste più come entità isolata con il proprio punto di ingresso/uscita in memoria, `perf probe` non trova un indirizzo fisico a cui agganciare la sonda.
*   **Ottimizzazioni dei Punti di Ritorno (`retprobes`)**: Per `prepare`, l'entry probe viene aggiunta, ma la return probe fallisce. Nelle funzioni complesse o ottimizzate (specialmente quelle che usano template C++), l'istruzione di ritorno `ret` viene fusa o riscritta dal compilatore. Di conseguenza, il punto di uscita formale della funzione non è più identificabile in modo univoco da `perf probe`, rendendo le return probe non supportate.
*   **Discrepanza nei Nomi Mangled di C++**: C++ altera i nomi delle funzioni per includere tipi di argomenti e namespace (name mangling). Ad esempio, il costruttore di `autodock_protein` genera una firma lunghissima (`_ZN6mudock16autodock_proteinC1ERNS_8moleculeINS...`). Se l'ottimizzazione del compilatore genera varianti specifiche della funzione (cloni ottimizzati per argomenti costanti, funzioni parziali o inline localizzate), il mangled name finale presente nella tabella dei simboli ELF differisce leggero da quello atteso e cercato dallo script, provocando l'errore `Probe point not found`.

### 3. Mancata Apertura dei JSON di `cpu_metrics` e `memory_metrics` in `perfetto.dev`
I file JSON delle metriche (`cpu_metrics.json` e `memory_metrics.json`) generati tramite lo script `stat_to_perfetto.py` non vengono caricati correttamente dall'interfaccia web di Perfetto. Le ragioni principali sono:

*   **Assenza di Eventi di Durata (Slices `ph: X/B/E`)**: Perfetto UI è ottimizzato per visualizzare intervalli di esecuzione (slices di durata dei thread). I file delle metriche contengono esclusivamente eventi di tipo Counter (`ph: C`). Senza alcuna barra di attività che definisca un range temporale iniziale e finale di riferimento, l'interfaccia web di Perfetto spesso fallisce l'inizializzazione della timeline, mostrando una schermata vuota o un errore di caricamento.
*   **Format Strictness**: L'inclusione di chiavi di metadati non standard a livello radice nel dizionario JSON (come `"metadata"` o `"displayTimeUnit"`) a volte va in conflitto con il parser JSON ad alte prestazioni (WASM) di Perfetto, che si aspetta una struttura puramente piana o limitata al solo array `"traceEvents"`.

## Strategie per Ottenere il Massimo delle Informazioni con gli Script

Se l'obiettivo prioritario non è preservare al massimo le performance (overhead di tracciamento accettabile), bensì estrarre la maggior quantità possibile di dati e dettagli, si possono adottare le seguenti strategie:

### A. Aumentare la Frequenza e la Profondità del Campionamento (`base_converter.sh`)
*   **Aumentare la Frequenza (`-F`)**: Nel comando `perf record`, possiamo impostare una frequenza di campionamento molto elevata (es. `-F 9999` o `-F max`) per acquisire molti più campioni e catturare dettagli anche su funzioni brevissime.
*   **Aggiungere Eventi Hardware e Software Simultanei**: Anziché profilare solo i cicli CPU, possiamo catturare un set combinato di eventi nello stesso run:
    ```bash
    perf record -g --call-graph dwarf -e task-clock,cycles,instructions,cache-misses,page-faults,context-switches,cpu-migrations -o traces/perf.data ...
    ```
    Questo creerà una traccia in Perfetto che unisce call stack, cache misses, cambi di contesto e migrazioni CPU sulla stessa timeline di ciascun thread.

### B. Disabilitare l'Inlining nel Compilatore per le uprobes (`low_level_probe.sh`)
*   **Compilare con `-O0` o `-Og`**: Per poter posizionare le sonde (`perf probe`) su TUTTE le funzioni desiderate (comprese `calc_energy` e i costruttori) sia in ingresso che in uscita, occorre ricompilare il codice di `muDock` disabilitando l'ottimizzazione dell'inlining. Utilizzando il flag `-Og` o `-O0` in CMake, le funzioni manterranno la loro individualità fisica in memoria e tutti i punti di ingresso/uscita saranno tracciabili con successo dal kernel.

### C. Estendere il Tracciamento Thread (`high_level_so.cpp` e OMPT)
*   **Intercettare la Sincronizzazione dei Thread (POSIX vs OpenMP)**: Inizialmente si è tentato di estendere `libhigh_level.so` intercettando `pthread_cond_wait` e `pthread_barrier_wait` tramite `LD_PRELOAD`.
*   **Diagnosi e Limite Rilevato**: Durante l'esecuzione di `muDock`, gli eventi di tipo `cond_wait` sono risultati pari a 0. L'analisi ha rivelato che la libreria runtime di OpenMP (`libgomp.so` di GCC) non usa i wrapper POSIX standard, ma effettua chiamate dirette al kernel Linux via `sys_futex`. Poiché `LD_PRELOAD` intercetta solo i simboli delle libreria dinamiche e non le syscall dirette, questo approccio non può catturare le attese dei thread del pool OpenMP.
*   **Soluzione Corretta (OMPT)**: Per tracciare correttamente la sincronizzazione di OpenMP senza modificare il codice sorgente, la soluzione ottimale è usare **OMPT (OpenMP Tools Interface)**, definendo un tool precaricato (via `OMP_TOOL_LIBRARIES`) che registri le callback di attesa (`ompt_callback_sync_region_wait`) messe a disposizione nativamente dal runtime OpenMP.

