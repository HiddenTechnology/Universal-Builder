#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TOOLS_DIR="${TOOLS_DIR:-$ROOT/tools}"
source "$ROOT/tools/internal-tools.sh"
failed=0

if [[ -f CMakeLists.txt || -f CMakePresets.json ]]; then
    cmake="$(ub_find_internal_tool cmake || true)"
    if [[ -n "$cmake" ]]; then echo "[OK] CMake interno: $cmake"
    else echo "[FALTA] CMake em tools/"; failed=1; fi

    backend=""
    for cmd in ninja make; do
        path="$(ub_find_internal_tool "$cmd" || true)"
        if [[ -n "$path" ]]; then backend="$path"; break; fi
    done
    if [[ -n "$backend" ]]; then echo "[OK] Gerador CMake: $backend"
    else echo "[FALTA] Ninja ou Make em tools/"; failed=1; fi
elif [[ -f Makefile ]]; then
    make="$(ub_find_internal_tool make || true)"
    if [[ -n "$make" ]]; then echo "[OK] Make interno: $make"
    else echo "[FALTA] Make em tools/"; failed=1; fi
fi

compiler=""
for cmd in g++ clang++; do
    path="$(ub_find_internal_tool "$cmd" || true)"
    if [[ -n "$path" ]]; then compiler="$path"; break; fi
done
if [[ -n "$compiler" ]]; then echo "[OK] Compilador C++ interno: $compiler"
else echo "[FALTA] g++ ou clang++ em tools/"; failed=1; fi

if [[ ! -f CMakeLists.txt && ! -f CMakePresets.json && ! -f Makefile ]]; then
    echo "[AVISO] Não foi encontrado CMakeLists.txt, CMakePresets.json ou Makefile."
fi
exit "$failed"
