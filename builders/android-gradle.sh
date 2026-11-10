#!/usr/bin/env bash
set -Eeuo pipefail

: "${PROJECT_DIR:?PROJECT_DIR não definido}"
: "${TOOLS_DIR:?TOOLS_DIR não definido}"
: "${BUILDER_OUTPUT_DIR:?Diretório de saída não definido}"

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$ROOT/tools/discover-tools.sh"

fail() {
    echo "[ERRO] $*" >&2
    exit 1
}

# Descobrir ferramentas e versões para este projeto.
ub_discover_android

# --------------------------------------------------
# AMBIENTE
# --------------------------------------------------

[[ -d "$PROJECT_DIR" ]] ||
    fail "Projeto não encontrado: $PROJECT_DIR"

[[ -n "${ANDROID_SDK_ROOT:-}" ]] ||
    fail "Android SDK interno não encontrado."

[[ -n "${JAVA_HOME:-}" && -x "$JAVA_HOME/bin/java" ]] ||
    fail "JDK interno não encontrado."

[[ -x "$JAVA_HOME/bin/javac" ]] ||
    fail "Javac interno não encontrado."

[[ -n "${ANDROID_GRADLE_BIN:-}" && -x "$ANDROID_GRADLE_BIN" ]] ||
    fail "Gradle interno compatível não encontrado."

[[ -n "${ANDROID_GRADLE_VERSION:-}" ]] ||
    fail "Não foi possível identificar a versão do Gradle."

# Não permitir uma versão diferente da declarada no Wrapper.
if [[ -n "${ANDROID_GRADLE_REQUIRED_VERSION:-}" &&
      "$ANDROID_GRADLE_VERSION" != "$ANDROID_GRADLE_REQUIRED_VERSION" ]]; then
    fail "Gradle incompatível. Exigido: $ANDROID_GRADLE_REQUIRED_VERSION; encontrado: $ANDROID_GRADLE_VERSION"
fi

# --------------------------------------------------
# CONFIGURAÇÃO INTERNA
# --------------------------------------------------

export ANDROID_HOME="$ANDROID_SDK_ROOT"
export ANDROID_SDK_ROOT
export JAVA_HOME
export PATH="$JAVA_HOME/bin:$PATH"

export GRADLE_USER_HOME="$TOOLS_DIR/gradle-user-home"

mkdir -p "$GRADLE_USER_HOME" "$BUILDER_OUTPUT_DIR"

GRADLE_BIN="$ANDROID_GRADLE_BIN"

# --------------------------------------------------
# COMPILAÇÃO
# --------------------------------------------------

echo
echo "===== COMPILAÇÃO ANDROID GRADLE ====="
echo "Projeto: $PROJECT_DIR"
echo "Gradle: $GRADLE_BIN"
echo "Versão Gradle: $ANDROID_GRADLE_VERSION"
echo "AGP: ${ANDROID_AGP_VERSION:-não identificado}"
echo "JDK: $JAVA_HOME"
echo "SDK: $ANDROID_SDK_ROOT"
echo "Plataforma: ${ANDROID_PLATFORM:-não identificada}"
echo "Build Tools exigidas: ${ANDROID_BUILD_TOOLS_REQUIRED_VERSION:-não declaradas}"
echo "Assinatura: v1 + v2"
echo "Gradle User Home: $GRADLE_USER_HOME"
echo

BUILD_VARIANT="${UB_BUILD_VARIANT:-debug}"
case "$BUILD_VARIANT" in
    debug|release) ;;
    *) fail "UB_BUILD_VARIANT deve ser debug ou release; recebido: $BUILD_VARIANT" ;;
esac
TASK="assemble${BUILD_VARIANT^}"

echo
echo "===== COMPILAÇÃO ANDROID GRADLE ====="
echo "Variante: $BUILD_VARIANT"
echo "Tarefa: $TASK"
echo "A assinatura será gerenciada pela configuração do próprio projeto Gradle."
echo

cd "$PROJECT_DIR"
BUILD_START="$(date +%s)"

# Expor somente JDKs empacotados em tools/java/ para toolchains Gradle.
JDK_PATHS=()
while IFS= read -r -d '' javac; do
    jdk="$(dirname "$(dirname "$javac")")"
    [[ -x "$jdk/bin/java" ]] && JDK_PATHS+=("$jdk")
done < <(find "$TOOLS_DIR/java" -type d \( -name .git -o -name jre \) -prune -o \
    -type f -path '*/bin/javac' -print0 2>/dev/null)

(("${#JDK_PATHS[@]}" > 0)) || fail "Nenhum JDK interno foi encontrado para as toolchains do Gradle."
JDK_PATHS_CSV="$(IFS=,; printf '%s' "${JDK_PATHS[*]}")"

"$GRADLE_BIN" \
    --no-daemon \
    --stacktrace \
    -Pandroid.builder.sdkDownload=false \
    -Dandroid.builder.sdkDownload=false \
    -Dorg.gradle.java.home="$JAVA_HOME" \
    -Dorg.gradle.java.installations.auto-detect=false \
    -Dorg.gradle.java.installations.auto-download=false \
    -Dorg.gradle.java.installations.paths="$JDK_PATHS_CSV" \
    "$TASK"

# Considerar somente APKs da variante solicitada gerados nesta execução.
mapfile -d '' APK_FILES < <(
    find "$PROJECT_DIR" \
        -type d \( -name .git -o -name .universal-builder \
            -o -name .gradle -o -name node_modules \) -prune -o \
        -type f -path "*/build/outputs/apk/$BUILD_VARIANT/*.apk" \
        -newermt "@$BUILD_START" -print0
)

(("${#APK_FILES[@]}" > 0)) ||
    fail "Gradle concluiu, mas não gerou APK novo para a variante $BUILD_VARIANT."

TOTAL=0
for apk in "${APK_FILES[@]}"; do
    relative="${apk#"$PROJECT_DIR"/}"
    module="${relative%%/build/outputs/apk/*}"
    nome="$(basename "$apk")"
    if [[ "$module" == "$relative" ]]; then module="root"; fi
    destino_dir="$BUILDER_OUTPUT_DIR/$module"
    destino="$destino_dir/$nome"

    mkdir -p -- "$destino_dir"
    [[ ! -e "$destino" ]] ||
        fail "O destino já existe; preservando o APK anterior: $destino"
    [[ -s "$apk" ]] || fail "APK vazio: $apk"

    cp -- "$apk" "$destino"
    echo "[OK] APK $BUILD_VARIANT copiado: $destino"
    TOTAL=$((TOTAL + 1))
done

echo
echo "[SUCESSO] $TOTAL APK(s) da variante $BUILD_VARIANT gerado(s) e copiado(s)."
