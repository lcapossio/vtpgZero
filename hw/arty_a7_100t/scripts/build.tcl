# SPDX-FileCopyrightText: 2026 Leonardo Capossio - bard0 design - hello@bard0.com
# SPDX-License-Identifier: Apache-2.0
#
# Vivado batch script for the vtpgZero Arty A7-100T demo.
# Invoked by build.py (which finds vivado on PATH).
#
#   vivado -mode batch -source hw/arty_a7_100t/scripts/build.tcl
#
# Outputs:
#   hw/arty_a7_100t/build/demo_top.bit
#   hw/arty_a7_100t/build/reports/{utilization,timing}.rpt

set project_name vtpgzero_arty
set part         xc7a100tcsg324-1
set top_module   demo_top

set script_dir [file normalize [file dirname [info script]]]
set hw_dir     [file normalize [file join $script_dir ..]]
set repo_root  [file normalize [file join $hw_dir ../..]]
set fcapz_dir  [file normalize [file join $repo_root fcapz]]
set build_dir  [file normalize [file join $hw_dir build]]
set rpt_dir    [file normalize [file join $build_dir reports]]
set proj_dir   [file normalize [file join $build_dir project]]

foreach required [list \
    $fcapz_dir/rtl/fcapz_async_fifo.v \
    $fcapz_dir/rtl/fcapz_ejtagaxi.v \
    $fcapz_dir/rtl/fcapz_ejtagaxi_xilinx7.v \
    $fcapz_dir/rtl/jtag_tap/jtag_tap_xilinx7.v \
    $fcapz_dir/rtl/dpram.v \
] {
    if {![file exists $required]} {
        error "Missing fcapz submodule file: $required. Run 'git submodule update --init --recursive'."
    }
}

file mkdir $build_dir
file mkdir $rpt_dir
file delete -force $proj_dir

create_project $project_name $proj_dir -part $part -force

# ─── RTL sources ──────────────────────────────────────────────────
add_files [list \
    $repo_root/rtl/vtpgz_axil_regs.v \
    $repo_root/rtl/vtpgz_core.v \
    $repo_root/rtl/vtpgz_axilite_top.v \
    $hw_dir/rtl/clk_gen.v \
    $hw_dir/rtl/axi4_to_axil.v \
    $hw_dir/rtl/bram_sdp.v \
    $hw_dir/rtl/frame_capture.v \
    $hw_dir/rtl/demo_top.v \
    $fcapz_dir/rtl/fcapz_async_fifo.v \
    $fcapz_dir/rtl/fcapz_ejtagaxi.v \
    $fcapz_dir/rtl/fcapz_ejtagaxi_xilinx7.v \
    $fcapz_dir/rtl/jtag_tap/jtag_tap_xilinx7.v \
    $fcapz_dir/rtl/dpram.v \
]

# Include path for `include "vtpgz_defs.vh"
set_property include_dirs [list $repo_root/rtl] [current_fileset]

add_files -fileset constrs_1 $hw_dir/constraints/arty_a7_100t.xdc

set_property top $top_module [current_fileset]

# ─── synthesis ────────────────────────────────────────────────────
# synth_1 and impl_1 run with Vivado defaults; the demo meets timing
# at 130 MHz without a non-default strategy.

puts "======================================================================"
puts "Synthesis"
puts "======================================================================"
launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
    error "Synthesis failed - see $proj_dir/${project_name}.runs/synth_1/"
}
open_run synth_1 -name synth_1
report_utilization    -file $rpt_dir/synth_utilization.rpt
report_timing_summary -file $rpt_dir/synth_timing.rpt
write_checkpoint -force $build_dir/post_synth.dcp

# ─── implementation ───────────────────────────────────────────────
puts "======================================================================"
puts "Implementation"
puts "======================================================================"
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    error "Implementation failed - see $proj_dir/${project_name}.runs/impl_1/"
}

open_run impl_1 -name impl_1
report_utilization    -file $rpt_dir/impl_utilization.rpt
report_timing_summary -file $rpt_dir/impl_timing.rpt
report_timing -nworst 10 -file $rpt_dir/impl_timing_worst10.rpt
write_checkpoint -force $build_dir/post_route.dcp

# ─── copy bitstream ───────────────────────────────────────────────
set bitsrc [glob -nocomplain $proj_dir/${project_name}.runs/impl_1/*.bit]
if {[llength $bitsrc] > 0} {
    file copy -force [lindex $bitsrc 0] $build_dir/demo_top.bit
    puts "BITSTREAM: $build_dir/demo_top.bit"
} else {
    error "No .bit produced - check impl_1 logs"
}

# ─── report WNS ───────────────────────────────────────────────────
set wns [get_property SLACK [get_timing_paths -max_paths 1 -setup]]
if {$wns ne "" && $wns ne "NONE"} {
    puts "WNS = $wns ns"
    if {$wns >= 0} { puts "TIMING MET at 130 MHz" } \
    else           { puts "TIMING VIOLATION" }
}

puts "DONE."
