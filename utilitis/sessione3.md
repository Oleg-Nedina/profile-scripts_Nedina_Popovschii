# Sessione 3 — Score-P Tracing, Visualizzazione e Miglioramenti Script

**Data:** 2026-06-22  
**Obiettivo principale:** Implementare il tracing real-time degli eventi OpenMP e user-defined con Score-P, supportare la doppia visualizzazione delle timeline (tramite Perfetto e Cube GUI), integrare le metriche hardware PAPI, e ottimizzare gli script di profiling CPU con dettagli granulari ed esecuzioni per-thread.

---

## 🛠️ Riepilogo delle Attività Svolte

In questa sessione sono stati affrontati e risolti 5 punti chiave per arricchire la qualità dei dati di profilazione raccolti ed estendere le capacità degli script esistenti:

### 1. Estensione Metriche CPU (`cpu_metrics.sh`)
*   **Contatori Hardware Aggiuntivi:** Integrati all'array `CPU_EVENTS` i contatori per:
    *   `stalled-cycles-backend` (stalli nella pipeline di esecuzione backend)
    *   `cache-references` (accessi / references alla cache di ultimo livello L3 - LLC)
    *   `cache-misses` (fallimenti di lettura in L3, con conseguente accesso a RAM)
*   **Nuova Sezione nel Report:** Introdotto il blocco **"LLC (Last Level Cache)"** che riporta:
    *   LLC references totali
    *   LLC misses
    *   LLC miss rate (%)
*   **Backend Stall Rate:** Rinominato il vecchio *Frontend stall rate* in `STALL_FE_RATE` ed introdotto `STALL_BE_RATE` per le stalle di backend.
*   **Esportazione CSV:** Esteso lo schema del file CSV di output per includere le 5 nuove metriche estratte.
*   **Misurazione Efficienza Multithreading (`task-clock`):** Reintrodotto l'evento `"task-clock"` nell'array `CPU_EVENTS` e corretto il parsing della metrica `CPUs utilized` (evitando che venissero estratte parentesi errate come `)` in presenza della deviazione standard generata dalle esecuzioni con `--repeat` maggiore di 1).
*   **Fallback Parametri di muDock:** Integrato un meccanismo di autodetect intelligente per cui, in assenza di argomenti espliciti passati tramite `--args`, vengono usati i file di input standard (`1fkb_protein.pdb`, `1fkb_ligand.mol2`, ecc.) individuandoli dinamicamente nella cartella `muDock`.
*   **Gestione Hardware Non Supportato:** Potenziato il parser `extract_val` sia in `cpu_metrics.sh` che in `memory_metrics.sh` per intercettare valori non numerici (come `<not supported>`), impostandoli a `0` ed evitando crash per divisione per zero in `awk`.

### 2. Ottimizzazione del Tracciamento con Score-P (`scorep.filter`)
*   **Rimozione Esclusioni Eccessive:** Rimossi dal blocco `EXCLUDE` le funzioni calde del Genetic Algorithm di muDock (come `evaluate`, `genetic` e `mutate`). Questo consente a Score-P di tracciare le fasi principali dell'algoritmo genetico rendendole visibili su Cube e Perfetto.
*   **Filtri Mantenuti:** Rimangono esclusi solo i namespace standard (`std::*`, `boost::*`), i calcoli matematici/geometrici di utilità a bassissimo livello (`*geom_transform*`, `*random*`, `*XORWOW*`) e gli operatori sovraccaricati per evitare un overhead di tracciamento ingestibile.

### 3. Analisi per Thread in `memory_metrics.sh`
*   **Run Granulare:** Subito dopo il run aggregato, viene avviata una sessione aggiuntiva di `perf stat` con l'opzione `--per-thread`.
*   **Estrazione Dati:** Raccoglie i contatori di memoria e cache separatamente per ogni thread OpenMP attivo, salvando i dati su un file temporaneo (`memory_metrics_per_thread.txt`).
*   **Integrazione Report:** Aggiunta una sezione finale che mostra il dettaglio granulare dell'attività cache ed esecuzione per ciascun thread, utile per rilevare sbilanciamenti di carico (load imbalance).
*   **Sudo per il breakdown per-thread:** Aggiunta l'opzione `-a` se lo script è eseguito con privilegi di root (`sudo`), permettendo di superare le restrizioni di `perf` e compilare correttamente il breakdown nel file `memory_metrics_per_thread.txt`.

