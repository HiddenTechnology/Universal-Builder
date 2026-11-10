#!/usr/bin/env bash
# Localização de ferramentas empacotadas dentro de tools/.
# Não consulta PATH do sistema para decidir se uma dependência está instalada.

ub_find_internal_tool() {
    local name="$1" root="${TOOLS_DIR:?TOOLS_DIR não definido}" found=""
    local -a candidates=()

    [[ -x "$root/bin/$name" ]] && candidates+=("$root/bin/$name")
    [[ -x "$root/$name/bin/$name" ]] && candidates+=("$root/$name/bin/$name")

    if (("${#candidates[@]}" == 0)); then
        if [[ "$name" == java || "$name" == javac || "$name" == keytool ]]; then
            found="$(find "$root/java" \( -type f -o -type l \) -path "*/bin/$name" -executable -print 2>/dev/null | sort -V | tail -n 1)"
        else
            found="$(find "$root" \
                -type d \( -name keys -o -name .git -o -name cache -o -name gradle-user-home \) -prune -o \
                \( -type f -o -type l \) -name "$name" -executable -print 2>/dev/null | sort -V | tail -n 1)"
        fi
        [[ -z "$found" ]] || candidates+=("$found")
    fi

    (("${#candidates[@]}" > 0)) || return 1
    printf '%s\n' "${candidates[0]}"
}

ub_internal_bin_path() {
    local root="${TOOLS_DIR:?TOOLS_DIR não definido}" dir
    local -a dirs=()
    [[ -d "$root/bin" ]] && dirs+=("$root/bin")
    while IFS= read -r -d '' dir; do
        dirs+=("$dir")
    done < <(
        find "$root" -type d \( -name keys -o -name .git -o -name cache -o -name gradle-user-home \) -prune -o \
            -type d -name bin -print0 2>/dev/null | sort -z -Vr
    )
    (("${#dirs[@]}" > 0)) || return 1
    local IFS=:
    printf '%s\n' "${dirs[*]}"
}
