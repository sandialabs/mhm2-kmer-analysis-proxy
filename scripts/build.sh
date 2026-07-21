#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

# Project root directory (contains input files and Kokkos installation)
export PROJECT_ROOT="${PROJECT_ROOT:=/projects/wg-proxy-apps}"
# Backend: CUDA (NVIDIA), HIP (AMD), or CPU (no CUDA/HIP in the app).
# Pair with KOKKOS_ON/OFF independently:
#   CPU + KOKKOS_OFF  -> classic host kcount (UPC++ only)
#   CPU + KOKKOS_ON   -> Kokkos kernels on a host ExecutionSpace (OpenMP/Serial/Threads)
export BACKEND="${BACKEND:=CUDA}"
export KOKKOS_USE="${KOKKOS_USE:=KOKKOS_ON}"

case "${BACKEND}" in
  CUDA|HIP|CPU) ;;
  *)
    echo "ERROR: BACKEND must be CUDA, HIP, or CPU (got '${BACKEND}')." >&2
    exit 1
    ;;
esac

case "${KOKKOS_USE}" in
  KOKKOS_ON|KOKKOS_OFF) ;;
  *)
    echo "ERROR: KOKKOS_USE must be KOKKOS_ON or KOKKOS_OFF (got '${KOKKOS_USE}')." >&2
    exit 1
    ;;
esac

# mhm2 proxy install directory
PROXY_INSTALL="${ROOT}/install_${BACKEND}_${KOKKOS_USE}"

# The project uses find_package(UPCXX), which injects the correct GASNet/MPI
# compile and link flags. That CMake integration requires CMAKE_CXX_COMPILER to
# be the SAME backend compiler UPC++ was built with (not the upcxx wrapper),
# otherwise UPCXXConfig.cmake fails its compiler-compatibility check. Query the
# matching compilers straight from upcxx-meta so they always line up.
upcxx_meta="$(command -v upcxx-meta || true)"
if [ -z "${upcxx_meta}" ]; then
  echo "ERROR: could not locate upcxx-meta. Add upcxx to PATH." >&2
  exit 1
fi
export CXX="${CXX:-$("${upcxx_meta}" CXX)}"
export CC="${CC:-$("${upcxx_meta}" CC)}"
if [ -z "${CXX}" ] || [ -z "${CC}" ]; then
  echo "ERROR: upcxx-meta did not report CC/CXX. Set CC and CXX explicitly." >&2
  exit 1
fi
export PROXY_KOKKOS_INSTALL="${PROXY_INSTALL}"
export MHM2_INSTALL_PATH="${PROXY_KOKKOS_INSTALL}"

# Default Kokkos install depends on the app backend. Override KOKKOS_INSTALL to
# use a different one. CPU+KOKKOS_ON must point at a host-only Kokkos build
# (OpenMP / Serial / Threads — no CUDA/HIP/SYCL device backend).
case "${BACKEND}" in
  CUDA) KOKKOS_INSTALL_DEFAULT="${HOME}/Kokkos/kokkos/install-hopper" ;;
  HIP)  KOKKOS_INSTALL_DEFAULT="${HOME}/Kokkos/kokkos/install-mi300a" ;;
  CPU)  KOKKOS_INSTALL_DEFAULT="${KOKKOS_CPU_INSTALL:-${HOME}/Kokkos/kokkos/install-cpu}" ;;
esac

if [ "${KOKKOS_USE}" = "KOKKOS_ON" ]; then
  export KOKKOS_INSTALL="${KOKKOS_INSTALL:=${KOKKOS_INSTALL_DEFAULT}}"
  CXXSTD=20
  ENABLE_KOKKOS=ON
else
  # KOKKOS_OFF does not link Kokkos; leave install unset unless the user set it.
  if [ "${BACKEND}" = "CPU" ]; then
    export KOKKOS_INSTALL="${KOKKOS_INSTALL:-}"
  else
    export KOKKOS_INSTALL="${KOKKOS_INSTALL:=${KOKKOS_INSTALL_DEFAULT}}"
  fi
  CXXSTD=17
  ENABLE_KOKKOS=OFF
