#!/usr/bin/env bash
set -u -o pipefail

# Usage: ./script1_diff_report.sh <repo_url> <branch1> <branch2>
# Example: ./script1_diff_report.sh https://github.com/example/project.git main develop

[ "$#" -eq 3 ] || { echo "Usage: $0 <repo_url> <branch1> <branch2>" >&2; exit 1; }

REPO_URL="$1"
BRANCH1="$2"
BRANCH2="$3"

if ! command -v git >/dev/null 2>&1; then
  echo "Error: git is not installed." >&2
  exit 1
fi

WORKDIR="$(pwd -P)"
OUT_FILE="diff_report_${BRANCH1}_vs_${BRANCH2}.txt"
GEN_DATE="$(date '+%Y-%m-%d %H:%M:%S')"

echo "[*] Preparing temporary directory..."
TMPDIR="$(mktemp -d)" || { echo "Error: mktemp failed" >&2; exit 1; }
cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT
cd "$TMPDIR" || { echo "Error: cannot cd to tmp dir" >&2; exit 1; }

echo "[*] Initializing git and adding origin..."
git init -q || { echo "Error: git init failed" >&2; exit 1; }
git remote add origin "$REPO_URL" || { echo "Error: add remote failed" >&2; exit 1; }

echo "[*] Checking branches availability on remote..."
# Note: ls-remote returns 0 even if a head is missing; this is only connectivity check
git ls-remote --heads "$REPO_URL" >/dev/null 2>&1 || { echo "Error: remote not reachable" >&2; exit 1; }

echo "[*] Fetching branches (shallow fetch)..."
if ! git fetch -q --depth=1 origin "$BRANCH1" "$BRANCH2"; then
  echo "Error: fetch failed (check branches exist): $BRANCH1, $BRANCH2" >&2
  exit 1
fi

echo "[*] Comparing origin/$BRANCH1..origin/$BRANCH2..."
DIFF_RAW=""
# Do not let non-zero rc abort the script; capture safely
if ! DIFF_RAW="$(git diff --name-status --no-renames "origin/$BRANCH1..origin/$BRANCH2" 2>/dev/null)"; then
  DIFF_RAW="${DIFF_RAW:-}"
fi
echo "[*] Diff collected. Bytes: ${#DIFF_RAW}"

# Stats
TOTAL=0; ADD=0; DEL=0; MOD=0
while IFS=$'\t' read -r status file; do
  [ -z "${status:-}" ] && continue
  TOTAL=$((TOTAL+1))
  case "$status" in
    A) ADD=$((ADD+1)) ;;
    D) DEL=$((DEL+1)) ;;
    M) MOD=$((MOD+1)) ;;
    *) : ;;
  esac
done <<< "$DIFF_RAW"

echo "[*] Writing report: $OUT_FILE (to $WORKDIR)"
{
  echo "Branch differences report"
  echo
  echo "================================"
  echo "Repository:     $REPO_URL"
  echo "Branch 1:       $BRANCH1"
  echo "Branch 2:       $BRANCH2"
  echo "Generated at:   $GEN_DATE"
  echo "================================"
  echo
  echo "CHANGED FILES:"
  if [ -n "$DIFF_RAW" ]; then
    printf "%s\n" "$DIFF_RAW"
  else
    echo "(no differences)"
  fi
  echo
  echo "STATS:"
  echo "Total changed files: $TOTAL"
  echo "Added (A):    $ADD"
  echo "Deleted (D):  $DEL"
  echo "Modified (M): $MOD"
} > "$WORKDIR/$OUT_FILE" || { echo "Error: failed to write $WORKDIR/$OUT_FILE" >&2; exit 1; }

echo "[OK] Done. Report saved at: $WORKDIR/$OUT_FILE"
