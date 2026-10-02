#!/usr/bin/env bash
# Build and run the self-checking testbench with Verilator.
#   scripts/sim_verilator.sh [ROWS] [COLS] [SEED] [extra flags, e.g. -DOVF_TEST]
# Builds happen on the native Linux filesystem (much faster than /mnt/*).
set -e
source "$(dirname "$0")/env.sh"
SRC="$(cd "$(dirname "$0")/.." && pwd)"
ROWS=${1:-4}; COLS=${2:-4}; SEED=${3:-1}
shift $(( $# < 3 ? $# : 3 ))
TAG="${ROWS}x${COLS}_s${SEED}$(echo "$@" | tr -dc 'A-Za-z0-9_')"
WORK="$HOME/.sa_sim/$TAG"
mkdir -p "$WORK"
cp "$SRC"/rtl/*.sv "$SRC"/tb/*.sv "$WORK/"
cd "$WORK"
verilator --binary --timing --assert -Wno-fatal -Wno-lint -Wno-style \
    -O2 --top-module tb_sa_core -Mdir obj \
    -DROWS=$ROWS -DCOLS=$COLS -DSEED=$SEED "$@" \
    sa_pe.sv sa_array.sv sa_core.sv sa_props.sv tb_sa_core.sv > build.log 2>&1 \
    || { cat build.log; exit 1; }
./obj/Vtb_sa_core
