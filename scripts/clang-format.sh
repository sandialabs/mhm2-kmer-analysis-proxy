#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

find . -type f \( -iname '*.h' -o -iname '*.c' -o -iname '*.hpp' -o -iname '*.cpp' \) \
  -not -path './.build/*' \
  -not -path './.git/*' \
  -print0 | xargs -0 -r clang-format -i
