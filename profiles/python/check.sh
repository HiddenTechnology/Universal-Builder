#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TOOLS_DIR="${TOOLS_DIR:-$ROOT/tools}"
source "$ROOT/tools/internal-tools.sh"
failed=0
python="$(ub_find_internal_tool python3 || true)"
if [[ -z "$python" ]]; then
    echo "[FALTA] Python 3 interno em tools/"
    exit 1
fi
echo "[OK] Python interno: $python"
if [[ -f pyproject.toml || -f setup.py ]]; then
    if ! "$python" -m build --version >/dev/null 2>&1; then
        echo "[FALTA] Módulo Python 'build' no ambiente interno"
        failed=1
    else
        echo "[OK] Módulo Python build"
    fi
fi
exit "$failed"
