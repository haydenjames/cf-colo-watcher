#!/bin/bash
#
# colowatch.sh - Watch Cloudflare colo and TTFB in real time
#
# Shows which Cloudflare colo (datacenter) is serving each request, along with
# cache status, TTFB, and per-phase DNS/TCP/TLS handshake times. Run it, switch
# VPN/connection mid-run, and watch how the colo and timing change.
#
# Usage:
#   ./colowatch.sh [options] <url> [interval] [count]
#
# Options:
#   -c, --compact     Narrower table without the DNS/TCP/TLS breakdown
#       --csv FILE    Write all samples as CSV to FILE
#       --json FILE   Write all samples as JSON Lines to FILE
#   -h, --help        Show this help
#
# Examples:
#   ./colowatch.sh https://example.com
#   ./colowatch.sh -c https://example.com
#   ./colowatch.sh --csv runs.csv https://example.com 5 50
#   ./colowatch.sh --json runs.jsonl https://example.com 5 100
#
# If count is omitted or 0, runs until Ctrl+C.
#
# Requires: curl, awk, sort. Works on bash 3.2+ (default macOS bash).

set -u

VERSION="1.2.0"
COMPACT=0
CSV_OUT=""
JSON_OUT=""

print_usage() {
  cat <<EOF
colowatch $VERSION

Usage: $0 [options] <url> [interval] [count]

Options:
  -c, --compact     Narrower table without the DNS/TCP/TLS breakdown
      --csv FILE    Write all samples as CSV to FILE
      --json FILE   Write all samples as JSON Lines to FILE
  -h, --help        Show this help

  interval          Seconds between requests (default 5)
  count             Stop after N requests (default 0 = run until Ctrl+C)

Examples:
  $0 https://example.com
  $0 -c https://example.com
  $0 --csv runs.csv https://example.com 5 50
EOF
}

# Parse options + positional args
POSITIONAL_1=""; POSITIONAL_2=""; POSITIONAL_3=""; PIDX=0
while [ $# -gt 0 ]; do
  case "$1" in
    -c|--compact)  COMPACT=1; shift ;;
    --csv)         CSV_OUT="${2:-}"; shift 2 ;;
    --json)        JSON_OUT="${2:-}"; shift 2 ;;
    -h|--help)     print_usage; exit 0 ;;
    --)            shift; while [ $# -gt 0 ]; do
                     PIDX=$((PIDX+1))
                     eval "POSITIONAL_$PIDX=\$1"
                     shift
                   done; break ;;
    -*)            echo "Unknown option: $1" >&2; print_usage >&2; exit 1 ;;
    *)             PIDX=$((PIDX+1))
                   eval "POSITIONAL_$PIDX=\$1"
                   shift ;;
  esac
done

URL="$POSITIONAL_1"
INTERVAL="${POSITIONAL_2:-5}"
COUNT="${POSITIONAL_3:-0}"

if [ -z "$URL" ]; then
  print_usage >&2
  exit 1
fi

# Colors (only if stdout is a terminal)
if [ -t 1 ]; then
  RED='\033[0;31m'; YELLOW='\033[0;33m'; GREEN='\033[0;32m'
  CYAN='\033[0;36m'; DIM='\033[2m'; BOLD='\033[1m'; RESET='\033[0m'
else
  RED=''; YELLOW=''; GREEN=''; CYAN=''; DIM=''; BOLD=''; RESET=''
fi

color_ttfb() {
  awk -v t="$1" -v r="$RED" -v y="$YELLOW" -v g="$GREEN" -v x="$RESET" \
    'BEGIN {
       if (t+0 >= 1.0)      printf "%s%6.3fs%s", r, t, x;
       else if (t+0 >= 0.5) printf "%s%6.3fs%s", y, t, x;
       else                 printf "%s%6.3fs%s", g, t, x;
     }'
}

# CSV field escape (RFC 4180): wrap in quotes if it contains a comma, quote, or newline
csv_field() {
  case "$1" in
    *,*|*\"*|*'
'*)
      printf '"%s"' "$(printf '%s' "$1" | sed 's/"/""/g')" ;;
    *)
      printf '%s' "$1" ;;
  esac
}

# JSON string escape (quotes, backslash, control chars)
json_str() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//	/\\t}"
  printf '"%s"' "$s"
}

# Working files
STATS_FILE=$(mktemp)
HEADER_FILE=$(mktemp)

# Stats CSV header (also used as default CSV output schema)
echo 'timestamp,colo,cache,http_code,dns_ms,tcp_ms,tls_ms,ttfb_s,total_s,cf_ray,server_timing' > "$STATS_FILE"

