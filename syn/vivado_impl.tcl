# =============================================================================
# vivado_impl.tcl -- out-of-context synthesis + place & route of sa_core
#
#   vivado -mode batch -source syn/vivado_impl.tcl \
#          -tclargs <ROWS> <COLS> <PERIOD_NS> [PART] [dsp|lut]
#
#   dsp : multiply-adds go into DSP48 slices (RTL attribute, see sa_pe.sv)
#   lut : Vivado's default for an 8x8 multiply: LUTs and carry chains
#
# Out-of-context means the core is implemented on its own, without I/O
# buffers, the way an IP block is signed off before integration.  The clock
# is the only timing constraint.
#
# Writes syn/reports/vivado_<ROWS>x<COLS>_<PART>_<dsp|lut>/ :
#   utilization.rpt  timing.rpt  critical_path.rpt  power.rpt  summary.txt
# =============================================================================
set rows   [lindex $argv 0]
set cols   [lindex $argv 1]
set period [lindex $argv 2]
set part   [expr {[llength $argv] > 3 ? [lindex $argv 3] : "xc7a100tcsg324-1"}]
set mult   [expr {[llength $argv] > 4 ? [lindex $argv 4] : "dsp"}]

set here [file dirname [file normalize [info script]]]
set root [file dirname $here]
set out  "$here/reports/vivado_${rows}x${cols}_${part}_${mult}"
file mkdir $out

set srcs [list $root/rtl/sa_pe.sv $root/rtl/sa_array.sv $root/rtl/sa_core.sv]
read_verilog -sv $srcs

set defs [expr {$mult eq "dsp" ? [list -verilog_define USE_DSP] : [list]}]
synth_design -top sa_core -part $part -mode out_of_context \
    -generic ROWS=$rows -generic COLS=$cols -flatten_hierarchy rebuilt {*}$defs

create_clock -name clk -period $period [get_ports clk]

opt_design
place_design
route_design

report_utilization    -file $out/utilization.rpt
report_timing_summary -file $out/timing.rpt -max_paths 5
report_timing         -file $out/critical_path.rpt -max_paths 1
report_power          -file $out/power.rpt

# one-line summary for the README tables
set wns  [get_property SLACK [get_timing_paths -max_paths 1 -setup]]
set fmax [expr {1000.0 / ($period - $wns)}]
set luts [llength [get_cells -hier -filter {PRIMITIVE_GROUP == LUT}]]
set ffs  [llength [get_cells -hier -filter {PRIMITIVE_GROUP == FLOP_LATCH}]]
set dsps [llength [get_cells -hier -filter {REF_NAME =~ DSP48*}]]
set pwr  [get_property TOTAL_POWER [current_design]]
set line [format "%s %dx%d %s  period %.2f ns  WNS %.3f ns  Fmax %.0f MHz  LUT %d  FF %d  DSP %d" \
              $part $rows $cols $mult $period $wns $fmax $luts $ffs $dsps]
set fh [open "$out/summary.txt" w]
puts $fh $line
close $fh
puts "SUMMARY: $line"
