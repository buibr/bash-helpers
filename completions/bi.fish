# fish completion for `bi` (see ~/.me/bi). Linked into ~/.config/fish/completions/
# by ~/.me/install.sh. fish shows the "word<TAB>description" lines as they are.

function __bi_complete
    set -l cur (commandline -ct)
    for line in (bi __complete (commandline -opc)[2..-1] $cur 2>/dev/null)
        switch $line
            case '@file*'
                __fish_complete_path $cur
            case '@dir*'
                __fish_complete_directories $cur
            case '@*'
            case '*'
                echo $line
        end
    end
end

complete -c bi -f -a '(__bi_complete)'
