# build_bd_8k.tcl -- Block design for the KV260 8K throughput bench.
#
# Author: Leonardo Capossio - bard0 design - hello@bard0.com
# Year:   2026
#
# Sourced from build_pl_8k.tcl. vtpgZero at 8 pixels per clock streams into
# axis_frame_monitor (TREADY high, per-frame counters and CRC-32), both on a
# fast clock from an MMCM. There is no video output: the KV260 DisplayPort
# tops out well below 8K, and the DDR could not absorb 8 px x 4 B per cycle
# at this rate anyway. The PS only provides the 100 MHz reference and the
# AXI-Lite path the host uses (over JTAG) to drive both cores.
#
# The PS configuration is the DisplayPort demo's (build_bd.tcl) minus the
# DDR write port, so that demo's FSBL brings this design up as well.
#
# Env: VTPGZ_8K_MHZ -- fast clock in MHz (default 250).

set BD_NAME kv260_8k
set MHZ 250
if {[info exists ::env(VTPGZ_8K_MHZ)] && $::env(VTPGZ_8K_MHZ) ne ""} {
    set MHZ $::env(VTPGZ_8K_MHZ)
}
puts "INFO: 8K bench fast clock = $MHZ MHz"

create_bd_design $BD_NAME
current_bd_design $BD_NAME

# ======================================================================
# 1. Zynq UltraScale+ PS (as build_bd.tcl, without S_AXI_HPC0)
# ======================================================================
create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e zynq_ps
apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e \
    -config { apply_board_preset {1} } [get_bd_cells zynq_ps]
set_property -dict [list \
    CONFIG.PSU__DISPLAYPORT__PERIPHERAL__ENABLE {1}             \
    CONFIG.PSU__DISPLAYPORT__LANE0__ENABLE      {1}             \
    CONFIG.PSU__DISPLAYPORT__LANE0__IO          {GT Lane1}      \
    CONFIG.PSU__DISPLAYPORT__LANE1__ENABLE      {1}             \
    CONFIG.PSU__DISPLAYPORT__LANE1__IO          {GT Lane0}      \
    CONFIG.PSU__DP__LANE_SEL                    {Dual Lower}    \
    CONFIG.PSU__DP__REF_CLK_SEL                 {Ref Clk0}      \
    CONFIG.PSU__DP__REF_CLK_FREQ                {27}            \
    CONFIG.PSU__DPAUX__PERIPHERAL__ENABLE       {1}             \
    CONFIG.PSU__DPAUX__PERIPHERAL__IO           {MIO 27 .. 30}  \
    CONFIG.PSU__USE__VIDEO                      {1}             \
    CONFIG.PSU__CRF_APB__DP_VIDEO_REF_CTRL__SRCSEL {VPLL}       \
    CONFIG.PSU__UART1__PERIPHERAL__ENABLE       {1}             \
    CONFIG.PSU__UART1__PERIPHERAL__IO           {MIO 36 .. 37}  \
    CONFIG.PSU__USE__M_AXI_GP0                  {1}             \
    CONFIG.PSU__MAXIGP0__DATA_WIDTH             {32}            \
    CONFIG.PSU__USE__S_AXI_GP0                  {0}             \
    CONFIG.PSU__USE__M_AXI_GP1                  {0}             \
    CONFIG.PSU__FPGA_PL0_ENABLE                 {1}             \
    CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ  {100}           \
    CONFIG.PSU__PSS_REF_CLK__FREQMHZ            {33.333}        \
] [get_bd_cells zynq_ps]
connect_bd_net [get_bd_pins zynq_ps/pl_clk0] [get_bd_pins zynq_ps/dp_video_in_clk]

# ======================================================================
# 2. Fast clock: MMCM from the 100 MHz pl_clk0
# ======================================================================
create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz clk_8k
# The input frequency propagates from pl_clk0 (99.999001 MHz: the PS
# derives it from IOPLL), so it is not set here.
set_property -dict [list \
    CONFIG.CLKOUT1_REQUESTED_OUT_FREQ $MHZ      \
    CONFIG.USE_RESET                  {false}   \
    CONFIG.USE_LOCKED                 {true}    \
] [get_bd_cells clk_8k]
connect_bd_net [get_bd_pins zynq_ps/pl_clk0] [get_bd_pins clk_8k/clk_in1]

# ======================================================================
# 3. vtpgZero (8 px/clk, RGB 8 bpc) and the monitor
# ======================================================================
create_bd_cell -type module -reference vtpgz_axilite_top u_tpg
set_property -dict [list \
    CONFIG.OUTPUT_MODE         0 \
    CONFIG.RGB_ORDER           0 \
    CONFIG.BPC                 8 \
    CONFIG.PIXELS_PER_CLOCK    8 \
    CONFIG.C_AXIS_TDATA_WIDTH 192 \
    CONFIG.C_S_AXI_ADDR_WIDTH 12 \
] [get_bd_cells u_tpg]
# C_AXIS_TDATA_WIDTH is derived (PIXELS_PER_CLOCK x 24) in the RTL, but a
# module reference freezes derived parameters at their default-PPC value,
# so it is set explicitly.

