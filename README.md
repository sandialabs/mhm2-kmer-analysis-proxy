## mhm2-kmer-analysis-proxy

This performance-portable proxy application is based on the CUDA implementation of the [*k*-mer analysis routine](https://www.nature.com/articles/s41598-020-67416-5/figures/7) in [MetaHipMer2 (MHM2)](https://bitbucket.org/berkeleylab/mhm2/src/master/), an exascale *de novo* metagenome assembler.

Given FASTQ or FASTA input sequences and *k*-mer length *k*, the application constructs a distributed hash table (DHT) of *k*-mers. The keys in the table are unique *k*-mers, and values store occurrence counts together with left and right single-base extensions. 

This DHT is a compact representation of *k*-mer abundance and connectivity used in downstream assembly stages.

## Dependencies

#### UPC++ (required)

MHM2 and this proxy are built on [UPC++](https://github.com/BerkeleyLab/upcxx/wiki), a C++ library for partitioned global address space (PGAS). UPC++ is for CPU only.

- [Download Current Stable Release](https://github.com/BerkeleyLab/upcxx/releases/download/upcxx-2025.10.0/upcxx-2025.10.0.tar.gz)
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

```text

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
**Representative AMD environment**:

```text
module list

Currently Loaded Modules:
  1) craype-x86-trento        5) craype/2.7.35           9) flux_wrappers/0.1  13) cray-dsmml/0.3.1     17) cray-mpich/9.0.1
  2) libfabric/match_SHS      6) PrgEnv-cray/8.7.0      10) cmake/3.24.2       14) cray-pmi/6.1.16      18) cray-openshmemx/11.8.0
  3) craype-network-ofi       7) xpmem/2.6.5            11) git/2.29.1         15) cce/18.0.1           19) rocm/6.3.1
  4) perftools-base/25.09.0   8) StdEnv            (S)  12) python/3.13.2      16) cray-libsci/25.03.0

  Where:
   S:  Module is Sticky, requires --force to unload or purge
```

#### Put UPC++ in `${PATH}`
Put UPC++ executables in `${PATH}`:

```bash
# export UPC++ installation point
export UPCXX_INSTALL=${PROJECT_WORKSPACE}/upcxx_install_eldorado_cce_2000_cray_mpich_901_HIP_631_MI300A_cxx_20_2026_06_24
 # put UPC++ executables in ${PATH}
export PATH=${UPCXX_INSTALL}/bin:${PATH}
```
#### Kokkos
[Kokkos](https://kokkos.org/) is a C++ performance-portability library that supports a single-source programming model, allowing developers to write portable parallel code in Kokkos instead of maintaining hardware-specific implementations (*e.g.*, CUDA or HIP).

- [Kokkos releases](https://github.com/kokkos/kokkos/releases)
- [Quick start guide](https://kokkos.org/kokkos-core-wiki/quick_start.html)
- [Kokkos Configuration for Various Hardware Targets](https://kokkos.org/kokkos-core-wiki/get-started/configuration-guide.html)

Build this application and Kokkos with the **same compiler toolchain**, using MPI wrapper compilers for the host C and C++ compilers. Set `KOKKOS_INSTALL` to the Kokkos installation root (*i.e.*, the installation prefix passed to Kokkos at install time).

If the target CPU microarchitecture is not known, `Kokkos_ARCH_NATIVE=ON` can be used during Kokkos configuration.

#### Example Kokkos configurations

**NVIDIA**

```bash
# NVIDIA h100
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
# AMD MI300A APU
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

#### Clone the repository

```bash
git clone https://github.com/sandialabs/mhm2-kmer-analysis-proxy.git
cd mhm2-kmer-analysis-proxy
# For required submodules `contrib/seqtk`, `upcxx-utils` and `zstr`
git submodule update --init --recursive
```


#### Check environment

Before building, verify that the MPI wrapper compilers are available in `PATH` and that you know the installation prefixes for UPC++ and Kokkos.

