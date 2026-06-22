// SPDX-FileCopyrightText: 2026 Leonardo Capossio - bard0 design - hello@bard0.com
// SPDX-License-Identifier: Apache-2.0
//
// sim_top.v - simulation wrapper that wires vtpgz_axilite_top to frame_capture
// and exposes both AXI slave interfaces to a C++ harness so we can
// reproduce the host clear/arm/enable cycle entirely in Verilator.

`timescale 1ns/1ps

module sim_top #(
    // Pass-through parameters for vtpgz_axilite_top
    parameter OUTPUT_MODE   = 0,
    parameter YUV_SUBSAMPLE = 0,
    parameter RAW_BAYER     = 1,
    parameter RGB_ORDER     = 0,
    parameter BPC           = 8,
    // Derived TDATA_WIDTH (must match vtpgz_axilite_top's localparam)
    parameter TDATA_WIDTH =
        (OUTPUT_MODE == 0) ? (((3*BPC + 7) / 8) * 8) :
        (OUTPUT_MODE == 1) ? (((  BPC + 7) / 8) * 8) :
        (YUV_SUBSAMPLE == 0 ? (((3*BPC + 7) / 8) * 8)
                            : (((2*BPC + 7) / 8) * 8))
)(
    input  wire        aclk,
    input  wire        aresetn,

    // VTPGZ AXI4-Lite slave
    input  wire [7:0]  vtpgz_awaddr,
    input  wire        vtpgz_awvalid,
    output wire        vtpgz_awready,
    input  wire [31:0] vtpgz_wdata,
    input  wire [3:0]  vtpgz_wstrb,
    input  wire        vtpgz_wvalid,
    output wire        vtpgz_wready,
    output wire [1:0]  vtpgz_bresp,
    output wire        vtpgz_bvalid,
    input  wire        vtpgz_bready,
    input  wire [7:0]  vtpgz_araddr,
    input  wire        vtpgz_arvalid,
    output wire        vtpgz_arready,
    output wire [31:0] vtpgz_rdata,
    output wire [1:0]  vtpgz_rresp,
    output wire        vtpgz_rvalid,
    input  wire        vtpgz_rready,

    // Frame capture AXI4 slave (single-beat ops + AXI4 burst reads)
    input  wire [31:0] fc_awaddr,
    input  wire [7:0]  fc_awlen,
    input  wire [2:0]  fc_awsize,
    input  wire [1:0]  fc_awburst,
    input  wire [2:0]  fc_awprot,
    input  wire        fc_awvalid,
    output wire        fc_awready,
    input  wire [31:0] fc_wdata,
    input  wire [3:0]  fc_wstrb,
    input  wire        fc_wlast,
    input  wire        fc_wvalid,
    output wire        fc_wready,
    output wire [1:0]  fc_bresp,
    output wire        fc_bvalid,
    input  wire        fc_bready,
    input  wire [31:0] fc_araddr,
    input  wire [7:0]  fc_arlen,
    input  wire [2:0]  fc_arsize,
    input  wire [1:0]  fc_arburst,
    input  wire [2:0]  fc_arprot,
    input  wire        fc_arvalid,
    output wire        fc_arready,
    output wire [31:0] fc_rdata,
    output wire [1:0]  fc_rresp,
    output wire        fc_rvalid,
    output wire        fc_rlast,
    input  wire        fc_rready
);

    wire [TDATA_WIDTH-1:0] axis_tdata;
    wire        axis_tvalid;
    wire        axis_tready;
    wire        axis_tlast;
    wire        axis_tuser;

    vtpgz_axilite_top #(
        .C_S_AXI_ADDR_WIDTH(8),
        .C_S_AXI_DATA_WIDTH(32),
        .OUTPUT_MODE  (OUTPUT_MODE),
        .YUV_SUBSAMPLE(YUV_SUBSAMPLE),
        .RAW_BAYER    (RAW_BAYER),
        .RGB_ORDER    (RGB_ORDER),
        .BPC          (BPC)
    ) u_vtpgz (
        .aclk          (aclk),
        .aresetn       (aresetn),
        .s_axi_awaddr (vtpgz_awaddr),
        .s_axi_awprot (3'b000),
        .s_axi_awvalid(vtpgz_awvalid),
        .s_axi_awready(vtpgz_awready),
        .s_axi_wdata  (vtpgz_wdata),
        .s_axi_wstrb  (vtpgz_wstrb),
        .s_axi_wvalid (vtpgz_wvalid),
        .s_axi_wready (vtpgz_wready),
        .s_axi_bresp  (vtpgz_bresp),
        .s_axi_bvalid (vtpgz_bvalid),
        .s_axi_bready (vtpgz_bready),
        .s_axi_araddr (vtpgz_araddr),
        .s_axi_arprot (3'b000),
        .s_axi_arvalid(vtpgz_arvalid),
        .s_axi_arready(vtpgz_arready),
        .s_axi_rdata  (vtpgz_rdata),
        .s_axi_rresp  (vtpgz_rresp),
        .s_axi_rvalid (vtpgz_rvalid),
        .s_axi_rready (vtpgz_rready),
        .m_axis_tdata  (axis_tdata),
        .m_axis_tvalid (axis_tvalid),
        .m_axis_tready (axis_tready),
        .m_axis_tlast  (axis_tlast),
        .m_axis_tuser  (axis_tuser),
        .frame_sync_in (1'b0)
    );

    frame_capture #(
        .DEPTH_LOG2 (13),
        .ADDR_W     (32),
        .DATA_W     (32),
        .TDATA_WIDTH(TDATA_WIDTH)
    ) u_fcap (
        .aclk          (aclk),
        .aresetn       (aresetn),
        .s_axis_tdata  (axis_tdata),
        .s_axis_tvalid (axis_tvalid),
        .s_axis_tready (axis_tready),
        .s_axis_tlast  (axis_tlast),
        .s_axis_tuser  (axis_tuser),
        .s_axi_awaddr  (fc_awaddr),
        .s_axi_awlen   (fc_awlen),
        .s_axi_awsize  (fc_awsize),
        .s_axi_awburst (fc_awburst),
        .s_axi_awprot  (fc_awprot),
        .s_axi_awvalid (fc_awvalid),
        .s_axi_awready (fc_awready),
        .s_axi_wdata   (fc_wdata),
        .s_axi_wstrb   (fc_wstrb),
        .s_axi_wlast   (fc_wlast),
        .s_axi_wvalid  (fc_wvalid),
        .s_axi_wready  (fc_wready),
        .s_axi_bresp   (fc_bresp),
        .s_axi_bvalid  (fc_bvalid),
        .s_axi_bready  (fc_bready),
        .s_axi_araddr  (fc_araddr),
        .s_axi_arlen   (fc_arlen),
        .s_axi_arsize  (fc_arsize),
        .s_axi_arburst (fc_arburst),
        .s_axi_arprot  (fc_arprot),
        .s_axi_arvalid (fc_arvalid),
        .s_axi_arready (fc_arready),
        .s_axi_rdata   (fc_rdata),
        .s_axi_rresp   (fc_rresp),
        .s_axi_rvalid  (fc_rvalid),
        .s_axi_rlast   (fc_rlast),
        .s_axi_rready  (fc_rready),
        .capture_busy_o(),
        .capture_done_o()
    );

endmodule
