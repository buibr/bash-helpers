# tcsh / csh completion for `bi` (see ~/.me/bi). Sourced from ~/.tcshrc by
# ~/.me/install.sh. tcsh cannot show descriptions, so only the words are listed.

complete bi 'p/*/`bi __complete-line`/'

# list the choices on TAB when it is ambiguous (tcsh's default is Ctrl-D)
if ( ! $?autolist ) set autolist = ambiguous
