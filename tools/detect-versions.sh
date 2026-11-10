#!/usr/bin/env bash
set -u

ROOT="${1:?Informe a pasta do projeto}"
PROFILE="${2:-all}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

if [[ ! -d "$ROOT" ]]; then
    echo "Projeto não encontrado: $ROOT"
    exit 1
fi

ROOT="$(cd -- "$ROOT" && pwd -P)"
cd "$ROOT"

scan() {
    local title="$1"
    local pattern="$2"

    echo
    echo "===== $title ====="

    grep -RInE \
        --exclude-dir=.git \
        --exclude-dir=node_modules \
        --exclude-dir=build \
        --exclude-dir=dist \
        --exclude-dir=.gradle \
        --exclude-dir=.idea \
        --exclude-dir=.venv \
        --exclude-dir=venv \
        "$pattern" . 2>/dev/null || echo "Nenhuma declaração encontrada."
}

echo "========================================"
echo " DETECTOR DE REQUISITOS DO PROJETO"
echo "========================================"
echo "Projeto: $(basename "$ROOT")"
echo "Perfil: $PROFILE"

case "$PROFILE" in
    python)
        scan "PYTHON: VERSÃO E CONFIGURAÇÕES" \
            'requires-python|python_requires|python_version|python='
        ;;
    java)
        scan "JAVA: VERSÃO EXIGIDA" \
            'maven.compiler.(source|target|release)|<source>|<target>|<release>|sourceCompatibility|targetCompatibility|JavaVersion.VERSION_|java.version|toolchain'
        scan "GRADLE: VERSÃO EXIGIDA" 'distributionUrl'
        ;;
    cpp)
        scan "C++: COMPILADOR E PADRÃO" \
            'cmake_minimum_required|CMAKE_CXX_STANDARD|CXX_STANDARD|set\(CMAKE_CXX_STANDARD|project\('
        ;;
    linux)
        scan "C: COMPILADOR E PADRÃO" \
            'cmake_minimum_required|CMAKE_C_STANDARD|C_STANDARD|CC[[:space:]]*=|gcc|clang'
        ;;
    android-gradle)
        scan "ANDROID GRADLE: VERSÕES E CONFIGURAÇÕES" \
            'compileSdk(Version)?|targetSdk(Version)?|minSdk(Version)?|ndkVersion|buildToolsVersion|com.android.tools.build:gradle|com.android.application'
        scan "ANDROID SDK E NDK LOCAIS" 'sdk.dir|ndk.dir|ANDROID_SDK_ROOT|ANDROID_NDK_HOME|ANDROID_NDK_ROOT'
        scan "GRADLE: VERSÃO EXIGIDA" 'distributionUrl'
        scan "JAVA: VERSÃO EXIGIDA" \
            'sourceCompatibility|targetCompatibility|JavaVersion.VERSION_|java.version|toolchain'
        ;;
    android-native)
        scan "ANDROID NATIVO: VERSÕES E CONFIGURAÇÕES" \
            'APP_PLATFORM|NDK_TOOLCHAIN_VERSION|APP_ABI|APP_STL'
        scan "ANDROID SDK E NDK LOCAIS" \
            'sdk.dir|ndk.dir|ANDROID_NDK_HOME|ANDROID_NDK_ROOT'
        scan "JAVA: VERSÃO EXIGIDA" \
            'sourceCompatibility|targetCompatibility|JavaVersion.VERSION_|java.version|toolchain'
        ;;
    all)
        scan "ANDROID: VERSÕES E CONFIGURAÇÕES" \
            'compileSdk(Version)?|targetSdk(Version)?|minSdk(Version)?|ndkVersion|buildToolsVersion|com.android.tools.build:gradle|com.android.application|APP_PLATFORM|NDK_TOOLCHAIN_VERSION'
        scan "ANDROID: SDK E NDK LOCAIS" \
            'sdk.dir|ndk.dir|ANDROID_NDK_HOME|ANDROID_NDK_ROOT'
        scan "GRADLE: VERSÃO EXIGIDA" 'distributionUrl'
        scan "JAVA: VERSÃO EXIGIDA" \
            'maven.compiler.(source|target|release)|<source>|<target>|<release>|sourceCompatibility|targetCompatibility|JavaVersion.VERSION_|java.version|toolchain'
        scan "C++: COMPILADOR E PADRÃO" \
            'cmake_minimum_required|CMAKE_CXX_STANDARD|CXX_STANDARD|set\(CMAKE_CXX_STANDARD|project\('
        scan "PYTHON: VERSÃO EXIGIDA" \
            'requires-python|python_requires|python_version|python='
        ;;
    *)
        echo "[ERRO] Perfil desconhecido: $PROFILE" >&2
        exit 2
        ;;
