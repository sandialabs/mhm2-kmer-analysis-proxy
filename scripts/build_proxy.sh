#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

export PROJECT_ROOT="${PROJECT_ROOT:=/projects/proxy_apps}"
export MACHINE="${MACHINE:=eldorado}"
export ARCH="${ARCH:=HIP}"
export KOKKOS_USE="${KOKKOS_USE:=KOKKOS_ON}"
export WORKING_DIR="${WORKING_DIR:=${PROJECT_ROOT}/jciesko_workspace}"

PROXY_INSTALL="${WORKING_DIR}/mhm2_kokkos_install_gpu_${ARCH}_${KOKKOS_USE}_${MACHINE}"

export CXX="$(which mpicxx)"
export CC="$(which mpicc)"
export PROXY_KOKKOS_INSTALL="${PROXY_INSTALL}"

if [ "${KOKKOS_USE}" = "KOKKOS_ON" ]; then
  export KOKKOS_INSTALL="${KOKKOS_INSTALL:=${PROJECT_ROOT}/Kokkos/kokkos_install_el_dorado_num_nodes_1_cray_mpich_1801_rocm_631_MI300A_HIP_cxx_20_2026_06_24}"
  CXXSTD=20
  ENABLE_KOKKOS=ON
else
  export KOKKOS_INSTALL="${KOKKOS_INSTALL:=${PROJECT_ROOT}/Kokkos/kokkos_install_el_dorado_num_nodes_1_cray_mpich_1801_rocm_631_MI300A_HIP_2026_05_26}"
  CXXSTD=17
  ENABLE_KOKKOS=OFF
fi

export KOKKOS_CMAKE_MODULE_DIR="${KOKKOS_INSTALL}/lib64/cmake/Kokkos"

echo "####################################################################"
echo "                     PROXY BUILDER                                  "
echo "####################################################################"
echo
echo "Building proxy with ${KOKKOS_USE} into ${PROXY_KOKKOS_INSTALL}"
echo

"${ROOT}/scripts/build.sh" \
  Release \
  -DCMAKE_CXX_STANDARD="${CXXSTD}" \
  -DCMAKE_C_COMPILER="${CC}" \
  -DCMAKE_CXX_COMPILER="${CXX}" \
  -DKokkos_ROOT="${KOKKOS_INSTALL}" \
  -DKokkos_DIR="${KOKKOS_CMAKE_MODULE_DIR}" \
  -DCMAKE_INSTALL_PREFIX="${PROXY_KOKKOS_INSTALL}" \
  -DENABLE_KOKKOS="${ENABLE_KOKKOS}"