fi

if [ -n "${KOKKOS_INSTALL}" ]; then
  export KOKKOS_CMAKE_MODULE_DIR="${KOKKOS_INSTALL}/lib64/cmake/Kokkos"
else
  export KOKKOS_CMAKE_MODULE_DIR=""
fi

# CUDA compute capability for the target GPU (H100/hopper = 90). Set explicitly
# so the build does not fall back to "native" arch detection, which fails on a
# login node with no visible GPU.
CUDA_ARCH="${CUDA_ARCH:-90}"
CUDA_ARCH_FLAG=""
if [ "${BACKEND}" = "CUDA" ] && [ -n "${CUDA_ARCH}" ]; then
  CUDA_ARCH_FLAG="-DCMAKE_CUDA_ARCHITECTURES=${CUDA_ARCH}"
fi

# Force CPU-only app builds even when nvcc/hipcc are on PATH.
GPU_ENABLE_FLAGS=""
if [ "${BACKEND}" = "CPU" ]; then
  GPU_ENABLE_FLAGS="-DENABLE_CUDA=OFF -DENABLE_HIP=OFF"
fi

# For CPU + KOKKOS_ON, require a host-parallel Kokkos install (no device backend).
_check_cpu_kokkos_install() {
  local install_dir=$1
  local cfg="${install_dir}/include/KokkosCore_config.h"
  if [ ! -f "${cfg}" ]; then
    echo "ERROR: Kokkos CPU install missing ${cfg}" >&2
    echo "Set KOKKOS_INSTALL (or KOKKOS_CPU_INSTALL) to a host-only Kokkos prefix." >&2
    exit 1
  fi
  if grep -qE '^#define KOKKOS_ENABLE_(CUDA|HIP|SYCL)\b' "${cfg}"; then
    echo "ERROR: ${install_dir} enables a Kokkos device backend (CUDA/HIP/SYCL)." >&2
    echo "BACKEND=CPU KOKKOS_USE=KOKKOS_ON requires a Kokkos build with only" >&2
    echo "host parallel backends (OPENMP, SERIAL, and/or THREADS)." >&2
    exit 1
  fi
  if ! grep -qE '^#define KOKKOS_ENABLE_(OPENMP|SERIAL|THREADS)\b' "${cfg}"; then
    echo "ERROR: ${install_dir} has no host parallel Kokkos backend enabled." >&2
    echo "Rebuild Kokkos with -DKokkos_ENABLE_OPENMP=ON (preferred) or SERIAL/THREADS." >&2
    exit 1
  fi
  echo "Kokkos CPU backends from ${cfg}:"
  grep -E '^#define KOKKOS_ENABLE_(OPENMP|SERIAL|THREADS|CUDA|HIP|SYCL)\b' "${cfg}" || true
}

if [ "${BACKEND}" = "CPU" ] && [ "${KOKKOS_USE}" = "KOKKOS_ON" ]; then
  if [ -z "${KOKKOS_INSTALL}" ]; then
    echo "ERROR: BACKEND=CPU KOKKOS_USE=KOKKOS_ON requires KOKKOS_INSTALL" >&2
    echo "(host-only Kokkos with OpenMP/Serial/Threads, not a GPU Kokkos install)." >&2
    exit 1
  fi
  _check_cpu_kokkos_install "${KOKKOS_INSTALL}"
fi

BUILD_CMD="${1:-Release}"
INSTALL_PATH="${MHM2_INSTALL_PATH}"
BINARY="${MHM2_BINARY:=mhm2}"