### 4. Tracciamento OpenMP Tasks in `ompt_tracer.cpp`
*   **Supporto OMPT per Task:** Estesa l'infrastruttura di callback OMPT della libreria di tracciamento per gestire il ciclo di vita dei task OpenMP (`omp_task`).
*   **Struttura Dati:** Introdotta la struct `TaskRecord` per registrare i timestamp e gli stati dei task (creazione, schedulazione, inizio esecuzione, completamento/cancellazione).
*   **Implementazione Callback:**
    *   `on_task_create`: Registra l'istante di creazione e associa i puntatori dati.
    *   `on_task_schedule`: Traccia il passaggio di stato del task (es. start, yield, complete).
*   **Serializzazione Perfetto:** Gli eventi dei task vengono inclusi nel file JSON generato in fase di `flush()` sotto la categoria `"omp_task"`, consentendo di visualizzarli come slice temporali dedicate su Perfetto UI.
*   **Risoluzione Errore di Compilazione (Status Enum Mapping):** Risolto un bug di compilazione in cui veniva utilizzata la costante inesistente `ompt_task_others`. La logica dello `switch` è stata corretta mappando in modo pulito ed esplicito tutti gli stati standard definiti da `ompt_task_status_t` nell'header `omp-tools.h` (come `ompt_task_switch`, `ompt_task_early_fulfill`, ecc.), prevenendo falsi positivi.

### 5. Metriche Hardware PAPI in Score-P (`profile_scorep.sh`)
*   **Rilevamento Automatico:** Lo script interroga `scorep-info config-summary` per controllare se Score-P ha il supporto PAPI compilato.
*   **Variabile Ambientale:** Se PAPI è presente, esporta `SCOREP_METRIC_PAPI="PAPI_TOT_CYC,PAPI_TOT_INS,PAPI_L2_TCM"` per catturare cicli totali, istruzioni completate e LLC misses.
*   **Fallback Sicuro:** Se non presente, stampa un warning ed esegue il tracciamento senza metriche PAPI evitando di crashare.
*   **Rilevamento Limite gcc-plugin in Spack e Risoluzione**: Identificata la causa del warning `[Score-P] WARNING: Instrument filter(s) will be ignored`. Il tentativo di installare `scorep+gcc-plugin` nell'ambiente Spack locale fallisce a causa dell'assenza di `gcc-plugin.h` nel pacchetto compiler `gcc@14.2.0`.
    *   **Soluzione Applicata**: L'ambiente Spack è stato riconfigurato su `scorep~gcc-plugin` in `spack.yaml` (sfruttando l'installazione locale già presente e pre-compilata con PAPI) e lo script `profile_scorep.sh` è stato impostato con la flag `--nocompiler` in `SCOREP_WRAPPER_INSTRUMENTER_FLAGS`. Ciò consente un tracciamento OpenMP e metriche PAPI ad alte prestazioni, eliminando al contempo la dipendenza dai plugin del compilatore e l'overhead dei wrapper sulle funzioni non strumentate.

---

## 🔍 Verifica dell'Ambiente (PAPI e Score-P)
Abbiamo verificato la configurazione nell'ambiente Spack attivo tramite il comando:
```bash
spack load scorep
scorep-info config-summary
```
Il risultato mostra che **PAPI è integrato e configurato con successo** (`papi@7.2.0`) all'interno dell'installazione di Score-P. Sarà possibile visualizzare le colonne delle metriche direttamente in Cube GUI accanto alla timeline.

---

## 📈 Visualizzazione delle Tracce OTF2
Per visualizzare i risultati di Score-P:
1. **Cube GUI (Profiling):** Consente di visualizzare i contatori PAPI aggregati, i tempi esclusivi/inclusivi e la gerarchia delle chiamate.
2. **Perfetto (Timeline):** Tramite il convertitore `otf2_to_perfetto.py`, la traccia OTF2 può essere trasformata in formato `.pftrace`/`.json` per analizzare graficamente l'evoluzione temporale dei thread e l'esecuzione dei task OpenMP.
