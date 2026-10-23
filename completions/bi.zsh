# zsh completion for `bi` (see ~/.me/bi). Sourced from ~/.zshrc by ~/.me/install.sh.
#
# Candidates come from `bi __complete` as "word<TAB>description" lines;
# "@file" / "@dir" lines add path completion.

_bi() {
    local line word desc fs
    local -a cands
    for line in "${(@f)$(bi __complete "${(@)words[2,CURRENT]}" 2>/dev/null)}"; do
        word=${line%%$'\t'*}
        desc=""; [[ $line == *$'\t'* ]] && desc=${line#*$'\t'}
        case $word in
            @file|@dir) fs=${word#@}; continue ;;
            @*|'')      continue ;;
        esac
        cands+=("${word//:/\\:}${desc:+:$desc}")
    done
    (( $#cands )) && _describe -t bi-commands 'bi' cands
    [[ $fs == file ]] && _files
    [[ $fs == dir ]] && _files -/
    return 0
}

(( $+functions[compdef] )) || { autoload -Uz compinit && compinit -i; }
compdef _bi bi
