#!/usr/bin/env bash
set -Eeuo pipefail

UB_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECTS_DIR="${UB_PROJECTS_DIR:-$UB_ROOT/projects}"
TOOLS_DIR="${UB_TOOLS_DIR:-$UB_ROOT/tools}"
OUTPUT_ROOT="${UB_OUTPUT_DIR:-$UB_ROOT/output}"
PROFILES_DIR="$UB_ROOT/profiles"

mkdir -p "$PROJECTS_DIR" "$TOOLS_DIR" "$OUTPUT_ROOT"

PROFILES=(android-gradle android-native cpp java python linux)

usage() {
cat <<EOF
Universal Builder
Uso:
  ./builder.sh wizard
  ./builder.sh list
  ./builder.sh clone URL [NOME]
  ./builder.sh init PASTA --profile PERFIL
  ./builder.sh requirements PASTA
  ./builder.sh check PASTA
  ./builder.sh build PASTA
  ./builder.sh clean PASTA
  ./builder.sh doctor
EOF
}

valid_profile() {
    local p
    for p in "${PROFILES[@]}"; do [[ "$p" == "$1" ]] && return 0; done
    return 1
}

detect_profile() {
    local dir="$1"
    local gradle_file

    # Projetos Android com Gradle têm perfil próprio, mesmo com Manifest
    # localizado dentro de app/src/main ou de outro módulo.
    while IFS= read -r gradle_file; do
        if grep -Eq \
            'com\.android\.(application|library)|com\.android\.tools\.build:gradle|compileSdk(Version)?[[:space:]]' \
            "$gradle_file"; then
            echo android-gradle
            return 0
        fi
    done < <(
        find "$dir" \
            -type d \( -name .git -o -name build -o -name .gradle -o -name node_modules \) -prune -o \
            -type f \( -name build.gradle -o -name build.gradle.kts \) -print
    )

    # Android NDK/ant legado, sem plugin Android Gradle.
    if [[ -d "$dir/jni" || -f "$dir/Application.mk" || -f "$dir/Android.mk" ||
          -f "$dir/AndroidManifest.xml" ]] || find "$dir" \
        -type d \( -name .git -o -name build -o -name .gradle -o -name node_modules \) -prune -o \
        -type f -name AndroidManifest.xml -print -quit | grep -q .; then
        echo android-native
    elif [[ -f "$dir/CMakeLists.txt" || -f "$dir/Makefile" || -f "$dir/CMakePresets.json" ]]; then
        echo cpp
    elif [[ -f "$dir/pom.xml" || -f "$dir/build.gradle" || -f "$dir/build.gradle.kts" ]]; then
        echo java
    elif [[ -f "$dir/pyproject.toml" || -f "$dir/requirements.txt" || -f "$dir/setup.py" ]]; then
        echo python
    else
        echo ""
    fi
}

