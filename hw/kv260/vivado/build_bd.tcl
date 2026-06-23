# build_bd.tcl -- Build the KV260 PS block design from scratch and emit a
# wrapper named "kv260_ps_wrapper" that the top-level RTL hooks to.
#
# Author: Leonardo Capossio - bard0 design - hello@bard0.com
# Year:   2026
#
# Sourced from build_pl.tcl after create_project. Assumes Vivado is in
# project mode (`current_project` is valid) and the KV260 board is set.
#
# APPROACH: use `apply_bd_automation -rule xilinx.com:bd_rule:axi4` for ALL
# AXI connections. This lets Vivado automatically create the interconnect,
# proc_sys_reset, clock/reset wiring, and address assignment - exactly like
# "Run Connection Automation" in the GUI. Manual wiring of smartconnect,
# protocol converters, and proc_sys_reset was the source of multiple bugs.

set BD_NAME kv260_ps

create_bd_design $BD_NAME
current_bd_design $BD_NAME

# ======================================================================
# 1. Zynq UltraScale+ PS - board preset + DP/UART/HPC0 overrides
# ======================================================================
create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e zynq_ps

apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e \
    -config { apply_board_preset {1} } [get_bd_cells zynq_ps]

# DP lives in TWO namespaces: PSU__DISPLAYPORT__* (gate) + PSU__DP__*
# (protocol). See docs/PSU_DP_CONFIG.md.
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
    CONFIG.PSU__USE__S_AXI_GP0                  {1}             \
    CONFIG.PSU__SAXIGP0__DATA_WIDTH             {32}            \
    CONFIG.PSU__USE__M_AXI_GP1                  {0}             \
    CONFIG.PSU__FPGA_PL0_ENABLE                 {1}             \
    CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ  {100}           \
    CONFIG.PSU__PSS_REF_CLK__FREQMHZ            {33.333}        \
] [get_bd_cells zynq_ps]

# dp_video_in_clk must be tied (USE__VIDEO=1 exposes it). We don't use
# live video - tie to pl_clk0.
connect_bd_net [get_bd_pins zynq_ps/pl_clk0] [get_bd_pins zynq_ps/dp_video_in_clk]

# ======================================================================
# 2. User RTL cells (module-reference)
# ======================================================================
create_bd_cell -type module -reference vtpgz_axilite_top u_tpg
# IMAGE_HEX_FILE is passed as an absolute path so $readmemh resolves
# regardless of Vivado's working directory.
set IMG_HEX [file normalize "$::env(VTPGZ_REPO)/tests/images/mandrill_128x128.mem"]
set_property -dict [list \
    CONFIG.OUTPUT_MODE             0 \
    CONFIG.RGB_ORDER               0 \
    CONFIG.BPC                     8 \
    CONFIG.C_S_AXI_ADDR_WIDTH     12 \
    CONFIG.EN_IMAGE                1 \
    CONFIG.IMAGE_W               128 \
    CONFIG.IMAGE_H               128 \
    CONFIG.IMAGE_OUT_W          1280 \
    CONFIG.IMAGE_OUT_H           720 \
    CONFIG.IMAGE_HEX_FILE     $IMG_HEX \
] [get_bd_cells u_tpg]

create_bd_cell -type module -reference axis_to_ddr_writer u_writer
set_property -dict [list \
    CONFIG.FB_BASE          0x4C000000 \
    CONFIG.M_AXI_ID_WIDTH   6 \
    CONFIG.M_AXI_ADDR_WIDTH 49 \
    CONFIG.M_AXI_DATA_WIDTH 32 \
] [get_bd_cells u_writer]

# ======================================================================
# 3. AXI connections via Vivado connection automation
#    This creates interconnect + proc_sys_reset + clock/reset wiring.
# ======================================================================

# Pre-connect clocks so automation can discover the interfaces.
connect_bd_net [get_bd_pins zynq_ps/pl_clk0] [get_bd_pins u_tpg/aclk]
connect_bd_net [get_bd_pins zynq_ps/pl_clk0] [get_bd_pins u_writer/aclk]

# HPM0_FPD (PS master) -> u_tpg/s_axi (AXI-Lite slave control path)
apply_bd_automation -rule xilinx.com:bd_rule:axi4 \
    -config {Master "/zynq_ps/M_AXI_HPM0_FPD" intc_ip "New AXI Interconnect" Clk_xbar "Auto" Clk_master "Auto" Clk_slave "Auto"} \
    [get_bd_intf_pins u_tpg/s_axi]

# u_writer/m_axi (PL master) -> HPC0 (PS slave, DDR write path)
apply_bd_automation -rule xilinx.com:bd_rule:axi4 \
    -config {Master "/u_writer/m_axi" intc_ip "New AXI Interconnect" Clk_xbar "Auto" Clk_master "Auto" Clk_slave "Auto"} \
    [get_bd_intf_pins zynq_ps/S_AXI_HPC0_FPD]

# ======================================================================
# 4. AXIS: vtpgZero video out -> DDR writer input
# ======================================================================
connect_bd_intf_net \
    [get_bd_intf_pins u_tpg/m_axis] \
    [get_bd_intf_pins u_writer/s_axis]

# ======================================================================
# 5. Address map
# ======================================================================
# The AXI4 automation assigns addresses, then we pin the vtpgZero AXI-Lite
# window to the firmware's expected base address. Keep this explicit: a silent
# address drift here turns into an A53 hang or bad CORE_ID read at boot.
set tpg_slave_segs [get_bd_addr_segs -quiet u_tpg/s_axi/*]
set ps_addr_space  [get_bd_addr_spaces -quiet zynq_ps/Data]
if {([llength $tpg_slave_segs] > 0) && ([llength $ps_addr_space] > 0)} {
    assign_bd_address -offset 0xA0000000 -range 4K \
        -target_address_space [lindex $ps_addr_space 0] \
        [lindex $tpg_slave_segs 0] -force
} else {
    puts "WARNING: could not locate u_tpg/s_axi address segment or PS address space to pin at 0xA0000000"
}

# Dump the address map for the log.
puts "=== BD ADDRESS MAP DUMP ==="
foreach seg [get_bd_addr_segs] {
    catch {
        set off [get_property OFFSET $seg]
        set rng [get_property RANGE  $seg]
        puts [format "  %-60s @ %s  range=%s" $seg $off $rng]
    }
}
puts "=== END BD ADDRESS MAP DUMP ==="

# ======================================================================
# 6. Validate, save, generate wrapper
# ======================================================================
validate_bd_design
save_bd_design

generate_target all [get_files [current_bd_design].bd]
make_wrapper -files [get_files [current_bd_design].bd] -top -import -force

puts "BD wrapper module: ${BD_NAME}_wrapper"
