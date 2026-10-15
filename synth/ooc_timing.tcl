# SPDX-FileCopyrightText: 2026 Leonardo Capossio - bard0 design - hello@bard0.com
# SPDX-License-Identifier: Apache-2.0
#
# Out-of-context place and route of vtpgz_axilite_top at a target clock, to
# find the core's fmax on a given part without a board design around it.
#
#   vivado -mode batch -nojournal -source synth/ooc_timing.tcl \
#       -tclargs <part> <period_ns> <tag> [NAME:VALUE ...]
#
# e.g. 8 pixels per clock at 250 MHz on the KV260's part:
#   ... -tclargs xck26-sfvc784-2LV-c 4.0 kv260_ppc8 PIXELS_PER_CLOCK:8
#
# Generics are NAME:VALUE because vivado.bat on Windows splits arguments at
# '='. Reports go to synth/results/ooc_<tag>/; the last line printed is
#   RESULT <tag> part=<part> period=<ns> WNS=<ns>
# I/O delays are 0: in a real design the ports are registered at the
# boundary, so they stay off the critical path.

if {$argc < 3} {
    error "usage: -tclargs <part> <period_ns> <tag> \[NAME:VALUE ...\]"
}
set part     [lindex $argv 0]
set period   [lindex $argv 1]
set tag      [lindex $argv 2]
set generics [lrange $argv 3 end]
set here [file dirname [file normalize [info script]]]
set rtl  [file normalize $here/../rtl]
set out  $here/results/ooc_$tag
file mkdir $out

read_verilog [list $rtl/vtpgz_axil_regs.v $rtl/vtpgz_core.v $rtl/vtpgz_axilite_top.v]
set gargs {}
foreach g $generics { lappend gargs -generic [string map {: =} $g] }
synth_design -top vtpgz_axilite_top -part $part -include_dirs [list $rtl] \
    -mode out_of_context {*}$gargs
create_clock -period $period -name aclk [get_ports aclk]
set_input_delay  0 -clock aclk [get_ports -filter {DIRECTION == IN && NAME != aclk}]
set_output_delay 0 -clock aclk [get_ports -filter {DIRECTION == OUT}]
opt_design
place_design
phys_opt_design
route_design
report_timing_summary -file $out/timing.rpt
report_timing -nworst 20 -unique_pins -file $out/worst.rpt
report_utilization -file $out/util.rpt
set wns [get_property SLACK [get_timing_paths -max_paths 1 -setup]]
puts "RESULT $tag part=$part period=$period WNS=$wns"
