#!/usr/bin/env bash

if [ -n "$MHM2_BUILD_ENV" ]; then
    echo "Source $MHM2_BUILD_ENV"
    source $MHM2_BUILD_ENV
fi

upcxx_exec=`which upcxx`


if [ -z "$upcxx_exec" ]; then
    echo "upcxx not found. Please install or set path."
    exit 1
fi

upcxx_exec_canonical=$(readlink -f $upcxx_exec)
if [ "$upcxx_exec_canonical" != "$upcxx_exec" ]; then
    echo "Found symlink for upcxx - using target at $upcxx_exec_canonical"
    export PATH=`dirname $upcxx_exec_canonical`:$PATH
fi



set -e

SECONDS=0

rootdir=`pwd`

INSTALL_PATH=${MHM2_INSTALL_PATH:=$rootdir/install}

echo "Installing into $INSTALL_PATH"

BINARY="${MHM2_BINARY:=mhm2}"

rm -rf $INSTALL_PATH/bin/mhm2
rm -rf $INSTALL_PATH/bin/${BINARY}

if [ "$1" == "cleanall" ]; then
    rm -rf .build/*
    # if this isn't removed then the the rebuild will not work
    rm -rf $INSTALL_PATH/cmake
    exit 0
elif [ "$1" == "clean" ]; then
    rm -rf .build/bin .build/CMake* .build/lib* .build/makeVersionFile .build/src .build/test .build/cmake* .build/Makefile .build/make*
    # if this isn't removed then the the rebuild will not work
    rm -rf $INSTALL_PATH/cmake
    exit 0
# -----------------------------------------------------------------------------
# Main build logic: clean, configure, build, test (optional), install
# -----------------------------------------------------------------------------
else
  # ensure build dir exists and cd into it
  mkdir -p "$rootdir"/.build
  cd "$rootdir"/.build

  # pick up testing=1 for Debug or RelWithDebInfo
  testing=0
  if [[ "$1" == "Debug" || "$1" == "RelWithDebInfo" ]]; then
    testing=1
  fi

  # check that $1 is a valid build type
  if [[ "$1" != "Debug" && "$1" != "Release" && "$1" != "RelWithDebInfo" ]]; then
    echo "Error: Unknown build type '$1'" >&2
    echo "Usage: $0 [clean|cleanall|Debug|Release|RelWithDebInfo] [<extra cmake flags>]" >&2
    exit 1
  fi

  # clean out previous build files and old CMake wrapper state
  rm -rf ./*                       # clean build tree
  rm -rf "$INSTALL_PATH"/cmake     # ensure fresh CMake install scripts

  # configure
  cmake "$rootdir" \
    -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
    -DCMAKE_BUILD_TYPE="$1" \
    -DCMAKE_INSTALL_PREFIX="$INSTALL_PATH" \
    -DMHM2_ENABLE_TESTING="$testing" \
    -DCMAKE_CXX_STANDARD=17 \
    -DCMAKE_CXX_FLAGS="-Wall -Wextra -Wno-deprecated-declarations -std=c++17" \
    $MHM2_CMAKE_EXTRAS \
    "${@:2}" \
  |& tee configure.log

  # determine parallel job count once
  : "${MHM2_BUILD_THREADS:=$(nproc)}"
  echo "Building with $MHM2_BUILD_THREADS threads..."

  # build & (optionally) test & install in one go
  cmake --build . \
        --parallel "$MHM2_BUILD_THREADS" \
        --target all           # builds everything
  if [[ "$testing" == "1" ]]; then
    ctest --output-on-failure
  fi
  cmake --build . \
        --parallel "$MHM2_BUILD_THREADS" \
        --target install       # install into $INSTALL_PATH

  # rename binary if needed
  if [[ "$BINARY" != "mhm2" ]]; then
    mv -f "$INSTALL_PATH"/bin/mhm2 "$INSTALL_PATH"/bin/"$BINARY"
  fi
fi
