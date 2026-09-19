# SPDX-FileCopyrightText: 2026 Leonardo Capossio - bard0 design - hello@bard0.com
# SPDX-License-Identifier: Apache-2.0
#
# Arty A7-100T constraints for vtpgZero hardware demo
# Device: XC7A100TCSG324-1
# Reference: Digilent Arty A7 master XDC

# ─── 100 MHz oscillator (board) ────────────────────────────────────
set_property -dict {PACKAGE_PIN E3 IOSTANDARD LVCMOS33} [get_ports CLK100MHZ]
create_clock -period 10.000 -name CLK100MHZ [get_ports CLK100MHZ]
# The MMCM in clk_gen multiplies this to 130 MHz; Vivado infers the
# generated clock automatically from the MMCM CLKOUT0 pin.

# ─── BTN0 (active high reset) ──────────────────────────────────────
set_property -dict {PACKAGE_PIN D9 IOSTANDARD LVCMOS33} [get_ports btn0]

# ─── Green LEDs LD0..LD3 ───────────────────────────────────────────
set_property -dict {PACKAGE_PIN H17 IOSTANDARD LVCMOS33} [get_ports led0]
set_property -dict {PACKAGE_PIN K15 IOSTANDARD LVCMOS33} [get_ports led1]
set_property -dict {PACKAGE_PIN J13 IOSTANDARD LVCMOS33} [get_ports led2]
set_property -dict {PACKAGE_PIN N14 IOSTANDARD LVCMOS33} [get_ports led3]

set_false_path -to [get_ports {led0 led1 led2 led3}]
set_false_path -from [get_ports btn0]

# ─── BSCANE2 TCK / CDC ─────────────────────────────────────────────
# Vivado auto-creates a clock for the BSCANE2 TCK output. Declare it
# explicitly so the CDC false-path is unambiguous (same trick as the
# fpgacapZero reference XDC).
create_clock -name tck_bscan -period 100.0 \
    [get_pins -hierarchical -filter {NAME =~ *u_bscan/TCK}]

set_clock_groups -asynchronous \
    -group [get_clocks -include_generated_clocks CLK100MHZ] \
    -group [get_clocks tck_bscan]

# ─── Moving box position update is once per frame (>= 2048 cycles) ─────
# The bounce-check arithmetic feeds back into box_x/box_y. The update only
# fires at end_of_frame, so the combinational chain has the entire frame
# to settle. Tell timing analysis it's a 2-cycle multi-cycle path.
#
# Matched hierarchically, not by absolute path. The core sits at
# u_vtpgz/u_core here, not at the top level, and the old absolute path
# (u_tpg/...) matched nothing at all -- Vivado only emits a critical warning
# for that, the build still succeeds, and the paths quietly go unconstrained.
# check_box_multicycle in scripts/build.tcl now fails the build if these stop
# matching. The logic lives there because an XDC file only accepts a subset of
# Tcl: foreach and if are rejected with "not supported in the xdc constraint
# file", which silently drops whatever they contain.
#
# IS_SEQUENTIAL is required: Vivado names the LUTs feeding a register after
# that register (box_x_reg[11]_i_1), so the name glob alone would apply -from
# to combinational cells. box_x_reflect_reg and box_x_wrap_thr_reg do not
# contain the substring "box_x_reg" and are excluded by the name.
set_multicycle_path 2 -setup -from [get_cells -hierarchical -filter {NAME =~ *g_box.box_x_reg* && IS_SEQUENTIAL}]
set_multicycle_path 1 -hold  -from [get_cells -hierarchical -filter {NAME =~ *g_box.box_x_reg* && IS_SEQUENTIAL}]
set_multicycle_path 2 -setup -from [get_cells -hierarchical -filter {NAME =~ *g_box.box_y_reg* && IS_SEQUENTIAL}]
set_multicycle_path 1 -hold  -from [get_cells -hierarchical -filter {NAME =~ *g_box.box_y_reg* && IS_SEQUENTIAL}]