# Truncate JSON output if requested
if [ -n "$JSON_OUT" ]; then
  : > "$JSON_OUT" || { echo "Cannot write to $JSON_OUT" >&2; exit 1; }
fi

# Banner
echo
echo -e "${BOLD}Cloudflare colo watch${RESET} v$VERSION"
echo    "URL:      $URL"
echo    "Interval: ${INTERVAL}s"
if [ "$COUNT" -gt 0 ]; then
  echo  "Count:    $COUNT requests"
else
  echo  "Count:    unlimited (Ctrl+C to stop)"
fi
echo    "Started:  $(date)"
echo    "Switch your VPN/connection mid-run to compare colos. Ctrl+C to stop."
if [ "$COMPACT" -eq 0 ]; then
  echo -e "${DIM}Tip: pass -c or --compact for a narrower table.${RESET}"
fi
if [ -n "$CSV_OUT" ];  then echo "CSV out:  $CSV_OUT"; fi
if [ -n "$JSON_OUT" ]; then echo "JSON out: $JSON_OUT"; fi
echo

# Table header
if [ "$COMPACT" -eq 1 ]; then
  printf "${BOLD}%-8s | %-6s | %-3s | %-9s | %-9s | %-9s | %s${RESET}\n" \
    "TIME" "COLO" "HTTP" "CACHE" "TTFB" "TOTAL" "CF-RAY"
  printf -- "---------+--------+-----+-----------+-----------+-----------+--------------------------\n"
else
  printf "${BOLD}%-8s | %-6s | %-3s | %-9s | %5s | %5s | %5s | %-9s | %-9s | %s${RESET}\n" \
    "TIME" "COLO" "HTTP" "CACHE" "DNS" "TCP" "TLS" "TTFB" "TOTAL" "CF-RAY"
  printf -- "---------+--------+-----+-----------+-------+-------+-------+-----------+-----------+--------------------------\n"
fi

# Summary on exit (Ctrl+C, TERM, or after fixed count)
SUMMARY_PRINTED=0
cleanup() {
  [ "$SUMMARY_PRINTED" -eq 1 ] && exit 0
  SUMMARY_PRINTED=1
  echo
  echo
  echo -e "${BOLD}Summary by colo and cache status:${RESET}"
  printf "%-6s | %-10s | %-7s | %-8s | %-8s | %-8s\n" \
    "COLO" "CACHE" "SAMPLES" "P50 TTFB" "P95 TTFB" "MAX TTFB"
  printf -- "-------+------------+---------+----------+----------+----------\n"

  # Sort by colo,cache,ttfb so percentiles can be picked by index in awk.
  tail -n +2 "$STATS_FILE" \
    | awk -F',' 'NF >= 9 { print $0 }' \
    | sort -t',' -k2,2 -k3,3 -k8,8g \
    | awk -F',' '
        {
          key = $2 "|" $3
          if (!(key in n)) keys[++K] = key
          n[key]++
          vals[key, n[key]] = $8 + 0
        }
        END {
          for (i = 1; i <= K; i++) {
            k = keys[i]
            cnt = n[k]
            p50_i = int(cnt * 0.50 + 0.5); if (p50_i < 1) p50_i = 1
            p95_i = int(cnt * 0.95 + 0.5); if (p95_i < 1) p95_i = 1
            split(k, p, "|")
            printf "%-6s | %-10s | %-7d | %7.3fs | %7.3fs | %7.3fs\n", \
              p[1], p[2], cnt, vals[k, p50_i], vals[k, p95_i], vals[k, cnt]
          }
        }
      '
  echo

  if [ -n "$CSV_OUT" ]; then
    cp "$STATS_FILE" "$CSV_OUT" && echo "CSV written: $CSV_OUT"
  fi
  if [ -n "$JSON_OUT" ]; then
    echo "JSON written: $JSON_OUT"
  fi

  exit 0
}
trap cleanup INT TERM
trap 'rm -f "$STATS_FILE" "$HEADER_FILE"' EXIT

