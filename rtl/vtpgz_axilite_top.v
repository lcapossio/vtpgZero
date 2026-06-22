//-----------------------------------------------------------------------------
// vtpgz_axilite_top.v - vtpgZero AXI-Lite-controlled top wrapper
//
// Verilog-2001. Thin wrapper around vtpgz_core that adds the AXI4-Lite
// register file (vtpgz_axil_regs). Use this module if you want to drive
// the test pattern generator from a CPU/host over AXI-Lite. If you'd
// rather drive the cfg_* fields from your own RTL (or hold them at
// build-time constants), instantiate vtpgz_core directly.
//
// All build-time parameters of vtpgz_core are forwarded.
//
// SPDX-FileCopyrightText: 2026 Leonardo Capossio - bard0 design - hello@bard0.com
// SPDX-License-Identifier: Apache-2.0
//-----------------------------------------------------------------------------
`include "vtpgz_defs.vh"

module vtpgz_axilite_top #(
    parameter C_S_AXI_ADDR_WIDTH = 8,
    parameter C_S_AXI_DATA_WIDTH = 32,
    // ----- per-pattern build-time enables (forwarded to vtpgz_core) -----
    parameter EN_COLORBAR   = 1,
    parameter EN_HGRAD      = 1,
    parameter EN_VGRAD      = 1,
    parameter EN_CHECKER    = 1,
    parameter EN_SOLID      = 1,
    parameter EN_MOVING_BOX = 1,
    parameter EN_GRID       = 1,
    parameter EN_RAMP       = 1,
    parameter EN_NOISE      = 1,
    // ----- output mode (forwarded) -----
    parameter OUTPUT_MODE   = `VTPGZ_MODE_RGB,
    parameter YUV_SUBSAMPLE = `VTPGZ_YUV_444,
    parameter RAW_BAYER     = `VTPGZ_RAW_RGGB,
    parameter RGB_ORDER     = `VTPGZ_RGB_ORDER_XILINX,
    parameter BPC           = 8,
    // ----- derived AXI-Stream tdata width (same formula as in core) -----
    parameter C_AXIS_TDATA_WIDTH =
        (OUTPUT_MODE == `VTPGZ_MODE_RGB) ? (((3*BPC + 7) / 8) * 8) :
        (OUTPUT_MODE == `VTPGZ_MODE_RAW) ? (((  BPC + 7) / 8) * 8) :
        /* MODE_YUV */
            (YUV_SUBSAMPLE == `VTPGZ_YUV_444 ? (((3*BPC + 7) / 8) * 8)
                                              : (((2*BPC + 7) / 8) * 8))
)(
    input  wire                          aclk,
    input  wire                          aresetn,

    // AXI4-Lite slave (control)
    input  wire [C_S_AXI_ADDR_WIDTH-1:0] s_axil_awaddr,
    input  wire [2:0]                    s_axil_awprot,
    input  wire                          s_axil_awvalid,
    output wire                          s_axil_awready,
    input  wire [C_S_AXI_DATA_WIDTH-1:0] s_axil_wdata,
    input  wire [3:0]                    s_axil_wstrb,
    input  wire                          s_axil_wvalid,
    output wire                          s_axil_wready,
    /*verilator coverage_off*/ output wire [1:0] s_axil_bresp, /*verilator coverage_on*/
    output wire                          s_axil_bvalid,
    input  wire                          s_axil_bready,
    input  wire [C_S_AXI_ADDR_WIDTH-1:0] s_axil_araddr,
    input  wire [2:0]                    s_axil_arprot,
    input  wire                          s_axil_arvalid,
    output wire                          s_axil_arready,
    output wire [C_S_AXI_DATA_WIDTH-1:0] s_axil_rdata,
    /*verilator coverage_off*/ output wire [1:0] s_axil_rresp, /*verilator coverage_on*/
    output wire                          s_axil_rvalid,
    input  wire                          s_axil_rready,

    // AXI4-Stream master (video out)
    /*verilator coverage_off*/ output wire [C_AXIS_TDATA_WIDTH-1:0] m_axis_tdata, /*verilator coverage_on*/
    output wire                          m_axis_tvalid,
    input  wire                          m_axis_tready,
    output wire                          m_axis_tlast,
    output wire                          m_axis_tuser,

    // External frame sync
    input  wire                          frame_sync_in
);

    // ---------------- cfg / status interconnect ----------------
    wire        cfg_enable;
    wire        cfg_sw_fsync;
    wire        cfg_ext_sync;
    wire [15:0] cfg_img_width;
    wire [15:0] cfg_img_height;
    wire [3:0]  cfg_pattern;
    wire [23:0] cfg_solid_color;
    wire [23:0] cfg_box_color;
    wire [15:0] cfg_box_width;
    wire [15:0] cfg_box_height;
    wire [15:0] cfg_box_dx;
    wire [15:0] cfg_box_dy;
    wire [15:0] cfg_grid_spacing;
    wire [23:0] cfg_grid_color;
    wire [15:0] cfg_checker_size;
    wire [31:0] cfg_frame_rate_div;
    wire [15:0] cfg_bar_width;
    wire [15:0] cfg_hg_step;
    wire [15:0] cfg_vg_step;
    wire [23:0] cfg_box_border_color;
    wire [7:0]  cfg_box_border_width;

    wire        sts_busy;
    wire [7:0]  sts_frame_count;

    // ---------------- AXI-Lite register file ----------------
    vtpgz_axil_regs #(
        .OUTPUT_MODE  (OUTPUT_MODE),
        .YUV_SUBSAMPLE(YUV_SUBSAMPLE),
        .RAW_BAYER    (RAW_BAYER),
        .RGB_ORDER    (RGB_ORDER),
        .BPC          (BPC),
        .TDATA_WIDTH  (C_AXIS_TDATA_WIDTH)
    ) u_regs (
        .aclk             (aclk),
        .aresetn          (aresetn),
        .s_axil_awaddr    (s_axil_awaddr),
        .s_axil_awprot    (s_axil_awprot),
        .s_axil_awvalid   (s_axil_awvalid),
        .s_axil_awready   (s_axil_awready),
        .s_axil_wdata     (s_axil_wdata),
        .s_axil_wstrb     (s_axil_wstrb),
        .s_axil_wvalid    (s_axil_wvalid),
        .s_axil_wready    (s_axil_wready),
        .s_axil_bresp     (s_axil_bresp),
        .s_axil_bvalid    (s_axil_bvalid),
        .s_axil_bready    (s_axil_bready),
        .s_axil_araddr    (s_axil_araddr),
        .s_axil_arprot    (s_axil_arprot),
        .s_axil_arvalid   (s_axil_arvalid),
        .s_axil_arready   (s_axil_arready),
        .s_axil_rdata     (s_axil_rdata),
        .s_axil_rresp     (s_axil_rresp),
        .s_axil_rvalid    (s_axil_rvalid),
        .s_axil_rready    (s_axil_rready),
        .sts_busy         (sts_busy),
        .sts_frame_count  (sts_frame_count),
        .cfg_enable       (cfg_enable),
        .cfg_sw_fsync     (cfg_sw_fsync),
        .cfg_ext_sync     (cfg_ext_sync),
        .cfg_img_width    (cfg_img_width),
        .cfg_img_height   (cfg_img_height),
        .cfg_pattern      (cfg_pattern),
        .cfg_solid_color  (cfg_solid_color),
        .cfg_box_color    (cfg_box_color),
        .cfg_box_width    (cfg_box_width),
        .cfg_box_height   (cfg_box_height),
        .cfg_box_dx       (cfg_box_dx),
        .cfg_box_dy       (cfg_box_dy),
        .cfg_grid_spacing (cfg_grid_spacing),
        .cfg_grid_color   (cfg_grid_color),
        .cfg_checker_size (cfg_checker_size),
        .cfg_frame_rate_div(cfg_frame_rate_div),
        .cfg_bar_width    (cfg_bar_width),
        .cfg_hg_step      (cfg_hg_step),
        .cfg_vg_step      (cfg_vg_step),
        .cfg_box_border_color(cfg_box_border_color),
        .cfg_box_border_width(cfg_box_border_width)
    );

    // ---------------- pattern generator core ----------------
    vtpgz_core #(
        .EN_COLORBAR  (EN_COLORBAR),
        .EN_HGRAD     (EN_HGRAD),
        .EN_VGRAD     (EN_VGRAD),
        .EN_CHECKER   (EN_CHECKER),
        .EN_SOLID     (EN_SOLID),
        .EN_MOVING_BOX(EN_MOVING_BOX),
        .EN_GRID      (EN_GRID),
        .EN_RAMP      (EN_RAMP),
        .EN_NOISE     (EN_NOISE),
        .OUTPUT_MODE  (OUTPUT_MODE),
        .YUV_SUBSAMPLE(YUV_SUBSAMPLE),
        .RAW_BAYER    (RAW_BAYER),
        .RGB_ORDER    (RGB_ORDER),
        .BPC          (BPC),
        .C_AXIS_TDATA_WIDTH(C_AXIS_TDATA_WIDTH)
    ) u_core (
        .aclk             (aclk),
        .aresetn          (aresetn),
        .cfg_enable       (cfg_enable),
        .cfg_sw_fsync     (cfg_sw_fsync),
        .cfg_ext_sync     (cfg_ext_sync),
        .cfg_img_width    (cfg_img_width),
        .cfg_img_height   (cfg_img_height),
        .cfg_pattern      (cfg_pattern),
        .cfg_solid_color  (cfg_solid_color),
        .cfg_box_color    (cfg_box_color),
        .cfg_box_width    (cfg_box_width),
        .cfg_box_height   (cfg_box_height),
        .cfg_box_dx       (cfg_box_dx),
        .cfg_box_dy       (cfg_box_dy),
        .cfg_grid_spacing (cfg_grid_spacing),
        .cfg_grid_color   (cfg_grid_color),
        .cfg_checker_size (cfg_checker_size),
        .cfg_frame_rate_div(cfg_frame_rate_div),
        .cfg_bar_width    (cfg_bar_width),
        .cfg_hg_step      (cfg_hg_step),
        .cfg_vg_step      (cfg_vg_step),
        .cfg_box_border_color(cfg_box_border_color),
        .cfg_box_border_width(cfg_box_border_width),
        .sts_busy         (sts_busy),
        .sts_frame_count  (sts_frame_count),
        .m_axis_tdata     (m_axis_tdata),
        .m_axis_tvalid    (m_axis_tvalid),
        .m_axis_tready    (m_axis_tready),
        .m_axis_tlast     (m_axis_tlast),
        .m_axis_tuser     (m_axis_tuser),
        .frame_sync_in    (frame_sync_in)
    );

endmodule