load_project() {
    local dir="$1"
    local detected example saved_profile

    dir="$(cd -- "$dir" && pwd -P)" || return 1
    [[ -d "$dir" ]] || {
        echo "Projeto não encontrado: $dir"
        return 1
    }

    # Criar a configuração automaticamente quando ela ainda não existir.
    if [[ ! -f "$dir/builder.conf" ]]; then
        echo "[DETECTOR] Configuração ausente. Analisando o projeto..."

        detected="$(detect_profile "$dir")"

        if [[ -z "$detected" ]] || ! valid_profile "$detected"; then
            echo "[ERRO] Não foi possível identificar o perfil do projeto."
            return 1
        fi

        example="$PROFILES_DIR/$detected/project.conf.example"

        [[ -f "$example" ]] || {
            echo "[ERRO] Modelo de configuração não encontrado: $example"
            return 1
        }

        cp -- "$example" "$dir/builder.conf"

        if [[ -f "$PROFILES_DIR/$detected/dependencies.txt" &&
              ! -f "$dir/dependencies.txt" ]]; then
            cp -- "$PROFILES_DIR/$detected/dependencies.txt" \
                "$dir/dependencies.txt"
        fi

        echo "[DETECTOR] Perfil identificado: $detected"
        echo "[DETECTOR] Configuração criada automaticamente."
    fi

    PROJECT_DIR="$dir"
    PROJECT_NAME="$(basename "$dir")"

    # Ferramentas empacotadas em tools/ têm prioridade sobre o PATH do host.
    source "$UB_ROOT/tools/internal-tools.sh"
    UB_INTERNAL_BIN_PATH="$(ub_internal_bin_path || true)"
    if [[ -n "$UB_INTERNAL_BIN_PATH" ]]; then
        PATH="$UB_INTERNAL_BIN_PATH:$PATH"
        export PATH
    fi

    # Repositórios/cache de ferramentas e dependências ficam sob tools/.
    GRADLE_USER_HOME="$TOOLS_DIR/gradle-user-home"
    MAVEN_OPTS="${MAVEN_OPTS:+$MAVEN_OPTS }-Dmaven.repo.local=$TOOLS_DIR/maven-repository"
    PIP_CACHE_DIR="$TOOLS_DIR/pip-cache"
    PYTHONUSERBASE="$TOOLS_DIR/python-userbase"
    export GRADLE_USER_HOME MAVEN_OPTS PIP_CACHE_DIR PYTHONUSERBASE
    # Ler configurações como dados, nunca como código shell executável.
    load_config_file() {
        local config="$1" line key value
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            [[ "$line" =~ ^[[:space:]]*$ ]] && continue
            [[ "$line" =~ ^[[:space:]]*([A-Z][A-Z0-9_]*)[[:space:]]*=(.*)$ ]] || {
                echo "[ERRO] Linha inválida em configuração: $config" >&2
                return 1
            }
            key="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"
            case "$key" in
                BUILDER_PROFILE|BUILD_COMMAND|ANDROID_SDK_ROOT|ANDROID_NDK_HOME|ANDROID_PLATFORM|ANDROID_BUILD_TOOLS_VERSION|JAVA_HOME|UB_BUILD_VARIANT|UB_KEYSTORE_PATH|UB_KEY_ALIAS|UB_PASSWORD_FILE|UB_JAVA_SOURCE|UB_JAVA_TARGET) ;;
                *) echo "[ERRO] Chave não permitida em configuração: $key" >&2; return 1 ;;
            esac
            # Remover somente as aspas externas; preservar aspas internas do comando.
            if [[ "$value" == \"*\" && "${#value}" -ge 2 ]]; then
                value="${value:1:${#value}-2}"
            elif [[ "$value" == \'*\' && "${#value}" -ge 2 ]]; then
                value="${value:1:${#value}-2}"
            else
                # Decodificar valores escapados por printf %q sem executar shell.
                value="$(python3 -c 'import shlex,sys; print(" ".join(shlex.split(sys.argv[1])))' "$value")"
            fi
            printf -v "$key" '%s' "$value"
            export "$key"
        done < "$config"
    }

    # Não herdar JDK do host; usar somente configuração validada ou tools/.
    unset JAVA_HOME
    load_config_file "$dir/builder.conf" || return 1
    if [[ -f "$dir/builder.local.conf" ]]; then
        load_config_file "$dir/builder.local.conf" || return 1
    fi

    # Migrar em memória configurações antigas geradas antes da separação
    # dos perfis. Nunca reescrever builder.conf nem builder.local.conf.
    saved_profile="${BUILDER_PROFILE:-}"
    if [[ "$saved_profile" == "android-native" ]] &&
       [[ -f "$dir/builder.local.conf" ]] &&
       grep -Eq '^[[:space:]]*BUILDER_PROFILE[[:space:]]*=' "$dir/builder.local.conf"; then
        :
    else
        detected="$(detect_profile "$dir")"
        if [[ "$saved_profile" == "android-native" && "$detected" == "android-gradle" ]]; then
            echo "[AVISO] Perfil salvo android-native está desatualizado; usando android-gradle nesta execução. Configurações preservadas."
            BUILDER_PROFILE="android-gradle"
            export BUILDER_PROFILE
        fi
    fi

    if [[ -n "${JAVA_HOME:-}" ]]; then
        java_home_real="$(cd -- "$JAVA_HOME" 2>/dev/null && pwd -P)" || {
            echo "[ERRO] JAVA_HOME não aponta para um diretório válido." >&2
            return 1
        }
        tools_real="$(cd -- "$TOOLS_DIR" && pwd -P)"
        [[ "$java_home_real" == "$tools_real/"* ]] || {
            echo "[ERRO] JAVA_HOME deve apontar para um JDK dentro de tools/." >&2
            return 1
        }
        JAVA_HOME="$java_home_real"
        export JAVA_HOME
    else
        internal_java="$(ub_find_internal_tool java || true)"
        if [[ -n "$internal_java" ]]; then
            JAVA_HOME="$(dirname "$(dirname "$internal_java")")"
            export JAVA_HOME
        fi
    fi

    BUILDER_OUTPUT_DIR="$OUTPUT_ROOT/$PROJECT_NAME"
    mkdir -p "$BUILDER_OUTPUT_DIR"
    export PROJECT_DIR PROJECT_NAME BUILDER_OUTPUT_DIR TOOLS_DIR OUTPUT_ROOT
}

detect_android_build_system() {
    local dir="$1"

    if [[ -f "$dir/gradlew" ]] || find "$dir" \
        -type d \( -name .git -o -name .universal-builder -o -name .gradle -o -name build -o -name node_modules \) -prune -o \
        -type f \( -name settings.gradle -o -name settings.gradle.kts -o -name build.gradle -o -name build.gradle.kts \) \
        -print -quit | grep -q .; then
        echo "gradle"
    elif find "$dir" \
        -type d \( -name .git -o -name .universal-builder -o -name .gradle -o -name build -o -name node_modules \) -prune -o \
        -type f -name Android.mk -print -quit | grep -q .; then
        echo "ndk-build"
    elif find "$dir" \
        -type d \( -name .git -o -name .universal-builder -o -name .gradle -o -name build -o -name node_modules \) -prune -o \
        -type f -name CMakeLists.txt -print -quit | grep -q .; then
        echo "cmake"
    elif find "$dir" \
        -type d \( -name .git -o -name .universal-builder -o -name .gradle -o -name build -o -name node_modules \) -prune -o \
        -type f -name AndroidManifest.xml -print -quit | grep -q .; then
        echo "java-android"
    else
        echo "unknown"
    fi
}

init_project() {
    local dir="$1" profile="$2"
    [[ -d "$dir" ]] || { echo "Pasta não encontrada: $dir"; return 1; }
    valid_profile "$profile" || { echo "Perfil inválido: $profile"; return 1; }
    local example="$PROFILES_DIR/$profile/project.conf.example"
    [[ -f "$example" ]] || { echo "Modelo não encontrado: $example"; return 1; }
    [[ ! -e "$dir/builder.conf" ]] || { echo "builder.conf já existe; nada foi sobrescrito."; return 1; }
    cp -- "$example" "$dir/builder.conf"
    if [[ -f "$PROFILES_DIR/$profile/dependencies.txt" && ! -e "$dir/dependencies.txt" ]]; then
        cp -- "$PROFILES_DIR/$profile/dependencies.txt" "$dir/dependencies.txt"
    elif [[ -e "$dir/dependencies.txt" ]]; then
        echo "[INFO] dependencies.txt existente preservado."
    fi
    echo "Projeto inicializado: $dir ($profile)"
}

clone_project() {
    local url="$1" name="${2:-}"
    command -v git >/dev/null 2>&1 || { echo "Git não está instalado."; return 1; }
    if [[ -z "$name" ]]; then name="${url##*/}"; name="${name%.git}"; fi
    [[ "$name" != */* && "$name" != "." && "$name" != ".." ]] || { echo "Nome inválido."; return 1; }
    local destination="$PROJECTS_DIR/$name"
    [[ ! -e "$destination" ]] || { echo "Projeto já existe: $destination"; return 1; }
    git clone "$url" "$destination"
}

requirements() {
    local dir="$1"

    load_project "$dir" || return 1

    echo
    echo "========================================"
    echo " REQUISITOS AUTOMÁTICOS DO PROJETO"
    echo "========================================"
    echo "Projeto: $PROJECT_NAME"
    echo "Perfil: ${BUILDER_PROFILE:-não definido}"

    echo
    echo "===== DETECÇÃO DE VERSÕES E ANÁLISE ====="
    if [[ -f "$UB_ROOT/tools/detect-versions.sh" ]]; then
        bash "$UB_ROOT/tools/detect-versions.sh" "$PROJECT_DIR" "${BUILDER_PROFILE:-all}"
    else
        echo "[AVISO] Detector de versões não encontrado em tools/."
    fi

    if [[ "${BUILDER_PROFILE:-}" == "android-native" || "${BUILDER_PROFILE:-}" == "android-gradle" ]]; then
        echo
        echo "===== FERRAMENTAS ANDROID INTERNAS ====="

        source "$UB_ROOT/tools/discover-tools.sh"
        ub_discover_android || true

        if [[ -n "${ANDROID_SDK_ROOT:-}" ]]; then
            echo "[OK] SDK: $ANDROID_SDK_ROOT"
        else
            echo "[FALTA] SDK Android em tools/"
        fi

        if [[ -n "${ANDROID_PLATFORM:-}" ]]; then
            echo "[OK] Plataforma: $ANDROID_PLATFORM"
        else
            echo "[FALTA] Plataforma Android exigida ou compatível"
        fi

        if [[ -n "${ANDROID_BUILD_TOOLS_VERSION:-}" ]]; then
            echo "[OK] Build Tools: $ANDROID_BUILD_TOOLS_VERSION"
        else
            echo "[FALTA] Build Tools compatíveis"
        fi

        if [[ -n "${JAVA_HOME:-}" ]]; then
            echo "[OK] JDK: $JAVA_HOME"
        else
            echo "[FALTA] JDK interno compatível"
        fi

        if [[ -n "${ANDROID_GRADLE_BIN:-}" ]]; then
            echo "[OK] Gradle: $ANDROID_GRADLE_VERSION"
        elif find "$PROJECT_DIR" -type f \
            \( -name build.gradle -o -name build.gradle.kts \) \
            -not -path '*/.git/*' -print -quit | grep -q .; then
            echo "[FALTA] Gradle compatível com o projeto"
        fi

        if [[ -n "${ANDROID_AGP_VERSION:-}" ]]; then
            echo "[INFO] Android Gradle Plugin: $ANDROID_AGP_VERSION"
        else
            echo "[INFO] Android Gradle Plugin: versão não resolvida"
        fi

        if [[ -n "${ANDROID_NDK_HOME:-}" ]]; then
            echo "[OK] NDK: $ANDROID_NDK_HOME"
        elif [[ -d "$PROJECT_DIR/jni" ]] ||
             [[ -n "$(find "$PROJECT_DIR" -type f \( -name Android.mk -o -name Application.mk \) -not -path '*/.git/*' -print -quit)" ]]; then
            echo "[FALTA] NDK Android (projeto utiliza código nativo)"
        else
            echo "[INFO] NDK não necessário para este projeto"
        fi
    fi

    echo
    echo "===== FIM DOS REQUISITOS ====="
}

check_project() {
    local dir="$1"
    load_project "$dir" || return 1
    local profile="${BUILDER_PROFILE:-}"
    valid_profile "$profile" || { echo "Perfil não definido ou inválido."; return 1; }
    local checker="$PROFILES_DIR/$profile/check.sh"
    [[ -f "$checker" ]] || { echo "Verificador não encontrado: $checker"; return 1; }
    echo "Verificando $PROJECT_NAME..."
    (cd "$PROJECT_DIR" && bash "$checker")
}

collect_artifacts() {
    local dir="$1" destination="$2" started="${3:-0}"
    local file target relative
    mkdir -p "$destination"
    while IFS= read -r -d '' file; do
        relative="${file#"$dir"/}"
        target="$destination/$relative"
        mkdir -p -- "$(dirname "$target")"
        if [[ -e "$target" ]]; then
            echo "[AVISO] Artefato existente preservado: $target"
            continue
        fi
        cp -- "$file" "$target"
        echo "Artefato novo: $file"
    done < <(
        find "$dir" -type f \( \
            -iname '*.apk' -o -iname '*.aab' -o -iname '*.exe' \
            -o -iname '*.appimage' -o -iname '*.deb' -o -iname '*.rpm' \
            -o -iname '*.jar' -o -iname '*.zip' -o -iname '*.tar.gz' \
            -o -iname '*.tar.xz' \) \
            -not -path '*/.git/*' -not -path '*/.gradle/*' \
            -not -path "$destination/*" -newermt "@$started" -print0
    )
}

build_project() {
    local dir="$1"
    local adapter=""
    local android_system=""
    local build_command=""
    local build_started

    load_project "$dir" || return 1
    build_command="${BUILD_COMMAND:-}"

    # Escolher o comando padrão pelo sistema real do projeto Java.
    if [[ -z "$build_command" ]]; then
        case "${BUILDER_PROFILE:-}" in
            java)
                if [[ -f "$PROJECT_DIR/pom.xml" ]]; then
                    build_command="mvn package"
                elif [[ -f "$PROJECT_DIR/gradlew" || -f "$PROJECT_DIR/build.gradle" || \
                        -f "$PROJECT_DIR/build.gradle.kts" || -f "$PROJECT_DIR/settings.gradle" || \
                        -f "$PROJECT_DIR/settings.gradle.kts" ]]; then
                    build_command="gradle build"
                fi
                ;;
            cpp)
                if [[ -f "$PROJECT_DIR/CMakeLists.txt" || -f "$PROJECT_DIR/CMakePresets.json" ]]; then
                    build_command='cmake -S . -B build && cmake --build build -j$(nproc)'
                elif [[ -f "$PROJECT_DIR/Makefile" ]]; then
                    build_command="make"
                fi
                ;;
        esac
    fi

    # Primeiro tenta selecionar um compilador especializado.
    case "${BUILDER_PROFILE:-}" in
        android-native|android-gradle)
            android_system="$(detect_android_build_system "$PROJECT_DIR")"
            echo "Sistema de build Android detectado: $android_system"

            case "$android_system" in
                gradle)
                    adapter="$UB_ROOT/builders/android-gradle.sh"
                    ;;
                ndk-build)
                    adapter="$UB_ROOT/builders/android-legacy.sh"
                    ;;
                cmake)
                    echo "CMake Android detectado; adaptador especializado ainda não disponível."
                    ;;
                java-android)
                    echo "Android Java legado detectado; adaptador especializado ainda não disponível."
                    ;;
                *)
                    echo "Sistema Android não identificado automaticamente."
                    ;;
            esac
            ;;
    esac

    # Verifica os requisitos antes de executar qualquer compilador.
    check_project "$PROJECT_DIR" || {
        echo "Verificação falhou; compilação cancelada."
        return 1
    }

    # Adaptadores especializados têm prioridade sobre BUILD_COMMAND.
    if [[ -n "$adapter" ]]; then
        [[ -f "$adapter" ]] || {
            echo "Adaptador não encontrado: $adapter"
            return 1
        }

        echo "Executando compilador especializado: $adapter"

        PROJECT_DIR="$PROJECT_DIR" \
        TOOLS_DIR="$TOOLS_DIR" \
        BUILDER_OUTPUT_DIR="$BUILDER_OUTPUT_DIR" \
        bash "$adapter" || {
            echo "Compilação pelo adaptador falhou."
            return 1
        }

    else
        # Comando manual é uma alternativa quando não há adaptador.
        [[ -n "$build_command" ]] || {
            echo "Nenhum compilador automático disponível para este projeto."
            echo "Configure BUILD_COMMAND em builder.conf para usar um comando manual."
            return 1
        }

        echo "Modo manual: $build_command"

        build_started="$(date +%s)"
        (
            cd "$PROJECT_DIR"
            export BUILDER_OUTPUT_DIR
            bash -c "$build_command"
        ) || {
            echo "Compilação manual falhou."
            return 1
        }

        collect_artifacts "$PROJECT_DIR" "$BUILDER_OUTPUT_DIR" "$build_started"
    fi

    echo "Concluído. Saída: $BUILDER_OUTPUT_DIR"
}

clean_project() {
    local dir="$1" name answer
    name="$(basename "$(cd "$dir" && pwd -P)")"
    read -r -p "Apagar arquivos de saída de $name? [s/N] " answer
    [[ "$answer" =~ ^([sS]|[sS][iI][mM])$ ]] || return 0
    rm -rf -- "$OUTPUT_ROOT/$name"
    echo "Saída removida."
}

list_projects() {
    echo "Projetos:"
    find "$PROJECTS_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n'
}

doctor() {
    echo "=== Diagnóstico ==="
    for cmd in bash git python3 find grep; do
        command -v "$cmd" >/dev/null 2>&1 && echo "[OK] $cmd" || echo "[FALTA] $cmd"
    done
    echo "Projetos: $PROJECTS_DIR"
    echo "Ferramentas: $TOOLS_DIR"
    echo "Saídas: $OUTPUT_ROOT"
}

WIZARD_PROJECT_CREATED=0
WIZARD_PROJECT_SUCCESS=0
WIZARD_DESTINATION=""

wizard_exit_cleanup() {
    local status=$?
    if [[ "$WIZARD_PROJECT_CREATED" -eq 1 && "$WIZARD_PROJECT_SUCCESS" -eq 0 && -n "$WIZARD_DESTINATION" ]]; then
        echo "Falha no assistente. Projeto preservado em: $WIZARD_DESTINATION"
    fi
    return "$status"
}

wizard() {
    command -v git >/dev/null 2>&1 || { echo "Git não está instalado."; return 1; }
    echo "=== Universal Builder: assistente ==="
    read -r -p "URL do repositório Git: " repo_url
    [[ -n "$repo_url" ]] || { echo "URL vazia."; return 1; }

    local name destination detected profile buildcmd answer
    name="${repo_url##*/}"; name="${name%.git}"
    read -r -p "Nome da pasta: " answer
    [[ -n "$answer" ]] && name="$answer"
    [[ "$name" != */* && "$name" != "." && "$name" != ".." && -n "$name" ]] || { echo "Nome inválido."; return 1; }

    destination="$PROJECTS_DIR/$name"
    [[ ! -e "$destination" ]] || { echo "Pasta já existe: $destination"; return 1; }
    WIZARD_DESTINATION="$destination"
    WIZARD_PROJECT_CREATED=1
    trap wizard_exit_cleanup EXIT

    echo "[1/5] Baixando projeto..."
    if ! git clone "$repo_url" "$destination"; then
        echo "ERRO: não foi possível baixar o repositório."
        return 1
    fi
    [[ -d "$destination" ]] || { echo "ERRO: Git não criou a pasta do projeto."; return 1; }

    echo
    echo "[DETECTOR] Analisando requisitos e versões..."
    bash "$UB_ROOT/tools/detect-versions.sh" "$destination"

    if [[ -f "$destination/builder.conf" ]]; then
        echo "[2/5] Configuração existente encontrada; preservando arquivos do projeto."
        load_project "$destination" || return 1
        profile="${BUILDER_PROFILE:-}"
        valid_profile "$profile" || {
            echo "[ERRO] builder.conf existente não define um perfil válido."
            return 1
        }
        buildcmd="${BUILD_COMMAND:-}"
    else
        detected="$(detect_profile "$destination")"
        if [[ -n "$detected" ]]; then
            echo "Perfil identificado: $detected"
            read -r -p "Usar esse perfil? [S/n] " answer
            [[ "$answer" =~ ^([nN]|[nN][aA][oO])$ ]] && detected=""
        fi
        if [[ -z "$detected" ]]; then
            echo "Escolha o perfil:"
            select profile in "${PROFILES[@]}"; do
                [[ -n "${profile:-}" ]] && break
                echo "Opção inválida."
            done
        else
            profile="$detected"
        fi

        echo "[2/5] Criando configuração..."
        init_project "$destination" "$profile" || return 1

        if [[ -f "$destination/scripts/build.sh" ]]; then
            buildcmd="./scripts/build.sh"
        elif [[ -f "$destination/build.sh" ]]; then
            buildcmd="./build.sh"
        elif [[ -f "$destination/pom.xml" ]]; then
            buildcmd="mvn package"
        elif [[ -f "$destination/gradlew" || -f "$destination/build.gradle" || \
                -f "$destination/build.gradle.kts" || -f "$destination/settings.gradle" || \
                -f "$destination/settings.gradle.kts" ]]; then
            buildcmd="gradle build"
        elif [[ -f "$destination/CMakeLists.txt" || -f "$destination/CMakePresets.json" ]]; then
            buildcmd='cmake -S . -B build && cmake --build build -j$(nproc)'
        elif [[ -f "$destination/Makefile" ]]; then
            buildcmd="make"
        else
            buildcmd=""
        fi

        if [[ -n "$buildcmd" ]]; then
            printf '\nBUILD_COMMAND=%q\n' "$buildcmd" >> "$destination/builder.conf"
        else
            read -r -p "Comando de compilação (vazio para configurar depois): " buildcmd
            [[ -z "$buildcmd" ]] || printf '\nBUILD_COMMAND=%q\n' "$buildcmd" >> "$destination/builder.conf"
        fi
    fi

    echo "[3/5] Dependências..."
    requirements "$destination" || return 1
    echo "As ferramentas precisam estar previamente instaladas em tools/."
    echo "Use instalar-ferramentas.sh para organizar os pacotes baixados manualmente."

    echo "[4/5] Verificando..."
    check_project "$destination" || { echo "ERRO: verificação do projeto falhou."; return 1; }
    if [[ "$profile" == "android-native" || "$profile" == "android-gradle" ]]; then
        android_system="$(detect_android_build_system "$destination")"
        case "$android_system" in
            gradle|ndk-build) ;;
            *)
                [[ -n "$buildcmd" ]] || {
                    echo "ERRO: não há adaptador automático para $android_system; configure BUILD_COMMAND."
                    return 1
                }
                ;;
        esac
    elif [[ "$profile" == "java" && ( -f "$destination/pom.xml" || \
          -f "$destination/build.gradle" || -f "$destination/build.gradle.kts" || \
          -f "$destination/settings.gradle" || -f "$destination/settings.gradle.kts" ) ]]; then
        :
    elif [[ "$profile" == "cpp" && ( -f "$destination/CMakeLists.txt" || \
          -f "$destination/CMakePresets.json" || -f "$destination/Makefile" ) ]]; then
        :
    elif [[ -z "$buildcmd" ]]; then
        echo "ERRO: configure BUILD_COMMAND antes de compilar."
        return 1
    fi

    echo "[5/5] Projeto pronto."
    read -r -p "Compilar agora? [S/n] " answer
    if [[ "$answer" =~ ^([nN]|[nN][aA][oO])$ ]]; then
        echo "Compilação adiada."
        WIZARD_PROJECT_SUCCESS=1
        trap - EXIT
        return 0
    fi

    build_project "$destination" || { echo "ERRO: compilação falhou."; return 1; }
    WIZARD_PROJECT_SUCCESS=1
    trap - EXIT
    echo "Assistente concluído com sucesso."
}

case "${1:-help}" in
    wizard) wizard ;;
    list) list_projects ;;
    doctor) doctor ;;
    clone) [[ $# -ge 2 ]] || { usage; exit 1; }; clone_project "$2" "${3:-}" ;;
    init) [[ $# -ge 4 && "$3" == "--profile" ]] || { usage; exit 1; }; init_project "$2" "$4" ;;
    requirements) [[ $# -ge 2 ]] || { usage; exit 1; }; requirements "$2" ;;
    check) [[ $# -ge 2 ]] || { usage; exit 1; }; check_project "$2" ;;
    build) [[ $# -ge 2 ]] || { usage; exit 1; }; build_project "$2" ;;
    clean) [[ $# -ge 2 ]] || { usage; exit 1; }; clean_project "$2" ;;
    help|--help|-h) usage ;;
    *) echo "Comando desconhecido: $1"; usage; exit 1 ;;
esac
