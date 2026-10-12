# MetaHipMer2 Kmer Analysis Proxy App

Performance-portable proxy application derived from [MetaHipMer2 (MHM2)](https://bitbucket.org/berkeleylab/mhm2/src/master/), an exascale *de novo* metagenome assembler developed at Lawrence Berkeley National Laboratory.

This application encapsulates the **kmer analysis stage** of the [MHM2 pipeline](https://www.nature.com/articles/s41598-020-67416-5/figures/7). Kmers are short DNA substrings of fixed length *k*, typically extracted from sequencing reads. They are a core data structure in genome assembly and many other bioinformatics workflows.

For a given set of FASTQ inputs and kmer length *k*, the app builds a distributed hash table of kmers. Keys are unique kmers; values store occurrence counts and the most probable single-base extensions. The result is a compact representation of kmer abundance and connectivity used by downstream assembly stages.

For background on the full MHM2 application, see the [JGI MetaHipMer page](https://jgi.doe.gov/data-and-tools/software-tools/metahipmer/) and the [MHM2 user guide](https://bitbucket.org/berkeleylab/mhm2/src/660ae5ab13f6a2c576b17d8c9925d44cffb98c6d/docs/mhm_guide.md). For Kokkos-specific design notes, see [kokkos_implementation.md](kokkos_implementation.md).

## Dependencies

### UPC++ (required)

MHM2 and this proxy are built on [UPC++](https://bitbucket.org/berkeleylab/upcxx/wiki/Home), a partitioned global address space (PGAS) library for C++.

- [Installation instructions](https://bitbucket.org/berkeleylab/upcxx/wiki/INSTALL)
- [Developer guide and documentation](https://bitbucket.org/berkeleylab/upcxx/wiki/README.md)

UPC++ uses [GASNet](https://bitbucket.org/berkeleylab/gasnet/src/stable/) for communication. On InfiniBand systems, UPC++ typically uses MPI for process spawning; you may need to build with an MPI compiler wrapper (see [Build](#build) below).

#### Example UPC++ configurations

**Power9 / NVIDIA V100** ([Lassen](https://hpc.llnl.gov/hardware/compute-platforms/lassen)):

```bash
../configure \
  --with-cxx="$(which mpicxx)" \
  --with-cc="$(which mpicc)" \
  --enable-udp \
  --enable-mpi \
  --enable-cuda \
  --enable-ibv \
  --with-cxxflags=-std=c++17 \
  --prefix="${INSTALL_DIR}"
```

**AMD MI300A** ([El Capitan / RZAdams](https://hpc.llnl.gov/hardware/compute-platforms/rzadams)):

```bash
# ROCm / Cray environment
export LD_LIBRARY_PATH="${CRAY_LD_LIBRARY_PATH}:${LD_LIBRARY_PATH}"

../configure \
  --with-cxx=mpicxx \
  --with-cc=mpicc \
  --with-pmi-rpath \
  --with-ofi-spawner=pmi \
  --enable-udp \
  --enable-hip \
  --enable-mpi \
  --enable-ofi \
  --with-cxxflags=-std=c++17 \
  --with-default-network=ofi \
  --with-ofi-provider=cxi \
  --prefix="${INSTALL_DIR}"
```

### Kokkos (recommended)

[Kokkos](https://kokkos.org/) provides a performance-portable programming model for GPU-accelerated kernels. This proxy includes a Kokkos implementation of key kmer-counting routines, allowing the same code to target NVIDIA and AMD GPUs while interoperating with UPC++ host code.

- [Kokkos releases](https://github.com/kokkos/kokkos/releases)
- [Quick start guide](https://kokkos.org/kokkos-core-wiki/quick_start.html)

Build this app and Kokkos with the **same compiler toolchain**.

## Build

### Clone the repository

```bash
git clone https://github.com/LoganWilliams1/mhm2_kmer_analysis_v2.git
cd mhm2_kmer_analysis_v2
```

Build and install with `scripts/build.sh` from the repository root. The script checks for UPC++, configures CMake, and installs the `mhm2` binary under `install_<BACKEND>_<KOKKOS_USE>/` in the repository (for example, `install_HIP_KOKKOS_ON/`).

```bash
./scripts/build.sh
KOKKOS_USE=KOKKOS_OFF ./scripts/build.sh
BACKEND=CPU KOKKOS_USE=KOKKOS_OFF ./scripts/build.sh
BACKEND=CPU KOKKOS_USE=KOKKOS_ON KOKKOS_INSTALL=/path/to/kokkos-openmp ./scripts/build.sh
```

Set `KOKKOS_USE` to `KOKKOS_ON` (default) or `KOKKOS_OFF`, and `BACKEND` to `CUDA` (default), `HIP`, or `CPU`:

| `BACKEND` | `KOKKOS_USE` | What you get |
|-----------|--------------|--------------|
| `CUDA` / `HIP` | `KOKKOS_OFF` | Native CUDA/HIP GPU kernels |
| `CUDA` / `HIP` | `KOKKOS_ON` | Kokkos GPU kernels (Kokkos built with CUDA/HIP) |
| `CPU` | `KOKKOS_OFF` | Host-only UPC++ (`kcount_cpu`); CUDA/HIP disabled in the app |
| `CPU` | `KOKKOS_ON` | Kokkos on a **host** ExecutionSpace only; CUDA/HIP disabled in the app. `KOKKOS_INSTALL` must be a Kokkos build with OpenMP/Serial/Threads and **no** CUDA/HIP/SYCL device backend (`build.sh` checks `KokkosCore_config.h`) |

Install prefixes are `install_<BACKEND>_<KOKKOS_USE>/` (for example `install_CPU_KOKKOS_OFF/`). On InfiniBand systems, the script uses `mpicxx`/`mpicc`; ensure UPC++ and Kokkos were built with the same toolchain. See the [UPC++ Linux configuration notes](https://bitbucket.org/berkeleylab/upcxx/wiki/INSTALL#markdown-header-configuration-linux).

Optional first argument (default `Release`): `Debug`, `RelWithDebInfo`, `clean`, or `cleanall`.

```bash
./scripts/build.sh clean
./scripts/build.sh cleanall
```

## Run

### Python wrapper

`scripts/mhm2.py` launches the installed `mhm2` binary via UPC++. A minimal run requires the number of UPC++ processes and at least one FASTQ input:

```bash
./scripts/mhm2.py -n 1 -p seqs_1.fastq seqs_2.fastq
```

#### Run options

| Option | Description |
|--------|-------------|
| `-n INT` | Number of UPC++ processes (**required**) |
| `-N INT` | Number of nodes (default: 1) |
| `-p FILE ...` | Separate paired-end reads; each R1 file must be immediately followed by its R2 mate |
| `-r FILE ...` | Interleaved paired-end reads |
| `-u FILE ...` | Unpaired reads |
| `-k INT` | Kmer length (default: 21) |
| `-o STRING` | Output directory (default: `mhm2-run-<READS>-n<PROCS>-N<NODES>-YYMMDDhhmmss-<JOBID>`) |
| `--use-qf=BOOL` | **Non-Kokkos GPU builds only.** When true, reduces GPU memory use at the cost of negligible variation in kmer counts. See [kokkos_implementation.md](kokkos_implementation.md). |

Example with two paired libraries:

```bash
./scripts/mhm2.py -n 4 -p lib1_1.fastq lib1_2.fastq lib2_1.fastq lib2_2.fastq
```

### Run script

For benchmark runs on El Dorado with preconfigured inputs and install paths:

```bash
./scripts/run.sh
RUN_BENCHMARK_LOOP=1 ./scripts/run.sh
BACKEND=CPU KOKKOS_USE=KOKKOS_OFF RUN_BENCHMARK_LOOP=1 ./scripts/run.sh
# Kokkos::OpenMP: --pin=spread; fair-share KOKKOS_NUM_THREADS=clamp(cores/ranks,2,16); OMP_* unset.
BACKEND=CPU KOKKOS_USE=KOKKOS_ON RUN_BENCHMARK_LOOP=1 ./scripts/run.sh
# Optional: OMP_NUM_THREADS_FIXED=4 MHM2_PIN=none ...
```

Environment variables:

| Variable | Description |
|----------|-------------|
| `KOKKOS_USE` | `KOKKOS_ON` (default) or `KOKKOS_OFF` |
| `BACKEND` | `CUDA` (default), `HIP`, or `CPU` (disables CUDA/HIP in the app) |
| `NUM_RANKS` | Number of UPC++ ranks (default: 2) |
| `NUM_RUNS` | Replicates per rank count (default: 3) |
| `RUN_BENCHMARK_LOOP` | If set, sweep ranks 1, 2, 4, …, 16 |
| `OMP_THREADS_PER_RANK` | CPU + `KOKKOS_ON`: max OpenMP threads per rank (default: `16`; fair-share uses `min(max, cores/ranks)`) |
| `OMP_THREADS_MIN` | CPU + `KOKKOS_ON`: min OpenMP threads per rank after fair-share (default: `2`) |
| `OMP_NUM_THREADS_FIXED` | CPU + `KOKKOS_ON`: if set, use this exact team size at every rank count (skip fair-share) |
| `MHM2_PIN` | CPU + `KOKKOS_ON`: default `spread` (partition physical cores across local ranks before Kokkos/OpenMP init). Other backends default to `none`. |

Results land under `results/<BACKEND>/results_<timestamp>_<hash>/` with per-rank dirs named `KOKKOS_{ON|OFF}_{BACKEND}_ranks_<N>` (for example `KOKKOS_ON_CPU_ranks_4/`). Each run writes `proxy_results_summary.csv` (read counts, kmer statistics, peak memory, timing).

Aggregate and plot batch results with `scripts/process_and_visualize.py` (for example `--compare --results-group H100 --backend CUDA`). Compare charts put the hardware name first in the legend (`--hardware`, or inferred from `--results-group`).

## Performance

Mean execution times of *mhm2-proxy* showing Kokkos versus native kmer-analysis performance across 1–16 UPC++ ranks (error bars: three-run standard deviation). **(a)** CUDA vs Kokkos::CUDA on NVIDIA Hopper. **(b)** HIP vs Kokkos::HIP on AMD MI300a. **(c)** Host-only UPC++ vs Kokkos::OpenMP on NVIDIA Grace. **(d)** Same as (c) on AMD Epyc.

![Kokkos vs native pipeline timing on Hopper, MI300a, Grace, and Epyc](docs/figures/pipeline_timing_cpu_gpu_vs_kokkos.png)

On Hopper, Kokkos matches native CUDA and pulls ahead at higher rank counts; the native path pays a growing per-rank GPU first-touch cost (`cudaMalloc` / full `cudaMemset`) that Kokkos avoids. On MI300a, Kokkos is faster at all ranks, helped by unified memory and skipping the native path’s first-touch preallocation. On Grace and Epyc, Kokkos::OpenMP wins strongly at low ranks; the gap narrows as work is already split across UPC++ ranks and each OpenMP team shrinks (Epyc runs use fair-share `KOKKOS_NUM_THREADS` with `--pin=spread`). Peak memory is also substantially lower for the Kokkos CPU builds.

Individual panels: [Hopper](docs/figures/pipeline_timing_cuda_vs_kokkos.png), [MI300a](docs/figures/pipeline_timing_hip_vs_kokkos.png), [Grace](docs/figures/pipeline_timing_grace_vs_kokkos.png), [Epyc](docs/figures/pipeline_timing_cpu_vs_kokkos.png).

## Docker (experimental)

Docker support is experimental. It is limited to a **single machine** and **CPUs only** (no GPUs).

Build a MetaHipMer image directly from the Bitbucket repository without cloning it locally:

```bash
docker build -t local/mhm2:latest https://bitbucket.org/berkeleylab/mhm2.git#master
```

To force a full rebuild and pick up the latest upstream changes, add `--no-cache`:

```bash
docker build --no-cache -t local/mhm2:latest https://bitbucket.org/berkeleylab/mhm2.git#master
```

When running the container, set `--shm-size` (typically 1–2 GB per process) and mount a host directory for inputs and outputs. On a 32-process run:

```bash
docker run --shm-size=32g --volume "${datadir}:/scratch" local/mhm2:latest \
  mhm2.py -r /scratch/arctic_sample_0.fq
```

Here `${datadir}` is the host directory containing input files; outputs are written there as well.

## Benchmark inputs

### Synthetic reads

- [ArcticSynth simulated sequences](https://portal.nersc.gov/project/hipmer/MetaHipMer_datasets_12_2019/ArcticSynth/)
- Described in [*Terabase-scale metagenome coassembly with MetaHipMer*](https://www.nature.com/articles/s41598-020-67416-5) and [supplemental materials](https://static-content.springer.com/esm/art%3A10.1038%2Fs41598-020-67416-5/MediaObjects/41598_2020_67416_MOESM1_ESM.pdf)

### NCBI Sequence Read Archive

| Study | Accession | Size |
|-------|-----------|------|
| [Gut microbiota in long-lived humans (2020)](https://pubmed.ncbi.nlm.nih.gov/32209716/) | [SRR9654970](https://www.ncbi.nlm.nih.gov/sra/?term=SRR9654970) (PRJNA553191) | 1.8 GB |
| [Ovine gut microbes](https://pubmed.ncbi.nlm.nih.gov/24170804/) | [SRX331704](https://www.ncbi.nlm.nih.gov/sra/?term=SRX331704) (PRJNA214227) | — |
| [Terabase-scale metagenome coassembly](https://pubmed.ncbi.nlm.nih.gov/32612216/) | [SRR5819383](https://www.ncbi.nlm.nih.gov/sra/SRR5819383) (PRJNA367436) | 15.9 GB |

Install the [SRA Toolkit](https://github.com/ncbi/sra-tools/wiki/02.-Installing-SRA-Toolkit) to download reads from the [Short Read Archive](https://www.ncbi.nlm.nih.gov/sra).

## Further reading

MHM2 runs efficiently on single nodes and at exascale, scaling to terabase-sized metagenome coassemblies. Key publications:

- [E. Georganas et al., "Extreme Scale De Novo Metagenome Assembly," SC18, 2018.](https://ieeexplore.ieee.org/document/8665813)
- [Hofmeyr, S. et al., "Terabase-scale metagenome coassembly with MetaHipMer," *Scientific Reports*, 2020.](https://www.nature.com/articles/s41598-020-67416-5)
- [Awan, M.G. et al., "ADEPT: a domain independent sequence alignment strategy for gpu architectures," *BMC Bioinformatics*, 2020.](https://bmcbioinformatics.biomedcentral.com/articles/10.1186/s12859-020-03720-1)
- [Muaaz Awan et al., "Accelerating large scale de novo metagenome assembly using GPUs," SC 2021.](https://dl.acm.org/doi/pdf/10.1145/3458817.3476212)
- [F. Meyer et al., "Critical Assessment of Metagenome Interpretation: the second round of challenges," *Nature Methods*, 2022.](https://www.nature.com/articles/s41592-022-01431-4) — MetaHipMer ranked first for quality on two of three CAMI2 datasets.

MHM2 is developed by the [ExaBiome Project](https://sites.google.com/lbl.gov/exabiome/) and supported by the [Exascale Computing Project](https://www.exascaleproject.org) (17-SC-20-SC).

## Point of contact

For questions about this proxy application:

- Amy Powell — [ajpowel@sandia.gov](mailto:ajpowel@sandia.gov)
