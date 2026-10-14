# mhm2-kmer-analysis proxy application

Our performance-portable proxy application is based on the CUDA implementation of the [*k*-mer analysis routine](https://www.nature.com/articles/s41598-020-67416-5/figures/7) in [MetaHipMer2 (MHM2)](https://bitbucket.org/berkeleylab/mhm2/src/master/), an exascale *de novo* metagenome assembler.

For FASTQ/FASTA inputs and kmer length *k*, the app builds a distributed hash table (DHT) of kmers. Keys are unique kmers, and values store occurrence counts and left and right single-base extensions. 

The DHT is a compact representation of kmer abundance and connectivity used in downstream assembly stages.

For background on the full MHM2 application, see the [JGI MetaHipMer page](https://jgi.doe.gov/data-and-tools/software-tools/metahipmer/) and the [MHM2 user guide](https://bitbucket.org/berkeleylab/mhm2/src/660ae5ab13f6a2c576b17d8c9925d44cffb98c6d/docs/mhm_guide.md).
## Dependencies

### UPC++ (required)

MHM2 and this proxy are built on [UPC++](https://github.com/BerkeleyLab/upcxx/wiki), a partitioned global address space (PGAS) library for C++ (CPU only).

- [Download](https://github.com/BerkeleyLab/upcxx/releases/download/upcxx-2025.10.0/upcxx-2025.10.0.tar.gz)
- [Installation instructions](https://github.com/BerkeleyLab/upcxx/wiki/site-docs)
- [Programmer's Guide](https://upcxx.lbl.gov/docs/html/guide.html)

We used `upcxx-2025-10.10` in the work reported here. UPC++ uses "Message Passing Interface" (MPI) for process spawning, and MPI compiler wrappers are required for building (below).

#### Example UPC++ configurations

**NVIDIA**:

```bash
# For H100 GPU
export CXXFLAGS="-std=c++20"
export CXX=`which mpicxx`
export CC=`which mpicc`
 
../configure \
--with-cxx="${CXX}" \
--with-cc="${CC}" \
--with-cxxflags="${CXXFLAGS}" \
--enable-cuda \
--disable-ibv \
--disable-ofi \
--with-default-network=smp \
--with-gasnet=https://bitbucket.org/berkeleylab/gasnet/downloads/GASNet-stable.tar.gz \
--prefix=${INSTALL_DIR}
```
**Representative CUDA environment**

```bash

module list
Currently Loaded Modules:
  1) cmake/3.31.8   2) git/2.41.0   3) gcc/13.3.0   4) openmpi/5.0.3   5) cuda/13.0.0
````

**AMD**:

```bash
# ROCm / Cray environment with cray-mpich
export LD_LIBRARY_PATH="${CRAY_LD_LIBRARY_PATH}:${LD_LIBRARY_PATH}"

export CXXFLAGS="-std=c++20"
#export CXXFLAGS="-std=c++17"
export CXX=$(which mpicxx)
export CC=$(which mpicc)
#export CUDACXX=`which nvcc`
 
 
../configure \
--with-cxx="${CXX}" \
--with-cc="${CC}" \
--with-cxxflags="${CXXFLAGS}" \
--disable-cuda \
--disable-ibv \
--enable-hip \
--enable-ofi \
--with-default-network=ofi \
--prefix=${INSTALL_DIR}
```
**Representative AMD Environment**:

```bash
module list

Currently Loaded Modules:
  1) craype-x86-trento        5) craype/2.7.35           9) flux_wrappers/0.1  13) cray-dsmml/0.3.1     17) cray-mpich/9.0.1
  2) libfabric/match_SHS      6) PrgEnv-cray/8.7.0      10) cmake/3.24.2       14) cray-pmi/6.1.16      18) cray-openshmemx/11.8.0
  3) craype-network-ofi       7) xpmem/2.6.5            11) git/2.29.1         15) cce/18.0.1           19) rocm/6.3.1
  4) perftools-base/25.09.0   8) StdEnv            (S)  12) python/3.13.2      16) cray-libsci/25.03.0

  Where:
   S:  Module is Sticky, requires --force to unload or purge

```

### Put UPC++ in `${PATH}`

Put UPC++ executables in `${PATH}`:

```bash
# export UPC++ installation point
export UPCXX_INSTALL=${PROJECT_WORKSPACE}/upcxx_install_eldorado_cce_2000_cray_mpich_901_HIP_631_MI300A_cxx_20_2026_06_24
 # put UPC++ executables in ${PATH}
export PATH=${UPCXX_INSTALL}/bin:${PATH}
```

### Kokkos

[Kokkos](https://kokkos.org/) is a C++ performance portability library supporting single-source implementation, meaning the developer writes code in Kokkos instead of hardware-specific versions.
- [Kokkos releases](https://github.com/kokkos/kokkos/releases)
- [Quick start guide](https://kokkos.org/kokkos-core-wiki/quick_start.html)
- [Kokkos Configuration for Various Hardware Targets](https://kokkos.org/kokkos-core-wiki/get-started/configuration-guide.html)

Build this app and Kokkos with the **same compiler toolchain**, making sure to use MPI wrappers as the CXX compiler. If the specific details about your CPU target hardware are not known, then `Kokkos_ARCH_NATIVE=ON` configuration option can be used.

#### Example Kokkos configurations

**NVIDIA**

```bash
# h100
export CXX=$(which mpicxx)

 cmake \
    -DCMAKE_CXX_STANDARD=20 \
    -DCMAKE_CXX_COMPILER=${CXX} \
    -DKokkos_ARCH_HOPPER90=ON \
    -DKokkos_ENABLE_SERIAL=ON \
    -DKokkos_ENABLE_CUDA=ON \
    -DCMAKE_INSTALL_PREFIX=${INSTALL_DIR} \
    -DCMAKE_BUILD_TYPE=Release ..
