#!/usr/bin/env bash
set -uo pipefail

CHECK_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
BUILDER_ROOT="$(cd -- "$CHECK_DIR/../.." && pwd -P)"

TOOLS_DIR="${TOOLS_DIR:-$BUILDER_ROOT/tools}"
PROJECT_DIR="${PROJECT_DIR:-$PWD}"

source "$BUILDER_ROOT/tools/discover-tools.sh"

failed=0
warnings=0

fail() {
    echo "[FALTA] $1"
    failed=$((failed + 1))
}

ok() {
    echo "[OK] $1: $2"
}

warn() {
    echo "[AVISO] $1"
    warnings=$((warnings + 1))
}

need_file() {
    local name="$1"
    local path="$2"

    if [[ -n "$path" && -f "$path" ]]; then
        ok "$name" "$path"
    else
        if [[ -n "$path" ]]; then
            fail "$name ($path)"
        else
            fail "$name: caminho não definido"
        fi
    fi
}

need_exec() {
    local name="$1"
    local path="$2"

    if [[ -n "$path" && -x "$path" ]]; then
        ok "$name" "$path"
    else
        if [[ -n "$path" ]]; then
            fail "$name ($path)"
        else
            fail "$name: caminho não definido"
        fi
    fi
}

need_dir() {
    local name="$1"
    local path="$2"

    if [[ -n "$path" && -d "$path" ]]; then
        ok "$name" "$path"
    else
        if [[ -n "$path" ]]; then
            fail "$name ($path)"
        else
            fail "$name: caminho não definido"
        fi
    fi
}

is_gradle_project() {
    [[ -f "$PROJECT_DIR/gradlew" ||
       -f "$PROJECT_DIR/settings.gradle" ||
       -f "$PROJECT_DIR/settings.gradle.kts" ||
       -f "$PROJECT_DIR/build.gradle" ||
       -f "$PROJECT_DIR/build.gradle.kts" ]] && return 0

    find "$PROJECT_DIR" \
        -type d \( -name .git -o -name .universal-builder \
            -o -name .gradle -o -name build -o -name node_modules \) -prune -o \
        -type f \( -name settings.gradle -o -name settings.gradle.kts \
            -o -name build.gradle -o -name build.gradle.kts \) \
        -print -quit 2>/dev/null | grep -q .
}

echo "===== VERIFICAÇÃO ANDROID ====="
echo "Projeto: $PROJECT_DIR"
echo "Ferramentas: $TOOLS_DIR"
echo

if [[ ! -d "$PROJECT_DIR" ]]; then
    echo "[ERRO] Diretório do projeto não existe."
    exit 1
fi

ub_discover_android

echo "===== AMBIENTE INTERNO ====="

need_dir "Android SDK" "${ANDROID_SDK_ROOT:-}"

echo
echo "===== ANDROID PLATFORM ====="

if [[ -n "${ANDROID_SDK_ROOT:-}" && -n "${ANDROID_PLATFORM:-}" ]]; then
    need_file "Android Platform / android.jar" \
        "$ANDROID_SDK_ROOT/platforms/$ANDROID_PLATFORM/android.jar"
elif [[ -z "${ANDROID_SDK_ROOT:-}" ]]; then
    fail "Android Platform não verificável: SDK Android não encontrado"
else
    fail "Android Platform não identificada: ANDROID_PLATFORM não definido"
fi

