#!/usr/bin/env bash
# bi: Disk, partition & space report, plus disk diagnostics
# bi-arg: health   Why is this disk slow? (mount|path|/dev/X)
# bi-arg: speed    Direct-I/O speed test: <dir> [MB]
# bi-arg: verify   Byte-level check of a copy: <src> <dst>
# bi-arg: git      git fsck every repo under <dir> [src-dir]
# bi-arg: perms    Strip exec bit left by NTFS/FAT copies (dry run)
# bi-arg: tune     Check/raise inotify limits and swappiness
# bi-arg: -w=      Warn threshold % (default 70)
# bi-arg: -c=      Crit threshold % (default 90)
# bi-arg: -o=@file Save report to file
# bi-arg: -s       Short summary only
# bi-arg: -h       Show help
# bi-arg health: @file
# bi-arg speed: @dir
# bi-arg verify: @dir
# bi-arg verify: --quick      Names/sizes/dates only
# bi-arg verify: --no-git     Skip git fsck
# bi-arg verify: --exclude=   Exclude pattern
# bi-arg verify: --out=@dir   Report directory
# bi-arg git: @dir
# bi-arg perms: @dir
# bi-arg perms: --apply  Actually strip the bits
# bi-arg tune: --apply   Apply the changes (root)
# =============================================================================
#  Disk, Partition & Space Checker
#  Compatible with Ubuntu 24.04
#  Usage: bi-disk.sh [OPTIONS]              full disk/space report
#         bi-disk.sh <command> [ARGS]       diagnostics (see Commands)
#
#  Options:
#    -w <percent>   Warn  threshold % (default: 70)
#    -c <percent>   Crit  threshold % (default: 90)
#    -o <file>      Save report to file
#    -s             Short summary only
#    -h             Show help
#
#  Commands:
#    health <mount|path|/dev/X>
#        Why is this disk slow? Device, PCIe link, DRAM-less/HMB, temperature,
#        kernel I/O errors, TRIM, mount options, IDE file-watcher (inotify)
#        exhaustion, swap & I/O pressure, SMART (with sudo).
#    speed <dir> [MB]
#        Direct-I/O speed test with a temp file (default 4096 MB), written in
#        512 MB steps to reveal SLC-cache drops. The file is always removed.
#    verify <src> <dst> [--quick] [--no-git] [--exclude PAT] [--out DIR]
#        Byte-level check that a copy is correct (rsync checksums, read-only).
#        Separates real problems from files changed after the copy, then runs
#        git fsck on every repo in <dst>. --quick = names/sizes/dates only.
#    git <dir> [src-dir]
#        git fsck every repo under <dir>; with src-dir, tells whether a
#        broken repo was already broken in the source.
#    perms <dir> [--apply]
#        Find files that got the executable bit from an NTFS/FAT copy and
#        strip it (keeps scripts with #! and ELF binaries). Dry run by default.
#    tune [--apply]
#        Check/raise inotify watch limits and swappiness for IDEs (root).
#
#  Examples:
#    bi-disk.sh health ~/Code
#    bi-disk.sh speed ~/Common 8192
#    bi-disk.sh verify /mnt/old-ntfs ~/Common
#    sudo bi-disk.sh tune --apply
# =============================================================================

set -euo pipefail

# ─── Defaults ────────────────────────────────────────────────────────────────
WARN_THRESHOLD=70
CRIT_THRESHOLD=90
OUTPUT_FILE=""
SHORT_MODE=false

# ─── Colours ─────────────────────────────────────────────────────────────────
RED='\033[0;31m';    GREEN='\033[0;32m';  YELLOW='\033[1;33m'
CYAN='\033[0;36m';   BLUE='\033[0;34m';  MAGENTA='\033[0;35m'
WHITE='\033[1;37m';  BOLD='\033[1m';     DIM='\033[2m';  RESET='\033[0m'

# Disable colour when writing to file
is_tty() { [[ -t 1 ]]; }

# ─── Helpers ─────────────────────────────────────────────────────────────────
sep()  { printf '%s\n' "$(printf '─%.0s' {1..72})"; }
sep2() { printf '%s\n' "$(printf '═%.0s' {1..72})"; }

usage() {
    grep '^#  ' "$0" | sed 's/^#  //'
    exit 0
}

while getopts ":w:c:o:sh" opt; do
    case $opt in
        w) WARN_THRESHOLD="$OPTARG" ;;
        c) CRIT_THRESHOLD="$OPTARG" ;;
        o) OUTPUT_FILE="$OPTARG"    ;;
        s) SHORT_MODE=true          ;;
        h) usage                    ;;
        :) echo "Option -$OPTARG requires an argument."; exit 1 ;;
       \?) echo "Unknown option: -$OPTARG"; exit 1 ;;
    esac
done

# ─── Check required tools ─────────────────────────────────────────────────────
need() {
    command -v "$1" &>/dev/null || { echo "Required tool '$1' not found."; exit 1; }
}
need lsblk; need df; need awk

# ─── Usage bar ───────────────────────────────────────────────────────────────
usage_bar() {
    local pct=$1 width=30
    local filled=$(( pct * width / 100 ))
    local empty=$(( width - filled ))
    local bar=""
    local color

    if   (( pct >= CRIT_THRESHOLD )); then color="$RED"
    elif (( pct >= WARN_THRESHOLD )); then color="$YELLOW"
    else                                   color="$GREEN"
    fi

    bar+="${color}"
    bar+="$(printf '█%.0s' $(seq 1 $filled 2>/dev/null || true))"
    bar+="${DIM}$(printf '░%.0s' $(seq 1 $empty  2>/dev/null || true))${RESET}"
    echo -e "$bar"
}

# Status badge
badge() {
    local pct=$1
    if   (( pct >= CRIT_THRESHOLD )); then echo -e "${RED}${BOLD}[CRITICAL]${RESET}"
    elif (( pct >= WARN_THRESHOLD )); then echo -e "${YELLOW}${BOLD}[WARNING] ${RESET}"
    else                                   echo -e "${GREEN}${BOLD}[OK]      ${RESET}"
    fi
}

# ─── Header ──────────────────────────────────────────────────────────────────
print_header() {
    clear 2>/dev/null || true
    echo ""
    echo -e "${BOLD}${WHITE}"
    sep2
    printf "  %-68s\n" "💽  DISK, PARTITION & SPACE REPORT"
    printf "  %-68s\n" "Host: $(hostname)   |   $(date '+%Y-%m-%d %H:%M:%S')   |   Kernel: $(uname -r)"
    sep2
    echo -e "${RESET}"
}

# ─── Section 1: Physical Disks ───────────────────────────────────────────────
section_physical_disks() {
    echo -e "${BOLD}${CYAN}  [ 1 ]  PHYSICAL DISKS${RESET}"
    sep
    echo ""

    lsblk -d -o NAME,TYPE,SIZE,ROTA,TRAN,MODEL,VENDOR,STATE \
        --noheadings 2>/dev/null \
    | while IFS= read -r line; do
        NAME=$(echo "$line" | awk '{print $1}')
        TYPE=$(echo "$line" | awk '{print $2}')
        SIZE=$(echo "$line" | awk '{print $3}')
        ROTA=$(echo "$line" | awk '{print $4}')
        TRAN=$(echo "$line" | awk '{print $5}')
        MODEL=$(echo "$line" | awk '{$1=$2=$3=$4=$5=""; print $0}' | xargs)

        # Drive type
        if   [[ "$ROTA" == "0" ]]; then DTYPE="${GREEN}SSD/NVMe${RESET}"
        elif [[ "$ROTA" == "1" ]]; then DTYPE="${YELLOW}HDD     ${RESET}"
        else                            DTYPE="${DIM}Unknown ${RESET}"
        fi

        printf "  ${BOLD}%-12s${RESET}  Type: %-20b  Size: ${WHITE}%-8s${RESET}  Bus: %-8s  %s\n" \
            "/dev/$NAME" "$DTYPE" "$SIZE" "${TRAN:-N/A}" "${MODEL:-}"
    done

    echo ""

    # Disk count summary
    NDISKS=$(lsblk -d --noheadings 2>/dev/null | wc -l)
    echo -e "  ${DIM}Total physical disks detected: ${NDISKS}${RESET}"
    echo ""
}

