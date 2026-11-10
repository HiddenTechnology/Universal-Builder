#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TOOLS_DIR="${TOOLS_DIR:-$ROOT/tools}"
source "$ROOT/tools/internal-tools.sh"
failed=0
java="$(ub_find_internal_tool java || true)"
javac="$(ub_find_internal_tool javac || true)"
if [[ -n "$java" && -n "$javac" ]]; then
    echo "[OK] Java interno: $java"
    echo "[OK] Javac interno: $javac"
else
    echo "[FALTA] JDK completo em tools/java/"
    failed=1
fi
if [[ -f pom.xml ]]; then
    mvn="$(ub_find_internal_tool mvn || true)"
    if [[ -n "$mvn" ]]; then echo "[OK] Maven interno: $mvn"
    else echo "[FALTA] Maven interno em tools/"; failed=1; fi
elif [[ -f gradlew || -f build.gradle || -f build.gradle.kts || -f settings.gradle || -f settings.gradle.kts ]]; then
    gradle="$(ub_find_internal_tool gradle || true)"
    if [[ -n "$gradle" ]]; then echo "[OK] Gradle interno: $gradle"
    else echo "[FALTA] Gradle interno em tools/"; failed=1; fi
fi
exit "$failed"
