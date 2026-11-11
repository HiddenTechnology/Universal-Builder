#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS="$ROOT/tools"
SDK="$TOOLS/android-sdk"

log()  { printf '\n[UB] %s\n' "$*"; }
ok()   { printf '[OK] %s\n' "$*"; }
warn() { printf '[AVISO] %s\n' "$*"; }
fail() { printf '[ERRO] %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------
# Selecionar projeto por argumento
# ---------------------------------------------------------

if [[ $# -ne 1 ]]; then
    echo "Uso: $0 CAMINHO_DO_PROJETO"
    echo
    echo "Exemplos:"
    echo "  $0 projects/Horror_Game"
    echo "  $0 tools/Horror_Game"
    echo "  $0 /home/brayan/projetos/MeuApp"
    exit 1
fi

PROJECT_ARG="$1"
PROJECT="$(realpath -e -- "$PROJECT_ARG" 2>/dev/null || true)"

if [[ -z "$PROJECT" || ! -d "$PROJECT" ]]; then
    echo "[ERRO] Diretório do projeto não encontrado: $PROJECT_ARG" >&2
    exit 1
fi

log "Projeto selecionado: $PROJECT"

# ---------------------------------------------------------
# Funções de detecção
# ---------------------------------------------------------

read_value() {
    local file="$1"
    local regex="$2"

    [[ -f "$file" ]] || return 0

    grep -Eho "$regex" "$file" 2>/dev/null |
        head -n 1 |
        sed -E 's/.*[:= ]+//; s/["'\'']//g; s/[[:space:]]//g' || true
}

find_version() {
    local file="$1"
    local regex="$2"

    [[ -f "$file" ]] || return 0

    grep -Eho "$regex" "$file" 2>/dev/null |
        head -n 1 |
        grep -Eo '[0-9]+(\.[0-9]+)*' || true
}

# ---------------------------------------------------------
# Android: Manifest, Gradle e project.properties
# ---------------------------------------------------------

log "Analisando requisitos Android..."

MANIFEST="$PROJECT/AndroidManifest.xml"
PROPERTIES="$PROJECT/project.properties"

MIN_SDK=""
TARGET_SDK=""
COMPILE_SDK=""
BUILD_TOOLS=""
NDK_VERSION=""
JAVA_VERSION=""
AGP_VERSION=""
GRADLE_VERSION=""

if [[ -f "$MANIFEST" ]]; then
    MIN_SDK="$(read_value "$MANIFEST" 'android:minSdkVersion="[0-9]+"')"
    TARGET_SDK="$(read_value "$MANIFEST" 'android:targetSdkVersion="[0-9]+"')"
fi

if [[ -f "$PROPERTIES" ]]; then
    TARGET_SDK="${TARGET_SDK:-$(read_value "$PROPERTIES" '^target=android-[0-9]+')}"
    TARGET_SDK="${TARGET_SDK#android-}"
fi

# Procurar configurações Gradle em todos os módulos.
while IFS= read -r file; do
    [[ -f "$file" ]] || continue

    value="$(find_version "$file" \
        'compileSdk(Version)?[[:space:]]*(=|[[:space:]])*[0-9]+')"
    [[ -n "$value" ]] && COMPILE_SDK="$value"

    value="$(find_version "$file" \
        'buildToolsVersion[[:space:]]*[=( ]+[\"'\''][0-9.]+')"
    [[ -n "$value" ]] && BUILD_TOOLS="$value"

    value="$(find_version "$file" \
        'ndkVersion[[:space:]]*[=( ]+[\"'\''][0-9.]+')"
    [[ -n "$value" ]] && NDK_VERSION="$value"

    value="$(find_version "$file" \
        'com.android.tools.build:gradle:[0-9.]+')"
    [[ -n "$value" ]] && AGP_VERSION="$value"

    value="$(find_version "$file" \
        'distributionUrl=.*gradle-[0-9.]+-(bin|all)\.zip')"
    [[ -n "$value" ]] && GRADLE_VERSION="$value"

    value="$(find_version "$file" \
        'JavaVersion\.VERSION_[0-9]+')"
    [[ -n "$value" ]] && JAVA_VERSION="$value"

done < <(find "$PROJECT" -type f \
    \( -name build.gradle -o -name build.gradle.kts \
       -o -name gradle-wrapper.properties \) \
    -not -path '*/.gradle/*' 2>/dev/null)

# Se compileSdk não estiver declarado, usar targetSdk como referência.
COMPILE_SDK="${COMPILE_SDK:-$TARGET_SDK}"

# ---------------------------------------------------------
# NDK: Application.mk e Android.mk
# ---------------------------------------------------------

APP_PLATFORM=""
APP_ABI=""
APP_STL=""
NDK_TOOLCHAIN=""

APP_MK="$PROJECT/jni/Application.mk"

if [[ -f "$APP_MK" ]]; then
    APP_PLATFORM="$(read_value "$APP_MK" '^APP_PLATFORM[[:space:]]*:=[[:space:]]*android-[0-9]+')"
    APP_ABI="$(read_value "$APP_MK" '^APP_ABI[[:space:]]*:=[[:space:]]*[a-zA-Z0-9_-]+')"
    APP_STL="$(read_value "$APP_MK" '^APP_STL[[:space:]]*:=[[:space:]]*[a-zA-Z0-9_-]+')"
    NDK_TOOLCHAIN="$(read_value "$APP_MK" '^NDK_TOOLCHAIN_VERSION[[:space:]]*:=[[:space:]]*[a-zA-Z0-9_.-]+')"
fi

BUILD_SYSTEM="desconhecido"

if [[ -f "$PROJECT/jni/Android.mk" ]]; then
    BUILD_SYSTEM="ndk-build"
elif [[ -f "$PROJECT/CMakeLists.txt" ]]; then
    BUILD_SYSTEM="cmake"
elif [[ -f "$PROJECT/build.gradle" ||
        -f "$PROJECT/build.gradle.kts" ]]; then
    BUILD_SYSTEM="gradle"
fi

# ---------------------------------------------------------
# Exibir diagnóstico
# ---------------------------------------------------------

echo
echo "=========================================="
echo "       REQUISITOS DETECTADOS"
echo "=========================================="

printf "Projeto:          %s\n" "$(basename "$PROJECT")"
printf "Sistema de build: %s\n" "$BUILD_SYSTEM"
printf "Min SDK:          %s\n" "${MIN_SDK:-não identificado}"
printf "Target SDK:       %s\n" "${TARGET_SDK:-não identificado}"
printf "Compile SDK:      %s\n" "${COMPILE_SDK:-não identificado}"
printf "Build Tools:      %s\n" "${BUILD_TOOLS:-não declaradas}"
printf "AGP:              %s\n" "${AGP_VERSION:-não identificado}"
printf "Gradle:           %s\n" "${GRADLE_VERSION:-não identificado}"
printf "Java:             %s\n" "${JAVA_VERSION:-não identificado}"
printf "NDK:              %s\n" "${NDK_VERSION:-não declarado}"
printf "APP_PLATFORM:     %s\n" "${APP_PLATFORM:-não declarado}"
printf "APP_ABI:          %s\n" "${APP_ABI:-não declarado}"
printf "APP_STL:          %s\n" "${APP_STL:-não declarado}"
printf "NDK Toolchain:    %s\n" "${NDK_TOOLCHAIN:-não declarado}"

# ---------------------------------------------------------
# Verificar SDK Manager
# ---------------------------------------------------------

SDKMANAGER="$SDK/cmdline-tools/latest/bin/sdkmanager"

if [[ ! -x "$SDKMANAGER" ]]; then
    fail "sdkmanager não encontrado em $SDKMANAGER. Instale primeiro as Command-line Tools."
fi

# ---------------------------------------------------------
# Identificar componentes ausentes
# ---------------------------------------------------------

PLAN=()

if [[ -n "$COMPILE_SDK" ]]; then
    if [[ ! -f "$SDK/platforms/android-$COMPILE_SDK/android.jar" ]]; then
        PLAN+=("platforms;android-$COMPILE_SDK")
    else
        ok "Android Platform $COMPILE_SDK já instalada."
    fi
fi

if [[ -n "$BUILD_TOOLS" ]]; then
    if [[ ! -d "$SDK/build-tools/$BUILD_TOOLS" ]]; then
        PLAN+=("build-tools;$BUILD_TOOLS")
    else
        ok "Build Tools $BUILD_TOOLS já instaladas."
    fi
fi

# ndkVersion explícita: instalar a versão declarada.
# NDK legado com gnustl/GCC 4.9: não substituir automaticamente.
if [[ -n "$NDK_VERSION" ]]; then
    if [[ ! -d "$SDK/ndk/$NDK_VERSION" ]]; then
        PLAN+=("ndk;$NDK_VERSION")
    else
        ok "NDK $NDK_VERSION já instalado."
    fi
elif [[ "$APP_STL" == "gnustl_static" ||
        "$NDK_TOOLCHAIN" == "4.9" ]]; then
    warn "Projeto exige NDK legado. Não será instalado um NDK moderno automaticamente."
    found=0
    for ndk in "$TOOLS"/android/*; do
        if [[ -x "$ndk/ndk-build" &&
              -d "$ndk/sources/cxx-stl/gnu-libstdc++" ]]; then
            ok "NDK legado encontrado: $ndk"
            found=1
        fi
    done
    (( found )) || warn "NDK legado compatível não encontrado em tools/android."
fi

# Platform Tools: necessárias para adb e instalação de APK.
if [[ ! -x "$SDK/platform-tools/adb" ]]; then
    PLAN+=("platform-tools")
else
    ok "Platform Tools já instaladas."
fi

# ---------------------------------------------------------
# Build Tools: resolução dinâmica para projetos legados
# ---------------------------------------------------------

NEEDS_DX=0

if find "$PROJECT" -type f -name '*.java' \
    -not -path '*/build/*' \
    -not -path '*/.gradle/*' -print -quit 2>/dev/null |
    grep -q .; then
    NEEDS_DX=1
fi

if (( NEEDS_DX )) && [[ "$BUILD_SYSTEM" != "gradle" ]]; then
    log "Projeto Java legado: verificando necessidade de DX..."

    compatible_bt=""

    for bt in "$SDK"/build-tools/*; do
        [[ -d "$bt" ]] || continue

        if [[ -x "$bt/dx" && -x "$bt/aapt" &&
              -x "$bt/zipalign" && -x "$bt/apksigner" ]]; then
            version="$(basename "$bt")"

            if [[ -n "$BUILD_TOOLS" && "$version" == "$BUILD_TOOLS" ]]; then
                compatible_bt="$version"
                break
            fi

            if [[ -z "$compatible_bt" ]]; then
                compatible_bt="$version"
            elif [[ "$version" == "$compatible_bt" ]]; then
                :
            fi
        fi
    done

    if [[ -n "$compatible_bt" ]]; then
        BUILD_TOOLS="$compatible_bt"
        ok "Build Tools compatíveis encontradas: $BUILD_TOOLS"
    else
        log "Consultando versões disponíveis no SDK Manager..."

        compile_major="${COMPILE_SDK%%.*}"
        available=()

        while IFS= read -r version; do
            [[ -n "$version" ]] && available+=("$version")
        done < <(
            "$SDKMANAGER" --sdk_root="$SDK" --list 2>/dev/null |
            sed -nE 's/.*build-tools;([0-9]+(\.[0-9]+)*)[[:space:]]*\|.*/\1/p' |
            sort -Vu
        )

        selected=""

        # Priorizar a mesma geração do compileSdk.
        for version in "${available[@]}"; do
            major="${version%%.*}"
            if [[ "$major" == "$compile_major" ]]; then
                selected="$version"
            fi
        done

        # Alternativa: maior versão estável anterior ou igual.
        if [[ -z "$selected" && "$compile_major" =~ ^[0-9]+$ ]]; then
            for version in "${available[@]}"; do
                major="${version%%.*}"
                if [[ "$major" =~ ^[0-9]+$ ]] &&
                   (( major <= compile_major )); then
                    selected="$version"
                fi
            done
        fi

        if [[ -n "$selected" ]]; then
            BUILD_TOOLS="$selected"
            PLAN+=("build-tools;$selected")
            ok "Versão selecionada automaticamente: $selected"
        else
            warn "Nenhuma Build Tools estável compatível foi encontrada."
        fi
    fi
fi

# ---------------------------------------------------------
# Plano de instalação
# ---------------------------------------------------------

echo
echo "=========================================="
echo "       PLANO DE PREPARAÇÃO"
echo "=========================================="

if (( ${#PLAN[@]} == 0 )); then
    ok "Nenhum componente SDK ausente foi identificado."
else
    printf 'Será solicitado ao SDK Manager:\n'
    printf '  - %s\n' "${PLAN[@]}"
fi

echo
echo "Nenhuma ferramenta existente será apagada."
echo "Nenhum arquivo do projeto será alterado."

if (( ${#PLAN[@]} == 0 )); then
    exit 0
fi

read -r -p "Deseja instalar os componentes listados? [s/N] " answer

case "$answer" in
    s|S|sim|SIM)
        ;;
    *)
        log "Instalação cancelada pelo usuário."
        exit 0
        ;;
esac

# ---------------------------------------------------------
# Instalação
# ---------------------------------------------------------

export JAVA_HOME="$TOOLS/java/$(basename "$(find "$TOOLS/java" \
    -mindepth 1 -maxdepth 1 -type d -name 'jdk-*' | head -n 1)")"

if [[ -x "$JAVA_HOME/bin/java" ]]; then
    export PATH="$JAVA_HOME/bin:$PATH"
fi

log "Aceitando licenças do Android SDK..."
yes | "$SDKMANAGER" --sdk_root="$SDK" --licenses >/dev/null 2>&1 || true

log "Instalando componentes..."

"$SDKMANAGER" --sdk_root="$SDK" "${PLAN[@]}" ||
    fail "O SDK Manager informou falha durante a instalação."

# ---------------------------------------------------------
# Validação final
# ---------------------------------------------------------

echo
echo "=========================================="
echo "       VALIDAÇÃO FINAL"
echo "=========================================="

failed=0

if [[ -n "$COMPILE_SDK" ]]; then
    if [[ -f "$SDK/platforms/android-$COMPILE_SDK/android.jar" ]]; then
        ok "Android Platform $COMPILE_SDK"
    else
        warn "Android Platform $COMPILE_SDK ausente"
        failed=1
    fi
fi

if [[ -n "$BUILD_TOOLS" ]]; then
    if [[ -d "$SDK/build-tools/$BUILD_TOOLS" ]]; then
        ok "Build Tools $BUILD_TOOLS"
    else
        warn "Build Tools $BUILD_TOOLS ausentes"
        failed=1
    fi
fi

if [[ -x "$SDK/platform-tools/adb" ]]; then
    ok "ADB disponível"
else
    warn "ADB não encontrado"
    failed=1
fi

if (( NEEDS_DX )) && [[ "$BUILD_SYSTEM" != "gradle" &&
    -n "$BUILD_TOOLS" ]]; then

    bt_dir="$SDK/build-tools/$BUILD_TOOLS"

    for tool in dx aapt zipalign apksigner; do
        if [[ -x "$bt_dir/$tool" ]]; then
            ok "$tool disponível"
        else
            warn "$tool ausente ou não executável em $bt_dir"
            failed=1
        fi
    done
fi

if (( failed )); then
    fail "Preparação incompleta. Consulte os avisos acima."
fi

log "Preparação concluída."
echo "Próximo passo: ./builder.sh check \"$PROJECT\""
