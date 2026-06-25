# 🔨 BUILD & RUN — muDock

# check di esistenza

```bash
ls ~/UNI/progetto_aca/muDock/build/application/muDock
```

## Compilazione

### Build completa

```bash
cd ~/UNI/progetto_aca/muDock


mkdir build && cd build

# i flag attivi sono quelli del cmakelist di mudock  , ci ho messo un sacco a capire come compilarlo in locale 
$(spack location -i cmake@3.31.11)/bin/cmake .. \
  -DCMAKE_C_COMPILER=gcc-14 \
  -DCMAKE_CXX_COMPILER=g++-14 \
  -DCMAKE_POLICY_DEFAULT_CMP0144=NEW \
  -DMUDOCK_ENABLE_SYCL=OFF \
  -DMUDOCK_ENABLE_OMP=ON \
  -DMUDOCK_ENABLE_GH=ON \
  -DMUDOCK_GPU_ARCHITECTURES="none" \
  -DMUDOCK_CPU_TARGET="native" \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DCMAKE_PREFIX_PATH="$(spack location -i boost@1.90.0);$(spack location -i highway);$(spack location -i openbabel)"

make -j 8
```

> **`RelWithDebInfo`** = ottimizzazioni `-O2` + simboli debug `-g`.  
> Obbligatorio per `perf` e `perf probe`. **No `Release`** per il profiling (buoan norma).

### Build completa con Clang (per abilitare OMPT fine-grained / Worksharing)

Da usare per abilitare il tracciamento completo di OpenMP (loop, task, ecc.) con il profiler OMPT, in quanto Clang traduce i loop paralleli in chiamate native di runtime LLVM compatibili con l'OMPT tracer:

```bash
cd ~/UNI/progetto_aca/muDock
rm -rf build && mkdir build && cd build

$(spack location -i cmake@3.31.11)/bin/cmake .. \
  -DCMAKE_C_COMPILER=clang-17 \
  -DCMAKE_CXX_COMPILER=clang++-17 \
  -DCMAKE_POLICY_DEFAULT_CMP0144=NEW \
  -DCMAKE_MODULE_PATH="$(pwd)/fake_cmake" \
  -DMUDOCK_ENABLE_SYCL=OFF \
  -DMUDOCK_ENABLE_OMP=ON \
  -DMUDOCK_ENABLE_GH=ON \
  -DMUDOCK_GPU_ARCHITECTURES="none" \
  -DMUDOCK_CPU_TARGET="native" \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DCMAKE_PREFIX_PATH="$(spack location -i boost@1.90.0);$(spack location -i highway);$(spack location -i openbabel)"

make -j 8
```

---

## Esecuzione

```
./build/application/muDock \
  --protein <file.pdb> \
  --ligand  <file.mol2> \
  --use     <IMPL:DEVICE:ID> \
  [--population N] [--generations N] [--seed N]
```

### Parametro `--use`

| Valore | Significato |
|---|---|
| `CPP:CPU:0` | Implementazione C++, CPU, device 0 |
| `CUDA:GPU:0` | Implementazione CUDA, GPU 0 (richiede GPU NVIDIA + build con CUDA) |
| `CPP:CPU:0;CPP:CPU:1` | Multi-device CPU |

### Esecuzione minima

```bash
cd ~/UNI/progetto_aca/muDock

./build/application/muDock \
  --protein data/1fkb/1fkb_protein.pdb \
  --ligand  data/1fkb/1fkb_ligand.mol2 \
  --use CPP:CPU:0
```

### Esecuzione con parametri personalizzati

```bash
./build/application/muDock \
  --protein data/1fkb/1fkb_protein.pdb \
  --ligand  data/1fkb/1fkb_ligand.mol2 \
  --use CPP:CPU:0 \
  --population 100 \
  --generations 100 \
  --seed 42
```

### Dataset allinterno di mudok

