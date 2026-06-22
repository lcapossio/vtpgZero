# SPDX-FileCopyrightText: 2026 Leonardo Capossio - bard0 design - hello@bard0.com
# SPDX-License-Identifier: Apache-2.0
#
# Standalone synth-only TCL for the vtpgZero IP. Drives one synth_design
# pass at a time with parameter overrides supplied via Vivado's tclargs and
# writes the utilization report to a per-config file.
#
# Invoked by run_matrix.py — do not call directly.

if {$argc < 2} {
    error "usage: vivado -mode batch -source synth_matrix.tcl -tclargs <tag> <generics-string>"
}
set tag      [lindex $argv 0]
set generics [lindex $argv 1]

set part xc7a100tcsg324-1
set script_dir [file normalize [file dirname [info script]]]
set repo_root  [file normalize $script_dir/..]
set out_dir    [file normalize $script_dir/results]
file mkdir $out_dir

read_verilog [list \
    $repo_root/rtl/vtpgz_axil_regs.v \
    $repo_root/rtl/vtpgz_core.v \
    $repo_root/rtl/vtpgz_axilite_top.v ]

# Generics: a Tcl list like "EN_CSC=1 EN_NOISE=0 EN_MOVING_BOX=0"
set generic_args {}
foreach kv $generics {
    lappend generic_args $kv
}
puts "synth_matrix: tag=$tag generics=$generic_args"

synth_design -top vtpgz_axilite_top -part $part \
    -include_dirs [list $repo_root/rtl] \
    -generic $generic_args \
    -mode out_of_context

report_utilization -file $out_dir/util_${tag}.rpt
puts "DONE: $out_dir/util_${tag}.rpt"