# ─── Section 2: Partition Tree ───────────────────────────────────────────────
section_partition_tree() {
    echo -e "${BOLD}${CYAN}  [ 2 ]  PARTITION LAYOUT${RESET}"
    sep
    echo ""

    lsblk -o NAME,TYPE,FSTYPE,SIZE,MOUNTPOINT,LABEL,UUID \
        2>/dev/null \
    | head -1 | awk '{printf "  %-40s %-10s %-12s %-10s %-22s %-14s\n", $1,$2,$3,$4,$5,$6}'

    lsblk -o NAME,TYPE,FSTYPE,SIZE,MOUNTPOINT,LABEL,UUID \
        --noheadings 2>/dev/null \
    | awk '{printf "  %-40s %-10s %-12s %-10s %-22s %-14s\n", $1,$2,$3,$4,$5,$6}'

    echo ""
}

# ─── Section 3: Filesystem Space Usage ───────────────────────────────────────
section_space_usage() {
    echo -e "${BOLD}${CYAN}  [ 3 ]  FILESYSTEM SPACE USAGE${RESET}"
    sep
    echo ""

    #        Filesystem        Total    Used     FREE     Use%   Bar                               Status
    printf "  ${BOLD}%-40s  %-8s %-9s %-10s %-6s  %-30s  %s${RESET}\n" \
        "Filesystem" "Total" "Used" "FREE" "Use%" "Used/Free bar" "Status"
    sep

    # Use plain df -h: columns are Filesystem Size Used Avail Use% Mounted-on
    # This works with ALL device types: /dev/sd*, /dev/mapper/*, LVM, etc.
    df -h 2>/dev/null \
    | tail -n +2 \
    | awk '
        # Skip virtual/pseudo filesystems
        $1 ~ /^(tmpfs|devtmpfs|udev|overlay|shm|cgroupfs|sysfs|proc|none)$/ { next }
        $1 ~ /\/dev\/loop/  { next }
        # df sometimes wraps long device names onto the next line (6 fields vs 1)
        NF == 1 { dev=$1; next }
        NF >= 5 {
            if (dev != "") { $1=dev; dev="" }
            # Fields: 1=fs 2=size 3=used 4=avail 5=use% 6=mount
            pct=$5; gsub(/%/,"",pct)
            print $1, $2, $3, $4, pct, $6
        }
    ' \
    | sort -k6 \
    | while read -r SRC SIZE USED AVAIL PCENT MNT; do
        [[ -z "$PCENT" || ! "$PCENT" =~ ^[0-9]+$ ]] && PCENT=0
        FREE_PCT=$(( 100 - PCENT ))

        BAR=$(usage_bar "$PCENT")
        STATUS=$(badge "$PCENT")

        if   (( PCENT >= CRIT_THRESHOLD )); then USED_COLOR="$RED"
        elif (( PCENT >= WARN_THRESHOLD )); then USED_COLOR="$YELLOW"
        else                                     USED_COLOR="$GREEN"
        fi

        if   (( FREE_PCT <= (100 - CRIT_THRESHOLD) )); then FREE_COLOR="${RED}${BOLD}"
        elif (( FREE_PCT <= (100 - WARN_THRESHOLD) )); then FREE_COLOR="${YELLOW}${BOLD}"
        else                                               FREE_COLOR="${GREEN}${BOLD}"
        fi

        printf "  %-40s  ${WHITE}%-8s${RESET} ${USED_COLOR}%-9s${RESET} ${FREE_COLOR}%-10s${RESET} " \
            "$SRC" "$SIZE" "$USED" "$AVAIL"
        printf "${USED_COLOR}%-6s${RESET}  %b  %b\n" "${PCENT}%" "$BAR" "$STATUS"
        printf "  ${DIM}%-40s  %-8s %-9s %-10s %-6s${RESET}\n" \
            "  mount: $MNT" "total" "used" "FREE LEFT" "used%"
        echo ""
    done

    echo ""
}

# ─── Section 4: Inode Usage ──────────────────────────────────────────────────
section_inodes() {
    echo -e "${BOLD}${CYAN}  [ 4 ]  INODE USAGE${RESET}"
    sep
    echo ""

    printf "  ${BOLD}%-40s %-12s %-12s %-12s %-8s  %s${RESET}\n" \
        "Filesystem" "Inodes" "IUsed" "IFree" "IUse%" "Mount"
    sep

    df -i 2>/dev/null \
    | tail -n +2 \
    | awk '
        $1 ~ /^(tmpfs|devtmpfs|udev|overlay|shm|cgroupfs|sysfs|proc|none)$/ { next }
        $1 ~ /\/dev\/loop/ { next }
        NF == 1 { dev=$1; next }
        NF >= 5 {
            if (dev != "") { $1=dev; dev="" }
            pct=$5; gsub(/%/,"",pct)
            print $1, $2, $3, $4, pct, $6
        }
    ' \
    | while read -r SRC ITOT IUSED IFREE IPCENT MNT; do
        [[ -z "$IPCENT" || ! "$IPCENT" =~ ^[0-9]+$ ]] && IPCENT=0

        if   (( IPCENT >= CRIT_THRESHOLD )); then ICOLOR="$RED"
        elif (( IPCENT >= WARN_THRESHOLD )); then ICOLOR="$YELLOW"
        else                                      ICOLOR="$GREEN"
        fi

        printf "  %-40s %-12s %-12s %-12s ${ICOLOR}%-8s${RESET}  %s\n" \
            "$SRC" "$ITOT" "$IUSED" "$IFREE" "${IPCENT}%" "$MNT"
    done

    echo ""
}

# ─── Section 5: Mount Points ─────────────────────────────────────────────────
section_mounts() {
    echo -e "${BOLD}${CYAN}  [ 5 ]  ACTIVE MOUNT POINTS${RESET}"
    sep
    echo ""

    printf "  ${BOLD}%-40s %-25s %-12s %s${RESET}\n" "Device" "Mount Point" "Type" "Options"
    sep

    findmnt -r --noheadings -o SOURCE,TARGET,FSTYPE,OPTIONS 2>/dev/null \
    | grep -vE '^(sysfs|proc|devpts|cgroup|tmpfs|udev|pstore|bpf|tracefs|debugfs|hugetlbfs|mqueue|fusectl|nsfs|overlay)' \
    | sort -k2 \
    | while IFS= read -r line; do
        SRC=$(echo  "$line" | awk '{print $1}')
        TGT=$(echo  "$line" | awk '{print $2}')
        TYPE=$(echo "$line" | awk '{print $3}')
        OPTS=$(echo "$line" | awk '{$1=$2=$3=""; print $0}' | xargs | cut -c1-40)
        printf "  %-40s %-25s %-12s ${DIM}%s${RESET}\n" "$SRC" "$TGT" "$TYPE" "$OPTS"
    done

    echo ""
}

