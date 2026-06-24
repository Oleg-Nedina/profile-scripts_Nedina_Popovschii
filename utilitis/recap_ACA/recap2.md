```python
md_content = """# Guida Completa: Compilazione, Ottimizzazione e Profiling Hardware di muDock

Questa guida raccoglie tutti i passaggi, i comandi esatti e le soluzioni sistemistiche adottate per compilare ed analizzare le performance di **muDock** sulla tua architettura **AMD Ryzen (Zen 5)**, utilizzando l'ambiente **Spack** e il tool di campionamento hardware **Linux perf**.

---

## 📌 Prerequisito Fondamentale
Ogni volta che si apre un nuovo terminale, è necessario attivare l'ambiente Spack dedicato e posizionarsi nella cartella radice (root) del progetto:

```

```text
File generato con successo.

```bash
spack env activate mudock_zen5
cd ~/UNI/progetto_aca/muDock

```

---

## 1. 🚀 Compilazione Standard (Massima Velocità)

Questa configurazione è ideale per l'esecuzione reale di produzione alla massima velocità, sfruttando appieno il parallelismo di OpenMP e l'esecuzioni vettoriali SIMD (AVX-512) tramite Google Highway.

Eseguire questo blocco di comandi dalla root del progetto per effettuare una build pulita:

```bash
rm -rf build && mkdir build && cd build

# 1. Configurazione delle esche anti-CUDA per ingannare CMake
mkdir -p fake_cmake
echo "set(CUDAToolkit_FOUND TRUE)" > fake_cmake/FindCUDAToolkit.cmake
echo "add_library(CUDA::toolkit INTERFACE IMPORTED)" >> fake_cmake/FindCUDAToolkit.cmake
echo "add_library(CUDA::cudart INTERFACE IMPORTED)" >> fake_cmake/FindCUDAToolkit.cmake

# 2. Lancio di CMake forzando la versione aggiornata di Spack e i compilatori GCC 14
$(spack location -i cmake@3.31.11)/bin/cmake .. \
  -DCMAKE_C_COMPILER=gcc-14 \
  -DCMAKE_CXX_COMPILER=g++-14 \
  -DCMAKE_POLICY_DEFAULT_CMP0144=NEW \
  -DCMAKE_MODULE_PATH="$(pwd)/fake_cmake" \
  -DMUDOCK_ENABLE_SYCL=OFF \
  -DMUDOCK_ENABLE_OMP=ON \
  -DMUDOCK_ENABLE_GH=ON \
  -DMUDOCK_GPU_ARCHITECTURES="none" \
  -DMUDOCK_CPU_TARGET="native" \
  -DCMAKE_PREFIX_PATH="$(spack location -i boost@1.90.0);$(spack location -i highway);$(spack location -i openbabel)"

# 3. Compilazione parallela sfruttando gli 8 core fisici
make -j 8

```

### Come lanciare la simulazione standard (Dalla Root)

```bash
cd ~/UNI/progetto_aca/muDock
./build/application/muDock --protein data/1fkb/1fkb_protein.pdb --ligand data/1fkb/1fkb_ligand.mol2 --use CPP:CPU:0 --population 100 --generations 100

