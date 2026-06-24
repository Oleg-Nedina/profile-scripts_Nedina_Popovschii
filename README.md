# 📊 Strumenti di Profiling e Tracing per muDock

Questo repository raccoglie tutti gli script, i convertitori e le librerie per l'analisi prestazionale del micro-app **muDock** per il corso di **Architettura dei Calcolatori Avanzata** (ACA).

L'infrastruttura è suddivisa in tre moduli principali in base al target e al livello di dettaglio dell'analisi: **CPU**, **GPU** e **User/Kernel-level PAPI**.

---

## 📁 Struttura del Repository

```
profile-scripts_Nedina_Popovschii/
├── perf_stat_user_kernel/    ← Profiling integrato C++ (Nuovo modulo)
│   ├── README.md             # Documentazione dettagliata PAPI + User Events
│   ├── include/              # Header per strumentazione C++ (aca_*)
│   ├── src/                  # Codice sorgente (PapiTracer, UserEventTracer)
│   ├── scripts/              # Orchestratori run_user_kernel.sh e run_papi.sh
│   ├── preset_template/      # Template JSON per formattazione dei report PAPI
│   └── templates/            # Guide d'integrazione CMake
│
├── cpu/                      ← Profiling CPU (system-wide e uprobes)
│   ├── README.md             # Documentazione + tabelle metriche
│   ├── perf_stat/            # Script perf stat per IPC, cache e TLB
│   ├── low_level/            # Dynamic tracing con uprobes (Top-N funzioni)
│   ├── high_level/           # Tracciamento thread via LD_PRELOAD (JSON/SDK native)
│   └── perfetto_converters/  # Convertitori Python verso il formato Perfetto JSON
│
└── gpu/                      ← Profiling GPU (Roofline e Nsight Compute)
    ├── README.md             # Panoramica sul profiling GPU
    ├── nvidia/               # Tooling per Nsight Compute (Roofline + Chart)
    └── amd/                  # Workflow per ROCProfiler su hardware AMD
```

---

## ⚡ Quick Start: I Tre Moduli in Sintesi

### 1. Combined User & Kernel Profiling (Modulo Principale)
Isola la computazione critica del codice utente (User) ed effettua profiling hardware a livello di singola funzione (Kernel) per thread:
```bash
# Esegui il profiling hardware con preset SIMD sui kernel di muDock
./perf_stat_user_kernel/scripts/run_papi.sh \
    --exe ./muDock/build/application/muDock \
    --args "--protein ./muDock/data/1fkb/1fkb_protein.pdb --ligand ./muDock/data/1fkb/ligands100_12col.adtmol2 --use CPP:CPU:0-3 --search genetic --population 100 --generations 100" \
    --preset simd \
    --knl-3 "GeneticInit" --knl-4 "GeneticIterate" --knl-5 "GeomTransform" --knl-6 "CalcEnergy"
```
*Vedi [perf_stat_user_kernel/README.md](file:///home/olly/UNI/progetto_aca/profile-scripts_Nedina_Popovschii/perf_stat_user_kernel/README.md) per istruzioni e compilazione CMake.*

### 2. CPU Profiling (Standard)
Analisi system-wide e hardware generale:
```bash
# Analisi IPC, branch e stall sull'intera esecuzione
./cpu/perf_stat/cpu_metrics.sh --exe ./muDock/build/application/muDock --args "--protein data/1fkb/1fkb_protein.pdb --use CPP:CPU:0"
```
*Vedi [cpu/README.md](file:///home/olly/UNI/progetto_aca/profile-scripts_Nedina_Popovschii/cpu/README.md) per ulteriori dettagli.*

### 3. GPU Profiling
Roofline ed Nsight Compute per GPU NVIDIA:
```bash
# Raccolta metriche Nsight Compute per generare grafici roofline
python3 gpu/nvidia/nsight_profiler.py --exe ./muDock/build/application/muDock --kernel "CalcEnergy"
```

---

## 🛠️ Tabella dei Requisiti ed Environment

| Modulo / Tool | Requisito Principale | Utilizzo |
| :--- | :--- | :--- |
| `perf` | `linux-tools-$(uname -r)` | Necessario per gli script in `cpu/perf_stat` e `cpu/low_level` |
| `PAPI (7.2.0)` | Spack package `papi` | Profiling hardware microscopico in `perf_stat_user_kernel` |
| `Python3` | `json`, `re` (Standard library) | Post-elaborazione tracciati e formattazione dei report dei preset |
| `Perfetto UI` | Browser moderno | Visualizzazione delle timeline interattive (`https://ui.perfetto.dev/`) |

---

*Documentazione del Progetto di ACA — Profiling e Tracing HPC*  
*Ultima modifica: Giugno 2026*
