#!/usr/bin/env bash

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

export ROOT=/projects/proxy_apps

export DATA_ROOT_COW=${ROOT}/assembler_input_datasets/gavin_lab_data/CowMetaGenome

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

export WORKING_DIR=${ROOT}/jciesko_workspace
cd "${WORKING_DIR}"

export APP="mhm2-proxy"
export MACHINE="eldorado"
export KOKKOS_USE="${KOKKOS_USE:=KOKKOS_ON}"
export ARCH="MI300A"
export BACKEND="HIP"
export NUM_RANKS=${NUM_RANKS:=2}

_run_proxy() {
  local mhm2_bin=$1
  local kokkos_use=$2

  export KOKKOS_USE=${kokkos_use}
  export PROXY_OUTPUT=${WORKING_DIR}/${KOKKOS_USE}_${BACKEND}_ranks_${NUM_RANKS}
  mkdir -p "${PROXY_OUTPUT}"

  upcxx-run \
  -n ${NUM_RANKS} \
  -shared-heap "250MB" \
  -network=ofi \
  ${mhm2_bin} \
  --pin=none \
  --paired-reads \
  ${DATA_SMALL}/36_S23_R1_001_trim2mil.fastq \
  ${DATA_SMALL}/36_S23_R2_001_trim2mil.fastq \
  --output "${PROXY_OUTPUT}"
}

run_proxy_kokkos_off() {
  _run_proxy ./mhm2_kokkos_install_gpu_HIP_KOKKOS_OFF_eldorado/bin/mhm2 KOKKOS_OFF
}

run_proxy_kokkos_on() {
  _run_proxy ./mhm2_kokkos_install_gpu_HIP_KOKKOS_ON_eldorado/bin/mhm2 KOKKOS_ON
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
