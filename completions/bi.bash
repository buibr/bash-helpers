# bash completion for `bi` (see ~/.me/bi). Source it from ~/.bashrc:
#   source ~/.me/completions/bi.bash
#
# Candidates come from `bi __complete`, as "word<TAB>description" lines. With more
# than one match the descriptions are shown next to the words; a single match
# is inserted alone. "@file" / "@dir" lines switch on path completion.

_bi_complete() {
    local cur=${COMP_WORDS[COMP_CWORD]}
    local line word desc fs="" words=() descs=() width=0 i

    COMPREPLY=()
    while IFS=$'\t' read -r word desc; do
        case "$word" in
            @file|@dir) fs=${word#@}; continue ;;
            @*|"")      continue ;;
        esac
        [[ "$word" == "$cur"* ]] || continue
        words+=("$word"); descs+=("$desc")
        (( ${#word} > width )) && width=${#word}
    done < <(bi __complete "${COMP_WORDS[@]:1:COMP_CWORD}" 2>/dev/null)

    # paths (plus any sub-commands), unless a flag is being typed
    if [[ -n "$fs" && "$cur" != -* ]]; then
        compopt -o filenames 2>/dev/null
        for word in "${words[@]}"; do [[ "$word" != -* ]] && COMPREPLY+=("$word"); done
        mapfile -t -O "${#COMPREPLY[@]}" COMPREPLY < <(compgen -"${fs:0:1}" -- "$cur")
        return
    fi

    if (( ${#words[@]} <= 1 )); then
        COMPREPLY=("${words[@]}")
        return
    fi

    # extend the typed text first when all matches share a longer prefix
    local prefix=${words[0]}
    for word in "${words[@]:1}"; do
        while [[ "$word" != "$prefix"* ]]; do prefix=${prefix%?}; done
    done
    if (( ${#prefix} > ${#cur} )); then
        compopt -o nospace 2>/dev/null
        COMPREPLY=("$prefix")
        return
    fi

    # one candidate per line: "word   -- description", cut to the terminal width
    local cols=${COLUMNS:-80}
    for i in "${!words[@]}"; do
        line=$(printf '%-*s  %s' "$width" "${words[$i]}" "${descs[$i]:+-- ${descs[$i]}}")
        (( ${#line} > cols - 1 )) && line="${line:0:cols-2}…"
        COMPREPLY+=("$line")
    done
}

complete -F _bi_complete bi
