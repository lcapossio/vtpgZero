# build_pl.tcl -- End-to-end PL build for vtpgZero on KV260.
#
# Author: Leonardo Capossio - bard0 design - hello@bard0.com
# Year:   2026
#
# Sourced from scripts/build_pl.py via `vivado -mode batch -source`.
#
# Reads the env vars (set by build_pl.py before invoking Vivado):
#   VTPGZ_REPO       - absolute path to the repository root
#   VTPGZ_KV260_OUT  - absolute path to the build output directory
#
# Steps:
#   1. Clean + create a fresh project (out-of-tree, in $VTPGZ_KV260_OUT/project)
#   2. Set the KV260 SOM board target
#   3. Add vtpgZero RTL + axis_to_ddr_writer as design sources
#   4. Source hw/kv260/vivado/build_bd.tcl to build the PS BD + wrapper
#   5. Set the BD wrapper as top
#   6. Synth, impl, write_bitstream
#   7. write_hw_platform -> vtpgzero_kv260.xsa

set REPO    $::env(VTPGZ_REPO)
set OUT     $::env(VTPGZ_KV260_OUT)
set PROJ    "$OUT/project"
set OUT_XSA "$OUT/vtpgzero_kv260.xsa"

file mkdir $OUT

if {[file exists "$PROJ/vtpgzero_kv260.xpr"]} {
    file delete -force $PROJ
}

create_project vtpgzero_kv260 $PROJ -part xck26-sfvc784-2LV-c -force
# Use the kv260_som board file. The board file is fine; we just have to
# apply DP-related properties in the right order (DPAUX first, then DP).
set_property board_part xilinx.com:kv260_som:part0:1.4 [current_project]

# RTL sources -- only the user IP. The top-level wrapper is the BD
# wrapper (kv260_ps_wrapper) itself, since vtpgZero + writer are
# instantiated as BD module cells (see build_bd.tcl).
add_files -norecurse [list \
    "$REPO/rtl/vtpgz_defs.vh" \
    "$REPO/rtl/vtpgz_axil_regs.v" \
    "$REPO/rtl/vtpgz_core.v" \
    "$REPO/rtl/vtpgz_axilite_top.v" \
    "$REPO/hw/kv260/rtl/axis_to_ddr_writer.v" \
]
# Mark the .vh as a Verilog header (not a normal source) so it's only
# treated as include text.
set_property file_type "Verilog Header" \
    [get_files "$REPO/rtl/vtpgz_defs.vh"]
set_property is_global_include true \
    [get_files "$REPO/rtl/vtpgz_defs.vh"]
# Include directory for vtpgz_defs.vh
set_property include_dirs "$REPO/rtl" [current_fileset]

# Build the BD + wrapper. After this runs, the wrapper module name is
# kv260_ps_wrapper which becomes the project top.
source "$REPO/hw/kv260/vivado/build_bd.tcl"

set_property top kv260_ps_wrapper [current_fileset]
update_compile_order -fileset sources_1

# Synth + Impl + Bitgen
launch_runs synth_1 -jobs 8
wait_on_run synth_1
if {[get_property STATUS [get_runs synth_1]] != "synth_design Complete!"} {
    puts "ERROR: synthesis failed"
    exit 1
}

launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
if {[get_property STATUS [get_runs impl_1]] != "write_bitstream Complete!"} {
    puts "ERROR: implementation failed"
    exit 1
}

# Export XSA with bitstream
write_hw_platform -fixed -include_bit -force -file $OUT_XSA
puts "=== XSA written: $OUT_XSA ==="

close_project
