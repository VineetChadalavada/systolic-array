#!/usr/bin/env bash
# Print the version of every tool the flow uses.
source "$(dirname "$0")/env.sh"
for t in yosys sby verilator iverilog yices-smt2 bitwuzla; do
    printf "%-12s " "$t"
    if command -v "$t" >/dev/null; then
        case "$t" in
            yosys)      yosys -V ;;
            verilator)  verilator --version ;;
            iverilog)   iverilog -V 2>&1 | head -1 ;;
            *)          echo "ok ($(command -v "$t"))" ;;
        esac
    else
        echo "MISSING"
    fi
done