```bash
# check MPI wrapper compilers
$ which mpicxx
# /path/to/mpicxx
$ which mpicc
# /path/to/mpicc

# Check installation prefixes for the main dependencies

$ echo $UPCXX_INSTALL
# path/to/upcxx

$ echo $KOKKOS_INSTALL
# path/to/kokkos

```
#### Build with `build_kmer_proxy.sh` script
Build and install with `build_kmer_proxy.sh` script at the repository root. The script validates the specified UPC++ and Kokkos installations, resolves the requested C and C++ compilers, configures CMake, builds the proxy application, and installs it under the user-specified `--install-prefix` (the default install location is the `install` directory at the repository root). 

The script uses `.build` as the build directory. Kokkos is enabled by default; setting `--kokkos-usage off` builds and runs with the raw backend (*e.g.*, CUDA, HIP). 

[!NOTE]
If oneAPI toolchain and SYCL build instructions are needed, contact the corresponding author.

#### Build script help 

```bash
# From repository root
./build_kmer_proxy --help
```

#### Usage

The build script supports four invocations:

```text
./build_kmer_proxy.sh [build] --kokkos-installation PATH --upcxx-installation PATH --cc <COMPILER --cxx COMPILER --build-type TYPE --cxxstd STD --install-prefix PATH [options]
./build_kmer_proxy.sh clean
./build_kmer_proxy.sh cleanall
./build_kmer_proxy.sh --help
```
#### Build script arguments

#### Required options

| Option | Value | Description | Allowed values / notes |
|---|---|---|---|
| `--kokkos-installation` | `PATH` | Path to the installed Kokkos prefix. | Kokkos must already be built and installed. |
| `--upcxx-installation` | `PATH` | Path to the installed UPC++ prefix. | UPC++ must already be built and installed. |
| `--cc` | `COMPILER` | C compiler to use. | Usually `mpicc`. |
| `--cxx` | `COMPILER` | C++ compiler to use. | Usually `mpicxx`. |
| `--build-type` | `TYPE` | CMake build type. | `Debug`, `Release`, or `RelWithDebInfo` |
| `--cxxstd` | `STD` | C++ standard to use. | `17` or `20` |
| `--install-prefix` | `PATH` | Installation prefix for the proxy build. | Install destination for the built proxy application. |

#### Optional options

| Option | Value | Description | Default / notes |
|---|---|---|---|
| `--kokkos-usage` | `on\|off` | Enable or disable Kokkos usage in the proxy build. | Default: `on` |
| `--jobs` | `N` | Number of parallel build jobs. | Must be a positive integer. |
| `--verbose` | — | Enable verbose build output. |  |
| `--dry-run` | — | Print the resolved configuration and build commands, but do not run them. |  |

#### Actions

| Action | Description | Notes |
|---|---|---|
| `build` | Configure, build, and install the proxy application. | Default action. |
| `clean` | Remove build artifacts. |  |
| `cleanall` | Remove build artifacts and installation-side CMake artifacts. |  |
| `--help` | Show the help message and exit. |  |



#### Example build command
```bash
./build_kmer_proxy \
  --kokkos-installation /path/to/kokkos \
  --upcxx-installation /path/to/upcxx \
  --cc mpicc \
  --cxx mpicxx \
  --build-type Release \
  --cxxstd 20 \
  --install-prefix /path/to/install
```

## Running the proxy

Use either `mhm2.py` or the `mhm2` executable directly to run the proxy; both are installed under `install/bin`. `mhm2.py` is a convenience wrapper that launches the installed binary via UPC++ and manages common launch settings, while direct execution with `upcxx-run` provides full control over the runtime configuration. The table below distinguishes `mhm2.py` wrapper options from options passed directly to the `mhm2` executable. To date, this proxy application has only been tested and exercised on a single node. The following examples assume the current working directory is `install/bin`.

```bash
# Run with the Python wrapper
./mhm2.py \
  --procs 1 \
  -p seqs_1.fastq seqs_2.fastq
```

