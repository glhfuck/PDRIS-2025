#!/usr/bin/env bash
set -Eeuo pipefail

# Usage: ./script3_loggrep.sh <logfile> <keyword>
# Example: ./script3_loggrep.sh HPC.log error

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <logfile> <keyword>" >&2
  exit 1
fi

LOGFILE="$1"
KEYWORD="$2"

if [[ ! -f "$LOGFILE" ]]; then
  echo "Error: file not found: $LOGFILE" >&2
  exit 1
fi

sanitize() {
  printf "%s" "$1" | tr -cs '[:alnum:]' '_'
}
KEY_SAFE="$(sanitize "$KEYWORD")"
TS="$(date '+%Y%m%d_%H%M%S')"

OUT_MATCHES="matches_${KEY_SAFE}_${TS}.log"
OUT_COUNT="matches_count_${KEY_SAFE}_${TS}.txt"

# Fixed-string search (case-sensitive). Use -Fi for case-insensitive.
grep -F -- "$KEYWORD" "$LOGFILE" > "$OUT_MATCHES" || true

COUNT="$(wc -l < "$OUT_MATCHES" | tr -d '[:space:]')"
echo "$COUNT" > "$OUT_COUNT"

echo "Matches found: $COUNT"
echo "Lines saved to:  $OUT_MATCHES"
echo "Count saved to:  $OUT_COUNT"