# ─── Section 6: LVM (if present) ─────────────────────────────────────────────
section_lvm() {
    command -v pvs &>/dev/null || return 0
    command -v vgs &>/dev/null || return 0
    command -v lvs &>/dev/null || return 0

    echo -e "${BOLD}${CYAN}  [ 6 ]  LVM${RESET}"
    sep
    echo ""

    echo -e "  ${BOLD}Physical Volumes:${RESET}"
    pvs --noheadings -o pv_name,pv_size,pv_free,vg_name 2>/dev/null \
    | awk '{printf "    %-18s  Size: %-10s  Free: %-10s  VG: %s\n", $1,$2,$3,$4}' \
    || echo "    (none)"
    echo ""

    echo -e "  ${BOLD}Volume Groups:${RESET}"
    vgs --noheadings -o vg_name,vg_size,vg_free,lv_count,pv_count 2>/dev/null \
    | awk '{printf "    %-18s  Size: %-10s  Free: %-10s  LVs: %-4s  PVs: %s\n", $1,$2,$3,$4,$5}' \
    || echo "    (none)"
    echo ""

    echo -e "  ${BOLD}Logical Volumes:${RESET}"
    lvs --noheadings -o lv_name,vg_name,lv_size,lv_attr,origin 2>/dev/null \
    | awk '{printf "    %-20s  VG: %-16s  Size: %-10s  Attr: %s\n", $1,$2,$3,$4}' \
    || echo "    (none)"
    echo ""
}

# ─── Section 7: SMART health (if smartctl available) ─────────────────────────
section_smart() {
    command -v smartctl &>/dev/null || return 0
    [[ $EUID -ne 0 ]] && return 0   # needs root

    echo -e "${BOLD}${CYAN}  [ 7 ]  SMART DISK HEALTH${RESET}"
    sep
    echo ""

    lsblk -d --noheadings -o NAME 2>/dev/null | while read -r DISK; do
        HEALTH=$(smartctl -H "/dev/$DISK" 2>/dev/null | grep -i "overall-health" | awk -F: '{print $2}' | xargs || echo "N/A")
        if echo "$HEALTH" | grep -qi "passed\|ok"; then
            printf "  ${GREEN}✔${RESET}  /dev/%-8s  %s\n" "$DISK" "$HEALTH"
        elif [[ "$HEALTH" == "N/A" ]]; then
            printf "  ${DIM}–  /dev/%-8s  SMART not supported or no data${RESET}\n" "$DISK"
        else
            printf "  ${RED}✘${RESET}  /dev/%-8s  ${RED}%s${RESET}\n" "$DISK" "$HEALTH"
        fi
    done

    echo ""
}

# ─── Section 8: Summary & Alerts ─────────────────────────────────────────────
section_summary() {
    echo -e "${BOLD}${CYAN}  [ ★ ]  SUMMARY & ALERTS${RESET}"
    sep
    echo ""

    # ── Free space table ──────────────────────────────────────────────────────
    echo -e "  ${BOLD}Free space per filesystem:${RESET}"
    echo ""
    printf "  ${BOLD}%-26s  %-10s  %-10s  %-12s  %-7s  %s${RESET}\n" \
        "Filesystem" "Total" "Used" "FREE LEFT" "Used%" "Mount"
    printf "  %s\n" "$(printf '─%.0s' {1..72})"

    df -h 2>/dev/null \
    | tail -n +2 \
    | awk '
        $1 ~ /^(tmpfs|devtmpfs|udev|overlay|shm|cgroupfs|sysfs|proc|none)$/ { next }
        $1 ~ /\/dev\/loop/ { next }
        NF == 1 { dev=$1; next }
        NF >= 5 {
            if (dev != "") { $1=dev; dev="" }
            pct=$5; gsub(/%/,"",pct)
            print $1, $2, $3, $4, pct, $6
        }
    ' \
    | sort -k6 \
    | while read -r SRC SIZE USED AVAIL PCT MNT; do
        [[ -z "$PCT" || ! "$PCT" =~ ^[0-9]+$ ]] && PCT=0

        if   (( PCT >= CRIT_THRESHOLD )); then FC="${RED}${BOLD}";   UC="$RED"
        elif (( PCT >= WARN_THRESHOLD )); then FC="${YELLOW}${BOLD}"; UC="$YELLOW"
        else                                   FC="${GREEN}${BOLD}";  UC="$GREEN"
        fi

        printf "  %-26s  %-10s  ${UC}%-10s${RESET}  ${FC}%-12s${RESET}  ${UC}%-7s${RESET}  %s\n" \
            "$SRC" "$SIZE" "$USED" "$AVAIL" "${PCT}%" "$MNT"
    done

    echo ""
    printf "  %s\n" "$(printf '─%.0s' {1..72})"
    echo ""

    # ── Alerts ────────────────────────────────────────────────────────────────
    ALERTS=$(df -h 2>/dev/null \
        | tail -n +2 \
        | awk -v w="$WARN_THRESHOLD" -v c="$CRIT_THRESHOLD" '
            $1 ~ /^(tmpfs|devtmpfs|udev|overlay|shm|cgroupfs|sysfs|proc|none)$/ { next }
            $1 ~ /\/dev\/loop/ { next }
            NF == 1 { dev=$1; next }
            NF >= 5 {
                if (dev != "") { $1=dev; dev="" }
                pct=$5; gsub(/%/,"",pct)
                free=$4; mnt=$6
                if (pct+0 >= c+0)      printf "CRITICAL  %-30s  %s%% used  FREE: %-10s  mount: %s\n", $1, pct, free, mnt
                else if (pct+0 >= w+0) printf "WARNING   %-30s  %s%% used  FREE: %-10s  mount: %s\n", $1, pct, free, mnt
            }
        ')

    if [[ -z "$ALERTS" ]]; then
        echo -e "  ${GREEN}${BOLD}✔  All filesystems within normal thresholds.${RESET}"
    else
        echo -e "  ${BOLD}Alerts:${RESET}"
        echo "$ALERTS" | while IFS= read -r line; do
            if [[ "$line" == CRITICAL* ]]; then
                echo -e "  ${RED}${BOLD}✘  $line${RESET}"
            else
                echo -e "  ${YELLOW}${BOLD}▲  $line${RESET}"
            fi
        done
    fi

    echo ""
    echo -e "  ${DIM}Warn threshold: ${WARN_THRESHOLD}%   Crit threshold: ${CRIT_THRESHOLD}%${RESET}"
    echo ""

    # ── Top 5 largest directories ─────────────────────────────────────────────
    echo -e "  ${BOLD}Top 5 largest directories in /:${RESET}"
    du -sh /*/ 2>/dev/null \
    | sort -rh \
    | head -5 \
    | awk '{printf "    %-10s  %s\n", $1, $2}' || true

    echo ""
}

# ─── Renderer ─────────────────────────────────────────────────────────────────
run_report() {
    print_header

    if $SHORT_MODE; then
        section_space_usage
        section_summary
        return
    fi

    section_physical_disks
    section_partition_tree
    section_space_usage
    section_inodes
    section_mounts
    section_lvm
    section_smart
    section_summary

    sep2
    echo -e "  ${DIM}Report generated: $(date '+%Y-%m-%d %H:%M:%S')   |   Run with -h for options${RESET}"
    sep2
    echo ""
}

# =============================================================================
# Diagnostic commands: health / speed / verify / git / perms / tune
# =============================================================================

REAL_USER=${SUDO_USER:-${USER:-$(id -un)}}
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
REAL_HOME=${REAL_HOME:-$HOME}
REPORT_DIR="$REAL_HOME/.cache/bi-disk"
SELF=$(basename "$0")

# Paths that are regenerated by tools (builds, caches, dependencies, git objects)
GEN_RE='(^|/)(node_modules|vendor|build|dist|out|target|\.gradle|\.git|\.idea|\.cache|cache|tmp|\.next|\.nuxt|\.cxx|\.kotlin|intermediates|__pycache__|storage/framework|storage/logs)(/|$)'

ISSUES=0
ok()    { echo -e "  ${GREEN}✔${RESET}  $*"; }
warn()  { echo -e "  ${YELLOW}▲${RESET}  $*"; ISSUES=$((ISSUES + 1)); }
bad()   { echo -e "  ${RED}✘${RESET}  $*"; ISSUES=$((ISSUES + 1)); }
info()  { echo -e "  ${DIM}•${RESET}  $*"; }
fix()   { echo -e "     ${CYAN}fix:${RESET} $*"; }
note()  { echo -e "     ${DIM}$*${RESET}"; }
title() { echo ""; echo -e "${BOLD}${CYAN}  $*${RESET}"; sep; }

sub_header() {
    echo ""
    echo -e "${BOLD}${WHITE}"
    sep2
    printf "  %-68s\n" "💽  $1"
    printf "  %-68s\n" "Host: $(hostname)   |   $(date '+%Y-%m-%d %H:%M:%S')   |   Kernel: $(uname -r)"
    sep2
    echo -e "${RESET}"
}

sub_footer() {
    echo ""
    sep2
    if (( ISSUES == 0 )); then
        echo -e "  ${GREEN}${BOLD}✔  No problems found.${RESET}"
    else
        echo -e "  ${YELLOW}${BOLD}▲  $ISSUES item(s) need attention — see ▲ / ✘ above.${RESET}"
    fi
    sep2
    echo ""
}

die() { echo -e "${RED}$*${RESET}" >&2; exit 1; }

fmt_dur() { printf '%dm%02ds' $(( $1 / 60 )) $(( $1 % 60 )); }

# Kernel log for a boot (0 = current, -1 = previous)
klog() {
    journalctl -k -b "$1" --no-pager -q 2>/dev/null && return 0
    [[ $1 == 0 ]] && dmesg 2>/dev/null
    return 0
}

# Map a mount point / path / device node to PART (partition, may be empty) and DISK (whole disk)
resolve_disk() {
    local arg=$1 src parent
    if [[ -b $arg ]]; then
        src=$(readlink -f "$arg")
    elif [[ -e $arg ]]; then
        src=$(findmnt -no SOURCE -T "$arg" 2>/dev/null | head -1 | sed 's/\[.*\]$//')
    else
        die "Not a device or path: $arg"
    fi
    [[ -b $src ]] || die "Can't map '$arg' to a block device (source: '${src:-none}')"
    src=${src#/dev/}
    PART=""; DISK=$src
    while parent=$(lsblk -dno PKNAME "/dev/$DISK" 2>/dev/null | head -1) && [[ -n $parent ]]; do
        PART=${PART:-$DISK}; DISK=$parent
    done
}

# "3.5 GB/s" -> 3500 (MB/s, integer)
to_mbs() {
    awk '{ v=$1; u=$2
           if (u ~ /^GB/) v*=1000; else if (u ~ /^kB/) v/=1000; else if (u ~ /^B\//) v/=1000000
           printf "%d\n", v }' <<<"$1"
}

# Prints "watches process pid" for every inotify user of the current (real) user
inotify_usage() {
    local uid f p n
    uid=$(id -u "$REAL_USER")
    declare -A per=()
    while IFS= read -r f; do
        p=${f#/proc/}; p=${p%%/*}
        [[ $(stat -c %u "/proc/$p" 2>/dev/null) == "$uid" ]] || continue
        n=$(grep -c '^inotify' "/proc/$p/fdinfo/${f##*/}" 2>/dev/null || true)
        per[$p]=$(( ${per[$p]:-0} + ${n:-0} ))
    done < <(find /proc/[0-9]*/fd -lname 'anon_inode:inotify' 2>/dev/null)
    for p in "${!per[@]}"; do
        echo "${per[$p]} $(cat "/proc/$p/comm" 2>/dev/null || echo '?') $p"
    done | sort -rn
}

