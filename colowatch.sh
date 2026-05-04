#!/bin/bash
#
# colowatch.sh - Watch Cloudflare colo and TTFB in real time
#
# Shows which Cloudflare colo (datacenter) is serving each request, along with
# cache status and TTFB. Run it, switch VPN/connection mid-run, and watch how
# the colo and timing change.
#
# Usage:
#   ./colowatch.sh <url> [interval] [count]
#
# Examples:
#   ./colowatch.sh https://example.com
#   ./colowatch.sh https://example.com 3
#   ./colowatch.sh https://example.com 5 20
#   ./colowatch.sh https://example.com 5 50 | tee results.log
#
# If count is omitted or 0, runs until Ctrl+C.
#
# Requires: curl, awk

set -u

URL="${1:-}"
INTERVAL="${2:-5}"
COUNT="${3:-0}"

if [ -z "$URL" ]; then
  echo "Usage: $0 <url> [interval_seconds] [count]"
  echo "Example: $0 https://example.com 5 20"
  echo "  count=0 or omitted means run until Ctrl+C"
  exit 1
fi

# Color codes (only used if stdout is a terminal)
if [ -t 1 ]; then
  RED='\033[0;31m'
  YELLOW='\033[0;33m'
  GREEN='\033[0;32m'
  CYAN='\033[0;36m'
  BOLD='\033[1m'
  RESET='\033[0m'
else
  RED='' YELLOW='' GREEN='' CYAN='' BOLD='' RESET=''
fi

# Color a TTFB value based on thresholds (seconds)
color_ttfb() {
  local t="$1"
  awk -v t="$t" -v r="$RED" -v y="$YELLOW" -v g="$GREEN" -v x="$RESET" \
    'BEGIN {
       if (t+0 >= 1.0) printf "%s%6.3fs%s", r, t, x;
       else if (t+0 >= 0.5) printf "%s%6.3fs%s", y, t, x;
       else printf "%s%6.3fs%s", g, t, x;
     }'
}

# Print header
echo
echo -e "${BOLD}Cloudflare colo watch${RESET}"
echo    "URL:      $URL"
echo    "Interval: ${INTERVAL}s"
if [ "$COUNT" -gt 0 ]; then
  echo  "Count:    $COUNT requests"
else
  echo  "Count:    unlimited (Ctrl+C to stop)"
fi
echo    "Started:  $(date)"
echo    "Switch your VPN/connection mid-run to compare colos. Ctrl+C to stop."
echo
printf "${BOLD}%-8s | %-6s | %-3s | %-12s | %-9s | %-9s | %s${RESET}\n" \
       "TIME" "COLO" "HTTP" "CACHE" "TTFB" "TOTAL" "CF-RAY"
printf -- "---------+--------+-----+--------------+-----------+-----------+--------------------------\n"

# Stats tracking per colo
declare -A count_colo sum_ttfb max_ttfb min_ttfb

cleanup() {
  echo
  echo
  echo -e "${BOLD}Summary by colo:${RESET}"
  printf "%-6s | %-7s | %-8s | %-8s | %-8s\n" "COLO" "SAMPLES" "AVG TTFB" "MIN TTFB" "MAX TTFB"
  printf -- "-------+---------+----------+----------+----------\n"
  for colo in "${!count_colo[@]}"; do
    n="${count_colo[$colo]}"
    sum="${sum_ttfb[$colo]}"
    avg=$(awk -v s="$sum" -v n="$n" 'BEGIN { printf "%.3f", s/n }')
    printf "%-6s | %-7d | %7.3fs | %7.3fs | %7.3fs\n" \
      "$colo" "$n" "$avg" "${min_ttfb[$colo]}" "${max_ttfb[$colo]}"
  done
  echo
  exit 0
}
trap cleanup INT TERM

tmpfile=""
trap 'rm -f "$tmpfile"' EXIT

i=0
while true; do
  i=$((i + 1))

  # Single request: capture timing AND headers in one shot
  tmpfile=$(mktemp)
  timing=$(curl -sS --max-time 15 -A "cf-colo-watcher/1.0" \
    -o /dev/null -D "$tmpfile" \
    -w "%{time_starttransfer} %{time_total} %{http_code}" \
    "$URL") || timing="0 0 000"

  ttfb=$(echo "$timing" | awk '{print $1}')
  total=$(echo "$timing" | awk '{print $2}')
  code=$(echo "$timing" | awk '{print $3}')

  ray=$(grep -i '^cf-ray:' "$tmpfile" | awk '{print $2}' | tr -d '\r')
  colo=$(echo "$ray" | awk -F'-' '{print $2}')
  cache=$(grep -i '^cf-cache-status:' "$tmpfile" | awk '{print $2}' | tr -d '\r')
  rm -f "$tmpfile"
  tmpfile=""

  # Defaults if missing
  colo="${colo:-???}"
  cache="${cache:-NONE}"
  ray="${ray:--}"
  code="${code:-000}"

  # Only update stats on a successful request, otherwise zeros pollute min/avg
  if [ "$code" != "000" ] && [ "$code" -ge 200 ] && [ "$code" -lt 400 ]; then
    count_colo[$colo]=$((${count_colo[$colo]:-0} + 1))
    sum_ttfb[$colo]=$(awk -v a="${sum_ttfb[$colo]:-0}" -v b="$ttfb" 'BEGIN { print a+b }')
    if [ -z "${min_ttfb[$colo]:-}" ] || awk -v a="$ttfb" -v b="${min_ttfb[$colo]}" 'BEGIN { exit !(a<b) }'; then
      min_ttfb[$colo]="$ttfb"
    fi
    if [ -z "${max_ttfb[$colo]:-}" ] || awk -v a="$ttfb" -v b="${max_ttfb[$colo]}" 'BEGIN { exit !(a>b) }'; then
      max_ttfb[$colo]="$ttfb"
    fi
  fi

  ttfb_colored=$(color_ttfb "$ttfb")
  printf "%-8s | ${CYAN}%-6s${RESET} | %-3s | %-12s | %b | %7.3fs | %s\n" \
    "$(date +%H:%M:%S)" "$colo" "$code" "$cache" "$ttfb_colored" "$total" "$ray"

  # Stop if we've hit the count
  if [ "$COUNT" -gt 0 ] && [ "$i" -ge "$COUNT" ]; then
    cleanup
  fi

  sleep "$INTERVAL"
done
