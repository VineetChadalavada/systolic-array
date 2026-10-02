#!/usr/bin/env bash
# Lint the RTL with Verilator's full warning set (-Wall), for the default
# 4x4 and an asymmetric 3x5 configuration.
set -e
source "$(dirname "$0")/env.sh"
cd "$(dirname "$0")/.."
for cfg in "4 4" "3 5" "8 8"; do
    set -- $cfg
    echo "== lint ROWS=$1 COLS=$2"
    verilator --lint-only -Wall -Irtl --top-module sa_core \
        -GROWS=$1 -GCOLS=$2 rtl/sa_pe.sv rtl/sa_array.sv rtl/sa_core.sv
done
echo "lint clean"
