# ~/.me — personal command toolbox

All personal scripts live here, grouped in folders. One command, `bi`, runs any
of them, and TAB completes groups, commands and arguments, with a short
description next to each choice.

```
$ bi <TAB><TAB>
android  -- adb-fix, jdk-fix
claude   -- Run Claude Code with several saved accounts (personal / work)
devops   -- db-create, lemp
dir      -- top, disk
email    -- test
help     -- show all commands
mysql    -- db-backup, db-restore
network  -- local-ip-ports
web      -- bench, dns, headers, ttfb

$ bi web dns example.com
```

## Install

Paste this into a terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/buibr/bash-helpers/master/install.sh | bash
```

Then open a new terminal and type `bi <TAB><TAB>`.

To also make `bi` available for cron, `sudo` and other users (asks for your sudo password):

```bash
curl -fsSL https://raw.githubusercontent.com/buibr/bash-helpers/master/install.sh | bash -s -- --system
```

Or do it by hand:

```bash
git clone https://github.com/buibr/bash-helpers.git ~/.me
bash ~/.me/install.sh
```

**Update:** run the same command again, or `git -C ~/.me pull`. Without git
installed, the installer downloads a tarball instead; install git to get updates.

If `~/.me` already exists but has no `bi` in it (a copy from the old installer),
the installer moves it to `~/.me.old-<date>` first, so nothing is lost.

The installer is safe to run again. Run it again after installing a new shell
(zsh, fish…) so that shell gets set up too. It:

- clones the repo into `~/.me`, or updates it with `git pull` if it is already there

- restores the exec bit on the scripts (zip / NTFS / USB copies lose it)
- links `~/.local/bin/bi` → `~/.me/bi`; every login puts `~/.local/bin` on PATH, so `bi`
  runs from any shell
- writes a marked block (`# >>> bash-helpers >>>` … `# <<< bash-helpers <<<`) into the
  config of each installed shell, replacing the old block on later runs
- warns about missing tools the scripts use (`jq`, `curl`, `dig`, `nc`, `ab`, `python3`)

| Shell             | `bi` runs | TAB completion            | Configured in                                    |
|-------------------|-----------|---------------------------|--------------------------------------------------|
| bash              | ✔         | ✔ with descriptions       | `~/.bashrc` (also loads `exports`, `aliases`)     |
| zsh               | ✔         | ✔ with descriptions       | `~/.zshrc` (also loads `exports`, `aliases`)      |
| fish              | ✔         | ✔ with descriptions       | `~/.config/fish/conf.d/bi.fish`, `completions/`  |
| tcsh              | ✔         | ✔ names only              | `~/.tcshrc` or `~/.cshrc`                        |
| csh, sh, dash, ksh | ✔        | ✘ no completion system    | —                                                |

**Settings for one machine** go in `~/.me/exports.local`. `exports` loads it, and git
ignores it. `bi android jdk-fix` and `bi android adb-fix` write `JAVA_HOME` /
`ANDROID_HOME` there, so run them once on each PC that needs Java or adb.

## Usage

```bash
bi                              # every group and command, with descriptions
bi web                          # the commands of one group
bi web dns example.com          # run a command; all arguments go to the script
bi dir disk --help              # the script's own help
```

## Layout

```
~/.me/
├── bi                    the dispatcher (bash)
├── install.sh            installer, see above
├── completions/          TAB completion: bi.bash, bi.zsh, bi.fish, bi.tcsh
├── exports, aliases      PATH / env and aliases, loaded by bash and zsh
├── exports.local         this machine's own settings (not in git)
└── <group>/bi-*          the scripts: android, claude, devops, dir, email, mysql, network, web
```

## How `bi` finds commands

Nothing is registered by hand: `bi` scans the folders next to it on every call.

- every folder that contains `bi-*` files is a **group**
- the script name minus `bi-`, the group name and `.sh` / `.py` is the **command**:

  | File                        | Command               |
  |-----------------------------|-----------------------|
  | `web/bi-web-dns.sh`         | `bi web dns`          |
  | `dir/bi-disk.sh`            | `bi dir disk`         |
  | `mysql/bi-db-backup.sh`     | `bi mysql db-backup`  |
  | `claude/bi-claude`          | `bi claude` (the group's own script, gets all args) |

- symlinks are skipped (they are old aliases of another script, e.g. `bi-claude-use`)
- a script runs directly if it is executable and has a `#!` line, otherwise with `bash`
- the scripts still work on their own too: `bi-web-dns.sh example.com`

## Adding a script

Drop a `bi-<name>` file into a group folder (or a new folder for a new group):

```bash
cat > ~/.me/web/bi-web-ping.sh <<'EOF'
#!/usr/bin/env bash
# bi: Ping a host 5 times
ping -c 5 "$1"
EOF
chmod +x ~/.me/web/bi-web-ping.sh
```

It shows up at once in `bi`, in `bi web` and in TAB completion.

### Metadata comments (optional)

Comment lines near the top of a script control the help text and completion.
Put them right after the `#!` line.

```bash
# bi: One-line description, shown in `bi` and next to the TAB choice
# bi-arg: <word> <description>              a choice for the first argument
# bi-arg <word>: <word> <description>       choices after the argument <word>
```

`<word>` can be:

| Word                         | Meaning                                                  |
|------------------------------|----------------------------------------------------------|
| `start`, `--quick`, `-v`     | a literal sub-command or flag                            |
| `-o=@file`                   | a flag followed by a file path                           |
| `-p=@dir`                    | a flag followed by a directory                           |
| `-r=`                        | a flag followed by a free value (no suggestions)         |
| `@file` / `@dir`             | complete file / directory paths here                     |
| `@none`                      | suggest nothing (e.g. the script takes a URL)            |
| `@run:<command> # <desc>`    | run a shell command; each output line is a choice       |

Example (from `dir/bi-disk.sh`):

```bash
# bi: Disk, partition & space report, plus disk diagnostics
# bi-arg: health   Why is this disk slow? (mount|path|/dev/X)
# bi-arg: verify   Byte-level check of a copy: <src> <dst>
# bi-arg: -o=@file Save report to file
# bi-arg verify: @dir
# bi-arg verify: --quick      Names/sizes/dates only
# bi-arg verify: --out=@dir   Report directory
```

and from `claude/bi-claude`, with live profile names:

```bash
# bi-arg switch: @run:ls ~/.claude/profiles # switch to this profile
```

Without a `# bi:` line, the description comes from the first line of the script's
header comment (or a Python docstring). Without `# bi-arg:` lines, TAB completes
file names.

## How completion works

Every shell asks `bi` itself, so the logic lives in one place:

```
TAB ──> completions/bi.<shell> ──> bi __complete <words typed so far>
                                    └─> "word<TAB>description" lines
```

- `bi __complete web d` prints `dns<TAB>full DNS / mail / TLS report…`;
  the shell file turns these lines into its own menu (`@file` / `@dir` lines switch on
  path completion)
- `bi __complete-line` is the same for tcsh: it reads the line from `$COMMAND_LINE` and
  prints plain words, since tcsh cannot show descriptions

Debug completion without a shell:

```bash
bi __complete ''                      # groups
bi __complete dir disk verify ''      # choices after "bi dir disk verify "
```

## Notes

- tcsh: paths starting with `~/` don't complete inside `bi` (relative and absolute
  paths do); `bi.tcsh` sets `autolist`, so TAB lists choices for every command, not only `bi`
- fish and tcsh get `bi` and its completion, but not `exports` / `aliases`
  (those are bash/zsh syntax)
- `BI_ROOT=/other/dir bi …` points `bi` at another script folder
