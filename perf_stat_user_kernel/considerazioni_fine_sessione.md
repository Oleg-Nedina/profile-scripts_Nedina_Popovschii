# 📝 Considerazioni di Fine Sessione & Roadmap Futura

Questo documento riassume lo stato dell'arte del sistema di profiling combinato di `muDock`, analizza i punti di forza e i limiti delle tecnologie attuali e definisce il contesto operativo e la roadmap per le prossime sessioni di ottimizzazione.

---

## 🏁 1. Stato Attuale della Sessione (Recap)

Durante la sessione abbiamo consolidato il modulo [perf_stat_user_kernel](file:///home/olly/UNI/progetto_aca/profile-scripts_Nedina_Popovschii/perf_stat_user_kernel/README.md) risolvendo bug critici e introducendo una reportistica flessibile:

1. **Risoluzione dei Crash & Compilazione**: Risolti i crash di heap corruption a fine esecuzione e i problemi di visibilità delle macro C++ tramite modifiche mirate a [aca_papi_tracer.cpp](file:///home/olly/UNI/progetto_aca/profile-scripts_Nedina_Popovschii/perf_stat_user_kernel/src/aca_papi_tracer.cpp).
2. **Allineamento Temporale (Perfetto)**: Allineati i tracciati temporali all'istante di avvio assoluto del programma e separata l'inizializzazione di TBB (`WorkerInit`, ~13.6s) dalla computazione parallela vera e propria (`TbbPipeline`), eliminando falsi colli di bottiglia visivi.
3. **Pulizia del Terminale**: Reindirizzato lo standard output dei ligand a file di log (`docking_output.log`) all'interno di [run_user_kernel.sh](file:///home/olly/UNI/progetto_aca/profile-scripts_Nedina_Popovschii/perf_stat_user_kernel/scripts/run_user_kernel.sh) e [run_papi.sh](file:///home/olly/UNI/progetto_aca/profile-scripts_Nedina_Popovschii/perf_stat_user_kernel/scripts/run_papi.sh).
4. **Validazione dei Contatori PAPI**: Risolto il bug critico del disallineamento degli indici dei thread quando un contatore falliva (es. `PAPI_FMA_INS` su Zen 5). Ora, tramite un EventSet fittizio globale in `initPapi`, i contatori non supportati vengono scartati all'avvio garantendo la correttezza matematica delle metriche.
5. **Autogestione RPATH**: Aggiornato il file [CMakeLists.txt](file:///home/olly/UNI/progetto_aca/muDock/CMakeLists.txt) per inserire automaticamente la directory delle librerie PAPI di Spack in `CMAKE_BUILD_RPATH`, eliminando la necessità di esportare manualmente `LD_LIBRARY_PATH` a runtime.
6. **Reportistica basata su Template**: Strutturata la visualizzazione dei preset hardware (`ipc`, `cache`, `branch`, `simd`, `full`) tramite file di configurazione in `preset_template/` elaborati da [format_papi_report.py](file:///home/olly/UNI/progetto_aca/profile-scripts_Nedina_Popovschii/perf_stat_user_kernel/scripts/format_papi_report.py), che genera sezioni globali e dettagli per singolo thread TID.

---

## 🔍 2. Analisi degli Strumenti Avanzati

### HPCToolkit (Campionamento Statistico)

* **Cosa offre**: Misura le prestazioni interrompendo la CPU ad intervalli regolari (sampling). Correlare i dati PMU direttamente alle righe del codice sorgente C++ tramite DWARF.
* **Pro**: Overhead irrisorio (1-2%), non altera le prestazioni dei loop caldi, nessuna necessità di aggiungere macro manuali.
* **Contro**: Misurazione statistica (non fornisce contatori di invocazione esatti). Richiede configurazione e compilazione con info di debug (`-g`).
* **Verdetto**: Complemento ideale a PAPI. PAPI quantifica l'impatto complessivo delle funzioni, HPCToolkit individua la riga esatta da ottimizzare all'interno del codice del kernel.

### Perfetto vs. Altri Visualizzatori

* **Perfetto.dev**: Lo strumento migliore per timeline asincrone, visualizzazione del parallelismo istantaneo (`user_events_active`) e flessibilità web.
* **AMD uProf**: La scelta ottimale e nativa per profilare hardware AMD Zen 5. Permette di visualizzare stalli microarchitetturali, saturazione dei canali di memoria Infinity Fabric e consumi, integrando timeline per thread.
* **Intel VTune**: Leader di mercato per l'analisi dei lock e dell'utilizzo dei thread, ma fortemente limitato su CPU AMD per via delle PMU proprietarie.

### Ottimizzazione delle Metriche per Thread e Kernel

L'attuale approccio PAPI via strumentazione manuale ha dei limiti intrinseci di overhead se richiamato su funzioni che durano pochi microsecondi.

* **Miglioramento proposto**: Implementare un campionamento software condizionale in C++ (es. registrare i contatori PAPI solo una volta ogni $N$ invocazioni del kernel) per ridurre l'overhead di calcolo durante esecuzioni su larga scala.

---

## 📅 3. Roadmap per le Prossime Sessioni

Le prossime sessioni dovrebbero concentrarsi sulla raccolta sistematica dei dati e sull'ottimizzazione effettiva del codice sulla base dei report ottenuti:

### Fase 1: Profiling Completo dei Preset PAPI

Eseguire sistematicamente i preset per raccogliere una base di partenza (baseline) delle prestazioni:

* **Analisi Cache**: Controllare i valori di `L1 MPKI` e `L2 MPKI` dei kernel `CalcEnergy` e `GeomTransform` per verificare l'impatto dei cache miss.
* **Analisi SIMD**: Verificare il `Vectorization Rate` per capire se il compilatore sta generando codice vettoriale ottimizzato (AVX-512) o se i loop computazionali necessitano di pragmi di vettorializzazione esplicita.

### Fase 2: Integrazione e Studio di HPCToolkit

* Configurare il workflow di HPCToolkit compilando `muDock` con simboli di debug.
* Eseguire run con campionamento di `cycles` e `PAPI_L2_DCM` per identificare le singole istruzioni C++ all'interno del calcolo dell'energia che causano rallentamenti.

---
*Documento di fine sessione — Corso di Advanced Computer Architecture*  
*Data di redazione: 23 Giugno 2026*
