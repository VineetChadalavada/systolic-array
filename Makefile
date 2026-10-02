# Systolic array -- every check in one place.  Run from Linux / WSL with the
# OSS CAD Suite on the PATH (scripts/env.sh adds ~/oss-cad-suite/bin).
#
#   make lint       Verilator -Wall on three array shapes
#   make sim        self-checking testbench, 4x4, seed 1
#   make regress    6 shapes x 3 seeds + the overflow build, in parallel
#   make formal     SymbiYosys: unbounded proof, 30-cycle BMC, cover
#   make mutants    re-inserts known bugs and checks the proof catches each
#   make all        all of the above
#
# Windows (PowerShell), Vivado 2021.1:
#   scripts\sim_xsim.ps1                 same testbench on xsim (4-state)
#   vivado -mode batch -source syn\vivado_impl.tcl -tclargs 4 4 4.0 xc7a100tcsg324-1 dsp
#   scripts\openlane.ps1 -Period 10      SKY130 RTL-to-GDS (Docker)

ROWS ?= 4
COLS ?= 4
SEED ?= 1

.PHONY: all lint sim regress formal mutants clean

all: lint regress formal mutants

lint:
	bash scripts/lint.sh

sim:
	bash scripts/sim_verilator.sh $(ROWS) $(COLS) $(SEED)

regress:
	bash scripts/regress.sh

formal:
	bash scripts/formal.sh

mutants:
	bash scripts/formal_mutants.sh

clean:
	rm -rf build formal/results syn/openlane/runs