create_bd_cell -type module -reference axis_frame_monitor u_mon
set_property -dict [list \
    CONFIG.DATA_W             192 \
    CONFIG.C_S_AXI_ADDR_WIDTH  12 \
] [get_bd_cells u_mon]

connect_bd_net [get_bd_pins clk_8k/clk_out1] [get_bd_pins u_tpg/aclk]
connect_bd_net [get_bd_pins clk_8k/clk_out1] [get_bd_pins u_mon/aclk]
connect_bd_intf_net [get_bd_intf_pins u_tpg/m_axis] [get_bd_intf_pins u_mon/s_axis]

# ======================================================================
# 4. AXI-Lite from HPM0_FPD (pl_clk0) to both slaves (fast clock).
#    Connection automation inserts the clock crossing and the resets.
# ======================================================================
apply_bd_automation -rule xilinx.com:bd_rule:axi4 \
    -config {Master "/zynq_ps/M_AXI_HPM0_FPD" intc_ip "New AXI Interconnect" Clk_xbar "/zynq_ps/pl_clk0" Clk_master "/zynq_ps/pl_clk0" Clk_slave "/clk_8k/clk_out1"} \
    [get_bd_intf_pins u_tpg/s_axi]
apply_bd_automation -rule xilinx.com:bd_rule:axi4 \
    -config {Master "/zynq_ps/M_AXI_HPM0_FPD" intc_ip "Auto" Clk_xbar "/zynq_ps/pl_clk0" Clk_master "/zynq_ps/pl_clk0" Clk_slave "/clk_8k/clk_out1"} \
    [get_bd_intf_pins u_mon/s_axi]

# Hold the fast domain in reset until the MMCM locks.
foreach rst [get_bd_cells -quiet -filter {VLNV =~ "*proc_sys_reset*"}] {
    set clk_net [get_bd_nets -quiet -of_objects [get_bd_pins $rst/slowest_sync_clk]]
    set fast_net [get_bd_nets -of_objects [get_bd_pins clk_8k/clk_out1]]
    if {$clk_net eq $fast_net} {
        # Connection automation usually wires this already.
        if {[llength [get_bd_nets -quiet -of_objects [get_bd_pins $rst/dcm_locked]]] == 0} {
            connect_bd_net [get_bd_pins clk_8k/locked] [get_bd_pins $rst/dcm_locked]
        }
        # ...but leaves ext_reset_in open, which ties it to 0: an
        # active-low reset held forever, and every AXI-Lite access hangs.
        if {[llength [get_bd_nets -quiet -of_objects [get_bd_pins $rst/ext_reset_in]]] == 0} {
            connect_bd_net [get_bd_pins zynq_ps/pl_resetn0] [get_bd_pins $rst/ext_reset_in]
        }
        puts "INFO: $rst gated by clk_8k/locked and pl_resetn0"
    }
}

# ======================================================================
# 5. Address map: vtpgZero at 0xA0000000, monitor at 0xA0010000
# ======================================================================
set ps_space [lindex [get_bd_addr_spaces zynq_ps/Data] 0]
assign_bd_address -offset 0xA0000000 -range 4K -target_address_space $ps_space \
    [lindex [get_bd_addr_segs u_tpg/s_axi/*] 0] -force
assign_bd_address -offset 0xA0010000 -range 4K -target_address_space $ps_space \
    [lindex [get_bd_addr_segs u_mon/s_axi/*] 0] -force

puts "=== BD ADDRESS MAP DUMP ==="
foreach seg [get_bd_addr_segs] {
    catch {
        puts [format "  %-60s @ %s  range=%s" $seg \
            [get_property OFFSET $seg] [get_property RANGE $seg]]
    }
}
puts "=== END BD ADDRESS MAP DUMP ==="

validate_bd_design
save_bd_design
# The bench host computes FRAME_RATE_DIV from the exact fast clock.
set hz [get_property CONFIG.FREQ_HZ [get_bd_pins clk_8k/clk_out1]]
puts "INFO: clk_8k/clk_out1 = $hz Hz"
set fh [open "$::env(VTPGZ_KV260_OUT)/clock_hz.txt" w]
puts $fh $hz
close $fh
generate_target all [get_files [current_bd_design].bd]
make_wrapper -files [get_files [current_bd_design].bd] -top -import -force
puts "BD wrapper module: ${BD_NAME}_wrapper"
