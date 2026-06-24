Un file di report di tutto (tante pagine ma tante davvero)

Abstract (introduzione)

- introduzione al progetto (cosa dovevamo fare ? script di profiling e automatizzazoine con focus esplorativo di tecniche e tool)
- Scelta app ? muDock (dettagli di compilazione)
- introduzione ai capitoli :
- introduzione ai tool utilizzati (perfetto.dev , perf , papi & contatori hw , hpctoolkit)
- capitolo 1 : intro all'idea generale (profilazione alto livello dei thread)
        - 1.1 high level , differnza tra sdk e implementazione nostra (sdk non funziona , ci abbiamo provato ma abbiamo problemi con le dipendenze delle funzioni)
         la nostta funzione non ci da molte infomrazioni (dettaglio tecnico sui .so)
         (aggiungere screen)
         -1.2 low_level : problema con inlining (il compilator fonde le funzioni  e qindi non riuscimao a mappare le hot function)
         aggiungere screen
          - 1.3 conclusioni su questa parte
  - capitolo 2 : perf_stat intro all'idea (profilare tutta l'applicazione a livello user-event e hw)
        - base_converter.sh profilazione a alto livello di tutto ma troppo infomrativa , piu che un user event è una profilazione di tutta lapplicazione e tutti i thread con livello di dettaglio a singola funzione  , si avra poi una vera profilazione di user event , utile la visualizzazione tramite perfetto (presente un convertitre otf2)
         (2 screen , visualizzione base +  time-slice)
        - cpu_metrics.sh da informazioni sulle metriche piu importanti di cpu con un report carino
         (screen terminale)
        - memory_metrics.sh come sopra ma per memoria

- Capitolo 3 : perf_stat_user_kernel
     possiamo modificare il codice ! utilizzo di macro e cmakelist modificato epr andare a porre il focus a particolari user-event e kernel function. (spiegare al volo come fa )
     per script di user e kernel event implementazioni simili e funzionamento uguale  , cambia solo i paramtri che guardo e osa fanno (iuser event per user event e kernel per tutti i parametri hw di interessa delle funzione e di tutti i worker che invocano quella funzione)
     una paginetta su hpctoolkit e quanto sia "forte" (implementato simile a prima)
  - capitolo 4 : problematiche esterne agli script in se ma pi generali (problema con clang che dava segmentation fault , e tutti i problemi di "codice" e non di idea dentor gli script)

- conclusioni finali (da fare assieme )  
alla fine di ogni spiegazione di script considerazioni personali sulla utilità e se lo abbiao tenuto

provato a usare anche cubo come visualizzare ma non mi sono trovato bene (problemi di compatibilità con il nostro ambiente e con le versioni di cubo) quindi non lo abbiamo approfondito.
