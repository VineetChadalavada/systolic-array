#!/usr/bin/env bash
# Run the SymbiYosys proof and cover tasks.  Work is done in a copy under
# the WSL home directory: SBY is much faster on a native Linux filesystem.
set -e
source "$(dirname "$0")/env.sh"
SRC="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$HOME/.sa_formal"
rm -rf "$WORK"; mkdir -p "$WORK"
cp -r "$SRC/rtl" "$SRC/tb" "$SRC/formal" "$WORK/"
cd "$WORK/formal"
sby -f sa_core.sby "$@" 2>&1 | grep -E "summary|DONE|Assert|PASS|FAIL|failed|Reached|cover|induction|BMC|Status" || true
# keep the result summaries next to the sources
mkdir -p "$SRC/formal/results"
for d in sa_core_*; do
    [ -f "$d/status" ] && cp "$d/status" "$SRC/formal/results/$d.status"
    [ -f "$d/logfile.txt" ] && cp "$d/logfile.txt" "$SRC/formal/results/$d.log"
done
grep -h . "$SRC"/formal/results/*.status
