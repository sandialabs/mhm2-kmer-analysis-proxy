#!/usr/bin/env bash
set -euo pipefail

die() {
  echo "ERROR: $*" >&2
  exit 1
}

info() {
  echo "INFO: $*"
}

usage() {
  cat <<'EOF'
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
EOF
}

on_error() {
  local exit_code=$?
  local line_no=${1:-unknown}
  echo "ERROR: build_kmer_proxy failed at line ${line_no} with exit code ${exit_code}." >&2
  exit "$exit_code"
}

trap 'on_error $LINENO' ERR

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found in PATH: $1"
}

require_directory() {
  local path="$1"
  local description="$2"
  [[ -d "$path" ]] || die "$description does not exist or is not a directory: $path"
}

require_file() {
  local path="$1"
  local description="$2"
  [[ -f "$path" ]] || die "$description not found: $path"
}

resolve_executable() {
  local exe="$1"
  local resolved
  resolved="$(command -v "$exe" 2>/dev/null || true)"
  [[ -n "$resolved" ]] || die "Compiler/executable not found in PATH: $exe"
  echo "$resolved"
}

resolve_kokkos_dir() {
  local prefix="$1"
  local candidate

  for candidate in \
    "$prefix/lib64/cmake/Kokkos" \
    "$prefix/lib/cmake/Kokkos" \
    "$prefix/cmake/Kokkos"
  do
    if [[ -f "$candidate/KokkosConfig.cmake" ]]; then
      echo "$candidate"
      return 0
    fi
  done

  return 1
}

validate_jobs() {
  local jobs="$1"
  [[ "$jobs" =~ ^[1-9][0-9]*$ ]] || die "Invalid --jobs value '$jobs'. It must be a positive integer."
}