```bash
# Run the executable directly
upcxx-run \
  -n ${NUM_RANKS} \
  -shared-heap "250MB" \
  -network=smp \
  ./mhm2 \
  --pin=none \
  --paired-reads \
  reads_1.fastq \
  reads_2.fastq \
  --output "${PROXY_OUTPUT}"
```

#### Run options

| Category | Option | Description | Notes / default |
|---|---|---|---|
| Wrapper | `--auto-resume` | Automatically resume after a failure. |  |
| Wrapper | `--shared-heap SHARED_HEAP` | Shared heap size as a percentage of memory or in MB. | Examples: `10%`, `250MB` |
| Wrapper | `--procs PROCS` | Total number of UPC++ processes. | Required for controlled launch configuration |
| Wrapper | `--nodes NODES` | Override the detected number of nodes. | Default: detected from the job environment |
| Wrapper | `--gasnet-stats` | Collect GASNet communication statistics. |  |
| Wrapper | `--gasnet-trace` | Collect GASNet trace output in separate files. |  |
| Wrapper | `--preproc PREPROC` | Comma-separated preprocessors and options, or options to `upcxx-run` before the binary. |  |
| Wrapper | `--binary BINARY` | File name for the UPC++ binary to launch. | Default: `mhm2` |
| Binary | `-r`, `--reads FILE ...` | Interleaved paired reads in FASTQ format. | At least one of `-r`, `-p`, or `-u` must be provided |
| Binary | `-p`, `--paired-reads FILE ...` | Separate paired-end reads in FASTQ format. | Each R1 file must be immediately followed by its matching R2 file |
| Binary | `-u`, `--unpaired-reads FILE ...` | Unpaired or single-end reads in FASTQ format. |  |
| Binary | `-k`, `--kmer-lens INT` | K-mer length. | Default: `21` |
| Binary | `-o`, `--output DIR` | Output directory. | If not specified, the binary creates a default output directory name |
| Binary | `--adapter-refs FILE` | Adapter reference sequences in FASTA format for trimming. |  |
| Binary | `--progress` | Show progress bars for operations. |  |
| Binary | `-v`, `--verbose` | Enable verbose output. |  |
| Binary | `--use-qf` | Use a quotient filter to reduce memory usage at the cost of slower processing. | Applies only to GPU builds |

[!NOTE] `mhm2.py` is a general MHM2 launcher. When used with this proxy application, it may still perform post-run checks intended for full assembly workflows.


## Inputs

#### Synthetic reads

- [ArcticSynth synthetic sequences](https://portal.nersc.gov/project/hipmer/MetaHipMer_datasets_12_2019/ArcticSynth/)
- Described in [*Terabase-scale metagenome coassembly with MetaHipMer*](https://www.nature.com/articles/s41598-020-67416-5) and [supplemental materials](https://static-content.springer.com/esm/art%3A10.1038%2Fs41598-020-67416-5/MediaObjects/41598_2020_67416_MOESM1_ESM.pdf)

#### NCBI Sequence Read Archive

| Study                                                                                    | SRA Archive Accession Number                                     |   
|------------------------------------------------------------------------------------------|------------------------------------------------------------------|
| [Ovine gut microbial ecosystem (2014)](https://pubmed.ncbi.nlm.nih.gov/24170804/)        | SRX331704 (multiple entries)
| [Terabase-scale metagenome coassembly (2020)](https://pubmed.ncbi.nlm.nih.gov/32612216/) | [SRR5819383](https://www.ncbi.nlm.nih.gov/sra/SRR5819383)

Install the [SRA Toolkit](https://github.com/ncbi/sra-tools/wiki/02.-Installing-SRA-Toolkit) to download read sets from the [Sequence Read Archive](https://www.ncbi.nlm.nih.gov/sra).

## Point of contact

For questions about this proxy application:

- Amy Powell — [ajpowel@sandia.gov](mailto:ajpowel@sandia.gov)
