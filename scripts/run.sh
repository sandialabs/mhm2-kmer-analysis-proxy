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

# Kokkos::OpenMP threading (CPU + KOKKOS_ON).
# Default (best measured on EPYC 7543P):
#   unset all OMP_* (no OMP_PROC_BIND / OMP_PLACES — they fight --pin)
#   --pin=spread
#   KOKKOS_NUM_THREADS = clamp(cores / ranks, OMP_THREADS_MIN, OMP_THREADS_PER_RANK)
#   defaults: max 16 (low ranks), min 2 (high ranks) — e.g. 16,16,8,5,4,3,2,2,2
#
# Optional overrides:
#   OMP_NUM_THREADS_FIXED=N  -> constant KOKKOS_NUM_THREADS at every rank count
#   MHM2_PIN=none|core|...   -> change/disable process pinning
export OMP_THREADS_PER_RANK="${OMP_THREADS_PER_RANK:-16}"
export OMP_THREADS_MIN="${OMP_THREADS_MIN:-2}"

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

_unset_all_omp_env() {
  # Drop OpenMP runtime OMP_* vars (modules/shell often inject these).
  # Keep script controls: OMP_THREADS_PER_RANK, OMP_THREADS_MIN, OMP_NUM_THREADS_FIXED.
  local var
  for var in $(compgen -e OMP_ 2>/dev/null || true); do
    case "${var}" in
      OMP_THREADS_PER_RANK|OMP_THREADS_MIN|OMP_NUM_THREADS_FIXED) continue ;;
    esac
    unset "${var}"
  done
  # Bash <4.2 may miss some; clear the usual suspects explicitly.
  unset OMP_NUM_THREADS OMP_PROC_BIND OMP_PLACES OMP_WAIT_POLICY \
        OMP_DYNAMIC OMP_SCHEDULE OMP_STACKSIZE OMP_DISPLAY_ENV \
        OMP_NESTED OMP_MAX_ACTIVE_LEVELS OMP_THREAD_LIMIT \
        OMP_CANCELLATION OMP_DEFAULT_DEVICE OMP_MAX_TASK_PRIORITY \
        OMP_DISPLAY_AFFINITY OMP_AFFINITY_FORMAT GOMP_CPU_AFFINITY
}

_configure_openmp_for_ranks() {
  local ranks=$1
  local kokkos_use=$2

  # Snapshot script controls before clearing OMP_* (names also match OMP_*).
  local threads_max="${OMP_THREADS_PER_RANK:-16}"
  local threads_min="${OMP_THREADS_MIN:-2}"
  local threads_fixed="${OMP_NUM_THREADS_FIXED:-}"

  _unset_all_omp_env
  unset KOKKOS_NUM_THREADS

  # Serial / GPU builds: leave Kokkos OpenMP unconfigured.
  if [ "${BACKEND}" != "CPU" ] || [ "${kokkos_use}" != "KOKKOS_ON" ]; then
    echo "    Threads: OMP_* unset, KOKKOS_NUM_THREADS unset (not using Kokkos::OpenMP)"
    return
  fi

  local ncores
  ncores="$(_physical_cores)"
  if ! [[ "${ncores}" =~ ^[1-9][0-9]*$ ]]; then
    ncores="$(nproc)"
  fi
  if ! [[ "${ranks}" =~ ^[1-9][0-9]*$ ]]; then
    echo "    WARNING: invalid rank count '${ranks}', defaulting to 1" >&2
    ranks=1
  fi

  local threads
  if [ -n "${threads_fixed}" ]; then
    threads="${threads_fixed}"
  else
    # Fair-share: cores/ranks, clamped to [OMP_THREADS_MIN, OMP_THREADS_PER_RANK].
    if ! [[ "${threads_max}" =~ ^[1-9][0-9]*$ ]]; then
      threads_max=16
    fi
    if ! [[ "${threads_min}" =~ ^[1-9][0-9]*$ ]]; then
      threads_min=2
    fi
    if [ "${threads_min}" -gt "${threads_max}" ]; then
      threads_min="${threads_max}"
    fi
    threads=$((ncores / ranks))
    if [ "${threads}" -lt 1 ]; then
      threads=1
    fi
    if [ "${threads}" -gt "${threads_max}" ]; then
      threads="${threads_max}"
    fi
    if [ "${threads}" -lt "${threads_min}" ]; then
      threads="${threads_min}"
    fi
  fi
  # Guard empty/non-numeric (Kokkos aborts on KOKKOS_NUM_THREADS=0).
  if ! [[ "${threads}" =~ ^[1-9][0-9]*$ ]]; then
    echo "    WARNING: invalid thread count '${threads}', defaulting to 2" >&2
    threads=2
  fi

  export KOKKOS_NUM_THREADS="${threads}"
  if [ -n "${threads_fixed}" ]; then
    echo "    Threads: KOKKOS_NUM_THREADS=${KOKKOS_NUM_THREADS}  (fixed; OMP_* unset; cores=${ncores}, ranks=${ranks})"
  else
    echo "    Threads: KOKKOS_NUM_THREADS=${KOKKOS_NUM_THREADS}  (fair-share clamp [${threads_min},${threads_max}]; OMP_* unset; cores=${ncores}, ranks=${ranks})"
  fi
}

