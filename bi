#!/usr/bin/env bash
#
# bi - one entry point for every bi-* script under ~/.me/<group>/
#
#   bi                         list all groups and commands
#   bi <group>                 list the commands of a group
#   bi <group> <command> ...   run ~/.me/<group>/bi-[<group>-]<command>[.sh]
#
# Scripts are found automatically; drop a new bi-* file into a folder and it
# shows up in `bi` and in TAB completion. Optional metadata comments in a script:
#
#   # bi: <one-line description>                 shown in help / completion
#   # bi-arg: <word> <description>               completion for the first argument
#   # bi-arg <word>: <word> <description>        completion after argument <word>
#
#   <word> can be a flag that takes a value: -o=@file, -p=@dir, -w= (free value)
#   or a dynamic source: @file, @dir, @none, @run:<shell command> # <description>
#
# TAB completion for bash, zsh, fish and tcsh/csh lives in ~/.me/completions/;
# ~/.me/install.sh wires it into every shell installed on the machine.

set -uo pipefail

# the folder this script really lives in, also when called through a symlink
ROOT="${BI_ROOT:-$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")}"

if [ -t 1 ]; then
    B=$'\e[1m'; C=$'\e[36m'; G=$'\e[32m'; D=$'\e[2m'; R=$'\e[31m'; N=$'\e[0m'
else
    B=""; C=""; G=""; D=""; R=""; N=""
fi

die() { printf '%s✘ %s%s\n' "$R" "$1" "$N" >&2; exit 1; }

# ------------------------------------------------------------- discovery ----

groups() {
    local d
    for d in "$ROOT"/*/; do
        d=${d%/}
        compgen -G "$d/bi-*" >/dev/null && basename "$d"
    done
}

# cmd_name <group> <file> - bi-web-dns.sh -> dns, bi-claude (in claude/) -> ""
cmd_name() {
    local n
    n=$(basename "$2")
    n=${n#bi-}
    n=${n%.sh}; n=${n%.py}
    [ "$n" = "$1" ] && n=""
    echo "${n#"$1"-}"
}

# commands <group> - "name|file" per script; symlinks are aliases of another script, skipped
commands() {
    local f
    for f in "$ROOT/$1"/bi-*; do
        [ -f "$f" ] && [ ! -L "$f" ] || continue
        printf '%s|%s\n' "$(cmd_name "$1" "$f")" "$f"
    done
}

# script_for <group> <command> - path of the script, "" command = group's default script
script_for() {
    local name file
    while IFS='|' read -r name file; do
        [ "$name" = "$2" ] && { echo "$file"; return 0; }
    done < <(commands "$1" 2>/dev/null)
    return 1
}

# describe <file> - "# bi:" line, else the first readable line of the header comment
describe() {
    local line
    line=$(sed -n 's/^# bi: *//p' "$1" | head -1)
    if [ -z "$line" ]; then
        line=$(sed -n '1,25{/^#!/d; /^# bi-arg/d; /^#/!q; s/^#[[:space:]]*//; /^[-=─═#[:space:]]*$/d; /^[Uu]sage/d; p}' "$1" \
            | head -1)
        # "bi-foo.sh - does things" -> "does things"
        line=$(sed -E 's/^bi-[A-Za-z0-9_.-]+[[:space:]]+(-|—|–)[[:space:]]+//' <<<"$line")
    fi
    if [ -z "$line" ] && head -c 64 "$1" | grep -q python; then
        line=$(sed -n '2,5{s/^"""//; s/"""$//; /./{p;q}}' "$1")
    fi
    echo "$line"
}

