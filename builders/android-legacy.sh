#!/usr/bin/env bash
set -Eeuo pipefail

: "${PROJECT_DIR:?PROJECT_DIR não definido}"
: "${TOOLS_DIR:?TOOLS_DIR não definido}"
: "${BUILDER_OUTPUT_DIR:?Diretório de saída não definido}"

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$ROOT/tools/discover-tools.sh"

ub_discover_android

fail() {
    echo "[ERRO] $*" >&2
    exit 1
}

need_file() {
    [[ -f "$1" ]] || fail "Arquivo necessário não encontrado: $1"
}

need_exec() {
    [[ -x "$1" ]] || fail "Executável necessário não encontrado ou sem permissão: $1"
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || fail "Comando ausente: $1"
}

MANIFEST="$PROJECT_DIR/AndroidManifest.xml"
need_file "$MANIFEST"

[[ -n "${ANDROID_SDK_ROOT:-}" ]] || fail "Android SDK não encontrado."

ANDROID_JAR="$ANDROID_SDK_ROOT/platforms/$ANDROID_PLATFORM/android.jar"
AAPT="${ANDROID_AAPT:-}"
DX="${ANDROID_DX:-}"
ZIPALIGN="${ANDROID_ZIPALIGN:-}"
APKSIGNER="${ANDROID_APKSIGNER:-}"

need_file "$ANDROID_JAR"
need_exec "$AAPT"
need_exec "$ZIPALIGN"
need_exec "$APKSIGNER"

HAS_JAVA_SOURCES=0
if find "$PROJECT_DIR" \
    -type d \( -name .git -o -name build -o -name .gradle -o -name .universal-builder \) -prune -o \
    -type f -name '*.java' -print -quit | grep -q .; then
    HAS_JAVA_SOURCES=1
    [[ -n "${JAVA_HOME:-}" ]] || fail "O projeto contém Java, mas nenhum JDK interno compatível foi encontrado."
    JAVAC="$JAVA_HOME/bin/javac"
    need_exec "$JAVAC"
    need_exec "$DX"
else
    JAVAC=""
    echo "[INFO] Nenhum código Java; JDK e DX não são necessários."
fi

need_cmd python3

echo "===== COMPILAÇÃO ANDROID AUTOMÁTICA ====="

# Ler os metadados diretamente do Manifest.
mapfile -t META < <(python3 - "$MANIFEST" "$PROJECT_DIR/project.properties" <<'PY'
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

manifest = Path(sys.argv[1])
properties = Path(sys.argv[2])

root = ET.parse(manifest).getroot()
ns = "{http://schemas.android.com/apk/res/android}"

package = root.attrib.get("package", "")
sdk = root.find("uses-sdk")

minimum = sdk.attrib.get(ns + "minSdkVersion", "1") if sdk is not None else "1"
target = sdk.attrib.get(ns + "targetSdkVersion", "") if sdk is not None else ""

if properties.is_file():
    for line in properties.read_text(errors="replace").splitlines():
        if line.strip().startswith("target="):
            value = line.split("=", 1)[1].strip()
            if value.startswith("android-"):
                target = value.removeprefix("android-")

if not target:
    target = minimum

print(package)
print(minimum)
print(target)
PY
)

PACKAGE="${META[0]:-}"
MIN_SDK="${META[1]:-1}"
TARGET_SDK="${META[2]:-1}"

[[ -n "$PACKAGE" ]] || fail "Pacote Android não identificado no Manifest."
[[ "$MIN_SDK" =~ ^[0-9]+$ ]] || fail "minSdkVersion inválido."
[[ "$TARGET_SDK" =~ ^[0-9]+$ ]] || fail "targetSdkVersion inválido."

echo "Pacote: $PACKAGE"
echo "Android mínimo: $MIN_SDK"
echo "Android alvo: $TARGET_SDK"
echo "SDK: $ANDROID_PLATFORM"

mkdir -p "$BUILDER_OUTPUT_DIR"

WORK="$(mktemp -d "$BUILDER_OUTPUT_DIR/.ub-build.XXXXXX")"
GEN="$WORK/generated"
CLASSES="$WORK/classes"
LIBS="$WORK/libs"
RES_APK="$WORK/resources.ap_"
UNSIGNED="$WORK/unsigned.apk"
ALIGNED="$WORK/aligned.apk"

FINAL_APK="$BUILDER_OUTPUT_DIR/${PACKAGE##*.}.apk"
OUTPUT_APK="$WORK/${PACKAGE##*.}.apk"

BUILD_SUCCEEDED=0