# ─── health ──────────────────────────────────────────────────────────────────
cmd_health() {
    [[ -n ${1:-} ]] || die "Usage: $SELF health <mount|path|/dev/X>"
    resolve_disk "$1"
    local sys=/sys/block/$DISK
    local ctrl="" pci="" pciaddr="" hmb=""

    sub_header "DISK HEALTH & SLOWNESS CHECK — /dev/$DISK"

    # ── Device ──
    title "[ 1 ]  DEVICE"
    local model size tran fw rota
    model=$(lsblk -dno MODEL "/dev/$DISK" 2>/dev/null | xargs || true)
    size=$(lsblk -dno SIZE "/dev/$DISK" 2>/dev/null | xargs || true)
    tran=$(lsblk -dno TRAN "/dev/$DISK" 2>/dev/null | xargs || true)
    rota=$(cat "$sys/queue/rotational" 2>/dev/null || echo "?")
    fw=$(cat "$sys/device/firmware_rev" "$sys/device/rev" 2>/dev/null | head -1 | xargs || true)
    info "Model: ${BOLD}${model:-?}${RESET}   Size: ${size:-?}   Bus: ${tran:-?}   Firmware: ${fw:-?}"
    [[ -n $PART ]] && info "Checked via partition /dev/$PART" || true
    if [[ $rota == 1 ]]; then
        warn "Rotational disk (HDD): slow random I/O is normal — keep code/IDE projects on an SSD"
    else
        ok "Solid-state (non-rotational)"
    fi
    info "I/O scheduler: $(cat "$sys/queue/scheduler" 2>/dev/null || echo '?')"

    if [[ $DISK == nvme* ]]; then
        ctrl=$(basename "$(readlink -f "$sys/device")")
        pci=$(readlink -f "/sys/class/nvme/$ctrl/device")
        pciaddr=$(basename "$pci")
        local cur max curw maxw
        cur=$(cat "$pci/current_link_speed" 2>/dev/null || true)
        max=$(cat "$pci/max_link_speed" 2>/dev/null || true)
        curw=$(cat "$pci/current_link_width" 2>/dev/null || true)
        maxw=$(cat "$pci/max_link_width" 2>/dev/null || true)
        if [[ -n $cur ]]; then
            if [[ $cur == "$max" && $curw == "$maxw" ]]; then
                ok "PCIe link: $cur x$curw (full speed, controller $ctrl @ $pciaddr)"
            else
                warn "PCIe link runs at $cur x$curw, the drive supports $max x$maxw"
                fix "check which M.2 slot it is in (chipset vs CPU lanes), BIOS PCIe settings, slot sharing"
            fi
        fi
        hmb=$(klog 0 | grep -oE "$ctrl: allocated [0-9]+ MiB host memory buffer" | grep -oE '[0-9]+ MiB' | tail -1 || true)
        if [[ -n $hmb ]]; then
            info "DRAM-less SSD (borrows $hmb of RAM, HMB). Normal use is fast, but long writes can drop"
            note "sharply when the SLC cache fills. Measure it: $SELF speed <mount> 8192"
        fi
    fi

    # Temperature: find the hwmon that belongs to this device
    local h dev t devpath ctrlpath=""
    devpath=$(readlink -f "$sys/device")
    [[ -n $ctrl ]] && ctrlpath=$(readlink -f "/sys/class/nvme/$ctrl") || true
    for h in /sys/class/hwmon/hwmon*; do
        dev=$(readlink -f "$h/device" 2>/dev/null || true)
        [[ -n $dev && ( $dev == "$devpath" || $dev == "$ctrlpath" ) ]] || continue
        t=$(cat "$h/temp1_input" 2>/dev/null || true)
        [[ -n $t ]] || continue
        t=$(( t / 1000 ))
        if   (( t >= 80 )); then bad  "Temperature ${t}°C — thermal throttling likely"; fix "add an M.2 heatsink / improve airflow"
        elif (( t >= 70 )); then warn "Temperature ${t}°C — close to throttling range"
        else                     ok   "Temperature ${t}°C"
        fi
        break
    done

    # ── Kernel log ──
    title "[ 2 ]  KERNEL LOG  (current + previous boot)"
    local pat="(${DISK}|${PART:-@none@}|${ctrl:-@none@}|${pciaddr:-@none@})([^0-9]|$)"
    local errs
    errs=$( { klog -1; klog 0; } \
        | grep -E "$pat" \
        | grep -iE 'I/O error|timeout|timed out|resetting|reset controller|abort|medium error|EXT4-fs (error|warning)|BTRFS (error|warning)|XFS .*(error|corrupt)|failed command|link down|offline|AER:' \
        | grep -vE 'AER: enabled' || true)
    if [[ -z $errs ]]; then
        ok "No I/O errors, timeouts, controller resets or filesystem errors logged for /dev/$DISK"
    else
        bad "$(wc -l <<<"$errs") error line(s) logged for /dev/$DISK — last 8:"
        tail -8 <<<"$errs" | cut -c1-150 | sed 's/^/       /'
    fi

    # ── Filesystems ──
    title "[ 3 ]  FILESYSTEMS ON THIS DISK"
    local n fstype mnt mnts opts pct discard
    discard=$(cat "$sys/queue/discard_max_bytes" 2>/dev/null || echo 0)
    for n in $(lsblk -lno NAME "/dev/$DISK"); do
        fstype=$(lsblk -dno FSTYPE "/dev/$n" 2>/dev/null | xargs || true)
        [[ -n $fstype ]] || continue
        mnts=$(findmnt -rno TARGET -S "/dev/$n" 2>/dev/null | sed 's/\\x20/ /g' || true)
        mnt=$(head -1 <<<"$mnts")
        if [[ -z $mnt ]]; then
            info "/dev/$n ($fstype) — not mounted"
            continue
        fi
        opts=$(findmnt -no OPTIONS "$mnt" | head -1)
        pct=$(df --output=pcent "$mnt" 2>/dev/null | tail -1 | tr -dc '0-9')
        echo -e "  ${BOLD}/dev/$n${RESET}  $fstype  on  $(tr '\n' ' ' <<<"$mnts")"
        note "options: $opts"
        if   (( ${pct:-0} >= 90 )); then bad  "${pct}% full — SSDs slow down a lot when nearly full"
        elif (( ${pct:-0} >= 80 )); then warn "${pct}% full — keep SSDs below ~80% for steady speed"
        else                             ok   "${pct}% used"
        fi
        case $fstype in
            ntfs|ntfs3|exfat|vfat)
                warn "$fstype is slow and loses Linux permissions for code/IDE work (many small files)"
                fix "move the data to ext4 and verify it: $SELF verify <old> <new>" ;;
        esac
        [[ $(findmnt -no FSTYPE "$mnt") == fuseblk ]] && warn "Mounted via FUSE (ntfs-3g): high CPU cost per file operation" || true
        if [[ ,$opts, != *,noatime,* && ,$opts, != *,relatime,* ]]; then
            warn "atime updated on every read"; fix "add 'noatime' to this entry in /etc/fstab"
        fi
        [[ ,$opts, == *,discard,* ]] && info "Online 'discard' enabled — on some drives weekly fstrim gives lower latency" || true
        if [[ $fstype == ext4 && $EUID -eq 0 ]]; then
            local st ec
            st=$(dumpe2fs -h "/dev/$n" 2>/dev/null | awk -F: '/^Filesystem state/{print $2}' | xargs || true)
            ec=$(dumpe2fs -h "/dev/$n" 2>/dev/null | awk -F: '/^FS Error count/{print $2}' | xargs || true)
            if [[ -n ${ec:-} && ${ec:-0} != 0 ]]; then bad "ext4 recorded $ec error(s) (state: $st)"; fix "unmount and run: sudo e2fsck -f /dev/$n"
            else ok "ext4 state: ${st:-?}, no recorded errors"; fi
        fi
    done
    if (( discard > 0 )); then
        if systemctl is-enabled fstrim.timer &>/dev/null; then
            ok "TRIM supported and fstrim.timer enabled ($(systemctl show fstrim.timer -p NextElapseUSecRealtime --value 2>/dev/null | cut -c1-20 || true))"
        else
            warn "TRIM supported but not scheduled"; fix "sudo systemctl enable --now fstrim.timer"
        fi
    elif [[ $rota == 0 ]]; then
        warn "Device reports no TRIM support (USB bridge or old controller?)"
    fi
    if pgrep -x ext4lazyinit &>/dev/null; then
        warn "ext4lazyinit is running — a new ext4 filesystem is initializing inode tables in the background"
        note "extra writes until it finishes; normal for a freshly formatted disk"
    fi

    # ── System factors ──
    title "[ 4 ]  SYSTEM FACTORS THAT FEEL LIKE A SLOW DISK"
    local maxw used=0 usage line
    maxw=$(cat /proc/sys/fs/inotify/max_user_watches)
    usage=$(inotify_usage)
    while read -r line; do [[ -n $line ]] && used=$(( used + ${line%% *} )); done <<<"$usage"
    local wpct=$(( used * 100 / maxw ))
    if (( wpct >= 90 )); then
        bad "File watchers (inotify): $used of $maxw used (${wpct}%) — IDEs fall back to re-scanning folders"
    elif (( wpct >= 70 )); then
        warn "File watchers (inotify): $used of $maxw used (${wpct}%)"
    else
        ok "File watchers (inotify): $used of $maxw used (${wpct}%)"
    fi
    head -5 <<<"$usage" | awk 'NF{printf "       %8d  %s (pid %s)\n", $1, $2, $3}'
    local jb vs
    jb=$(grep -hs 'inotify_add_watch.*No space left on device' \
            "$REAL_HOME"/.cache/JetBrains/*/log/idea.log \
            "$REAL_HOME"/.var/app/com.jetbrains.*/cache/JetBrains/*/log/idea.log 2>/dev/null | tail -1 || true)
    vs=$(grep -rhs 'System limit for number of file watchers reached' \
            "$REAL_HOME/.config/Code/logs" "$REAL_HOME/.config/Cursor/logs" 2>/dev/null | tail -1 || true)
    # IDE logs prove the limit was hit even if usage is lower right now
    [[ -n $jb ]] && echo -e "  ${RED}✘${RESET}  JetBrains IDE ran out of watchers — last at ${jb:0:19}" || true
    [[ -n $vs ]] && echo -e "  ${RED}✘${RESET}  VS Code ran out of watchers — last at ${vs:0:19}" || true
    if (( wpct >= 70 )) || [[ -n $jb || -n $vs ]]; then
        if (( wpct < 70 )); then ISSUES=$((ISSUES + 1)); fi
        fix "sudo $SELF tune --apply   (then restart the IDEs)"
        note "also exclude vendor/, node_modules/, build/, storage/ from IDE indexing"
    fi

    local st sf
    read -r st sf < <(awk '/^SwapTotal/{t=$2} /^SwapFree/{f=$2} END{print t+0, f+0}' /proc/meminfo)
    if (( st > 0 )); then
        local su=$(( (st - sf) * 100 / st )) swp
        swp=$(cat /proc/sys/vm/swappiness)
        if (( su >= 50 )); then
            warn "Swap ${su}% used ($(( (st - sf) / 1024 )) of $(( st / 1024 )) MB), swappiness=$swp — swapping stalls everything"
            fix "sudo $SELF tune --apply   (swappiness 10), or close memory-heavy apps"
        else
            ok "Swap ${su}% used, swappiness=$swp"
        fi
    fi

    local pio pmem
    if [[ -r /proc/pressure/io ]]; then
        pio=$(awk '/^some/{split($4,a,"="); print a[2]}' /proc/pressure/io)
        pmem=$(awk '/^some/{split($4,a,"="); print a[2]}' /proc/pressure/memory)
        if awk -v v="$pio" 'BEGIN{exit !(v >= 10)}'; then
            warn "I/O pressure (5 min avg): ${pio}% of time tasks waited on I/O"
        else
            ok "I/O pressure (5 min avg): ${pio}%   memory pressure: ${pmem}%"
        fi
    fi
    local ram dr
    ram=$(awk '/^MemTotal/{print int($2/1024)}' /proc/meminfo)
    dr=$(cat /proc/sys/vm/dirty_ratio)
    info "Write-back buffer: up to $(( ram * dr / 100 )) MB of unwritten data (vm.dirty_ratio=$dr%) before writers block"

    # ── SMART ──
    title "[ 5 ]  SMART"
    if [[ $EUID -ne 0 ]]; then
        info "Needs root: sudo $SELF health $1"
    elif ! command -v smartctl &>/dev/null; then
        info "smartctl not installed: sudo apt install smartmontools"
    else
        local out health v
        out=$(smartctl -a "/dev/$DISK" 2>/dev/null || true)
        health=$(grep -iE 'overall-health|SMART Health Status' <<<"$out" | awk -F: '{print $2}' | xargs || true)
        if [[ $health =~ PASSED|OK ]]; then ok "SMART overall health: $health"
        elif [[ -z $health ]]; then info "No SMART data (USB bridge?)"
        else bad "SMART overall health: $health"; fi
        sget() { grep -m1 -E "^$1" <<<"$out" | awk -F: '{print $2}' | xargs || true; }
        if [[ $DISK == nvme* ]]; then
            v=$(sget 'Critical Warning');                  [[ -n $v && $v != 0x00 ]] && bad "Critical warning: $v"
            v=$(sget 'Media and Data Integrity Errors');   [[ -n $v ]] && { if [[ $v != 0 ]]; then bad "Media/data integrity errors: $v"; else ok "Media/data integrity errors: 0"; fi; }
            v=$(sget 'Percentage Used' | tr -dc '0-9');    [[ -n $v ]] && { if (( v >= 80 )); then warn "Wear: ${v}% of rated life used"; else ok "Wear: ${v}% of rated life used"; fi; }
            info "Available spare: $(sget 'Available Spare:')   Power-on hours: $(sget 'Power On Hours')   Unsafe shutdowns: $(sget 'Unsafe Shutdowns')"
            info "Data written: $(sget 'Data Units Written')"
        else
            local a raw
            for a in Reallocated_Sector_Ct Current_Pending_Sector Offline_Uncorrectable Reported_Uncorrect UDMA_CRC_Error_Count; do
                raw=$(awk -v a="$a" '$2==a{print $10}' <<<"$out")
                [[ -z $raw ]] && continue || true
                if [[ $raw == 0 ]]; then ok "$a: 0"
                elif [[ $a == UDMA_CRC_Error_Count ]]; then warn "$a: $raw (cable/port errors)"; fix "replace the SATA cable / try another port"
                else bad "$a: $raw"; fi
            done
            for a in Power_On_Hours Percent_Lifetime_Remain SSD_Life_Left Wear_Leveling_Count Total_LBAs_Written; do
                raw=$(awk -v a="$a" '$2==a{print $4" (raw "$10")"}' <<<"$out")
                [[ -n $raw ]] && info "$a: $raw" || true
            done
        fi
    fi

    sub_footer
}

# ─── speed ───────────────────────────────────────────────────────────────────
cmd_speed() {
    local dir=${1:-} mb=${2:-4096}
    [[ -d $dir ]] || die "Usage: $SELF speed <dir> [MB]   (dir must be on the disk to test)"
    [[ $mb =~ ^[0-9]+$ ]] && (( mb >= 512 )) || die "MB must be a number >= 512"
    [[ -w $dir ]] || die "Not writable: $dir"
    local free
    free=$(df --output=avail -m "$dir" | tail -1 | tr -dc '0-9')
    (( free > mb * 2 )) || die "Not enough free space: ${free} MB free, need $(( mb * 2 )) MB"

    SPEED_FILE="$dir/.bi-disk-speedtest.$$"
    local f=$SPEED_FILE
    trap 'rm -f "${SPEED_FILE:-}"' EXIT INT TERM

    sub_header "DISK SPEED TEST — $dir ($(findmnt -no SOURCE -T "$dir" | head -1))"

    local wflag=oflag=direct rflag=iflag=direct
    if ! dd if=/dev/zero of="$f" bs=1M count=1 oflag=direct status=none 2>/dev/null; then
        wflag=""; rflag=""
        warn "O_DIRECT not supported here (FUSE/NTFS?) — read results may come from RAM cache"
    fi

    local chunk=512 steps=$(( mb / 512 )) i s v vmin=999999 vmax=0
    title "Sustained write: $(( steps * chunk )) MB in $chunk MB steps"
    for (( i = 0; i < steps; i++ )); do
        s=$(dd if=/dev/zero of="$f" bs=1M count=$chunk seek=$(( i * chunk )) conv=notrunc,fsync $wflag 2>&1 | tail -1 | awk -F, '{print $NF}' | xargs)
        v=$(to_mbs "$s")
        (( v < vmin )) && vmin=$v || true
        (( v > vmax )) && vmax=$v || true
        printf "  %6d MB   %10s   %s\n" $(( (i + 1) * chunk )) "$s" "$(printf '█%.0s' $(seq 1 $(( v / 200 + 1 ))))"
    done
    if (( vmax > 0 && vmin * 2 < vmax )); then
        warn "Write speed dropped from ${vmax} to ${vmin} MB/s — SLC cache full or thermal throttling"
        note "normal for DRAM-less/QLC drives on long writes; day-to-day work stays in the fast cache"
    else
        ok "Write speed steady: ${vmin}–${vmax} MB/s"
    fi

    title "Read"
    s=$(dd if="$f" of=/dev/null bs=1M $rflag 2>&1 | tail -1 | awk -F, '{print $NF}' | xargs)
    info "Sequential read (1 MB blocks):        $s"
    s=$(dd if="$f" of=/dev/null bs=4k count=25000 $rflag 2>&1 | tail -1 | awk -F, '{print $NF}' | xargs)
    v=$(to_mbs "$s")
    info "4 KB reads, queue depth 1 (dd):       $s  (~$(( v * 1000 / 4 )) IOPS)"
    if command -v fio &>/dev/null; then
        local qd r
        for qd in 1 32; do
            r=$(fio --name=rr --filename="$f" --rw=randread --bs=4k --direct=1 --ioengine=libaio \
                    --iodepth=$qd --runtime=8 --time_based --minimal 2>/dev/null | awk -F';' '{printf "%d MB/s, %d IOPS", $7/1000, $8}' || true)
            info "4 KB random read, queue depth $qd (fio): ${r:-n/a}"
        done
    else
        note "install fio for true random-I/O numbers: sudo apt install fio"
    fi
    note "typical: NVMe Gen4 seq 3000–7000 MB/s · SATA SSD ~500 MB/s · HDD 100–250 MB/s"

    rm -f "$f"
    ok "Test file removed"
    sub_footer
}

# ─── git ─────────────────────────────────────────────────────────────────────
git_fsck() {
    ionice -c3 git -c safe.directory='*' -C "$1" fsck --no-progress --no-dangling 2>&1 \
        | grep -vE '^(notice|Checking|warning: ignoring)' || true
}

cmd_git() {
    local dir=${1:-} src=${2:-}
    [[ -d $dir ]] || die "Usage: $SELF git <dir> [src-dir]"
    command -v git &>/dev/null || die "git not installed"
    dir=$(realpath "$dir"); [[ -n $src ]] && src=$(realpath "$src")

    title "GIT REPOSITORIES IN $dir"
    local g r rel out sout remote repos=0 broken=0
    while IFS= read -r g; do
        r=$(dirname "$g"); rel=${r#"$dir"}; rel=${rel#/}; rel=${rel:-.}
        repos=$((repos + 1))
        out=$(git_fsck "$r")
        if [[ -z $out ]]; then ok "$rel"; continue; fi
        broken=$((broken + 1))
        if [[ -n $src && -e "$src/$rel" ]] && [[ $(git_fsck "$src/$rel") == "$out" ]]; then
            warn "$rel — same problem in the source copy (existed before, not caused by the copy)"
        else
            bad "$rel"
        fi
        head -3 <<<"$out" | cut -c1-140 | sed 's/^/       /'
        remote=$(grep -oE 'refs/remotes/[^/]+/HEAD: invalid' <<<"$out" | head -1 | cut -d/ -f3 || true)
        [[ -n $remote ]] && fix "git -C '$r' remote set-head $remote -a" || true
    done < <(find "$dir" -maxdepth 8 \( -name node_modules -o -name vendor -o -name lost+found \) -prune -o -name .git -print 2>/dev/null | sort)
    echo ""
    info "$repos repositories checked, $broken with problems"
}

# ─── verify ──────────────────────────────────────────────────────────────────
show_list() { # <file> <level> <label> [note]
    local f=$1 level=$2 label=$3 msg=${4:-} n g s
    n=$(grep -c '' "$f" || true)
    if (( n == 0 )); then ok "$label: 0"; return; fi
    "$level" "$label: ${BOLD}$n${RESET}"
    [[ -n $msg ]] && note "$msg" || true
    g=$(grep -cE "$GEN_RE" "$f" || true)
    (( g > 0 )) && note "$g of them inside build/cache/vendor/.git folders (regenerated, usually harmless)" || true
    note "by folder:"
    awk -F/ '{ k = NF - 1; if (k > 3) k = 3; d = ""
               for (i = 1; i <= k; i++) d = d (i > 1 ? "/" : "") $i
               print (d == "" ? "(top level)" : d) }' "$f" | sort | uniq -c | sort -rn | head -6 | sed 's/^/       /'
    s=$(grep -vE "$GEN_RE" "$f" | head -5 || true)
    if [[ -n $s ]]; then
        note "examples outside build/cache folders:"
        sed 's/^/       /' <<<"$s" | cut -c1-140
    fi
    note "full list: $f"
}

cmd_verify() {
    local src="" dst="" quick=false dogit=true out="" rc=0
    local excl=()
    while (( $# )); do
        case $1 in
            --quick)   quick=true ;;
            --no-git)  dogit=false ;;
            --out)     out=${2:?--out needs a directory}; shift ;;
            --exclude) excl+=("--exclude=${2:?--exclude needs a pattern}"); shift ;;
            -*)        die "Unknown option: $1" ;;
            *)         if   [[ -z $src ]]; then src=$1
                       elif [[ -z $dst ]]; then dst=$1
                       else die "Too many arguments"; fi ;;
        esac
        shift
    done
    [[ -d $src && -d $dst ]] || die "Usage: $SELF verify <src> <dst> [--quick] [--no-git] [--exclude PAT] [--out DIR]"
    command -v rsync &>/dev/null || die "rsync not installed: sudo apt install rsync"
    src=$(realpath "$src"); dst=$(realpath "$dst")
    [[ $src != "$dst" ]] || die "Source and destination are the same folder"
    out=${out:-$REPORT_DIR/verify-$(date +%Y%m%d-%H%M%S)}
    mkdir -p "$out"

    local mode="checksum (every byte of every file)"
    $quick && mode="quick (names, sizes, dates — content not read)"
    sub_header "COPY VERIFICATION"
    info "Source:      $src  ($(findmnt -no FSTYPE -T "$src" | head -1))"
    info "Destination: $dst  ($(findmnt -no FSTYPE -T "$dst" | head -1))"
    info "Mode:        $mode"
    info "Read-only:   rsync runs with --dry-run, nothing is copied or deleted"
    info "Report:      $out"

    local flags=-rlnti
    $quick || flags=-rlntci
    excl+=(--exclude='/System Volume Information/' --exclude='/$RECYCLE.BIN/' --exclude='/lost+found/' --exclude='/.Trash-*/')

    title "Comparing..."
    local t0=$SECONDS pid
    ionice -c3 nice -n10 rsync $flags --delete --stats "${excl[@]}" "$src/" "$dst/" \
        > "$out/rsync.txt" 2> "$out/rsync-errors.txt" &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        [[ -t 1 ]] && printf "\r  ⏳ %s elapsed, %d differences so far   " "$(fmt_dur $(( SECONDS - t0 )))" "$(grep -c '' "$out/rsync.txt" || true)" || true
        sleep 2
    done
    wait "$pid" || rc=$?
    [[ -t 1 ]] && printf "\r%-70s\r" "" || true
    info "Finished in $(fmt_dur $(( SECONDS - t0 ))) (rsync exit $rc)"
    if [[ -s $out/rsync-errors.txt ]]; then
        warn "rsync reported $(grep -c '' "$out/rsync-errors.txt") problem(s) (unreadable files?) — first 3:"
        head -3 "$out/rsync-errors.txt" | cut -c1-140 | sed 's/^/       /'
        note "full list: $out/rsync-errors.txt"
    fi
    (( rc == 0 || rc == 23 || rc == 24 )) || die "rsync failed (exit $rc), see $out/rsync-errors.txt"

    # Classify rsync's itemized output
    local L
    for L in missing-in-dst extra-in-dst content-differs corrupt-candidates mtime-only non-regular; do : > "$out/$L.txt"; done
    awk -v o="$out" '
        NF == 0 { next }
        /^\*deleting / { sub(/^\*deleting +/, ""); print > (o "/extra-in-dst.txt"); next }
        /^skipping non-regular file "/ { sub(/^skipping non-regular file "/, ""); sub(/"$/, ""); print > (o "/non-regular.txt"); next }
        /^[<>ch.][fdLDS][c.+?][s.+?][tT.+?]/ {
            it = substr($0, 1, 11); p = substr($0, 13); ty = substr(it, 2, 1)
            if (ty == "L") sub(/ -> .*/, "", p)
            if (substr(it, 3, 9) ~ /^\++$/) { print p > (o "/missing-in-dst.txt"); next }
            if (ty != "f") next
            c = substr(it, 3, 1); s = substr(it, 4, 1); t = substr(it, 5, 1)
            if (c == "c" && s == "." && t == ".")  print p > (o "/corrupt-candidates.txt")
            else if (c == "c" || s == "s")         print p > (o "/content-differs.txt")
            else if (t == "t" || t == "T")         print p > (o "/mtime-only.txt")
        }' "$out/rsync.txt"

    # Content differs: newer in destination = edited after the copy; otherwise suspicious
    : > "$out/changed-after-copy.txt"; : > "$out/suspicious.txt"
    local p
    while IFS= read -r p; do
        if [[ "$dst/$p" -nt "$src/$p" ]]; then echo "$p" >> "$out/changed-after-copy.txt"
        else echo "$p" >> "$out/suspicious.txt"; fi
    done < "$out/content-differs.txt"

    local nfiles tsize
    nfiles=$(grep -m1 '^Number of files:' "$out/rsync.txt" | cut -d: -f2- | xargs || true)
    tsize=$(grep -m1 '^Total file size:' "$out/rsync.txt" | cut -d: -f2- | xargs || true)
    title "RESULT"
    info "Source: ${nfiles:-?} entries, ${tsize:-?}"
    echo ""

    if ! $quick; then
        show_list "$out/corrupt-candidates.txt" bad  "Same size & date but DIFFERENT content (possible corruption)"
    fi
    show_list "$out/suspicious.txt"         warn "Content differs and destination is NOT newer (check these)" \
        "a truncated/failed copy or a file restored from an older version"
    show_list "$out/missing-in-dst.txt"     info "Only in source (missing in destination)" \
        "files never copied, or deleted/moved/rebuilt after the copy"
    show_list "$out/changed-after-copy.txt" info "Changed in destination after the copy (newer date)" \
        "your own edits, rebuilds, caches — expected on a disk in use"
    show_list "$out/extra-in-dst.txt"       info "Only in destination (created after the copy)"
    if $quick; then
        show_list "$out/mtime-only.txt" info "Same size, different date (content NOT checked in --quick mode)"
    else
        show_list "$out/mtime-only.txt" info "Identical content, only the date differs" "harmless (tools touched them)"
    fi
    show_list "$out/non-regular.txt"        info "Skipped sockets/fifos/devices (not data)"

    local real_missing
    real_missing=$(grep -vcE "$GEN_RE" "$out/missing-in-dst.txt" || true)

    # Executable bits — the usual side effect of copying from NTFS/FAT
    title "PERMISSIONS IN DESTINATION"
    local total xbits
    total=$(find "$dst" -xdev -type f 2>/dev/null | wc -l)
    xbits=$(find "$dst" -xdev -type f -perm /111 2>/dev/null | wc -l)
    if (( total > 0 && xbits * 100 / total >= 50 )); then
        warn "$xbits of $total files are executable — typical after copying from NTFS/FAT"
        fix "$SELF perms '$dst'   (dry run first, then --apply)"
    else
        ok "$xbits of $total files executable"
    fi

    $dogit && cmd_git "$dst" "$src"

    title "VERDICT"
    local nc ns
    nc=$(grep -c '' "$out/corrupt-candidates.txt" || true)
    ns=$(grep -c '' "$out/suspicious.txt" || true)
    if (( nc + ns > 0 )); then
        bad "Possible data problems: $nc corruption candidate(s), $ns suspicious file(s) — see the lists above"
    elif (( real_missing > 0 )); then
        warn "Data matches, but $real_missing file(s) outside build/cache folders exist only in the source"
        note "check $out/missing-in-dst.txt — copy them if they were not deleted on purpose"
    elif $quick; then
        ok "Names, sizes and dates match. Run without --quick for a byte-level check."
    else
        ok "All data matches byte for byte; remaining differences are changes made after the copy."
    fi
    [[ -n ${SUDO_USER:-} ]] && chown -R "$SUDO_USER": "$REPORT_DIR" 2>/dev/null || true
    sub_footer
}

