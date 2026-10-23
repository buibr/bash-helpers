#!/usr/bin/env bash
# bi: Install ~/.me on this machine (bi on PATH, aliases, TAB completion in every shell)
#
# Usage: curl -fsSL https://raw.githubusercontent.com/buibr/bash-helpers/master/install.sh | bash
#        bash ~/.me/install.sh [--system]
#
#   Run through curl, it first gets the repo into ~/.me (git clone, or a tarball
#   without git); when ~/.me is already a clone it updates it with git pull.
#
#   bi is linked into ~/.local/bin, which every login session puts on PATH, so it
#   runs from any shell: sh, dash, bash, zsh, fish, ksh, csh, tcsh...
#   --system   also link /usr/local/bin/bi (sudo), so it works for cron, sudo, other users
#
# Then each installed shell gets its config, inside a marked block that is
# rewritten (not duplicated) on every run:
#   bash   ~/.bashrc                          exports, aliases, completion
#   zsh    ~/.zshrc                           exports, aliases, completion
#   fish   ~/.config/fish/conf.d/bi.fish      PATH + completion
#   tcsh   ~/.tcshrc or ~/.cshrc              PATH + completion (csh: PATH only)
#
# Installed a new shell later? Just run this again.

set -euo pipefail

ME="$HOME/.me"
REPO="buibr/bash-helpers"
BRANCH="master"
BEGIN="# >>> bash-helpers >>>"
END="# <<< bash-helpers <<<"
SYSTEM=false
[ "${1:-}" = "--system" ] && SYSTEM=true

ok()   { printf '✔ %s\n' "$1"; }
warn() { printf '⚠ %s\n' "$1"; }

# --------------------------------------------------------------- fetch ----

if [ -d "$ME/.git" ]; then
    git -C "$ME" pull --ff-only -q && ok "updated $ME (git pull)" \
        || warn "could not update $ME (local changes?) - installing what is there"
elif [ ! -f "$ME/bi" ]; then
    # an older copy without bi (e.g. from the previous installer) is kept aside
    if [ -e "$ME" ]; then
        old="$ME.old-$(date +%Y%m%d-%H%M%S)"
        mv "$ME" "$old"
        warn "moved the old $ME to $old"
    fi
    if command -v git >/dev/null; then
        git clone -q -b "$BRANCH" "https://github.com/$REPO.git" "$ME"
        ok "cloned $REPO into $ME"
    else
        mkdir -p "$ME"
        curl -fsSL "https://github.com/$REPO/archive/refs/heads/$BRANCH.tar.gz" \
            | tar xz -C "$ME" --strip-components=1
        ok "downloaded $REPO into $ME (install git to update it with: git -C ~/.me pull)"
    fi
fi

[ -f "$ME/bi" ] || { echo "$ME has no bi - download failed?" >&2; exit 1; }

# scripts lose their exec bit when copied through zip / NTFS / some USB sticks
chmod +x "$ME/bi" "$ME/install.sh" "$ME"/*/bi-*

# set_block <file> <content> - write the managed block, replacing an older one
set_block() {
    local file=$1 body=$2 tmp
    mkdir -p "$(dirname "$file")"
    touch "$file"
    tmp=$(mktemp)
    awk -v b="$BEGIN" -v e="$END" '$0 == b { skip = 1 } !skip { print } $0 == e { skip = 0 }' "$file" >"$tmp"
    # drop trailing blank lines left behind, then append the fresh block
    sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$tmp" >"$file"
    printf '\n%s\n%s\n%s\n' "$BEGIN" "$body" "$END" >>"$file"
    rm -f "$tmp"
    ok "configured $file"
}

has() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------- PATH ----

mkdir -p "$HOME/.local/bin"
ln -sfn "$ME/bi" "$HOME/.local/bin/bi"
ok "linked ~/.local/bin/bi"

if $SYSTEM; then
    sudo ln -sfn "$ME/bi" /usr/local/bin/bi && ok "linked /usr/local/bin/bi"
fi

# ---------------------------------------------------------------- bash ----

# lines from an older manual setup move into the managed block
if [ -f "$HOME/.bashrc" ]; then
    sed -i -E '/^# bash-helpers$/d; \#^source \$HOME/\.me/(exports|aliases|bi-completion\.bash|completions/bi\.bash)$#d' "$HOME/.bashrc"
fi
set_block "$HOME/.bashrc" 'source $HOME/.me/exports
source $HOME/.me/aliases
source $HOME/.me/completions/bi.bash'

# ----------------------------------------------------------------- zsh ----

if has zsh || [ -f "$HOME/.zshrc" ]; then
    set_block "$HOME/.zshrc" 'source $HOME/.me/exports
source $HOME/.me/aliases
source $HOME/.me/completions/bi.zsh'
fi

# ---------------------------------------------------------------- fish ----

if has fish || [ -d "$HOME/.config/fish" ]; then
    mkdir -p "$HOME/.config/fish/completions" "$HOME/.config/fish/conf.d"
    ln -sfn "$ME/completions/bi.fish" "$HOME/.config/fish/completions/bi.fish"
    cat >"$HOME/.config/fish/conf.d/bi.fish" <<'EOF'
# written by ~/.me/install.sh
contains -- $HOME/.local/bin $PATH; or set -gx PATH $HOME/.local/bin $PATH
EOF
    ok "configured ~/.config/fish (conf.d/bi.fish, completions/bi.fish)"
fi

# ------------------------------------------------------------ tcsh/csh ----

if has tcsh || has csh || [ -f "$HOME/.tcshrc" ] || [ -f "$HOME/.cshrc" ]; then
    # tcsh reads ~/.tcshrc if it exists, else ~/.cshrc; plain csh only ~/.cshrc
    rcs=("$HOME/.cshrc")
    [ -f "$HOME/.tcshrc" ] && rcs+=("$HOME/.tcshrc")
    for rc in "${rcs[@]}"; do
        set_block "$rc" 'set path = ( $HOME/.local/bin $path )
if ( $?tcsh ) source $HOME/.me/completions/bi.tcsh'
    done
fi

# ------------------------------------------------------------- summary ----

missing=()
for c in jq curl dig nc ab python3; do has "$c" || missing+=("$c"); done
[ ${#missing[@]} -eq 0 ] || warn "some commands use tools not installed here: ${missing[*]}
  sudo apt install jq curl dnsutils netcat-openbsd apache2-utils python3"

case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) warn "~/.local/bin is not on PATH in this session yet - log out and back in once" ;;
esac

ok "done - open a new terminal, then type: bi <TAB><TAB>"
