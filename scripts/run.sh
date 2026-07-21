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

export PROJECT_ROOT="${PROJECT_ROOT:=/home/jciesko/RAndD/proxy-apps/}"

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
# Backend: CUDA (NVIDIA/H100), HIP (AMD/MI300A), or CPU (no CUDA/HIP).
# Selects the install dir (install_${BACKEND}_${KOKKOS_USE}) and result labels.
# Result dirs are named KOKKOS_{ON|OFF}_{CUDA|HIP|CPU}_ranks_<N>
# e.g. BACKEND=CPU -> KOKKOS_ON_CPU_ranks_4 / KOKKOS_OFF_CPU_ranks_4
export BACKEND="${BACKEND:=CUDA}"
BACKEND="$(printf '%s' "${BACKEND}" | tr '[:lower:]' '[:upper:]')"
export BACKEND
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

export NUM_RANKS=${NUM_RANKS:=2}
export NUM_RUNS=${NUM_RUNS:=3}

# GASNet conduit to launch with. Must be one the UPC++ install was built with
# (see: upcxx-meta GASNET_CONDUIT / the upcxx.opt.gasnet_*.<net> dirs). This
# install provides smp/ibv/mpi/udp (default smp); "ofi" is NOT available.
export RUN_NETWORK="${RUN_NETWORK:=smp}"

# OpenMP / Kokkos::OpenMP threading (CPU + KOKKOS_ON).
# Default: fixed 2 threads per UPC++ rank. Override with OMP_THREADS_PER_RANK.
# Still never exceeds physical_cores/NUM_RANKS (fair share).
export OMP_PROC_BIND="${OMP_PROC_BIND:-close}"
export OMP_PLACES="${OMP_PLACES:-cores}"
export OMP_WAIT_POLICY="${OMP_WAIT_POLICY:-passive}"
export OMP_THREADS_PER_RANK="${OMP_THREADS_PER_RANK:-2}"

_physical_cores() {
  # Unique physical core IDs from lscpu; fall back to nproc.
  local cores
  cores="$(lscpu -p=CORE 2>/dev/null | grep -v '^#' | sort -u | wc -l | tr -d ' ')"
  if [ -n "${cores}" ] && [ "${cores}" -gt 0 ] 2>/dev/null; then
    echo "${cores}"
  else
    nproc
  fi
}

_configure_openmp_for_ranks() {
  local ranks=$1
  local kokkos_use=$2

  # Serial / GPU builds: do not leave a large OpenMP pool lying around.
  if [ "${BACKEND}" != "CPU" ] || [ "${kokkos_use}" != "KOKKOS_ON" ]; then
    export OMP_NUM_THREADS=1
    echo "    OpenMP: OMP_NUM_THREADS=1 (not using Kokkos::OpenMP)"
    return
  fi

  local ncores
  ncores="$(_physical_cores)"
  local fair=$((ncores / ranks))
  if [ "${fair}" -lt 1 ]; then
    fair=1
  fi

  local threads="${OMP_THREADS_PER_RANK}"
  if [ -n "${OMP_NUM_THREADS_FIXED:-}" ]; then
    threads="${OMP_NUM_THREADS_FIXED}"
  fi
  # Never oversubscribe physical cores across ranks.
  if [ "${threads}" -gt "${fair}" ]; then
    threads="${fair}"
  fi
  if [ "${threads}" -lt 1 ]; then
    threads=1
  fi

  export OMP_NUM_THREADS="${threads}"
  # Kokkos OpenMP backend also honors this when set.
  export KOKKOS_NUM_THREADS="${OMP_NUM_THREADS}"

  echo "    OpenMP: OMP_NUM_THREADS=${OMP_NUM_THREADS}  OMP_PROC_BIND=${OMP_PROC_BIND}  OMP_PLACES=${OMP_PLACES}  (cores=${ncores}, fair=${fair}, ranks=${ranks})"
}

