#!/usr/bin/env bash
# Regression: six array shapes x three random seeds, plus the overflow build.
# Runs in parallel.  Exit code 0 only if every run passes.
cd "$(dirname "$0")/.."
LOG="$HOME/.sa_sim/regress"; rm -rf "$LOG"; mkdir -p "$LOG"

jobs=()
for shape in "1 1" "2 2" "4 4" "3 5" "5 3" "8 8"; do
    for seed in 1 2 3; do jobs+=("$shape $seed"); done
done
jobs+=("4 4 1 -DOVF_TEST")

i=0
for j in "${jobs[@]}"; do
    ( bash scripts/sim_verilator.sh $j > "$LOG/$i.log" 2>&1; echo $? > "$LOG/$i.rc" ) &
    i=$((i + 1))
done
wait

fail=0; i=0
for j in "${jobs[@]}"; do
    if [ "$(cat "$LOG/$i.rc")" = 0 ] && grep -q '^PASS' "$LOG/$i.log"; then
        printf "  %-22s %s\n" "$j" "$(grep '^PASS' "$LOG/$i.log")"
    else
        printf "  %-22s FAIL\n" "$j"
        grep -E 'MISMATCH|Assert|FAIL|rror' "$LOG/$i.log" | head -5
        fail=1
    fi
    i=$((i + 1))
done
[ $fail = 0 ] && echo "REGRESSION PASSED (${#jobs[@]} runs)" || { echo "REGRESSION FAILED"; exit 1; }
