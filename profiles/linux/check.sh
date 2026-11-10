#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TOOLS_DIR="${TOOLS_DIR:-$ROOT/tools}"
source "$ROOT/tools/internal-tools.sh"
failed=0

make="$(ub_find_internal_tool make || true)"
if [[ -n "$make" ]]; then echo "[OK] Make interno: $make"
else echo "[FALTA] Make em tools/"; failed=1; fi

compiler=""
for cmd in gcc clang; do
    path="$(ub_find_internal_tool "$cmd" || true)"
    if [[ -n "$path" ]]; then compiler="$path"; break; fi
done
if [[ -n "$compiler" ]]; then echo "[OK] Compilador C interno: $compiler"
else echo "[FALTA] gcc ou clang em tools/"; failed=1; fi

exit "$failed"