if is_gradle_project; then
    echo
    echo "===== PROJETO ANDROID GRADLE ====="

    need_exec "Java interno" "${JAVA_HOME:+$JAVA_HOME/bin/java}"
    need_exec "Javac interno" "${JAVA_HOME:+$JAVA_HOME/bin/javac}"
    if [[ -z "${ANDROID_GRADLE_BIN:-}" ]]; then
        fail "Gradle interno não encontrado em tools/gradle/"
    elif [[ -n "${ANDROID_GRADLE_REQUIRED_VERSION:-}" ]]; then
        if [[ "${ANDROID_GRADLE_VERSION:-}" == "$ANDROID_GRADLE_REQUIRED_VERSION" ]]; then
            ok "Versão Gradle exigida" "$ANDROID_GRADLE_VERSION"
        else
            fail "Gradle exigido: $ANDROID_GRADLE_REQUIRED_VERSION; encontrado: ${ANDROID_GRADLE_VERSION:-não identificado}"
        fi
    elif [[ -n "${ANDROID_GRADLE_VERSION:-}" ]]; then
        ok "Gradle interno selecionado" "$ANDROID_GRADLE_VERSION"
    else
        fail "Gradle localizado, mas versão não identificada"
    fi

    if [[ -n "${ANDROID_AGP_VERSION:-}" ]]; then
        ok "Android Gradle Plugin detectado" "$ANDROID_AGP_VERSION"
    else
        warn "Versão do Android Gradle Plugin não identificada automaticamente."
    fi

    # Validar Build Tools somente quando projeto/usuário fixa uma versão.
    if [[ -n "${ANDROID_BUILD_TOOLS_REQUIRED_VERSION:-}" ]]; then
        need_dir "Build Tools exigidas ($ANDROID_BUILD_TOOLS_REQUIRED_VERSION)" \
            "$ANDROID_SDK_ROOT/build-tools/$ANDROID_BUILD_TOOLS_REQUIRED_VERSION"
    elif [[ -n "${ANDROID_BUILD_TOOLS_VERSION:-}" ]]; then
        need_dir "Build Tools selecionadas" \
            "$ANDROID_SDK_ROOT/build-tools/$ANDROID_BUILD_TOOLS_VERSION"
    else
        echo "[INFO] A versão padrão de Build Tools será determinada pelo AGP; download automático está desativado."
    fi

else
    echo
    echo "===== PROJETO ANDROID LEGADO ====="

    if find "$PROJECT_DIR" \
        -type d \( -name .git -o -name build -o -name .gradle -o -name .universal-builder \) -prune -o \
        -type f -name '*.java' -print -quit | grep -q .; then
        need_exec "Java interno" "${JAVA_HOME:+$JAVA_HOME/bin/java}"
        need_exec "Javac interno" "${JAVA_HOME:+$JAVA_HOME/bin/javac}"
        need_exec "DX" "${ANDROID_DX:-}"
    else
        echo "[INFO] Sem fontes Java; JDK e DX dispensados."
    fi

    need_exec "AAPT" "${ANDROID_AAPT:-}"
    need_exec "ZIPALIGN" "${ANDROID_ZIPALIGN:-}"
    need_exec "APKSIGNER" "${ANDROID_APKSIGNER:-}"

    if ub_project_has_native_sources; then
        need_dir "Android NDK" "${ANDROID_NDK_HOME:-}"
        need_exec "ndk-build" "${ANDROID_NDK_HOME:+$ANDROID_NDK_HOME/ndk-build}"
    else
        echo "[INFO] NDK dispensado: projeto sem fontes nativas."
    fi

    if [[ -n "${ANDROID_D8:-}" ]]; then
        ok "D8 disponível como ferramenta adicional" "$ANDROID_D8"
    fi
fi

# O adaptador legado usa a chave interna; Gradle gerencia a própria assinatura.
if ! is_gradle_project; then
    echo
    echo "===== ASSINATURA DO ADAPTADOR LEGADO ====="
    KEYSTORE="${UB_KEYSTORE_PATH:-$TOOLS_DIR/keys/universal-builder-release.jks}"
    PASSWORD_FILE="${UB_PASSWORD_FILE:-$TOOLS_DIR/keys/release-passwords.conf}"
    need_file "Keystore RELEASE interno" "$KEYSTORE"
    need_file "Arquivo interno de senhas" "$PASSWORD_FILE"
    if [[ -r "$PASSWORD_FILE" ]]; then
        if ! grep -Eq '^[[:space:]]*UB_KEYSTORE_PASS[[:space:]]*=' "$PASSWORD_FILE"; then
            fail "Senha UB_KEYSTORE_PASS não configurada em $PASSWORD_FILE"
        else
            ok "Senha do keystore RELEASE" "configurada"
        fi
    fi
fi

echo
echo "===== RESULTADO ====="

if (( failed != 0 )); then
    echo "[ERRO] Existem dependências ausentes ou incompatíveis."
    echo "Resolva os itens [FALTA] antes da compilação."
    exit 1
fi

echo "[SUCESSO] Verificação das dependências concluída."

if (( warnings > 0 )); then
    echo "[AVISO] Foram encontrados $warnings aviso(s) para análise."
fi

exit 0