# UPCXXConfig.cmake reads these to decide which UPC++ library variant/flags to
# emit for the linked targets. Map the CMake build type to the code mode and
# default the network to the conduit this install was built with.
case "${BUILD_CMD}" in
  Debug) export UPCXX_CODEMODE="${UPCXX_CODEMODE:-debug}" ;;
  *)     export UPCXX_CODEMODE="${UPCXX_CODEMODE:-opt}" ;;
esac
export UPCXX_NETWORK="${UPCXX_NETWORK:-smp}"

if [ -n "${MHM2_BUILD_ENV:-}" ]; then
  echo "Source ${MHM2_BUILD_ENV}"
  # shellcheck source=/dev/null
  source "${MHM2_BUILD_ENV}"
fi

upcxx_exec="$(which upcxx)"
if [ -z "${upcxx_exec}" ]; then
  echo "upcxx not found. Please install or set path."
  exit 1
fi

upcxx_exec_canonical="$(readlink -f "${upcxx_exec}")"
if [ "${upcxx_exec_canonical}" != "${upcxx_exec}" ]; then
  echo "Found symlink for upcxx - using target at ${upcxx_exec_canonical}"
  export PATH="$(dirname "${upcxx_exec_canonical}"):${PATH}"
fi

# Pin a plain host C/C++ compiler (a bare gcc/g++, not the MPI wrapper). This is
# used for two things:
#   1. As the backend for the OpenMPI compiler wrappers (OMPI_CC/OMPI_CXX), so
#      the wrapper's backend gcc matches any loaded gcc module's GCC_ROOT.
#      Otherwise a wrapper backed by a different gcc gets its internal header
#      search redirected and fails with e.g. "stddef.h: No such file".
#   2. As nvcc's host compiler (CMAKE_CUDA_HOST_COMPILER). nvcc picks its host
#      compiler from PATH independent of CMAKE_CXX_COMPILER, so without this it
#      can grab an unsupported gcc (e.g. CUDA 12.6 rejects gcc > 13).
CUDA_HOST_CXX="${CUDA_HOST_CXX:-${OMPI_CXX:-$(command -v g++ || true)}}"
CUDA_HOST_CC="${CUDA_HOST_CC:-${OMPI_CC:-$(command -v gcc || true)}}"
if [ -n "${CUDA_HOST_CXX}" ]; then export OMPI_CXX="${OMPI_CXX:-${CUDA_HOST_CXX}}"; fi
if [ -n "${CUDA_HOST_CC}" ]; then export OMPI_CC="${OMPI_CC:-${CUDA_HOST_CC}}"; fi
# CMake picks nvcc's host compiler from the CUDAHOSTCXX environment variable
# during CUDA language detection (this is CMAKE_CUDA_HOST_COMPILER_ENV_VAR).
# Passing -DCMAKE_CUDA_HOST_COMPILER on the command line is NOT honored reliably,
# so export the env var to guarantee nvcc uses a supported gcc (-ccbin).
if [ -n "${CUDA_HOST_CXX}" ]; then export CUDAHOSTCXX="${CUDAHOSTCXX:-${CUDA_HOST_CXX}}"; fi
if [ -n "${CUDA_HOST_CXX}" ]; then
  echo "Host C++ compiler for OpenMPI/nvcc: ${CUDA_HOST_CXX} ($(${CUDA_HOST_CXX} -dumpfullversion 2>/dev/null || echo '?'))"
fi

# GASNet in this UPC++ install enables the MPI bootstrap even for the smp
# conduit (GASNET_LD_REQUIRES_MPI=1; libgasnet-*-seq.a contains
# gasnet_bootstrap_mpi). GASNet therefore expects the final link to go through
# mpicc/mpicxx so -lmpi is pulled in. With CUDA separable compilation the link
# often bypasses the MPI wrapper and fails with undefined references to
# MPI_Finalized / MPI_Abort. Inject the wrapper's link flags explicitly.
MPI_LINK_FLAGS="${MPI_LINK_FLAGS:-}"
if [ -z "${MPI_LINK_FLAGS}" ]; then
  if command -v mpicxx >/dev/null 2>&1; then
    MPI_LINK_FLAGS="$(mpicxx --showme:link 2>/dev/null || true)"
  elif command -v mpicc >/dev/null 2>&1; then
    MPI_LINK_FLAGS="$(mpicc --showme:link 2>/dev/null || true)"
  fi
