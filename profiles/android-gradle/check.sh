
#!/usr/bin/env bash
set -uo pipefail

CHECK_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
BUILDER_ROOT="$(cd -- "$CHECK_DIR/../.." && pwd -P)"
TOOLS_DIR="${TOOLS_DIR:-$BUILDER_ROOT/tools}"
PROJECT_DIR="${PROJECT_DIR:-$PWD}"

source "$BUILDER_ROOT/tools/discover-tools.sh"

failed=0
fail() {
    echo "[FALTA] $1"
    failed=$((failed + 1))
}
ok() {
    echo "[OK] $1: $2"
}

echo "===== VERIFICAÇÃO ANDROID GRADLE ====="
echo "Projeto: $PROJECT_DIR"
echo "Ferramentas: $TOOLS_DIR"
echo

if [[ ! -d "$PROJECT_DIR" ]]; then
    echo "[ERRO] Diretório do projeto não existe."
    exit 1
fi

ub_discover_android

# Android SDK
if [[ -n "${ANDROID_SDK_ROOT:-}" && -d "$ANDROID_SDK_ROOT" ]]; then
    ok "Android SDK" "$ANDROID_SDK_ROOT"
else
    fail "Android SDK interno não encontrado em tools/"
fi

# Android Platform
if [[ -n "${ANDROID_PLATFORM:-}" &&
      -n "${ANDROID_SDK_ROOT:-}" &&
      -f "$ANDROID_SDK_ROOT/platforms/$ANDROID_PLATFORM/android.jar" ]]; then
    ok "Android Platform" "$ANDROID_PLATFORM"
else
    fail "Plataforma Android compatível não encontrada"
fi

# Java
if [[ -n "${JAVA_HOME:-}" && -x "$JAVA_HOME/bin/java" ]]; then
    ok "Java interno" "$JAVA_HOME/bin/java"
else
    fail "Java interno não encontrado"
fi

# Javac
if [[ -n "${JAVA_HOME:-}" && -x "$JAVA_HOME/bin/javac" ]]; then
    ok "Javac interno" "$JAVA_HOME/bin/javac"
else
    fail "Javac interno não encontrado"
fi

# Gradle
if [[ -z "${ANDROID_GRADLE_BIN:-}" ]]; then
    fail "Gradle interno compatível não encontrado em tools/gradle/"
elif [[ -n "${ANDROID_GRADLE_REQUIRED_VERSION:-}" &&
        "${ANDROID_GRADLE_VERSION:-}" != "$ANDROID_GRADLE_REQUIRED_VERSION" ]]; then
    fail "Gradle exigido: $ANDROID_GRADLE_REQUIRED_VERSION; encontrado: ${ANDROID_GRADLE_VERSION:-não identificado}"
elif [[ -n "${ANDROID_GRADLE_VERSION:-}" ]]; then
    ok "Gradle interno selecionado" "$ANDROID_GRADLE_VERSION"
else
    fail "Gradle localizado, mas versão não identificada"
fi

# Android Gradle Plugin
if [[ -n "${ANDROID_AGP_VERSION:-}" ]]; then
    echo "[INFO] Android Gradle Plugin declarado no projeto: $ANDROID_AGP_VERSION"
    echo "[INFO] A resolução do plugin depende da execução do Gradle."
else
    echo "[AVISO] Android Gradle Plugin não identificado automaticamente."
fi

# Android Build Tools
if [[ -n "${ANDROID_BUILD_TOOLS_REQUIRED_VERSION:-}" ]]; then
    if [[ -n "${ANDROID_SDK_ROOT:-}" &&
          -d "$ANDROID_SDK_ROOT/build-tools/$ANDROID_BUILD_TOOLS_REQUIRED_VERSION" ]]; then
        ok "Build Tools exigidas" "$ANDROID_BUILD_TOOLS_REQUIRED_VERSION"
    else
        fail "Build Tools exigidas ($ANDROID_BUILD_TOOLS_REQUIRED_VERSION) não encontradas no SDK interno"
    fi
elif [[ -n "${ANDROID_BUILD_TOOLS_VERSION:-}" ]]; then
    ok "Build Tools selecionadas" "$ANDROID_BUILD_TOOLS_VERSION"
else
    echo "[INFO] Nenhuma versão explícita de Build Tools foi identificada."
    echo "[INFO] A versão padrão será determinada pelo Android Gradle Plugin."
fi

# Código nativo
if ub_project_has_native_sources; then
    echo "[INFO] Fontes nativas detectadas; NDK/CMake devem ser verificados conforme o módulo."
else
    echo "[INFO] NDK não necessário: nenhuma configuração nativa detectada."
fi

echo
echo "===== RESULTADO ====="

if (( failed > 0 )); then
    echo "[ERRO] Existem dependências ausentes ou incompatíveis."
    echo "Resolva os itens [FALTA] antes da compilação."
    exit 1
fi

echo "[SUCESSO] Verificação das dependências concluída."
exit 0
