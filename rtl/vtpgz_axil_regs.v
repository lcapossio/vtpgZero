//-----------------------------------------------------------------------------
// vtpgz_axil_regs.v - AXI4-Lite slave + register file for vtpgZero
//
// 32-bit data, 8-bit byte address space (64 registers max).
// Verilog-2001 only.
//
// SPDX-FileCopyrightText: 2026 Leonardo Capossio - bard0 design - hello@bard0.com
// SPDX-License-Identifier: Apache-2.0
//-----------------------------------------------------------------------------
`include "vtpgz_defs.vh"

module vtpgz_axil_regs #(
    // Build-time configuration mirrored on the COLOR_FORMAT read-back.
    parameter OUTPUT_MODE   = `VTPGZ_MODE_RGB,
    parameter YUV_SUBSAMPLE = `VTPGZ_YUV_444,
    parameter RAW_BAYER     = `VTPGZ_RAW_RGGB,
    parameter RGB_ORDER     = `VTPGZ_RGB_ORDER_XILINX,
    parameter BPC           = 8,
    parameter TDATA_WIDTH   = 24
)(
    input  wire        aclk,
    input  wire        aresetn,

    // AXI4-Lite slave
    input  wire [7:0]  s_axi_awaddr,
    input  wire [2:0]  s_axi_awprot,
    input  wire        s_axi_awvalid,
    output reg         s_axi_awready,

    input  wire [31:0] s_axi_wdata,
    input  wire [3:0]  s_axi_wstrb,
    input  wire        s_axi_wvalid,
    output reg         s_axi_wready,

    /*verilator coverage_off*/ output reg  [1:0]  s_axi_bresp, /*verilator coverage_on*/
    output reg         s_axi_bvalid,
    input  wire        s_axi_bready,

    input  wire [7:0]  s_axi_araddr,
    input  wire [2:0]  s_axi_arprot,
    input  wire        s_axi_arvalid,
    output reg         s_axi_arready,

    output reg  [31:0] s_axi_rdata,
    /*verilator coverage_off*/ output reg  [1:0]  s_axi_rresp, /*verilator coverage_on*/
    output reg         s_axi_rvalid,
    input  wire        s_axi_rready,

    // Status inputs from datapath
    input  wire        sts_busy,
    input  wire [7:0]  sts_frame_count,

    // Configuration outputs to datapath
    output wire        cfg_enable,
    output wire        cfg_sw_fsync,
    output wire        cfg_ext_sync,
    output wire [15:0] cfg_img_width,
    output wire [15:0] cfg_img_height,
    output wire [3:0]  cfg_pattern,
    output wire [23:0] cfg_solid_color,
    output wire [23:0] cfg_box_color,
    output wire [15:0] cfg_box_width,
    output wire [15:0] cfg_box_height,
    output wire [15:0] cfg_box_dx,
    output wire [15:0] cfg_box_dy,
    output wire [15:0] cfg_grid_spacing,
    output wire [23:0] cfg_grid_color,
    output wire [15:0] cfg_checker_size,
    output wire [31:0] cfg_frame_rate_div,
    output wire [15:0] cfg_bar_width,
    output wire [15:0] cfg_hg_step,
    output wire [15:0] cfg_vg_step,
    output wire [23:0] cfg_box_border_color,
    output wire [7:0]  cfg_box_border_width
);

    // ---------------- registers ----------------
    reg [31:0] reg_control;
    reg [31:0] reg_img_width;
    reg [31:0] reg_img_height;
    reg [31:0] reg_pattern_sel;
    reg [31:0] reg_solid_color;
    reg [31:0] reg_box_color;
    reg [31:0] reg_box_size;
    reg [31:0] reg_box_speed;
    reg [31:0] reg_grid_spacing;
    reg [31:0] reg_grid_color;
    reg [31:0] reg_checker_size;
    reg [31:0] reg_frame_rate;
    reg [31:0] reg_bar_width;
    reg [31:0] reg_hg_step;
    reg [31:0] reg_vg_step;
    reg [31:0] reg_box_border;

    // ---------------- write FSM ----------------
    reg [7:0]  awaddr_q;
    reg        aw_captured;
    reg        w_captured;
    reg [31:0] wdata_q;
    reg [3:0]  wstrb_q;

    wire do_write = aw_captured && w_captured && !s_axi_bvalid;

    function [31:0] apply_wstrb;
        input [31:0] old_value;
        input [31:0] new_value;
        input [3:0]  strb;
        begin
            apply_wstrb[7:0]   = strb[0] ? new_value[7:0]   : old_value[7:0];
            apply_wstrb[15:8]  = strb[1] ? new_value[15:8]  : old_value[15:8];
            apply_wstrb[23:16] = strb[2] ? new_value[23:16] : old_value[23:16];
            apply_wstrb[31:24] = strb[3] ? new_value[31:24] : old_value[31:24];
        end
    endfunction

    always @(posedge aclk) begin
        if (!aresetn) begin
            s_axi_awready <= 1'b0;
            s_axi_wready  <= 1'b0;
            s_axi_bvalid  <= 1'b0;
            s_axi_bresp   <= 2'b00;
            aw_captured    <= 1'b0;
            w_captured     <= 1'b0;
            awaddr_q       <= 8'h00;
            wdata_q        <= 32'h0;
            wstrb_q        <= 4'h0;

            reg_control      <= 32'h0;
            reg_img_width    <= 32'd1920;
            reg_img_height   <= 32'd1080;
            reg_pattern_sel  <= 32'h0;
            reg_solid_color  <= 32'h00FFFFFF;
            reg_box_color    <= 32'h00FF0000;
            reg_box_size     <= {16'd64, 16'd64};
            reg_box_speed    <= {16'd1,  16'd1};
            reg_grid_spacing <= 32'd32;
            reg_grid_color   <= 32'h00FFFFFF;
            reg_checker_size <= 32'd32;
            reg_frame_rate   <= 32'd100000;
            // Defaults for 1920x1080: bar = 1920/8 = 240
            // hg_step = ((4095<<8)/1919) ~= 546 (Q8.8 fractional step per pixel)
            // vg_step = ((4095<<8)/1079) ~= 970 (per line)
            reg_bar_width    <= 32'd240;
            reg_hg_step      <= 32'd546;
            reg_vg_step      <= 32'd970;
            reg_box_border   <= 32'h0;  // border_width=0, no border
        end else begin
            // address handshake
            if (!aw_captured && s_axi_awvalid) begin
                aw_captured    <= 1'b1;
                awaddr_q       <= s_axi_awaddr;
                s_axi_awready <= 1'b1;
            end else begin
                s_axi_awready <= 1'b0;
            end

            // data handshake
            if (!w_captured && s_axi_wvalid) begin
                w_captured    <= 1'b1;
                wdata_q       <= s_axi_wdata;
                wstrb_q       <= s_axi_wstrb;
                s_axi_wready <= 1'b1;
            end else begin
                s_axi_wready <= 1'b0;
            end

            // commit
            if (do_write) begin
                case (awaddr_q)
                    `VTPGZ_REG_CONTROL      : reg_control      <= apply_wstrb(reg_control,      wdata_q, wstrb_q);
                    `VTPGZ_REG_IMG_WIDTH    : reg_img_width    <= apply_wstrb(reg_img_width,    wdata_q, wstrb_q);
                    `VTPGZ_REG_IMG_HEIGHT   : reg_img_height   <= apply_wstrb(reg_img_height,   wdata_q, wstrb_q);
                    `VTPGZ_REG_PATTERN_SEL  : reg_pattern_sel  <= apply_wstrb(reg_pattern_sel,  wdata_q, wstrb_q);
                    // COLOR_FORMAT is RO (build-time), writes are dropped
                    `VTPGZ_REG_SOLID_COLOR  : reg_solid_color  <= apply_wstrb(reg_solid_color,  wdata_q, wstrb_q);
                    `VTPGZ_REG_BOX_COLOR    : reg_box_color    <= apply_wstrb(reg_box_color,    wdata_q, wstrb_q);
                    `VTPGZ_REG_BOX_SIZE     : reg_box_size     <= apply_wstrb(reg_box_size,     wdata_q, wstrb_q);
                    `VTPGZ_REG_BOX_SPEED    : reg_box_speed    <= apply_wstrb(reg_box_speed,    wdata_q, wstrb_q);
                    `VTPGZ_REG_GRID_SPACING : reg_grid_spacing <= apply_wstrb(reg_grid_spacing, wdata_q, wstrb_q);
                    `VTPGZ_REG_GRID_COLOR   : reg_grid_color   <= apply_wstrb(reg_grid_color,   wdata_q, wstrb_q);
                    `VTPGZ_REG_CHECKER_SIZE : reg_checker_size <= apply_wstrb(reg_checker_size, wdata_q, wstrb_q);
                    `VTPGZ_REG_FRAME_RATE   : reg_frame_rate   <= apply_wstrb(reg_frame_rate,   wdata_q, wstrb_q);
                    `VTPGZ_REG_BAR_WIDTH    : reg_bar_width    <= apply_wstrb(reg_bar_width,    wdata_q, wstrb_q);
                    `VTPGZ_REG_HG_STEP      : reg_hg_step      <= apply_wstrb(reg_hg_step,      wdata_q, wstrb_q);
                    `VTPGZ_REG_VG_STEP      : reg_vg_step      <= apply_wstrb(reg_vg_step,      wdata_q, wstrb_q);
                    `VTPGZ_REG_BOX_BORDER   : reg_box_border   <= apply_wstrb(reg_box_border,   wdata_q, wstrb_q);
                    default               : ;
                endcase
                s_axi_bvalid <= 1'b1;
                s_axi_bresp  <= 2'b00;
                aw_captured   <= 1'b0;
                w_captured    <= 1'b0;
            end else if (s_axi_bvalid && s_axi_bready) begin
                s_axi_bvalid <= 1'b0;
            end
        end
    end

    // ---------------- read FSM ----------------
    always @(posedge aclk) begin
        if (!aresetn) begin
            s_axi_arready <= 1'b0;
            s_axi_rvalid  <= 1'b0;
            s_axi_rresp   <= 2'b00;
            s_axi_rdata   <= 32'h0;
        end else begin
            if (!s_axi_arready && s_axi_arvalid && !s_axi_rvalid) begin
                s_axi_arready <= 1'b1;
                s_axi_rvalid  <= 1'b1;
                s_axi_rresp   <= 2'b00;
                case (s_axi_araddr)
                    `VTPGZ_REG_CORE_ID      : s_axi_rdata <= `VTPGZ_CORE_ID_MAGIC;
                    `VTPGZ_REG_VERSION      : s_axi_rdata <= {`VTPGZ_VERSION_MAJOR, `VTPGZ_VERSION_MINOR, `VTPGZ_VERSION_PATCH};
                    `VTPGZ_REG_CONTROL      : s_axi_rdata <= reg_control;
                    `VTPGZ_REG_STATUS       : s_axi_rdata <= {16'h0, sts_frame_count, 7'h0, sts_busy};
                    `VTPGZ_REG_IMG_WIDTH    : s_axi_rdata <= reg_img_width;
                    `VTPGZ_REG_IMG_HEIGHT   : s_axi_rdata <= reg_img_height;
                    `VTPGZ_REG_PATTERN_SEL  : s_axi_rdata <= reg_pattern_sel;
                    `VTPGZ_REG_COLOR_FORMAT : s_axi_rdata <= {
                        TDATA_WIDTH[15:0],
                        BPC[7:0],
                        1'b0,           // [7]    reserved
                        RGB_ORDER[0],   // [6]
                        RAW_BAYER[2:0], // [5:3]  PLAIN/RGGB/BGGR/GRBG/GBRG
                        YUV_SUBSAMPLE[0], // [2]
                        OUTPUT_MODE[1:0]  // [1:0]
                    };
                    `VTPGZ_REG_SOLID_COLOR  : s_axi_rdata <= reg_solid_color;
                    `VTPGZ_REG_BOX_COLOR    : s_axi_rdata <= reg_box_color;
                    `VTPGZ_REG_BOX_SIZE     : s_axi_rdata <= reg_box_size;
                    `VTPGZ_REG_BOX_SPEED    : s_axi_rdata <= reg_box_speed;
                    `VTPGZ_REG_GRID_SPACING : s_axi_rdata <= reg_grid_spacing;
                    `VTPGZ_REG_GRID_COLOR   : s_axi_rdata <= reg_grid_color;
                    `VTPGZ_REG_CHECKER_SIZE : s_axi_rdata <= reg_checker_size;
                    `VTPGZ_REG_FRAME_RATE   : s_axi_rdata <= reg_frame_rate;
                    `VTPGZ_REG_BAR_WIDTH    : s_axi_rdata <= reg_bar_width;
                    `VTPGZ_REG_HG_STEP      : s_axi_rdata <= reg_hg_step;
                    `VTPGZ_REG_VG_STEP      : s_axi_rdata <= reg_vg_step;
                    `VTPGZ_REG_BOX_BORDER   : s_axi_rdata <= reg_box_border;
                    default               : s_axi_rdata <= 32'h0;
                endcase
            end else begin
                s_axi_arready <= 1'b0;
                if (s_axi_rvalid && s_axi_rready)
                    s_axi_rvalid <= 1'b0;
            end
        end
    end

    // ---------------- cfg outputs ----------------
    assign cfg_enable        = reg_control[0];
    assign cfg_sw_fsync      = reg_control[1];
    assign cfg_ext_sync      = reg_control[2];
    assign cfg_img_width     = reg_img_width[15:0];
    assign cfg_img_height    = reg_img_height[15:0];
    assign cfg_pattern       = reg_pattern_sel[3:0];
    assign cfg_solid_color   = reg_solid_color[23:0];
    assign cfg_box_color     = reg_box_color[23:0];
    assign cfg_box_width     = reg_box_size[31:16];
    assign cfg_box_height    = reg_box_size[15:0];
    assign cfg_box_dx        = reg_box_speed[31:16];
    assign cfg_box_dy        = reg_box_speed[15:0];
    assign cfg_grid_spacing  = reg_grid_spacing[15:0];
    assign cfg_grid_color    = reg_grid_color[23:0];
    assign cfg_checker_size  = reg_checker_size[15:0];
    assign cfg_frame_rate_div= reg_frame_rate;
    assign cfg_bar_width     = reg_bar_width[15:0];
    assign cfg_hg_step       = reg_hg_step[15:0];
    assign cfg_vg_step       = reg_vg_step[15:0];
    assign cfg_box_border_color = reg_box_border[23:0];
    assign cfg_box_border_width = reg_box_border[31:24];

endmodule