RUN_TS=$(date +"%Y%m%d_%H%M%S")
RUN_HASH=$(printf '%s' "${RUN_TS}" | md5sum | awk '{print substr($1, 1, 8)}')
# Group batches by backend so CPU/CUDA/HIP runs stay separated.
export RESULTS_DIR="${ROOT}/results/${BACKEND}/results_${RUN_TS}_${RUN_HASH}"
export CSV_DIR="${RESULTS_DIR}/csv"
mkdir -p "${RESULTS_DIR}" "${CSV_DIR}"
echo "BACKEND:       ${BACKEND}"
echo "KOKKOS_USE:    ${KOKKOS_USE}"
echo "Result label:  ${KOKKOS_USE}_${BACKEND}_ranks_<N>[_threads_<T>]"
echo "Results batch: ${RESULTS_DIR}"
echo "CSV output:    ${CSV_DIR}"
echo "Runs per rank: ${NUM_RUNS}"
if [ "${BACKEND}" = "CPU" ] && [ "${KOKKOS_USE}" = "KOKKOS_ON" ]; then
  echo "OpenMP env:    all OMP_* unset (no OMP_PROC_BIND / OMP_PLACES)"
  if [ -n "${OMP_NUM_THREADS_FIXED:-}" ]; then
    echo "Kokkos threads: fixed OMP_NUM_THREADS_FIXED=${OMP_NUM_THREADS_FIXED} -> KOKKOS_NUM_THREADS (all ranks)"
  else
    echo "Kokkos threads: fair-share cores/ranks, clamp [${OMP_THREADS_MIN},${OMP_THREADS_PER_RANK}] -> KOKKOS_NUM_THREADS"
  fi
  echo "CPU pin:       --pin=\${MHM2_PIN:-spread} (partition physical cores across ranks before Kokkos init)"
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
  local tag_threads=0
  if [ "${BACKEND}" = "CPU" ] && [ "${KOKKOS_USE}" = "KOKKOS_ON" ] && [ -n "${RUN_BENCHMARK_LOOP:-}" ]; then
    tag_threads=1
  fi

  if [ ! -x "${mhm2_bin}" ]; then
    echo "Missing executable: ${mhm2_bin}" >&2
    echo "Build it first: BACKEND=${BACKEND} KOKKOS_USE=${KOKKOS_USE} ./scripts/build.sh" >&2
    exit 1
  fi

  _configure_openmp_for_ranks "${NUM_RANKS}" "${KOKKOS_USE}"

  # Tag after configure so the label reflects team size (or "auto").
  local thread_tag="auto"
  if [ -n "${KOKKOS_NUM_THREADS:-}" ]; then
    thread_tag="${KOKKOS_NUM_THREADS}"
  fi
  local out_suffix="ranks_${NUM_RANKS}"
  if [ "${tag_threads}" -eq 1 ]; then
    out_suffix="${out_suffix}_threads_${thread_tag}"
  fi
  local rank_output="${RESULTS_DIR}/${result_label}_${out_suffix}"
  mkdir -p "${rank_output}"

  # CPU + Kokkos::OpenMP: partition cores across ranks, then OpenMP binds within
  # that mask (OMP_PROC_BIND=spread OMP_PLACES=threads). Other backends: none.
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

    echo "--- ${result_label} ranks=${NUM_RANKS} KOKKOS_NUM_THREADS=${KOKKOS_NUM_THREADS:-unset} ${run_label} ---"
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
      local csv_name="${base}_ranks_${NUM_RANKS}_${run_label}.csv"
      if [ "${tag_threads}" -eq 1 ]; then
        csv_name="${base}_ranks_${NUM_RANKS}_threads_${thread_tag}_${run_label}.csv"
      fi
      cp "${csv_file}" "${CSV_DIR}/${csv_name}"
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

_run_once() {
  if [ "${KOKKOS_USE}" == "KOKKOS_OFF" ]; then
    run_proxy_kokkos_off
  else
    run_proxy_kokkos_on
  fi
}

# Small — scale ranks 1, 2, 4, …, 16 when RUN_BENCHMARK_LOOP is set.
# CPU + KOKKOS_ON: fair-share threads (default clamp [2,16]) unless OMP_NUM_THREADS_FIXED.
if [ -n "${RUN_BENCHMARK_LOOP}" ]; then
  for NUM_RANKS in 1 $(seq 2 2 16); do
    export NUM_RANKS
    if [ "${BACKEND}" = "CPU" ] && [ "${KOKKOS_USE}" = "KOKKOS_ON" ]; then
      if [ -n "${OMP_NUM_THREADS_FIXED:-}" ]; then
        echo "=== ranks=${NUM_RANKS} (OpenMP fixed ${OMP_NUM_THREADS_FIXED}) ==="
      else
        echo "=== ranks=${NUM_RANKS} (OpenMP fair-share clamp [${OMP_THREADS_MIN},${OMP_THREADS_PER_RANK}]) ==="
      fi
    fi
    _run_once
  done
else
  _run_once
fi
