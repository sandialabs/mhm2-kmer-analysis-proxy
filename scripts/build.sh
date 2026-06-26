#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

# Project root directory (contains input files and Kokkos installation)
export PROJECT_ROOT="${PROJECT_ROOT:=/projects/proxy_apps}"
export BACKEND="${BACKEND:=HIP}"
export KOKKOS_USE="${KOKKOS_USE:=KOKKOS_ON}"

# mhm2 proxy install directory
PROXY_INSTALL="${ROOT}/install_${BACKEND}_${KOKKOS_USE}"

export CXX="$(which mpicxx)"
export CC="$(which mpicc)"
export PROXY_KOKKOS_INSTALL="${PROXY_INSTALL}"
export MHM2_INSTALL_PATH="${PROXY_KOKKOS_INSTALL}"

if [ "${KOKKOS_USE}" = "KOKKOS_ON" ]; then
  # Kokkos installation directory 
  export KOKKOS_INSTALL="${KOKKOS_INSTALL:=${PROJECT_ROOT}/Kokkos/kokkos_install_el_dorado_num_nodes_1_cray_mpich_1801_rocm_631_MI300A_HIP_cxx_20_2026_06_24}"
  CXXSTD=20
  ENABLE_KOKKOS=ON
else
  export KOKKOS_INSTALL="${KOKKOS_INSTALL:=${PROJECT_ROOT}/Kokkos/kokkos_install_el_dorado_num_nodes_1_cray_mpich_1801_rocm_631_MI300A_HIP_2026_05_26}"
  CXXSTD=17
  ENABLE_KOKKOS=OFF
fi

export KOKKOS_CMAKE_MODULE_DIR="${KOKKOS_INSTALL}/lib64/cmake/Kokkos"

BUILD_CMD="${1:-Release}"
INSTALL_PATH="${MHM2_INSTALL_PATH}"
BINARY="${MHM2_BINARY:=mhm2}"

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
    -DKokkos_ROOT="${KOKKOS_INSTALL}" \
    -DKokkos_DIR="${KOKKOS_CMAKE_MODULE_DIR}" \
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