esac

echo
echo "===== ARQUIVOS DE VERSÃO ====="

case "$PROFILE" in
    python)
        find . -maxdepth 4 -type f \( \
            -name '.python-version' -o -name '.tool-versions' -o \
            -name 'pyproject.toml' -o -name 'setup.cfg' -o \
            -name 'setup.py' -o -name 'uv.lock' -o -name 'Pipfile' \
        \) -not -path '*/.git/*' -print
        ;;
    java|android-gradle)
        find . -maxdepth 5 -type f \( \
            -name '.java-version' -o -name '.tool-versions' -o \
            -name 'gradle-wrapper.properties' -o -name 'gradle.properties' \
        \) -not -path '*/.git/*' -print
        ;;
    android-native)
        find . -maxdepth 5 -type f \( \
            -name '.java-version' -o -name '.tool-versions' -o \
            -name 'gradle-wrapper.properties' -o -name 'pom.xml' \
        \) -not -path '*/.git/*' -print
        ;;
    cpp|linux)
        find . -maxdepth 4 -type f \( \
            -name 'CMakeLists.txt' -o -name 'CMakePresets.json' -o \
            -name 'Makefile' -o -name 'configure.ac' \
        \) -not -path '*/.git/*' -print
        ;;
    all)
        find . -maxdepth 4 -type f \( \
            -name '.python-version' -o -name '.java-version' -o \
            -name '.tool-versions' -o -name 'gradle-wrapper.properties' -o \
            -name 'global.json' \
        \) -not -path '*/.git/*' -print
        ;;
esac

echo
echo "===== FERRAMENTAS INTERNAS DISPONÍVEIS ====="

TOOLS_DIR="${TOOLS_DIR:-${UB_TOOLS_DIR:-$(cd "$SCRIPT_DIR/.." && pwd -P)/tools}}"
source "$SCRIPT_DIR/internal-tools.sh"

case "$PROFILE" in
    python) commands=(python3) ;;
    java) commands=(java javac gradle mvn) ;;
    cpp) commands=(cmake ninja make gcc g++ clang clang++) ;;
    linux) commands=(make gcc clang) ;;
    android-gradle)
        commands=(java javac gradle)
        if find "$ROOT" -type f -name Android.mk -not -path '*/.git/*' -print -quit | grep -q .; then
            commands+=(ndk-build)
        fi
        if find "$ROOT" -type f -name CMakeLists.txt -not -path '*/.git/*' -print -quit | grep -q .; then
            commands+=(cmake)
        fi
        if find "$ROOT" -type f -name Makefile -not -path '*/.git/*' -print -quit | grep -q .; then
            commands+=(make)
        fi
        ;;
    android-native)
        commands=(java javac)
        if find "$ROOT" -type f \( -name Android.mk -o -name Application.mk \) -not -path '*/.git/*' -print -quit | grep -q .; then
            commands+=(ndk-build)
        fi
        if find "$ROOT" -type f -name CMakeLists.txt -not -path '*/.git/*' -print -quit | grep -q .; then
            commands+=(cmake)
        fi
        if find "$ROOT" -type f -name Makefile -not -path '*/.git/*' -print -quit | grep -q .; then
            commands+=(make)
        fi
        ;;
    all) commands=(java javac cmake make gcc g++ clang clang++ python3 pip3 gradle mvn ninja) ;;
esac

for cmd in "${commands[@]}"; do
    path="$(ub_find_internal_tool "$cmd" || true)"
    if [[ -n "$path" ]]; then
        printf '[OK] %-10s %s\n' "$cmd" "$path"
    else
        printf '[--] %-10s não encontrado em tools/\n' "$cmd"
    fi
done

echo
echo "===== FIM DO DIAGNÓSTICO ====="

python3 "$SCRIPT_DIR/analyze-project.py" "$ROOT"
