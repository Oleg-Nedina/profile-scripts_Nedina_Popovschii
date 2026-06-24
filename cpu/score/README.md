
---

## File

| File | Descrizione |
|------|-------------|
| `profile_scorep.sh` | Script di automazione completo (build → run → conversione → browser) |
| `scorep.filter` | Filtro per escludere funzioni ad alta frequenza (evita overflow buffer) |
| `otf2_to_perfetto.py` | Convertitore OTF2 → JSON Perfetto (per visualizzazione su browser) |

---

## Quick Start

```bash
# Dalla root del progetto profile-scripts:
./cpu/score/profile_scorep.sh --population 100 --generations 100
```

Se la compilazione è già stata eseguita in precedenza:

```bash
./cpu/score/profile_scorep.sh --skip-build --population 100 --generations 100
```

---

## ️ Parametri dello script

| Parametro | Default | Descrizione |
|-----------|---------|-------------|
| `--skip-build` | off | Salta la compilazione, usa il binario già compilato in `build_scorep/` |
| `--no-browser` | off | Non aprire il browser automaticamente |
| `--population N` | `100` | Dimensione della popolazione del GA |
| `--generations N` | `100` | Numero di generazioni del GA |
| `--out-dir DIR` | `traces/` | Directory di output per tutti i file generati |
| `--port PORT` | `9003` | Porta del server HTTP locale per Perfetto |

---

## Output generati

| File | Strumento | Descrizione |
|------|-----------|-------------|
| `traces/scorep_trace/traces.otf2` | Score-P | Traccia OTF2 grezza (timeline thread/regioni OpenMP) |
| `traces/scorep_trace/profile.cubex` | Cube GUI | Profilo aggregato (tempo per regione, per thread) |
| `traces/scorep_perfetto.json` | Perfetto | Traccia convertita per il browser |
| `traces/scorep_run.log` | — | Log stdout/stderr dell'esecuzione di muDock |

---

## Visualizzazione

### Perfetto (timeline nel browser)

La conversione e l'apertura del browser sono **automatiche** al termine dello script.  
In alternativa, manualmente:

```bash
# Avvia server locale
python3 -m http.server 9003 --directory ~/UNI/progetto_aca/muDock &
# Apri nel browser
xdg-open "https://ui.perfetto.dev/#!/?url=http://localhost:9003/traces/scorep_perfetto.json"
```

### Cube GUI (profilo aggregato con metriche per thread)

**Installazione** (se non ancora disponibile in Spack):

```bash
source ~/spack/share/spack/setup-env.sh
spack install cube +gui   # installa Cube con interfaccia grafica
spack load cube
```

**Apertura**:

```bash
source ~/spack/share/spack/setup-env.sh
spack load cube
cube ~/UNI/progetto_aca/muDock/traces/scorep_trace/profile.cubex
```

Cube mostra **tre pannelli**:

- **Sinistra**: metriche aggregate (tempo wall clock, idle, ecc.)
- **Centro**: gerarchia delle regioni OpenMP (parallel → workshare → barrier)
- **Destra**: suddivisione per thread (rivela lo sbilanciamento di carico)

### Ispezione testuale rapida (senza GUI)

```bash
source ~/spack/share/spack/setup-env.sh
spack load scorep
otf2-print ~/UNI/progetto_aca/muDock/traces/scorep_trace/traces.otf2 | head -50
```

---

## ️ Come funziona la strumentazione

Lo script usa i **compiler wrapper** di Score-P al posto dei compilatori di sistema:

```
gcc-14 / g++-14  →  scorep-gcc / scorep-g++
```

I wrapper aggiungono automaticamente la strumentazione OpenMP (via **OPARI2**) durante la compilazione.  
La flag `--nocompiler` disabilita la strumentazione per-funzione (troppo costosa), lasciando attiva **solo** quella OpenMP:

| Evento tracciato | Categoria |
|-----------------|-----------|
| `#pragma omp parallel` (begin/end) | `omp_parallel` |
| `#pragma omp for` / workshare | `omp_work` |
| Barriere implicite ed esplicite | `omp_sync` |
| Thread lifecycle (begin/end) | `thread_lifecycle` |

---

## Filtro (`scorep.filter`)

Il file `scorep.filter` esclude le funzioni matematiche ad altissima frequenza di chiamata (es. `evaluate*`, `geom_transform*`, `std::*`) che causerebbero:

- Overflow del buffer di Score-P (`SCOREP_TOTAL_MEMORY`)
- Overhead di esecuzione proibitivo (100x rallentamento)
- Warning `Instrument filter(s) will be ignored` a compile-time

---

## ️ Note

> [!WARNING]
> Non eseguire lo script con `source` o `.`. Usa sempre la chiamata diretta:
>
> ```bash
> ./cpu/score/profile_scorep.sh
> ```
>
> Il meccanismo di protezione anti-source è integrato nello script e restituisce un errore esplicito se lo rileva.

