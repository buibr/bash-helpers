#!/usr/bin/env bash
# bi: Disk usage analyzer - biggest directories and files [dir] [top_n]
# bi-arg: @dir

TARGET="${1:-.}"
TOP="${2:-15}"

if [ ! -d "$TARGET" ]; then
  echo "Usage: $0 [directory] [top_n]"
  exit 1
fi

BOLD='\033[1m'
DIM='\033[2m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

bar() {
  local pct=$1
  local w=25
  local filled=$((pct * w / 100))
  [ "$filled" -gt "$w" ] && filled=$w
  printf "["
  for ((i=0; i<w; i++)); do
    [ "$i" -lt "$filled" ] && printf "█" || printf "░"
  done
  printf "]"
}

fmt() {
  local bytes=$1
  if [ "$bytes" -lt 1024 ]; then echo "${bytes}B"
  elif [ "$bytes" -lt 1048576 ]; then echo "$((bytes / 1024))KB"
  elif [ "$bytes" -lt 1073741824 ]; then echo "$((bytes / 1048576))MB"
  else echo "$((bytes / 1073741824))GB"
  fi
}

TOTAL=$(du -sb "$TARGET" 2>/dev/null | awk '{print $1}')
[ -z "$TOTAL" ] && TOTAL=0

echo
echo -e "  ${BOLD}${WHITE}╭──────────────────────────────────────╮${NC}"
echo -e "  ${BOLD}${WHITE}│       Disk Usage Analyzer            │${NC}"
echo -e "  ${BOLD}${WHITE}╰──────────────────────────────────────╯${NC}"
echo
echo -e "  ${DIM}Target:${NC} ${CYAN}${TARGET}${NC}"
echo -e "  ${DIM}Total: ${NC}${GREEN}$(fmt ${TOTAL})${NC}"
echo

echo -e "  ${BOLD}${YELLOW}▸ Top ${TOP} Directories${NC}"
echo

data=$(du -sb "${TARGET}/"*/ 2>/dev/null | sort -rn | head -n "${TOP}") || true
if [ -z "$data" ]; then
  echo -e "  ${DIM}  (no subdirectories)${NC}"
else
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    sz=$(echo "$line" | awk '{print $1}')
    nm=$(echo "$line" | awk '{print $2}')
    bn=$(basename "$nm")
    [ "$TOTAL" -eq 0 ] && pct=0 || pct=$((sz * 100 / TOTAL))
    [ "$pct" -gt 100 ] && pct=100
    b=$(bar "$pct")
    h=$(fmt "$sz")
    printf "  ${BLUE}%-28s${NC} ${GREEN}%6s${NC} ${DIM}%3d%%${NC} %s\n" "${bn}" "${h}" "${pct}" "${b}"
  done <<< "$data"
fi

echo
echo -e "  ${BOLD}${YELLOW}▸ Top ${TOP} Files${NC}"
echo

fdata=$(find "$TARGET" -maxdepth 4 -type f -exec du -b {} + 2>/dev/null | sort -rn | head -n "${TOP}") || true
if [ -z "$fdata" ]; then
  echo -e "  ${DIM}  (no files found)${NC}"
else
  maxname=0
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    nm=$(echo "$line" | awk '{$1=""; print substr($0,2)}')
    len=${#nm}
    [ "$len" -gt "$maxname" ] && maxname=$len
  done <<< "$fdata"
  [ "$maxname" -gt 80 ] && maxname=80

  while IFS= read -r line; do
    [ -z "$line" ] && continue
    sz=$(echo "$line" | awk '{print $1}')
    nm=$(echo "$line" | awk '{$1=""; print substr($0,2)}')
    [ ${#nm} -gt 80 ] && nm="...${nm: -77}"
    h=$(fmt "$sz")
    printf "  ${MAGENTA}%8s${NC}  ${DIM}%s${NC}\n" "${h}" "${nm}"
  done <<< "$fdata"
fi

echo
echo -e "  ${BOLD}${GREEN}✓${NC} ${DIM}Done${NC}"
echo
