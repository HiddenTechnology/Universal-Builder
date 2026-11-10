#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
INPUT="$ROOT/ferramentas"
TOOLS="$ROOT/tools"

WORK=""
COUNT=0
INSTALLED=0
FAILED=0
IGNORED=0

msg() {
    printf '\n[UB] %s\n' "$*"
}

error() {
    printf '[ERRO] %s\n' "$*" >&2
}

cleanup() {
    if [[ -n "$WORK" && -d "$WORK" ]]; then
        rm -rf -- "$WORK"
    fi
}
trap cleanup EXIT

# Mescla diretórios sem substituir arquivos existentes.
# Permite instalar versões adicionais de SDK/Build Tools no mesmo diretório.
copy_tree() {
    local source="$1"
    local destination="$2"

    [[ -d "$source" ]] || return 1
    mkdir -p -- "$destination"
    cp -a -n -- "$source/." "$destination/"
}

# Procura os executáveis dentro do pacote extraído.
find_ndk() {
    find "$1" -type d \
        \( -name .git -o -name build -o -name sources \) -prune -o \
        -type f -name ndk-build -print -quit 2>/dev/null
}

find_jdk() {
    find "$1" -type f -path '*/bin/javac' -print -quit 2>/dev/null
}

find_gradle() {
    find "$1" -type f -path '*/bin/gradle' -print -quit 2>/dev/null
}

find_sdkmanager() {
    find "$1" -type f -name sdkmanager -print -quit 2>/dev/null
}

# Organiza o Android NDK.
install_ndk() {
    local executable="$1"
    local source name destination

    source="$(dirname "$executable")"
    name="$(basename "$source")"
    destination="$TOOLS/android/$name"

    msg "NDK encontrado: $name"

    copy_tree "$source" "$destination" || return 1

    chmod +x "$destination/ndk-build"

    msg "NDK instalado em tools/android/$name"
}

# Organiza somente as versões de JDK suportadas pelo Builder.
install_jdk() {
    local javac="$1"
    local source name version destination

    source="$(dirname "$(dirname "$javac")")"
    name="$(basename "$source")"
    version=""

    if [[ -f "$source/release" ]]; then
        version="$(
            sed -nE 's/^JAVA_VERSION="([^"]+)".*/\1/p' \
                "$source/release" | head -n 1
        )"
    fi

    # Manter cada JDK em seu próprio diretório; não limitar versões.
    [[ -n "$name" && "$name" != "." && "$name" != ".." ]] || {
        error "Nome do diretório JDK inválido."
        return 1
    }
    destination="$TOOLS/java/$name"
    if [[ -e "$destination" ]]; then
        destination="$TOOLS/java/${name}-${version:-unknown}"
    fi

    msg "JDK encontrado: ${version:-$name}"

    copy_tree "$source" "$destination" || return 1

    chmod +x "$destination/bin/java" "$destination/bin/javac"

    msg "JDK organizado em ${destination#"$ROOT"/}"
}

# Organiza uma distribuição Gradle.
install_gradle() {
    local executable="$1"
    local source name destination

    source="$(dirname "$(dirname "$executable")")"
    name="$(basename "$source")"
    destination="$TOOLS/gradle/$name"

    msg "Gradle encontrado: $name"

    copy_tree "$source" "$destination" || return 1

    chmod +x "$destination/bin/gradle"

    msg "Gradle instalado em tools/gradle/$name"
}

# Organiza as Command-line Tools.
install_cmdline_tools() {
    local executable="$1"
    local bin version_dir destination

    bin="$(dirname "$executable")"
    version_dir="$(dirname "$bin")"
    destination="$TOOLS/android-sdk/cmdline-tools/latest"

    msg "Android SDK Command-line Tools encontradas."

    copy_tree "$version_dir" "$destination" || return 1

    chmod +x "$destination/bin/sdkmanager"

    msg "Command-line Tools instaladas em tools/android-sdk/cmdline-tools/latest"
}

# Copia componentes SDK encontrados no pacote.
install_sdk_component() {
    local source="$1"
    local component="$2"
    local destination="$TOOLS/android-sdk/$component"

    [[ -d "$source" ]] || return 0

    msg "Componente Android SDK encontrado: $component"

    copy_tree "$source" "$destination" || return 1

    msg "Componente organizado em tools/android-sdk/$component"
}

# Procura e instala plataformas, Build Tools, platform-tools e licenças.
install_sdk_components() {
    local stage="$1"
    local component source found=0
    local -a components=(
        platforms
        build-tools
        platform-tools
        licenses
    )

    for component in "${components[@]}"; do
        source="$(
            find "$stage" -type d -name "$component" -print -quit 2>/dev/null
        )"

        if [[ -n "$source" ]]; then
            install_sdk_component "$source" "$component" || return 1
            found=1
        fi
    done

    [[ "$found" -eq 1 ]]
}

