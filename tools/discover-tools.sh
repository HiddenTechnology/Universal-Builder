#!/usr/bin/env bash
# Descoberta de ferramentas Android empacotadas em tools/.
# Não instala, baixa nem altera ferramentas ou arquivos dos projetos.

ub_discover_android() {
    local root="${TOOLS_DIR:?TOOLS_DIR não definido}"
    local project="${PROJECT_DIR:-}"
    local sdk="" candidate="" file="" value=""
    local compile_sdk="" required_bt="" platform=""
    local gradle_file="" agp=""
    local ndk_required=0 toolchain="" stl=""
    local ndk="" ndk_version="" ndk_build=""
    local java_bin="" gradle_bin=""
    local item=""
    local -a sdk_candidates=()
    local -a platforms=()
    local -a build_tools=()
    local -a ndk_candidates=()

    # Limpar somente resultados desta descoberta.
    unset ANDROID_SDK_ROOT ANDROID_PLATFORM
    unset ANDROID_BUILD_TOOLS_VERSION ANDROID_NDK_HOME
    unset ANDROID_GRADLE_BIN ANDROID_GRADLE_VERSION
    unset ANDROID_AGP_VERSION ANDROID_BUILD_TOOLS_REQUIRED_VERSION

    # ---------------------------------------------------------
    # 1. Identificar requisitos declarados pelo projeto.
    # ---------------------------------------------------------

    if [[ -n "$project" && -d "$project" ]]; then

        while IFS= read -r file; do
            value="$(
                sed -nE \
                    's/.*buildToolsVersion[[:space:]]*["'\'']([^"'\'']+)["'\''].*/\1/p' \
                    "$file" | head -n 1
            )"
            if [[ -n "$value" ]]; then
                required_bt="$value"
                break
            fi
        done < <(
            find "$project" \
                -type d \( -name .git -o -name build -o -name .gradle \
                    -o -name node_modules -o -name .universal-builder \) -prune -o \
                -type f \( -name build.gradle -o -name build.gradle.kts \) \
                -print
        )

        while IFS= read -r file; do
            value="$(
                grep -Eo 'compileSdk(Version)?[[:space:]]*(=|[[:space:]])*[0-9]+' \
                    "$file" | head -n 1 |
                grep -Eo '[0-9]+$'
            )"
            if [[ -n "$value" ]]; then
                compile_sdk="$value"
                break
            fi
        done < <(
            find "$project" \
                -type d \( -name .git -o -name build -o -name .gradle \
                    -o -name node_modules -o -name .universal-builder \) -prune -o \
                -type f \( -name build.gradle -o -name build.gradle.kts \) \
                -print
        )

        while IFS= read -r file; do
            value="$(
                sed -nE \
                    's/.*com\.android\.tools\.build:gradle:([^"'\'']+).*/\1/p' \
                    "$file" | head -n 1
            )"
            if [[ -n "$value" ]]; then
                agp="$value"
                break
            fi
        done < <(
            find "$project" \
                -type d \( -name .git -o -name build -o -name .gradle \
                    -o -name node_modules -o -name .universal-builder \) -prune -o \
                -type f \( -name build.gradle -o -name build.gradle.kts \) \
                -print
        )

        # Requisitos de projetos Android NDK.
        if [[ -d "$project/jni" ]] ||
           find "$project" -type f \
               \( -name Android.mk -o -name Application.mk \) \
               -not -path '*/.git/*' -print -quit | grep -q .; then
            ndk_required=1
        fi

        local app_mk=""
        app_mk="$(find "$project" \
            -type d \( -name .git -o -name build -o -name .gradle \
                -o -name node_modules \) -prune -o \
            -type f -name Application.mk -print -quit)"

        if [[ -n "$app_mk" ]]; then
            toolchain="$(sed -nE \
                's/^[[:space:]]*NDK_TOOLCHAIN_VERSION[[:space:]]*:?=[[:space:]]*([^[:space:]#]+).*/\1/p' \
                "$app_mk" | head -n 1)"
            stl="$(sed -nE \
                's/^[[:space:]]*APP_STL[[:space:]]*:?=[[:space:]]*([^[:space:]#]+).*/\1/p' \
                "$app_mk" | head -n 1)"
        fi
    fi

    if [[ -n "$required_bt" ]]; then
        ANDROID_BUILD_TOOLS_REQUIRED_VERSION="$required_bt"
        export ANDROID_BUILD_TOOLS_REQUIRED_VERSION
    fi

    [[ -z "$agp" ]] || {
        ANDROID_AGP_VERSION="$agp"
        export ANDROID_AGP_VERSION
    }

    # ---------------------------------------------------------
    # 2. Localizar Android SDK.
    # ---------------------------------------------------------

    [[ -n "${ANDROID_SDK_ROOT:-}" ]] &&
        sdk_candidates+=("$ANDROID_SDK_ROOT")

    [[ -n "${ANDROID_HOME:-}" ]] &&
        sdk_candidates+=("$ANDROID_HOME")

    sdk_candidates+=(
        "$root/android"
        "$root/android-sdk"
        "$root/sdk"
    )

    for candidate in "${sdk_candidates[@]}"; do
        [[ -d "$candidate" ]] || continue

        if [[ -d "$candidate/platforms" ||
              -d "$candidate/build-tools" ||
              -d "$candidate/platform-tools" ]]; then
            sdk="$(cd "$candidate" && pwd -P)"
            break
        fi
    done

    if [[ -n "$sdk" ]]; then
        ANDROID_SDK_ROOT="$sdk"
        export ANDROID_SDK_ROOT
    fi

    # ---------------------------------------------------------
    # 3. Localizar plataforma Android compatível.
    # ---------------------------------------------------------

    if [[ -n "$sdk" && -d "$sdk/platforms" ]]; then
        while IFS= read -r candidate; do
            [[ -d "$candidate" ]] && platforms+=("$candidate")
        done < <(
            find "$sdk/platforms" -mindepth 1 -maxdepth 1 \
                -type d -name 'android-*' -print | sort -V
        )

        if [[ -n "$compile_sdk" ]]; then
            for candidate in "${platforms[@]}"; do
                if [[ "$(basename "$candidate")" == "android-$compile_sdk" ]]; then
                    platform="$candidate"
                    break
                fi
            done
        else
            platform="${platforms[${#platforms[@]}-1]:-}"
        fi

        if [[ -n "$platform" && -f "$platform/android.jar" ]]; then
            ANDROID_PLATFORM="$(basename "$platform")"
            export ANDROID_PLATFORM
        fi
    fi

    # ---------------------------------------------------------
    # 4. Localizar Android Build Tools.
    # ---------------------------------------------------------

    if [[ -n "$sdk" && -d "$sdk/build-tools" ]]; then
        while IFS= read -r candidate; do
            [[ -d "$candidate" ]] && build_tools+=("$candidate")
        done < <(
            find "$sdk/build-tools" -mindepth 1 -maxdepth 1 \
                -type d -print | sort -V
        )

        if [[ -n "$required_bt" ]]; then
            for candidate in "${build_tools[@]}"; do
                if [[ "$(basename "$candidate")" == "$required_bt" ]]; then
                    if [[ -x "$candidate/aapt" || -x "$candidate/aapt2" ]]; then
                        ANDROID_BUILD_TOOLS_VERSION="$required_bt"
                        break
                    fi
                fi
            done
        else
            for ((i=${#build_tools[@]}-1; i>=0; i--)); do
                candidate="${build_tools[$i]}"
                if [[ -x "$candidate/aapt" || -x "$candidate/aapt2" ]]; then
                    ANDROID_BUILD_TOOLS_VERSION="$(basename "$candidate")"
                    break
                fi
            done
        fi

        [[ -z "${ANDROID_BUILD_TOOLS_VERSION:-}" ]] ||
            export ANDROID_BUILD_TOOLS_VERSION
    fi

    # ---------------------------------------------------------
    # 5. Localizar Java interno.
    # ---------------------------------------------------------

    if declare -F ub_find_internal_tool >/dev/null 2>&1; then
        java_bin="$(ub_find_internal_tool java || true)"
    fi

    if [[ -n "$java_bin" ]]; then
        JAVA_HOME="$(dirname "$(dirname "$java_bin")")"
        export JAVA_HOME
    fi

    # ---------------------------------------------------------
    # 6. Localizar Gradle interno.
    # ---------------------------------------------------------

    if declare -F ub_find_internal_tool >/dev/null 2>&1; then
        gradle_bin="$(ub_find_internal_tool gradle || true)"
    fi

    if [[ -n "$gradle_bin" ]]; then
        ANDROID_GRADLE_BIN="$gradle_bin"
        ANDROID_GRADLE_VERSION="$(
            "$gradle_bin" --version 2>/dev/null |
                sed -nE 's/^Gradle ([0-9][^ ]*).*/\1/p' |
                head -n 1
        )"
        export ANDROID_GRADLE_BIN ANDROID_GRADLE_VERSION
    fi

    # ---------------------------------------------------------
    # 7. Localizar NDK, se o projeto realmente precisar dele.
    # ---------------------------------------------------------

    if (( ndk_required )); then
        [[ -d "$root/android/ndk-bundle" ]] &&
            ndk_candidates+=("$root/android/ndk-bundle")

        for candidate in \
            "$root/android/ndk/"* \
            "$root/ndk/"* \
            "$root"/android-ndk*; do
            [[ -d "$candidate" ]] && ndk_candidates+=("$candidate")
        done

        # Também procurar ndk-build em estruturas não padronizadas.
        while IFS= read -r ndk_build; do
            candidate="${ndk_build%/ndk-build}"
            ndk_candidates+=("$candidate")
        done < <(
            find "$root/android" "$root/ndk" \
                -type d \( -name .git -o -name cache \) -prune -o \
                -type f -name ndk-build -executable -print 2>/dev/null
        )

        # Eliminar candidatos duplicados e escolher o mais recente
        # que satisfaça os requisitos legados declarados.
        local best_ndk=""
        local best_version=""
        local revision=""
        local compatible=""

        for candidate in "${ndk_candidates[@]}"; do
            [[ -x "$candidate/ndk-build" ]] || continue

            revision=""
            if [[ -f "$candidate/source.properties" ]]; then
                revision="$(sed -nE \
                    's/^[[:space:]]*Pkg.Revision[[:space:]]*=[[:space:]]*([^[:space:]]+).*/\1/p' \
                    "$candidate/source.properties" | head -n 1)"
            fi

            compatible=1

            # Toolchain 4.9 e gnustl_static são legados do NDK.
            # gnustl_static deixou de existir nas versões mais novas.
            if [[ "$toolchain" == "4.9" || "$stl" == "gnustl_static" ]]; then
                if [[ -z "$revision" ]]; then
                    compatible=0
                else
                    local major="${revision%%.*}"
                    if [[ "$major" =~ ^[0-9]+$ ]] && (( major >= 18 )); then
                        compatible=0
                    fi
                fi
            fi

            if (( compatible )); then
                if [[ -z "$best_ndk" ]] ||
                   [[ "$(printf '%s\n%s\n' "$best_version" "$revision" | sort -V | tail -n 1)" == "$revision" ]]; then
                    best_ndk="$candidate"
                    best_version="${revision:-0}"
                fi
            fi
        done

        if [[ -n "$best_ndk" ]]; then
            ANDROID_NDK_HOME="$(cd "$best_ndk" && pwd -P)"
            export ANDROID_NDK_HOME
        else
            [[ -n "$toolchain" ]] &&
                echo "[REQUISITO] NDK_TOOLCHAIN_VERSION=$toolchain" >&2
            [[ -n "$stl" ]] &&
                echo "[REQUISITO] APP_STL=$stl" >&2
        fi
    fi

    return 0
}


# Retorna sucesso quando o projeto contém fontes de código nativo.
ub_project_has_native_sources() {
    local dir="${1:-${PROJECT_DIR:-}}"

    [[ -n "$dir" && -d "$dir" ]] || return 1

    find "$dir" \
        -type d \( -name .git -o -name build -o -name .gradle \
            -o -name node_modules -o -name .universal-builder \
            -o -name cache \) -prune -o \
        -type f \( \
            -name '*.c' -o -name '*.cc' -o -name '*.cpp' \
            -o -name '*.cxx' -o -name '*.C' \
            -o -name '*.s' -o -name '*.S' \
        \) -print -quit 2>/dev/null | grep -q .
}