# args_of <file> [section] - "word<TAB>description" for a completion level
args_of() {
    local sec=${2:-}
    awk -v sec="$sec" '
        match($0, /^# bi-arg( [^:]+)?: */) {
            head = substr($0, 1, RLENGTH); rest = substr($0, RLENGTH + 1)
            s = head; sub(/^# bi-arg ?/, "", s); sub(/: *$/, "", s)
            if (s != sec) next
            if (rest ~ /^@run:/) {          # "@run:<command> # <description>"
                w = rest; sub(/ # .*/, "", w)
                d = (index(rest, " # ") ? substr(rest, index(rest, " # ") + 3) : "")
            } else {
                w = rest; sub(/[[:space:]].*/, "", w)
                d = rest; sub(/^[^[:space:]]+[[:space:]]*/, "", d)
            }
            print w "\t" d
        }' "$1"
}

# ------------------------------------------------------------------ help ----

help_group() {
    local g=$1 name file
    while IFS='|' read -r name file; do
        printf '  %s%-28s%s %s%s%s\n' "$G" "bi $g${name:+ $name}" "$N" "$D" "$(describe "$file")" "$N"
    done < <(commands "$g")
}

help_main() {
    local g
    cat <<EOF
${B}bi${N} - personal command toolbox (~/.me)

${B}Usage:${N}
  bi <group> <command> [args...]
  bi <group>                       list a group's commands
  bi <group> <command> --help      help of the command itself
EOF
    for g in $(groups); do
        printf '\n%s%s%s\n' "$B$C" "$g" "$N"
        help_group "$g"
    done
    echo
    echo "${D}TAB completes groups, commands and their arguments (see ~/.me/install.sh).${N}"
}

# -------------------------------------------------------------- complete ----

# group_desc <group> - "dns, headers, ttfb" style summary
group_desc() {
    local name file list=()
    while IFS='|' read -r name file; do
        if [ -z "$name" ]; then
            list=("$(describe "$file")"); break
        fi
        list+=("$name")
    done < <(commands "$1")
    local IFS=,; echo "${list[*]}" | sed 's/,/, /g'
}

# emit candidate lines "word<TAB>desc" for the args of a script
complete_args() {
    local file=$1; shift
    local args=("$@") n=$# prev sec line w

    # a flag declared as "-o=@file" / "-w=" wants a value next
    if [ "$n" -ge 1 ]; then
        prev=${args[$((n - 1))]}
        while IFS=$'\t' read -r w _; do
            if [[ "$w" == "$prev="* ]]; then
                w=${w#*=}
                [ -n "$w" ] && echo "$w"
                return
            fi
        done < <(args_of "$file" "" ; [ "$n" -ge 2 ] && args_of "$file" "${args[0]}")
    fi

    # section = first argument, if the script declares one for it
    sec=""
    if [ "$n" -ge 1 ] && [ -n "$(args_of "$file" "${args[0]}")" ]; then
        sec=${args[0]}
    elif [ "$n" -ge 1 ] && [[ "${args[0]}" != -* ]]; then
        # a positional without its own section: nothing more to suggest but files
        echo "@file"; return
    fi

    line=$(args_of "$file" "$sec")
    [ -z "$line" ] && { echo "@file"; return; }
    while IFS=$'\t' read -r w d; do
        case "$w" in
            @run:*) bash -c "${w#@run:}" 2>/dev/null | awk -v d="$d" 'NF { print $0 "\t" d }' ;;
            *)      printf '%s\t%s\n' "${w%%=*}" "$d" ;;
        esac
    done <<<"$line"
}

# __complete <words after "bi"...> - the last word is the one being completed (ignored here)
complete_words() {
    local words=("$@") n=$(( $# - 1 )) g name file def

    if [ "$n" -le 0 ]; then
        for g in $(groups); do printf '%s\t%s\n' "$g" "$(group_desc "$g")"; done
        printf 'help\tshow all commands\n'
        return
    fi

    g=${words[0]}
    [ -d "$ROOT/$g" ] || return
    def=$(script_for "$g" "" || true)

    if [ "$n" -eq 1 ]; then
        while IFS='|' read -r name file; do
            [ -n "$name" ] && printf '%s\t%s\n' "$name" "$(describe "$file")"
        done < <(commands "$g")
        [ -n "$def" ] && complete_args "$def" | grep -v '^@'
        return
    fi

    if file=$(script_for "$g" "${words[1]}") && [ -n "${words[1]}" ]; then
        complete_args "$file" "${words[@]:2:$((n - 2))}"
    elif [ -n "$def" ]; then
        complete_args "$def" "${words[@]:1:$((n - 1))}"
    fi
}

# paths <f|d> <partial> - compgen, keeping a leading ~/ as typed
paths() {
    if [[ "$2" == "~/"* ]]; then
        compgen -"$1" -- "$HOME/${2:2}" | sed "s|^$HOME/|~/|"
    else
        compgen -"$1" -- "$2"
    fi
}

# __complete-line ["bi web d"] - plain words for shells without descriptions (tcsh/csh);
# reads $COMMAND_LINE, which tcsh sets while it runs a completion command
complete_line() {
    local line=${1-${COMMAND_LINE:-}} words=() cur w
    exec 2>/dev/null    # tcsh would print any error into the command line
    read -ra words <<<"$line"
    [[ -z "$line" || "$line" == *[[:space:]] ]] && words+=("")
    words=("${words[@]:1}")
    cur=${words[${#words[@]} - 1]:-}
    complete_words "${words[@]}" | while IFS=$'\t' read -r w _; do
        case "$w" in
            @file) paths f "$cur" ;;
            @dir)  paths d "$cur" ;;
            @*|"") ;;
            *)     echo "$w" ;;
        esac
    done
}

# ------------------------------------------------------------------ main ----

case "${1:-}" in
    ""|-h|--help|help) help_main; exit 0 ;;
    __complete)        shift; complete_words "$@"; exit 0 ;;
    __complete-line)   shift; complete_line "$@"; exit 0 ;;
esac

group=$1; shift
[[ "$group" != */* && "$group" != .* ]] && [ -n "$(commands "$group" 2>/dev/null)" ] \
    || die "unknown group '$group' (try: bi help)"

cmd=${1:-}
if [ -n "$cmd" ] && file=$(script_for "$group" "$cmd"); then
    shift
elif file=$(script_for "$group" ""); then
    :   # the group's own script (e.g. claude/bi-claude) gets all the args
elif [ -z "$cmd" ] || [ "$cmd" = "-h" ] || [ "$cmd" = "--help" ] || [ "$cmd" = "help" ]; then
    printf '%s%s%s\n' "$B$C" "$group" "$N"
    help_group "$group"
    exit 0
else
    die "unknown command '$cmd' in '$group' (try: bi $group)"
fi

if [ -x "$file" ] && head -c 2 "$file" | grep -q '#!'; then
    exec "$file" "$@"
fi
exec bash "$file" "$@"