```

**AMD**

```bash
# MI300A APU
export CC=$(which mpicc)
export CXX=$(which mpicxx)
export CXXFLAGS="-Wall -Wshadow -Wsign-compare -Wtype-limits -Wignored-qualifiers -Wempty-body -Wclobbered -Wuninitialized -Wmaybe-uninitialized"
 
cmake \
    -DCRAYPE_LINK_TYPE=dynamic \
    -DKokkos_ENABLE_BENCHMARKS=OFF \
    -DKokkos_ENABLE_HIP=ON \
    -DKokkos_ARCH_AMD_GFX942_APU=ON \
    -DKokkos_ENABLE_SERIAL=ON \
    -DCMAKE_CXX_STANDARD="${CXXSTD}" \
    -DCMAKE_CXX_COMPILER="${CXX}" \
    -DCMAKE_CXX_FLAGS=${CXXFLAGS} \
    -DCMAKE_INSTALL_PREFIX=${INSTALL_DIR} \
    -DCMAKE_BUILD_TYPE=Release ..
```

## Build

### Clone the repository

```bash
git clone https://github.com/sandialabs/mhm2-kmer-analysis-proxy.git
cd mhm2-kmer-analysis-proxy
# For required submodules `contrib/seqtk`, `upcxx-utils` and `zstr`
git subumodule update --init --recursive
```



Build and install with `build_kmer` script at the repository root. The script checks for UPC++, configures CMake, and installs the `mhm2` binary under `install` in the repository (for example, `install_HIP_KOKKOS_ON/`).

#### Check Envirnoment
```bash
# check MPI wrappers
$ which mpicxx
... /openmpi/5.0.3/gcc/13.3.0/base/aa3z356/bin/mpicxx
$ which mpicc
... /openmpi/5.0.3/gcc/13.3.0/base/aa3z356/bin/mpicc

# Check main dependencies, namely UPC++ and Kokkos

$ echo $UPCXX_INSTALL
... /upcxx_install_gcc_1330_openmpi_503_CUDA_1300_H100_2026_06_16

$ echo $KOKKOS_INSTALL
... /kokkos_install_h100_gcc_1330_mpi_503_cuda_1300_gpu_H100_cxx_20_2026-06-16

```
#### Build with build_kmer_proxy Script
Build and install with `build_kmer` script at the repository root. The script checks for UPC++, configures CMake, and installs the `mhm2` binary under `install` directory in the repository. Your build directory is `.build` (for debugging purposes). Kokkos is on by default; setting `--kokkos-usage off` means building and running with the raw backend (e.g., CUDA, HIP). 

```bash
./build_kmer_proxy \
  --kokkos-installation "${KOKKOS_INSTALL}" \
  --upcxx-installation "${UPCXX_INSTALL}" \
  --cc "$(which mpicc)" \
  --cxx "$(which mpicxx)" \
  --build-type Release \
  --cxxstd 20 \
  --kokkos-usage on \
  --install-prefix "${PWD}/install" \
  --jobs 16               
```



#### Build Script Help 

```bash
# You are here

pwd
mhm2-kmer-analysis-proxy

# Call help

$ ./build_kmer_proxy --help
Usage:
  build_kmer_proxy [build] --kokkos-installation PATH --upcxx-installation PATH --cc COMPILER --cxx COMPILER --build-type TYPE --cxxstd STD --install-prefix PATH [options]
  build_kmer_proxy clean
  build_kmer_proxy cleanall
  build_kmer_proxy --help

Required arguments:
  --kokkos-installation PATH
      Path to the installed Kokkos prefix.

  --upcxx-installation PATH
      Path to the installed UPC++ prefix.

  --cc COMPILER
      C compiler to use.
      Hint: this is usually mpicc.

  --cxx COMPILER
      C++ compiler to use.
      Hint: this is usually mpicxx.

  --build-type TYPE
      CMake build type. Must be one of:
        Debug
        Release
        RelWithDebInfo

  --cxxstd STD
      C++ standard to use. Must be one of:
        17
        20

  --install-prefix PATH
      Installation prefix for the proxy build.

Optional arguments:
  --kokkos-usage {on|off}
      Enable or disable Kokkos usage in the proxy build.
      Default: on

  --jobs N
      Number of parallel build jobs.

  --verbose
      Enable verbose build output.

  --dry-run
      Print the resolved configuration and build commands, but do not run them.

Actions:
  build
      Configure, build, and install the proxy application.
      This is the default action.

  clean
      Remove build artifacts.

  cleanall
      Remove build artifacts and installation-side CMake artifacts.

  --help
      Show this help message and exit.

Notes:
  - The Kokkos backend is determined by the installed Kokkos build.
  - The script will derive the needed Kokkos CMake variables from
    --kokkos-installation.
  - UPC++ and Kokkos are assumed to already be built.
```


## Running the mhm2 Executable

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

# TODO
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





## Benchmark inputs

### Synthetic reads

- [ArcticSynth simulated sequences](https://portal.nersc.gov/project/hipmer/MetaHipMer_datasets_12_2019/ArcticSynth/)
- Described in [*Terabase-scale metagenome coassembly with MetaHipMer*](https://www.nature.com/articles/s41598-020-67416-5) and [supplemental materials](https://static-content.springer.com/esm/art%3A10.1038%2Fs41598-020-67416-5/MediaObjects/41598_2020_67416_MOESM1_ESM.pdf)

### NCBI Sequence Read Archive

| Study | Accession | Size |
|-------|-----------|------|
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