```

---

## 2. 🧠 Perché Score-P è fallito? (Analisi ACA)

Durante i test con **Score-P**, l'applicazione subiva un blocco temporale (*catastrophic overhead*). Per l'esame di Architettura dei Calcolatori Avanzata, questo comportamento evidenzia un aspetto chiave del software:

1. **Parallelismo a Grana Fine (*Fine-Grained Parallelism*):** muDock parallelizza tramite OpenMP cicli nidificati molto interni e profondi dell'Algoritmo Genetico (es. il calcolo delle distanze atomiche e delle griglie energetiche).
2. **Strumentazione Software vs Frequenza di Chiamata:** Score-P (tramite lo strumento OPARI2) modifica il codice sorgente inserendo funzioni gancio (*hooks*) ad ogni ingresso/uscita di una regione OpenMP. Quando un blocco parallelo viene creato e distrutto miliardi di volte al secondo, la CPU spende il 99% dei cicli a gestire i cronometri di Score-P invece di fare docking molecolare.
3. **Limite di Memoria:** Score-P supporta al massimo 4GB di memoria per singolo processo in questa configurazione, sollevando warning bloccanti in presenza di allocazioni superiori (`SCOREP_TOTAL_MEMORY`).

---

## 3. 🛠️ Profiling Hardware Nativo con Linux `perf`

Per ovviare all'overhead di Score-P, la metodologia corretta in ambito HPC è il **Profiling per Campionamento Hardware (Sampling)** mediante i contatori nativi della CPU Ryzen. L'overhead in questo caso è prossimo allo 0%.

### Passaggio A: Configurazione Sicurezza Kernel (Una tantum)

Di default, Ubuntu Noble blocca l'accesso ai contatori hardware per gli utenti non-root (`perf_event_paranoid = 4`). Sbloccare temporaneamente il sistema inserendo la propria password di sistema:

```bash
sudo sysctl -w kernel.perf_event_paranoid=-1

```

### Passaggio B: Installazione dei Binari Reali per il Kernel

Sui sistemi con Kernel OEM/Lenovo, il wrapper di sistema `/usr/bin/perf` non riesce ad agganciarsi automaticamente. È necessario installare il tool reale associato al kernel base di Ubuntu:

```bash
sudo apt update
sudo apt install linux-tools-6.8.0-117-generic

```

### Passaggio C: Registrazione delle Performance (Dalla Root)

Eseguire la simulazione standard completa all'interno di `perf`. Il programma terminerà alla massima velocità nativa in pochi secondi:

```bash
cd ~/UNI/progetto_aca/muDock

/usr/lib/linux-tools/6.8.0-117-generic/perf record -g -- ./build/application/muDock \
  --protein data/1fkb/1fkb_protein.pdb \
  --ligand data/1fkb/1fkb_ligand.mol2 \
  --use CPP:CPU:0 \
  --population 100 \
  --generations 100

```

*Nota: Il flag `-g` è fondamentale perché abilita la registrazione della Call-Graph (l'albero delle chiamate delle funzioni).*

---

## 4. 📊 Analisi e Lettura dei Risultati

Una volta completata la registrazione, viene generato il file `perf.data` nella root del progetto. Per esplorarlo interattivamente nel terminale, digitare:

```bash
/usr/lib/linux-tools/6.8.0-117-generic/perf report

```

### ⌨️ Scorciatoie da Tastiera per la Navigazione

* **Frecce Su/Giù:** Permettono di scorrere l'elenco delle funzioni ordinate per consumo di cicli CPU (dalla più pesante alla più leggera).
* **Tasto Invio (su una funzione):** Apre un menu contestuale. Selezionando *"Zoom into DSO"* o *"Annotate"*, è possibile scendere nel dettaglio del codice.
* **Tasto `+` / `-` (o Invio sulla Call-Graph):** Permette di espandere l'albero delle chiamate per capire quale funzione ha chiamato quel blocco parallelo OpenMP.
* **Tasto `q`:** Permette di tornare indietro o uscire dal report.

### 🔍 Cosa analizzare per la relazione d'esame

1. **Colli di Bottiglia (Hotspots):** Identificare la prima funzione in cima alla lista. Quella è la funzione critica su cui concentrare l'ottimizzazione architetturale.
2. **Impatto di OpenMP:** Cercare le funzioni associate a `libgomp.so`. Se le funzioni di gestione dei thread (`gomp_team_start`, `gomp_barrier_wait`) occupano una percentuale alta (es. > 15-20%), significa che c'è un grosso problema di sbilanciamento del carico (*Load Imbalance*) o troppi overhead di sincronizzazione.
3. **Ottimizzazione Vettoriale (Google Highway):** Verificare la presenza dei simboli legati a `hwy::` nell'albero. Un'elevata percentuale in queste funzioni indica che il processore sta sfruttando massicciamente i registri vettoriali e le istruzioni AVX-512 nativamente supportate dalla microarchitettura Zen 5.
"""
