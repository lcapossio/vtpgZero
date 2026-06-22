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
set_multicycle_path 2 -setup -from [get_cells u_tpg/g_box.box_x_reg*]
set_multicycle_path 1 -hold  -from [get_cells u_tpg/g_box.box_x_reg*]
set_multicycle_path 2 -setup -from [get_cells u_tpg/g_box.box_y_reg*]
set_multicycle_path 1 -hold  -from [get_cells u_tpg/g_box.box_y_reg*]