# ─── perms ───────────────────────────────────────────────────────────────────
cmd_perms() {
    local dir="" apply=false
    while (( $# )); do
        case $1 in
            --apply) apply=true ;;
            -*)      die "Unknown option: $1" ;;
            *)       dir=$1 ;;
        esac
        shift
    done
    [[ -d $dir ]] || die "Usage: $SELF perms <dir> [--apply]"
    dir=$(realpath "$dir")
    mkdir -p "$REPORT_DIR"
    local list="$REPORT_DIR/exec-bits-$(date +%Y%m%d-%H%M%S).lst"
    : > "$list"

    sub_header "EXECUTABLE-BIT CLEANUP — $dir"
    $apply || info "Dry run — nothing is changed. Add --apply to fix."
    info "Kept executable: scripts starting with #! and ELF binaries (incl. AppImages)"

    local LC_ALL=C f magic total=0 keep=0 strip=0
    while IFS= read -r -d '' f; do
        total=$((total + 1))
        magic=""
        { IFS= read -r -n 4 magic; } 2>/dev/null < "$f" || true
        if [[ $magic == '#!'* || $magic == $'\x7fELF' ]]; then
            keep=$((keep + 1))
        else
            strip=$((strip + 1))
            printf '%s\0' "$f" >> "$list"
        fi
        if [[ -t 1 ]] && (( total % 20000 == 0 )); then printf "\r  scanned %d executable files..." "$total"; fi
    done < <(find "$dir" -xdev -name lost+found -prune -o -type f -perm /111 -print0 2>/dev/null)
    [[ -t 1 ]] && printf "\r%-60s\r" "" || true

    title "RESULT"
    info "Executable files found: $total"
    ok   "Keep (scripts/binaries): $keep"
    if (( strip == 0 )); then ok "Nothing to strip"; sub_footer; return; fi
    if $apply; then info "Strip the executable bit: ${BOLD}$strip${RESET}"
    else warn "Should not be executable: ${BOLD}$strip${RESET}"; fi
    note "by folder:"
    tr '\0' '\n' < "$list" | sed "s|^$dir/||" \
        | awk -F/ '{ k = NF - 1; if (k > 3) k = 3; d = ""
                     for (i = 1; i <= k; i++) d = d (i > 1 ? "/" : "") $i
                     print (d == "" ? "(top level)" : d) }' | sort | uniq -c | sort -rn | head -8 | sed 's/^/       /'
    note "examples:"
    tr '\0' '\n' < "$list" | head -5 | sed "s|^$dir/|       |" | cut -c1-140

    if $apply; then
        xargs -0 -r chmod a-x -- < "$list"
        ok "Removed the executable bit from $strip files (list: $list)"
        note "git repos with core.fileMode=false can now use: git config core.fileMode true"
    else
        fix "$SELF perms '$dir' --apply"
        note "list (NUL-separated): $list"
    fi
    sub_footer
}