cleanup_build() {
    local status=$?

    if [[ "$BUILD_SUCCEEDED" == 1 ]]; then
        case "$WORK" in
            "$BUILDER_OUTPUT_DIR"/.ub-build.*)
                rm -rf -- "$WORK"
                ;;
            *)
                echo "[AVISO] Pasta temporária preservada: $WORK" >&2
                ;;
        esac
    else
        echo "[AVISO] Compilação não concluída."
        echo "[AVISO] Arquivos temporários preservados em: $WORK"
    fi

    return "$status"
}

trap cleanup_build EXIT

mkdir -p "$GEN" "$CLASSES" "$LIBS"

# 1. Gerar R.java e empacotar os recursos.
echo
echo "[1/6] Processando recursos Android..."

AAPT_ARGS=(
    package -f -m
    -J "$GEN"
    -M "$MANIFEST"
    -I "$ANDROID_JAR"
    -F "$RES_APK"
    --min-sdk-version "$MIN_SDK"
    --target-sdk-version "$TARGET_SDK"
)

[[ ! -d "$PROJECT_DIR/res" ]] || AAPT_ARGS+=(-S "$PROJECT_DIR/res")
[[ ! -d "$PROJECT_DIR/assets" ]] || AAPT_ARGS+=(-A "$PROJECT_DIR/assets")

"$AAPT" "${AAPT_ARGS[@]}"

# 2. Compilar o código Java.
echo
echo "[2/6] Compilando Java..."

JAVA_SOURCES=()
JAVA_LIBS=()

while IFS= read -r -d '' file; do
    JAVA_SOURCES+=("$file")
done < <(
    find "$PROJECT_DIR" \
        \( -path "$PROJECT_DIR/.git" \
        -o -path "$PROJECT_DIR/.universal-builder" \
        -o -path "$PROJECT_DIR/build" \
        -o -path "$PROJECT_DIR/.gradle" \) -prune \
        -o -type f -name '*.java' -print0
)

# Bibliotecas JAR fornecidas pelo projeto em diretórios libs/ ou lib/.
while IFS= read -r -d '' libdir; do
    while IFS= read -r -d '' file; do
        JAVA_LIBS+=("$file")
    done < <(find "$libdir" -type f -name '*.jar' -print0)
done < <(
    find "$PROJECT_DIR" \
        \( -path "$PROJECT_DIR/.git" -o -path "$PROJECT_DIR/.universal-builder" \
        -o -path "$PROJECT_DIR/build" -o -path "$PROJECT_DIR/.gradle" \) -prune \
        -o -type d \( -name libs -o -name lib \) -print0
)

while IFS= read -r -d '' file; do
    JAVA_SOURCES+=("$file")
done < <(find "$GEN" -type f -name '*.java' -print0)

if (("${#JAVA_SOURCES[@]}")); then
    JAVA_SOURCE_LEVEL="${UB_JAVA_SOURCE:-8}"
    JAVA_TARGET_LEVEL="${UB_JAVA_TARGET:-$JAVA_SOURCE_LEVEL}"
    [[ "$JAVA_SOURCE_LEVEL" =~ ^(1\.)?[0-9]+$ && "$JAVA_TARGET_LEVEL" =~ ^(1\.)?[0-9]+$ ]] ||
        fail "UB_JAVA_SOURCE/UB_JAVA_TARGET inválidos."

    JAVA_CLASSPATH="$ANDROID_JAR"
    for jar in "${JAVA_LIBS[@]}"; do
        JAVA_CLASSPATH="$JAVA_CLASSPATH:$jar"
    done

    "$JAVAC" \
        -encoding UTF-8 \
        -source "$JAVA_SOURCE_LEVEL" -target "$JAVA_TARGET_LEVEL" \
        -bootclasspath "$ANDROID_JAR" \
        -classpath "$JAVA_CLASSPATH" \
        -d "$CLASSES" \
        "${JAVA_SOURCES[@]}"
else
    echo "Nenhum código Java encontrado."
fi

# 3. Gerar DEX.
echo
echo "[3/6] Gerando DEX..."

