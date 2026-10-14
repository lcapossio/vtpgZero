# build_pl_8k.tcl -- PL build for the KV260 8K throughput bench.
#
# Author: Leonardo Capossio - bard0 design - hello@bard0.com
# Year:   2026
#
# Sourced from scripts/bench8k.py (build). Env:
#   VTPGZ_REPO       - repository root
#   VTPGZ_KV260_OUT  - output directory (bitstream + reports)
#   VTPGZ_8K_MHZ     - fast clock in MHz (read by build_bd_8k.tcl)
#
# Uses the timing-driven strategies: the vtpgZero colorbar recurrence sits
# right at 250 MHz on this -2LV part.

set REPO $::env(VTPGZ_REPO)
set OUT  $::env(VTPGZ_KV260_OUT)
set PROJ "$OUT/project"
file mkdir $OUT
if {[file exists $PROJ]} { file delete -force $PROJ }

create_project vtpgz_kv260_8k $PROJ -part xck26-sfvc784-2LV-c -force
set_property board_part xilinx.com:kv260_som:part0:1.4 [current_project]

add_files -norecurse [list \
    "$REPO/rtl/vtpgz_defs.vh" \
    "$REPO/rtl/vtpgz_axil_regs.v" \
    "$REPO/rtl/vtpgz_core.v" \
    "$REPO/rtl/vtpgz_axilite_top.v" \
    "$REPO/hw/kv260/rtl/axis_frame_monitor.v" \
]
set_property file_type "Verilog Header" [get_files "$REPO/rtl/vtpgz_defs.vh"]
set_property is_global_include true [get_files "$REPO/rtl/vtpgz_defs.vh"]
set_property include_dirs "$REPO/rtl" [current_fileset]

source "$REPO/hw/kv260/vivado/build_bd_8k.tcl"
set_property top kv260_8k_wrapper [current_fileset]
update_compile_order -fileset sources_1

set_property strategy Flow_PerfOptimized_high [get_runs synth_1]
set_property strategy Performance_ExplorePostRoutePhysOpt [get_runs impl_1]

launch_runs synth_1 -jobs 8
wait_on_run synth_1
if {[get_property STATUS [get_runs synth_1]] != "synth_design Complete!"} {
    puts "ERROR: synthesis failed"
    exit 1
}
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1

open_run impl_1
report_timing_summary -file $OUT/timing_summary.rpt
report_timing -nworst 10 -unique_pins -file $OUT/timing_worst.rpt
report_utilization -hierarchical -file $OUT/utilization_hier.rpt
report_utilization -file $OUT/utilization.rpt
set wns [get_property SLACK [get_timing_paths -max_paths 1 -setup]]
set whs [get_property SLACK [get_timing_paths -max_paths 1 -hold]]
puts "RESULT 8k bench WNS=$wns WHS=$whs"

if {[get_property STATUS [get_runs impl_1]] != "write_bitstream Complete!"} {
    puts "ERROR: implementation failed"
    exit 1
}
set bit [glob -nocomplain "$PROJ/vtpgz_kv260_8k.runs/impl_1/*.bit"]
file copy -force [lindex $bit 0] "$OUT/vtpgz_kv260_8k.bit"
puts "=== bitstream: $OUT/vtpgz_kv260_8k.bit ==="
close_project