# ─── tune ────────────────────────────────────────────────────────────────────
cmd_tune() {
    local apply=false
    [[ ${1:-} == --apply ]] && apply=true || true
    sub_header "KERNEL SETTINGS FOR IDE / DEV WORKLOADS"

    local conf=/etc/sysctl.d/60-bi-disk.conf k cur want lines=()
    local -A rec=( [fs.inotify.max_user_watches]=1048576 [fs.inotify.max_user_instances]=1024 [vm.swappiness]=10 )
    for k in fs.inotify.max_user_watches fs.inotify.max_user_instances vm.swappiness; do
        cur=$(sysctl -n "$k"); want=${rec[$k]}
        if [[ $k == vm.swappiness ]]; then
            if (( cur <= want )); then ok "$k = $cur"; continue; fi
        elif (( cur >= want )); then ok "$k = $cur"; continue; fi
        warn "$k = $cur  →  recommended $want"
        lines+=("$k = $want")
    done
    (( ${#lines[@]} )) || { sub_footer; return; }

    if ! $apply; then
        fix "sudo $SELF tune --apply"
    else
        [[ $EUID -eq 0 ]] || die "Needs root: sudo $SELF tune --apply"
        { echo "# Added by bi-disk tune — IDE file watchers & swap"; printf '%s\n' "${lines[@]}"; } > "$conf"
        sysctl -q -p "$conf"
        ISSUES=0
        ok "Written to $conf and applied:"
        printf '       %s\n' "${lines[@]}"
        note "restart PhpStorm / VS Code so they pick up the new watcher limit"
    fi
    sub_footer
}

case "${1:-}" in
    health) shift; cmd_health "$@"; exit 0 ;;
    speed)  shift; cmd_speed  "$@"; exit 0 ;;
    verify) shift; cmd_verify "$@"; exit 0 ;;
    git)    shift; sub_header "GIT INTEGRITY"; cmd_git "$@"; sub_footer; exit 0 ;;
    perms)  shift; cmd_perms  "$@"; exit 0 ;;
    tune)   shift; cmd_tune   "$@"; exit 0 ;;
    help)   usage ;;
    ""|-*)  ;;
    *)      die "Unknown command: $1 (run $SELF -h)" ;;
esac

# ─── Output ──────────────────────────────────────────────────────────────────
if [[ -n "$OUTPUT_FILE" ]]; then
    # Strip ANSI codes for file output
    run_report | sed 's/\x1b\[[0-9;]*m//g' | tee "$OUTPUT_FILE"
    echo ""
    echo "Report saved to: $OUTPUT_FILE"
else
    run_report
fi