> [!NOTE]
> La compilazione avviene in una directory separata (`muDock/build_scorep/`) del tutto indipendente dalla build normale (`muDock/build/`). Le due build coesistono senza interferire.

> [!NOTE]
> Il modulo `otf2` Python è necessario per il convertitore. Se non è installato:
>
> ```bash
> pip install otf2 --break-system-packages
> ```

---

## 🔍 Risoluzione dei Problemi e Caveat

In questa sezione raccogliamo le soluzioni ai problemi di overhead, compilazione e visualizzazione riscontrati durante l'integrazione di Score-P e Perfetto.

### 1. Errore Python `AttributeError: 'Location' object has no attribute 'location_group'`
*   **Sintomo**: Durante l'esecuzione del convertitore `otf2_to_perfetto.py`, il parsing fallisce con un errore di tipo `AttributeError` indicando che `location_group` non è un attributo dell'oggetto `Location`.
*   **Causa**: Versioni diverse della libreria Python `otf2` (ad esempio quella installata tramite Spack rispetto a versioni `pip` più vecchie/nuove) utilizzano una nomenclatura differente per le proprietà di localizzazione.
*   **Soluzione**: Nel file `otf2_to_perfetto.py`, accedere alla proprietà abbreviata `.group` (cioè `loc.group`) invece della forma estesa `.location_group`.

### 2. Esecuzione estremamente lenta (Overhead di Strumentazione)
*   **Sintomo**: Nonostante la riduzione dei parametri del Genetic Algorithm (es. `population` e `generations`), l'esecuzione di `muDock` con Score-P impiega molti minuti o sembra bloccata.
*   **Causa**: L'utilizzo della sola strumentazione automatica del compilatore (`--compiler`) accoppiata a un filtro di esclusione a *runtime* (`export SCOREP_FILTERING_FILE=...`) costringe comunque l'eseguibile a chiamare la funzione di hook all'inizio e alla fine di miliardi di micro-funzioni (operazioni su matrici, vettori, griglie spaziali). Anche se le chiamate vengono poi scartate a runtime, il solo costo di chiamata dell'hook rallenta l'applicazione in modo insostenibile (*effetto sonda*).
*   **Soluzione**: Applicare il filtro direttamente **in fase di compilazione** tramite l'opzione `--instrument-filter=<file>` (già configurata in `profile_scorep.sh`).
    > [!IMPORTANT]
    > **Nota sulla variante `+gcc-plugin` (Provata ma non riuscita)**: Abbiamo provato a ricompilare Score-P abilitando il supporto per i plugin GCC (`+gcc-plugin`) seguendo questa procedura, ma l'installazione è **fallita** a causa della mancanza degli header `gcc-plugin.h` nel pacchetto compiler `gcc@14.2.0` gestito da Spack.
    > 
    > Per superare questo problema ed eliminare l'overhead dei wrapper, abbiamo riconfigurato l'ambiente `spack.yaml` impostando `scorep~gcc-plugin` (già presente localmente) e aggiornato lo script `profile_scorep.sh` per utilizzare la modalità `--nocompiler` (strumentazione delle sole regioni OpenMP e metriche PAPI, senza strumentazione automatica del compilatore).

### 3. Filtrare tutto tranne le macro-funzioni (Approccio Whitelist)
*   **Problema**: Identificare a mano ogni singola funzione matematica a basso livello per escluderla nel filtro è laborioso e soggetto a errori.
*   **Soluzione**: Strutturare il file `scorep.filter` definendo un blocco `INCLUDE` all'inizio per elencare esclusivamente le macro-fasi desiderate (come `*genetic*`, `*evaluate*`, `*mutate*`, `*calc_energy*`, `*prepare*`, `*virtual_screen*`), seguito da una regola finale `EXCLUDE *`. Poiché Score-P valuta le regole in ordine di apparizione (la prima corrispondenza vince), questo include solo le macro-funzioni prescelte ed esclude qualsiasi altra cosa.

### 4. I tasti direzionali non funzionano in Perfetto (Firefox)
*   **Sintomo**: Quando si apre Perfetto su Firefox, la digitazione dei tasti `W` / `S` / `A` / `D` (usati per lo zoom e lo spostamento temporale) apre automaticamente la barra di ricerca testo in fondo alla pagina.
*   **Causa**: Firefox ha un'opzione di usabilità attiva di default (*Cerca il testo digitato nella pagina*) che cattura l'input da tastiera prima che arrivi all'applicazione web WASM di Perfetto.
*   **Soluzione**: Disattivare l'opzione in Firefox andando su: *Impostazioni* $\rightarrow$ *Generale* $\rightarrow$ *Navigazione* $\rightarrow$ togliere la spunta a *"Cerca il testo digitato nella pagina"*.

---

*Documentazione progetto ACA — Score-P Profiling HPC*  
*Ultima modifica: 2026-06-22*