safe_clean_build_dir() {
  [[ -n "$BUILD_DIR" ]] || die "Internal error: BUILD_DIR is empty."
  [[ "$BUILD_DIR" != "/" ]] || die "Refusing to operate on root directory."
  [[ "$BUILD_DIR" == "$ROOT_DIR/.build" ]] || die "Internal error: unexpected build directory '$BUILD_DIR'."
  mkdir -p "$BUILD_DIR"
  rm -rf "$BUILD_DIR"/*
}

safe_clean_action() {
  mkdir -p "$BUILD_DIR"
  rm -rf "$BUILD_DIR/bin" \
         "$BUILD_DIR/CMakeCache.txt" \
         "$BUILD_DIR/CMakeFiles" \
         "$BUILD_DIR/lib"* \
         "$BUILD_DIR/makeVersionFile" \
         "$BUILD_DIR/src" \
         "$BUILD_DIR/test" \
         "$BUILD_DIR/cmake"* \
         "$BUILD_DIR/Makefile" \
         "$BUILD_DIR/make"*
}

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#BUILD_DIR="$ROOT_DIR/.build"

if [[ -d "$ROOT_DIR/build" ]]; then
  BUILD_DIR="$ROOT_DIR/build"
else
  BUILD_DIR="$ROOT_DIR/.build"
fi

ACTION="build"

KOKKOS_INSTALLATION=""
UPCXX_INSTALLATION=""
CC_COMPILER=""
CXX_COMPILER=""
BUILD_TYPE=""
CXXSTD=""
INSTALL_PREFIX=""
KOKKOS_USAGE="on"
JOBS=""
VERBOSE=0
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    build)
      ACTION="build"
      shift
      ;;
    clean)
      ACTION="clean"
      shift
      ;;
    cleanall)
      ACTION="cleanall"
      shift
      ;;
    --kokkos-installation)
      [[ $# -ge 2 ]] || die "--kokkos-installation requires a path argument"
      KOKKOS_INSTALLATION="$2"
      shift 2
      ;;
    --upcxx-installation)
      [[ $# -ge 2 ]] || die "--upcxx-installation requires a path argument"
      UPCXX_INSTALLATION="$2"
      shift 2
      ;;
    --cc)
      [[ $# -ge 2 ]] || die "--cc requires a compiler argument"
      CC_COMPILER="$2"
      shift 2
      ;;
    --cxx)
      [[ $# -ge 2 ]] || die "--cxx requires a compiler argument"
      CXX_COMPILER="$2"
      shift 2
      ;;
    --build-type)
      [[ $# -ge 2 ]] || die "--build-type requires an argument"
      BUILD_TYPE="$2"
      shift 2
      ;;
    --cxxstd)
      [[ $# -ge 2 ]] || die "--cxxstd requires an argument"
      CXXSTD="$2"
      shift 2
      ;;
    --install-prefix)
      [[ $# -ge 2 ]] || die "--install-prefix requires a path argument"
      INSTALL_PREFIX="$2"
      shift 2
      ;;
    --kokkos-usage)
      [[ $# -ge 2 ]] || die "--kokkos-usage requires 'on' or 'off'"
      KOKKOS_USAGE="$2"
      shift 2
      ;;
    --jobs)
      [[ $# -ge 2 ]] || die "--jobs requires an integer argument"
      JOBS="$2"
      shift 2
      ;;
    --verbose)
      VERBOSE=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1. Use --help for usage."
      ;;
  esac
done

require_command cmake
require_command make

if [[ "$ACTION" == "clean" ]]; then
  safe_clean_action
  info "Clean completed."
  exit 0
fi

if [[ "$ACTION" == "cleanall" ]]; then
  safe_clean_build_dir
  info "Cleanall completed."
  exit 0
fi

[[ -n "$KOKKOS_INSTALLATION" ]] || die "--kokkos-installation is required"
[[ -n "$UPCXX_INSTALLATION" ]] || die "--upcxx-installation is required"
[[ -n "$CC_COMPILER" ]] || die "--cc is required"
[[ -n "$CXX_COMPILER" ]] || die "--cxx is required"
[[ -n "$BUILD_TYPE" ]] || die "--build-type is required"
[[ -n "$CXXSTD" ]] || die "--cxxstd is required"
[[ -n "$INSTALL_PREFIX" ]] || die "--install-prefix is required"

case "$BUILD_TYPE" in
  Debug|Release|RelWithDebInfo) ;;
  *)
    die "Invalid --build-type '$BUILD_TYPE'. Valid values: Debug, Release, RelWithDebInfo"
    ;;
esac

case "$CXXSTD" in
  17|20) ;;
  *)
    die "Invalid --cxxstd '$CXXSTD'. Valid values: 17, 20"
    ;;
esac

case "$KOKKOS_USAGE" in
  on|off) ;;
  *)
    die "Invalid --kokkos-usage '$KOKKOS_USAGE'. Valid values: on, off"
    ;;
esac

if [[ -n "$JOBS" ]]; then
  validate_jobs "$JOBS"
fi

require_directory "$KOKKOS_INSTALLATION" "Kokkos installation"
require_directory "$UPCXX_INSTALLATION" "UPC++ installation"

KOKKOS_DIR="$(resolve_kokkos_dir "$KOKKOS_INSTALLATION")" || die \
  "Could not locate KokkosConfig.cmake under '$KOKKOS_INSTALLATION'. Looked in lib64/cmake/Kokkos, lib/cmake/Kokkos, and cmake/Kokkos."

require_file "$UPCXX_INSTALLATION/bin/upcxx" "UPC++ executable"
require_file "$UPCXX_INSTALLATION/bin/upcxx-meta" "UPC++ metadata tool"

CC_RESOLVED="$(resolve_executable "$CC_COMPILER")"
CXX_RESOLVED="$(resolve_executable "$CXX_COMPILER")"

ENABLE_KOKKOS="ON"
if [[ "$KOKKOS_USAGE" == "off" ]]; then
  ENABLE_KOKKOS="OFF"
fi

mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

TESTING=0
if [[ "$BUILD_TYPE" == "Debug" || "$BUILD_TYPE" == "RelWithDebInfo" ]]; then
  TESTING=1
fi

safe_clean_build_dir
rm -rf "$INSTALL_PREFIX/cmake"

export PATH="$UPCXX_INSTALLATION/bin:$PATH"

CMAKE_CMD=(
  cmake
  -S "$ROOT_DIR"
  -B "$BUILD_DIR"
  -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
  -DCMAKE_BUILD_TYPE="$BUILD_TYPE"
  -DCMAKE_INSTALL_PREFIX="$INSTALL_PREFIX"
  -DMHM2_ENABLE_TESTING="$TESTING"
  -DCMAKE_CXX_STANDARD="$CXXSTD"
  -DCMAKE_C_COMPILER="$CC_RESOLVED"
  -DCMAKE_CXX_COMPILER="$CXX_RESOLVED"
  -DCMAKE_CXX_FLAGS=-Wall\ -Wno-deprecated-declarations
  -DKokkos_ROOT="$KOKKOS_INSTALLATION"
  -DKokkos_DIR="$KOKKOS_DIR"
  -DENABLE_KOKKOS="$ENABLE_KOKKOS"
)

MAKE_CMD=(make)
INSTALL_CMD=(make install)

if [[ -n "$JOBS" ]]; then
  MAKE_CMD+=(-j "$JOBS")
  INSTALL_CMD+=(-j "$JOBS")
fi

MAKE_CMD+=(all)

echo "Configuration:"
echo "  ROOT_DIR             = $ROOT_DIR"
echo "  BUILD_DIR            = $BUILD_DIR"
echo "  KOKKOS_INSTALLATION  = $KOKKOS_INSTALLATION"
echo "  KOKKOS_DIR           = $KOKKOS_DIR"
echo "  UPCXX_INSTALLATION   = $UPCXX_INSTALLATION"
echo "  CC                   = $CC_RESOLVED"
echo "  CXX                  = $CXX_RESOLVED"
echo "  BUILD_TYPE           = $BUILD_TYPE"
echo "  CXXSTD               = $CXXSTD"
echo "  INSTALL_PREFIX       = $INSTALL_PREFIX"
echo "  KOKKOS_USAGE         = $KOKKOS_USAGE"
if [[ -n "$JOBS" ]]; then
  echo "  JOBS                 = $JOBS"
fi

echo "Running:"
printf '  %q' "${CMAKE_CMD[@]}"
echo
printf '  %q' "${MAKE_CMD[@]}"
echo
printf '  %q' "${INSTALL_CMD[@]}"
echo

if [[ "$DRY_RUN" -eq 1 ]]; then
  info "Dry run requested; exiting without executing commands."
  exit 0
fi

"${CMAKE_CMD[@]}"
"${MAKE_CMD[@]}"

if [[ "$TESTING" -eq 1 ]]; then
  ctest --output-on-failure || die "ctest reported test failures"
fi

"${INSTALL_CMD[@]}"

info "Build completed successfully."