| Dataset | Protein | Ligand |
|---|---|---|
| `1fkb` | `data/1fkb/1fkb_protein.pdb` | `data/1fkb/1fkb_ligand.mol2` |
| `1hii` | `data/1hii/1hii_protein.pdb` | `data/1hii/1hii_ligand.mol2` |
| `2ya6` | `data/2ya6/2ya6_protein.pdb` | `data/2ya6/2ya6_ligand.mol2` |
| `3fv3` | `data/3fv3/3fv3_protein.pdb` | `data/3fv3/3fv3_ligand.mol2` |
| `3udd` | `data/3udd/3udd_protein.pdb` | `data/3udd/3udd_ligand.mol2` |
| `4few` | `data/4few/4few_protein.pdb` | `data/4few/4few_ligand.mol2` |
| `5cst` | `data/5cst/5cst_protein.pdb` | `data/5cst/5cst_ligand.mol2` |
| `5uez` | `data/5uez/5uez_protein.pdb` | `data/5uez/5uez_ligand.mol2` |
| `5wuk` | `data/5wuk/5wuk_protein.pdb` | `data/5wuk/5wuk_ligand.mol2` |

---

## secuzione per il profiling (con gli script)

### Con perf (base_converter.sh)

```bash
cd ~/UNI/progetto_aca/muDock

# Salta la build, usa il binario esistente
../profile-scripts_Nedina_Popovschii/cpu/base_converter.sh --skip-build
```

### Con LD_PRELOAD (high_level)

```bash
cd ~/UNI/progetto_aca/muDock

LD_PRELOAD=../profile-scripts_Nedina_Popovschii/cpu/high_level/libhigh_level.so \
MUDOCK_TRACE_HL_OUT=trace_high_level.json \
./build/application/muDock \
  --protein data/1fkb/1fkb_protein.pdb \
  --ligand  data/1fkb/1fkb_ligand.mol2 \
  --use CPP:CPU:0 \
  --population 100 \
  --generations 100
```

### Con cpu_metrics.sh / memory_metrics.sh

```bash
cd ~/UNI/progetto_aca/muDock

# Metriche CPU (IPC, branch, stall)
../profile-scripts_Nedina_Popovschii/cpu/cpu_metrics.sh \
  --exe ./build/application/muDock \
  --args "--protein data/1fkb/1fkb_protein.pdb --ligand data/1fkb/1fkb_ligand.mol2 --use CPP:CPU:0 --population 100 --generations 100"

# Metriche memoria (L1, LLC, TLB)
../profile-scripts_Nedina_Popovschii/cpu/memory_metrics.sh \
  --exe ./build/application/muDock \
  --args "--protein data/1fkb/1fkb_protein.pdb --ligand data/1fkb/1fkb_ligand.mol2 --use CPP:CPU:0 --population 100 --generations 100"
```

---

## Opzioni CMake

| Opzione | Valore | motivazione |
|---|---|---|
| `CMAKE_C_COMPILER` | `gcc-14` | Versione GCC specifica per Zen 5 |
| `CMAKE_CXX_COMPILER` | `g++-14` | Versione GCC specifica per Zen 5 |
| `CMAKE_BUILD_TYPE` | `RelWithDebInfo` | Ottimizzazioni `-O2` + simboli debug per perf |
| `MUDOCK_ENABLE_OMP` | `ON` | Abilita OpenMP (parallelismo CPU) |
| `MUDOCK_ENABLE_GH` | `ON` | Abilita Google Highway (SIMD portabile) |
| `MUDOCK_ENABLE_SYCL` | `OFF` | Disabilita SYCL (non usato) |
| `MUDOCK_GPU_ARCHITECTURES` | `none` | Disabilita GPU (profiling CPU only) |
| `MUDOCK_CPU_TARGET` | `native` | Ottimizza per l'architettura locale (Zen 5) |
| `CMAKE_MODULE_PATH` | `fake_cmake/` | Stub per FindCUDAToolkit (evita errori senza CUDA) |

---

```

# comano per usare perf
sudo apt install linux-tools-$(uname -r) linux-tools-generic
```

### `perf_event_paranoid` per bloccare i contatori hardware e usare i contatori

```bash
sudo sysctl -w kernel.perf_event_paranoid=-1
```