if ((${#JAVA_SOURCES[@]})); then
    "$DX" --dex --output="$WORK/classes.dex" "$CLASSES" "${JAVA_LIBS[@]}"
fi

# 4. Compilar bibliotecas nativas, se existirem.
echo
echo "[4/6] Verificando código nativo..."

ANDROID_MK="$(find "$PROJECT_DIR" \
    -type d \( -name .git -o -name build -o -name .gradle -o -name .universal-builder \) -prune -o \
    -type f -name Android.mk -print -quit 2>/dev/null)"
APPLICATION_MK="$(find "$PROJECT_DIR" \
    -type d \( -name .git -o -name build -o -name .gradle -o -name .universal-builder \) -prune -o \
    -type f -name Application.mk -print -quit 2>/dev/null)"

if [[ -n "$ANDROID_MK" ]]; then
    [[ -x "$ANDROID_NDK_HOME/ndk-build" ]] ||
        fail "ndk-build não encontrado."

    NDK_ARGS=(
        "NDK_PROJECT_PATH=$PROJECT_DIR"
        "APP_BUILD_SCRIPT=$ANDROID_MK"
        "NDK_OUT=$WORK/obj"
        "NDK_LIBS_OUT=$LIBS"
    )

    if [[ -n "$APPLICATION_MK" ]]; then
        NDK_ARGS+=("NDK_APPLICATION_MK=$APPLICATION_MK")
    fi

    "$ANDROID_NDK_HOME/ndk-build" -C "$PROJECT_DIR" "${NDK_ARGS[@]}"
else
    echo "Projeto sem Android.mk. Etapa nativa ignorada."
fi

# 5. Montar APK.
echo
echo "[5/6] Montando APK..."

cp "$RES_APK" "$UNSIGNED"

python3 - "$UNSIGNED" "$WORK/classes.dex" "$LIBS" <<'PY'
import sys
import zipfile
from pathlib import Path

apk = Path(sys.argv[1])
dex = Path(sys.argv[2])
libs = Path(sys.argv[3])

with zipfile.ZipFile(apk, "a", zipfile.ZIP_DEFLATED) as z:
    if dex.is_file():
        z.write(dex, "classes.dex")

    if libs.is_dir():
        for lib in libs.rglob("*.so"):
            relative = lib.relative_to(libs)
            z.write(lib, "lib/" + relative.as_posix())
PY

# 6. Alinhar e assinar.
echo
echo "[6/6] Alinhando e assinando APK..."

KEYSTORE="${UB_KEYSTORE_PATH:-$TOOLS_DIR/keys/universal-builder-release.jks}"
KEY_ALIAS="${UB_KEY_ALIAS:-universal-builder}"

echo "Assinatura: RELEASE (chave geral)"

need_file "$KEYSTORE"

PASSWORD_FILE="${UB_PASSWORD_FILE:-$TOOLS_DIR/keys/release-passwords.conf}"
need_file "$PASSWORD_FILE"
# Ler somente as duas chaves esperadas; não executar o arquivo de configuração.
read_secret() {
    local key="$1"
    awk -v key="$key" '
        /^[[:space:]]*#/ { next }
        {
            line=$0
            sub(/^[[:space:]]*/, "", line)
            if (index(line, key "=") == 1) {
                value=substr(line, length(key)+2)
                sub(/^[[:space:]]*/, "", value)
                quote=substr(value, 1, 1)
                if (quote == "\"" || quote == sprintf("%c", 39)) {
                    value=substr(value, 2)
                    end=index(value, quote)
                    if (end > 0) value=substr(value, 1, end-1)
                } else {
                    sub(/[[:space:]]+#.*/, "", value)
                    sub(/[[:space:]]*$/, "", value)
                }
                print value
                exit
            }
        }
    ' "$PASSWORD_FILE"
}

UB_KEYSTORE_PASS="$(read_secret UB_KEYSTORE_PASS)"
UB_KEY_PASS="$(read_secret UB_KEY_PASS)"
[[ -n "$UB_KEYSTORE_PASS" ]] || fail "Senha do keystore não encontrada no arquivo."
UB_KEY_PASS="${UB_KEY_PASS:-$UB_KEYSTORE_PASS}"
export UB_KEYSTORE_PASS UB_KEY_PASS

SIGN_ARGS=(
    --ks "$KEYSTORE"
    --ks-key-alias "$KEY_ALIAS"
    --ks-pass "env:UB_KEYSTORE_PASS"
    --key-pass "env:UB_KEY_PASS"
)

"$ZIPALIGN" -f 4 "$UNSIGNED" "$ALIGNED"

"$APKSIGNER" sign \
    "${SIGN_ARGS[@]}" \
    --out "$OUTPUT_APK" \
    "$ALIGNED"

unset UB_KEYSTORE_PASS UB_KEY_PASS


"$APKSIGNER" verify "$OUTPUT_APK" ||
    fail "A verificação da assinatura falhou."

[[ -s "$OUTPUT_APK" ]] || fail "APK não foi gerado."

[[ ! -e "$FINAL_APK" ]] || fail "O APK de destino já existe; preservando arquivo: $FINAL_APK"
mv -- "$OUTPUT_APK" "$FINAL_APK"
BUILD_SUCCEEDED=1

echo
echo "[SUCESSO] APK criado:"
echo "$FINAL_APK"