# Organiza toolchains de host sem exigir que estejam instaladas no sistema.
install_host_package() {
    local stage="$1" archive="$2" base destination tool executable
    base="$(basename "$archive")"
    base="${base%.tar.gz}"; base="${base%.tar.xz}"; base="${base%.tar.bz2}"
    base="${base%.tgz}"; base="${base%.txz}"; base="${base%.tbz2}"
    base="${base%.zip}"; base="${base%.tar}"
    [[ -n "$base" ]] || base="toolchain"
    destination="$TOOLS/host/$base"
    mkdir -p -- "$destination"
    cp -a -n -- "$stage/." "$destination/"

    for tool in cmake make gcc g++ clang clang++ python3 pip3 mvn ninja ant; do
        while IFS= read -r -d '' executable; do
            chmod +x -- "$executable"
        done < <(find "$destination" -type f -name "$tool" -print0 2>/dev/null)
    done
    msg "Pacote de ferramentas de host organizado em tools/host/$base"
}

has_host_tool() {
    local stage="$1"
    find "$stage" -type f \( -name cmake -o -name make -o -name gcc -o -name g++ \
        -o -name clang -o -name clang++ -o -name python3 -o -name pip3 \
        -o -name mvn -o -name ninja -o -name ant \) -print -quit 2>/dev/null | grep -q .
}

# Extrai o pacote em uma pasta temporária e identifica seu conteúdo.
process_archive() {
    local archive="$1"
    local stage="$WORK/extracted"
    local marker sdk_found=0

    mkdir -p "$stage"

    msg "Analisando pacote: $(basename "$archive")"

    case "$archive" in
        *.zip|*.ZIP)
            if ! command -v unzip >/dev/null 2>&1; then
                error "unzip não está disponível no sistema."
                return 1
            fi

            unzip -q "$archive" -d "$stage" || return 1
            ;;
        *.tar.gz|*.tgz|*.TAR.GZ|*.TGZ|*.tar.xz|*.txz|*.TAR.XZ|*.TXZ|*.tar|*.tar.bz2|*.tbz2)
            tar -xf "$archive" -C "$stage" || return 1
            ;;
        *)
            error "Formato não suportado."
            return 1
            ;;
    esac

    # Primeiro verifica ferramentas completas.
    marker="$(find_ndk "$stage" || true)"
    if [[ -n "$marker" ]]; then
        install_ndk "$marker"
        return $?
    fi

    marker="$(find_jdk "$stage" || true)"
    if [[ -n "$marker" ]]; then
        install_jdk "$marker"
        return $?
    fi

    marker="$(find_gradle "$stage" || true)"
    if [[ -n "$marker" ]]; then
        install_gradle "$marker"
        return $?
    fi

    # Command-line Tools.
    marker="$(find_sdkmanager "$stage" || true)"
    if [[ -n "$marker" ]]; then
        install_cmdline_tools "$marker" || return 1
        sdk_found=1
    fi

    # Componentes do SDK, inclusive quando estão em arquivos separados.
    if install_sdk_components "$stage"; then
        sdk_found=1
    fi

    if [[ "$sdk_found" -eq 1 ]]; then
        return 0
    fi

    if has_host_tool "$stage"; then
        install_host_package "$stage" "$archive"
        return 0
    fi

    error "Não foi possível identificar o conteúdo desse pacote."
    error "O arquivo original foi preservado."
    return 1
}

main() {
    local archive

    msg "INSTALADOR MANUAL DO UNIVERSAL BUILDER"

    echo "Origem:  $INPUT"
    echo "Destino: $TOOLS"
    echo
    echo "Downloads automáticos: NÃO"
    echo "Remoção dos arquivos originais: NÃO"
    echo "Sobrescrita de ferramentas: NÃO"

    if [[ ! -d "$INPUT" ]]; then
        error "A pasta ferramentas/ não existe."
        return 1
    fi

    command -v tar >/dev/null 2>&1 || {
        error "O comando tar não está disponível."
        return 1
    }

    mkdir -p "$TOOLS"

    WORK="$(mktemp -d "${TMPDIR:-/tmp}/ub-install.XXXXXX")"

    while IFS= read -r -d '' archive; do
        COUNT=$((COUNT + 1))

        if process_archive "$archive"; then
            INSTALLED=$((INSTALLED + 1))
        else
            FAILED=$((FAILED + 1))
            error "Falha ao processar $(basename "$archive")."
        fi

        rm -rf -- "$WORK/extracted"
    done < <(
        find "$INPUT" -maxdepth 1 -type f \
            \( -iname '*.zip' \
            -o -iname '*.tar.gz' \
            -o -iname '*.tgz' \
            -o -iname '*.tar.xz' \
            -o -iname '*.txz' \
            -o -iname '*.tar' \
            -o -iname '*.tar.bz2' \
            -o -iname '*.tbz2' \) \
            -print0 | sort -z
    )

    echo
    echo "========== RELATÓRIO =========="
    echo "Pacotes encontrados: $COUNT"
    echo "Pacotes organizados: $INSTALLED"
    echo "Pacotes com falha:   $FAILED"
    echo
    echo "Arquivos originais preservados em:"
    echo "$INPUT"

    if (( COUNT == 0 )); then
        msg "Nenhum pacote compactado encontrado."
    fi

    if (( FAILED > 0 )); then
        return 1
    fi

    return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