fi
if [ -n "${MPI_LINK_FLAGS}" ]; then
  echo "MPI link flags (GASNet bootstrap): ${MPI_LINK_FLAGS}"
  export LDFLAGS="${MPI_LINK_FLAGS} ${LDFLAGS:-}"
fi

echo "####################################################################"
echo "                     PROXY BUILDER                                  "
echo "####################################################################"
echo
echo "Building proxy with ${KOKKOS_USE} into ${INSTALL_PATH}"
echo

SECONDS=0

rm -rf "${INSTALL_PATH}/bin/mhm2"
rm -rf "${INSTALL_PATH}/bin/${BINARY}"

if [ "${BUILD_CMD}" = "cleanall" ]; then
  rm -rf .build/*
  rm -rf "${INSTALL_PATH}/cmake"
  echo "Build took ${SECONDS}s"
  exit 0
elif [ "${BUILD_CMD}" = "clean" ]; then
  rm -rf .build/bin .build/CMake* .build/lib* .build/makeVersionFile .build/src .build/test .build/cmake* .build/Makefile .build/make*
  rm -rf "${INSTALL_PATH}/cmake"
  echo "Build took ${SECONDS}s"
  exit 0
fi

mkdir -p "${ROOT}/.build"
cd "${ROOT}/.build"

testing=0
if [ "${BUILD_CMD}" = "Debug" ] || [ "${BUILD_CMD}" = "RelWithDebInfo" ]; then
  testing=1
fi

if [ "${BUILD_CMD}" = "Debug" ] || [ "${BUILD_CMD}" = "Release" ] || [ "${BUILD_CMD}" = "RelWithDebInfo" ]; then
  rm -rf ./*
  rm -rf "${INSTALL_PATH}/cmake"
  # shellcheck disable=SC2086
  cmake "${ROOT}" \
    -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
    -DCMAKE_BUILD_TYPE="${BUILD_CMD}" \
    -DCMAKE_INSTALL_PREFIX="${INSTALL_PATH}" \
    -DCMAKE_CXX_FLAGS="-Wall -Wno-deprecated-declarations" \
    -DCMAKE_CXX_STANDARD="${CXXSTD}" \
    -DCMAKE_C_COMPILER="${CC}" \
    -DCMAKE_CXX_COMPILER="${CXX}" \
    ${CUDA_HOST_CXX:+-DCMAKE_CUDA_HOST_COMPILER="${CUDA_HOST_CXX}"} \
    ${CUDA_ARCH_FLAG} \
    ${GPU_ENABLE_FLAGS} \
    ${MPI_LINK_FLAGS:+-DCMAKE_EXE_LINKER_FLAGS="${MPI_LINK_FLAGS}"} \
    ${KOKKOS_INSTALL:+-DKokkos_ROOT="${KOKKOS_INSTALL}"} \
    ${KOKKOS_CMAKE_MODULE_DIR:+-DKokkos_DIR="${KOKKOS_CMAKE_MODULE_DIR}"} \
    -DENABLE_KOKKOS="${ENABLE_KOKKOS}" \
    ${MHM2_CMAKE_EXTRAS:-}
fi

# shellcheck disable=SC2086
make -j ${MHM2_BUILD_THREADS:-} all
if [ "${testing}" = "1" ]; then
  ctest --output-on-failure
fi
# shellcheck disable=SC2086
make -j ${MHM2_BUILD_THREADS:-} install

if [ "${BINARY}" != "mhm2" ]; then
  mv -f "${INSTALL_PATH}/bin/mhm2" "${INSTALL_PATH}/bin/${BINARY}"
fi

echo "Build took ${SECONDS}s"
