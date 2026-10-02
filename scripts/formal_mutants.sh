#!/usr/bin/env bash
# Sanity check for the proof: put known bugs back into a copy of the RTL and
# make sure the proof FAILS for every one of them.  A proof that cannot fail
# proves nothing.
source "$(dirname "$0")/env.sh"
SRC="$(cd "$(dirname "$0")/.." && pwd)"
ok=1
mutate() {   # name, file, sed expression
    W="$HOME/.sa_mut_$1"; rm -rf "$W"; mkdir -p "$W"
    cp -r "$SRC/rtl" "$SRC/tb" "$SRC/formal" "$W/"
    sed -i "$3" "$W/$2"
    if cmp -s "$SRC/$2" "$W/$2"; then echo "  $1: mutation did not apply"; ok=0; return; fi
    (cd "$W/formal" && sby -f sa_core.sby prove >/dev/null 2>&1)
    st=$(cat "$W/formal/sa_core_prove/status" 2>/dev/null | cut -d' ' -f1)
    if [ "$st" = "FAIL" ] || [ "$st" = "UNKNOWN" ]; then
        printf "  %-34s caught (%s)\n" "$1" "$st"
    else
        printf "  %-34s NOT CAUGHT (%s)\n" "$1" "$st"; ok=0
    fi
}
echo "assertion cells in the proved model: $(grep -c 'cell \$assert' "$HOME/.sa_formal/formal/sa_core_prove/model/design_prep.il" 2>/dev/null)"
mutate stale_weights   rtl/sa_core.sv 's/assign a_ready = en \&\& bank_fresh\[rd_bank\];/assign a_ready = en \&\& bank_full[rd_bank];/'
mutate early_retire    rtl/sa_core.sv 's/if (br_consume \&\& br_last)/if (br_consume)/'
mutate no_bank_check   rtl/sa_core.sv 's/assign w_ready = !bank_full\[wr_bank\];/assign w_ready = 1'"'"'b1;/'
mutate fifo_3_deep     rtl/sa_core.sv "s/assign en = (fifo_cnt != 2'd2);/assign en = 1'b1;/"
mutate keep_fresh      rtl/sa_core.sv 's/bank_fresh\[rd_bank\] <= 1'"'"'b0;/bank_fresh[rd_bank] <= 1'"'"'b1;/'
[ $ok = 1 ] && echo "every mutant was caught" || { echo "SOME MUTANTS SURVIVED"; exit 1; }
