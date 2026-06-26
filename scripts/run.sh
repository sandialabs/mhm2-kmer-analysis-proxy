#!/usr/bin/env bash

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

echo "####################################################################"
echo "                     PROXY RUNNER                                   "
echo "####################################################################"
echo -e "\n\n"

echo -e "upcxx executables:  $(which upcxx)"
echo -e "\n\n"

export GASNET_BACKTRACE=1
#export GASNET_IBV_PORTS_VERBOSE=1
#export GASNET_IBV_PORTS=4

export DATE=$(date +"%Y-%m-%d")

export PROJECT_ROOT="${PROJECT_ROOT:=/projects/proxy_apps}"

export DATA_ROOT_COW=${PROJECT_ROOT}/assembler_input_datasets/gavin_lab_data/CowMetaGenome

# 36_S23_R1_001_trim2mil.fastq
# 36_S23_R2_001_trim2mil.fastq
export DATA_SMALL=${DATA_ROOT_COW}/trimmed

# 36_S23_R1_001_trim.fastq
# 36_S23_R2_001_trim.fastq
# 5 million seqs
export DATA_MEDIUM=${DATA_ROOT_COW}/trimmed

# 36_S23_R1_001.fastq
# 36_S23_R2_001.fastq
# ~ 20 million seqs
export DATA_LARGE=${DATA_ROOT_COW}

export INPUT_SIZE="small"
#export INPUT_SIZE="medium"
#export INPUT_SIZE="large"

export KOKKOS_USE="${KOKKOS_USE:=KOKKOS_ON}"
export BACKEND="${BACKEND:=HIP}"
export NUM_RANKS=${NUM_RANKS:=2}

_run_proxy() {
  local kokkos_use=$1

  export KOKKOS_USE=${kokkos_use}
  local mhm2_bin="${ROOT}/mhm2_kokkos_install_gpu_${BACKEND}_${KOKKOS_USE}/bin/mhm2"
  export PROXY_OUTPUT="${ROOT}/${KOKKOS_USE}_${BACKEND}_ranks_${NUM_RANKS}"
  mkdir -p "${PROXY_OUTPUT}"

  if [ ! -x "${mhm2_bin}" ]; then
    echo "Missing executable: ${mhm2_bin}" >&2
    echo "Build it first: ./scripts/build.sh" >&2
    exit 1
  fi

  upcxx-run \
  -n ${NUM_RANKS} \
  -shared-heap "250MB" \
  -network=ofi \
  "${mhm2_bin}" \
  --pin=none \
  --paired-reads \
  ${DATA_SMALL}/36_S23_R1_001_trim2mil.fastq \
  ${DATA_SMALL}/36_S23_R2_001_trim2mil.fastq \
  --output "${PROXY_OUTPUT}"
}

run_proxy_kokkos_off() {
  _run_proxy KOKKOS_OFF
}

run_proxy_kokkos_on() {
  _run_proxy KOKKOS_ON
}

# Small — scale 1, 2, 4, 6, …, 16 ranks when RUN_BENCHMARK_LOOP is set
if [ -n "${RUN_BENCHMARK_LOOP}" ]; then
  for NUM_RANKS in 1 $(seq 2 2 16); do
    export NUM_RANKS
    if [ "${KOKKOS_USE}" == "KOKKOS_OFF" ]; then
      run_proxy_kokkos_off
    else
      run_proxy_kokkos_on
    fi
  done
else
  if [ "${KOKKOS_USE}" == "KOKKOS_OFF" ]; then
    run_proxy_kokkos_off
  else
    run_proxy_kokkos_on
  fi
fi