PREV_COLO=""
i=0
while true; do
  i=$((i + 1))

  : > "$HEADER_FILE"
  timing=$(curl -sS --max-time 15 -A "cf-colo-watcher/$VERSION" \
    -o /dev/null -D "$HEADER_FILE" \
    -w "%{time_namelookup} %{time_connect} %{time_appconnect} %{time_starttransfer} %{time_total} %{http_code}" \
    "$URL") || timing="0 0 0 0 0 000"

  t_dns=$(echo "$timing"   | awk '{print $1}')
  t_tcp=$(echo "$timing"   | awk '{print $2}')
  t_tls=$(echo "$timing"   | awk '{print $3}')
  ttfb=$(echo "$timing"    | awk '{print $4}')
  total=$(echo "$timing"   | awk '{print $5}')
  code=$(echo "$timing"    | awk '{print $6}')

  # Per-phase deltas in ms, integer
  dns_ms=$(awk -v a="$t_dns"                 'BEGIN { printf "%d", a*1000 + 0.5 }')
  tcp_ms=$(awk -v a="$t_tcp" -v b="$t_dns"   'BEGIN { v=(a-b)*1000; if (v<0) v=0; printf "%d", v+0.5 }')
  tls_ms=$(awk -v a="$t_tls" -v b="$t_tcp"   'BEGIN { v=(a-b)*1000; if (v<0) v=0; printf "%d", v+0.5 }')

  ray=$(grep -i '^cf-ray:'         "$HEADER_FILE" | tail -1 | awk '{print $2}' | tr -d '\r')
  colo=$(echo "$ray" | awk -F'-' '{print $2}')
  cache=$(grep -i '^cf-cache-status:' "$HEADER_FILE" | tail -1 | awk '{print $2}' | tr -d '\r')

  # Join multiple server-timing headers into one comma-separated string
  server_timing=$(grep -i '^server-timing:' "$HEADER_FILE" \
    | sed -E 's/^[Ss]erver-[Tt]iming:[[:space:]]*//' \
    | tr -d '\r' \
    | paste -sd ',' - 2>/dev/null)

  colo="${colo:-???}"
  cache="${cache:-NONE}"
  ray="${ray:--}"
  code="${code:-000}"

  ts=$(date +%H:%M:%S)
  ts_iso=$(date +%FT%T%z)

  # Colo-change banner
  if [ -n "$PREV_COLO" ] && [ "$PREV_COLO" != "$colo" ] \
     && [ "$colo" != "???" ] && [ "$PREV_COLO" != "???" ]; then
    printf "${DIM}─── colo changed: %s → %s ───${RESET}\n" "$PREV_COLO" "$colo"
  fi
  PREV_COLO="$colo"

  # Live row
  ttfb_colored=$(color_ttfb "$ttfb")
  if [ "$COMPACT" -eq 1 ]; then
    printf "%-8s | ${CYAN}%-6s${RESET} | %-3s | %-9s | %b | %7.3fs | %s\n" \
      "$ts" "$colo" "$code" "$cache" \
      "$ttfb_colored" "$total" "$ray"
  else
    printf "%-8s | ${CYAN}%-6s${RESET} | %-3s | %-9s | %5s | %5s | %5s | %b | %7.3fs | %s\n" \
      "$ts" "$colo" "$code" "$cache" \
      "$dns_ms" "$tcp_ms" "$tls_ms" \
      "$ttfb_colored" "$total" "$ray"
  fi

  # Stats / output: only record successful requests
  if [ "$code" != "000" ] && [ "$code" -ge 200 ] && [ "$code" -lt 400 ]; then
    {
      printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$(csv_field "$ts_iso")" \
        "$(csv_field "$colo")" \
        "$(csv_field "$cache")" \
        "$code" \
        "$dns_ms" \
        "$tcp_ms" \
        "$tls_ms" \
        "$ttfb" \
        "$total" \
        "$(csv_field "$ray")" \
        "$(csv_field "$server_timing")"
    } >> "$STATS_FILE"

    if [ -n "$JSON_OUT" ]; then
      {
        printf '{'
        printf '"timestamp":%s,'    "$(json_str "$ts_iso")"
        printf '"colo":%s,'         "$(json_str "$colo")"
        printf '"cache":%s,'        "$(json_str "$cache")"
        printf '"http_code":%s,'    "$code"
        printf '"dns_ms":%s,'       "$dns_ms"
        printf '"tcp_ms":%s,'       "$tcp_ms"
        printf '"tls_ms":%s,'       "$tls_ms"
        printf '"ttfb_s":%s,'       "$ttfb"
        printf '"total_s":%s,'      "$total"
        printf '"cf_ray":%s,'       "$(json_str "$ray")"
        printf '"server_timing":%s' "$(json_str "$server_timing")"
        printf '}\n'
      } >> "$JSON_OUT"
    fi
  fi

  if [ "$COUNT" -gt 0 ] && [ "$i" -ge "$COUNT" ]; then
    cleanup
  fi

  sleep "$INTERVAL"
done