RUN_TS=$(date +"%Y%m%d_%H%M%S")
RUN_HASH=$(printf '%s' "${RUN_TS}" | md5sum | awk '{print substr($1, 1, 8)}')
# Group batches by backend so CPU/CUDA/HIP runs stay separated.
export RESULTS_DIR="${ROOT}/results/${BACKEND}/results_${RUN_TS}_${RUN_HASH}"
export CSV_DIR="${RESULTS_DIR}/csv"
mkdir -p "${RESULTS_DIR}" "${CSV_DIR}"
echo "BACKEND:       ${BACKEND}"
echo "KOKKOS_USE:    ${KOKKOS_USE}"
echo "Result label:  ${KOKKOS_USE}_${BACKEND}_ranks_<N>"
echo "Results batch: ${RESULTS_DIR}"
echo "CSV output:    ${CSV_DIR}"
echo "Runs per rank: ${NUM_RUNS}"
if [ "${BACKEND}" = "CPU" ] && [ "${KOKKOS_USE}" = "KOKKOS_ON" ]; then
  echo "OpenMP bind:   OMP_PROC_BIND=${OMP_PROC_BIND} OMP_PLACES=${OMP_PLACES}"
  echo "OpenMP threads: fixed OMP_THREADS_PER_RANK=${OMP_THREADS_PER_RANK} (capped by cores/ranks)"
  echo "CPU pin:       --pin=\${MHM2_PIN:-spread} (partition physical cores across ranks before Kokkos/OpenMP init)"
fi
echo
echo "========== lscpu =========="
if command -v lscpu >/dev/null 2>&1; then
  lscpu | tee "${RESULTS_DIR}/lscpu.txt"
else
  echo "lscpu not available" | tee "${RESULTS_DIR}/lscpu.txt"
fi
echo "==========================="
echo

_run_proxy() {
  local kokkos_use=$1

  export KOKKOS_USE=${kokkos_use}
  # Explicit label: KOKKOS_ON_CPU, KOKKOS_OFF_CPU, KOKKOS_ON_CUDA, ...
  local result_label="${KOKKOS_USE}_${BACKEND}"
  local install_dir="${ROOT}/install_${BACKEND}_${KOKKOS_USE}"
  local mhm2_bin="${install_dir}/bin/mhm2"
  local rank_output="${RESULTS_DIR}/${result_label}_ranks_${NUM_RANKS}"
  mkdir -p "${rank_output}"

  if [ ! -x "${mhm2_bin}" ]; then
    echo "Missing executable: ${mhm2_bin}" >&2
    echo "Build it first: BACKEND=${BACKEND} KOKKOS_USE=${KOKKOS_USE} ./scripts/build.sh" >&2
    exit 1
  fi

  _configure_openmp_for_ranks "${NUM_RANKS}" "${KOKKOS_USE}"

  # CPU + Kokkos::OpenMP: partition CPUs across ranks before OpenMP binds
  # (see pin_spread + Kokkos init after affinity in main.cpp).
  local pin_arg="--pin=none"
  if [ "${BACKEND}" = "CPU" ] && [ "${KOKKOS_USE}" = "KOKKOS_ON" ]; then
    pin_arg="--pin=${MHM2_PIN:-spread}"
  elif [ -n "${MHM2_PIN:-}" ]; then
    pin_arg="--pin=${MHM2_PIN}"
  fi

  for run_idx in $(seq 1 "${NUM_RUNS}"); do
    local run_label
    run_label=$(printf "run_%02d" "${run_idx}")
    export PROXY_OUTPUT="${rank_output}/${run_label}"
    mkdir -p "${PROXY_OUTPUT}"

    echo "--- ${result_label} ranks=${NUM_RANKS} ${run_label} ---"
    echo "    binary: ${mhm2_bin}"
    echo "    output: ${PROXY_OUTPUT}"
    echo "    pin:    ${pin_arg}"

    upcxx-run \
    -n ${NUM_RANKS} \
    -shared-heap "250MB" \
    -network="${RUN_NETWORK}" \
    "${mhm2_bin}" \
    ${pin_arg} \
    --paired-reads \
    ${DATA_SMALL}/36_S23_R1_001_trim2mil.fastq \
    ${DATA_SMALL}/36_S23_R2_001_trim2mil.fastq \
    --output "${PROXY_OUTPUT}"

    shopt -s nullglob
    for csv_file in "${ROOT}"/*.csv; do
      base=$(basename "${csv_file}" .csv)
      cp "${csv_file}" "${CSV_DIR}/${base}_ranks_${NUM_RANKS}_${run_label}.csv"
      rm -f "${csv_file}"
    done
    shopt -u nullglob
  done
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
