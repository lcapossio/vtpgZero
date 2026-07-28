//-----------------------------------------------------------------------------
// tb_ppc_capture.v - iverilog capture harness for pixels-per-clock (M1).
//
// Drives vtpgz_core (port-driven, no AXI-Lite) with configuration supplied
// via plusargs, captures exactly one frame of AXI-Stream beats, and writes
// each beat as one hex line to +out=<file>. A companion Python script
// (check_ppc_vs_model.py) compares that against render_frame_beats().
//
// Build-time PIXELS_PER_CLOCK / OUTPUT_MODE / BPC / pattern-enables are
// overridden per run via -P<top>.<param>=<val> (iverilog) so one harness
// covers PPC=1/2/4/8 across the M1 patterns.
//
// SPDX-FileCopyrightText: 2026 Leonardo Capossio - bard0 design - hello@bard0.com
// SPDX-License-Identifier: Apache-2.0
//-----------------------------------------------------------------------------
`timescale 1ns/1ps
`include "vtpgz_defs.vh"

module tb_ppc_capture;
    // Overridable build-time configuration (set via -P on the iverilog cmd line).
    parameter integer PIXELS_PER_CLOCK = 1;
    parameter integer OUTPUT_MODE      = `VTPGZ_MODE_RGB;
    parameter integer YUV_SUBSAMPLE    = `VTPGZ_YUV_444;
    parameter integer RAW_BAYER        = `VTPGZ_RAW_RGGB;
    parameter integer RGB_ORDER        = `VTPGZ_RGB_ORDER_XILINX;
    parameter integer BPC              = 8;
    // Only M1 patterns are legal at PPC>1, so the non-M1 enables default off.
    // For a PPC=1 regression they can be turned on via -P to re-check the
    // refactored pack stage against the model for every pattern.
    parameter integer EN_SOLID    = 1;
    parameter integer EN_GRID     = 1;
    parameter integer EN_CHECKER  = 1;
    parameter integer EN_BOX      = 1;
    parameter integer EN_COLORBAR = 0;
    parameter integer EN_HGRAD    = 0;
    parameter integer EN_VGRAD    = 0;
    parameter integer EN_RAMP     = 0;
    parameter integer EN_NOISE    = 0;

    localparam integer PIX_TDATA_WIDTH =
        (OUTPUT_MODE == `VTPGZ_MODE_RGB) ? (((3*BPC + 7) / 8) * 8) :
        (OUTPUT_MODE == `VTPGZ_MODE_RAW) ? (((  BPC + 7) / 8) * 8) :
            (YUV_SUBSAMPLE == `VTPGZ_YUV_444 ? (((3*BPC + 7) / 8) * 8)
                                             : (((2*BPC + 7) / 8) * 8));
    localparam integer TDATA_WIDTH = PIXELS_PER_CLOCK * PIX_TDATA_WIDTH;

    reg aclk = 1'b0;
    reg aresetn = 1'b0;
    always #5 aclk = ~aclk;

    // config
    reg  [15:0] cfg_img_width;
    reg  [15:0] cfg_img_height;
    reg  [3:0]  cfg_pattern;
    reg         cfg_enable;

    wire [TDATA_WIDTH-1:0] m_tdata;
    wire                   m_tvalid;
    wire                   m_tlast;
    wire                   m_tuser;
    reg                    m_tready;

    vtpgz_core #(
        .EN_COLORBAR  (EN_COLORBAR),
        .EN_HGRAD     (EN_HGRAD),
        .EN_VGRAD     (EN_VGRAD),
        .EN_CHECKER   (EN_CHECKER),
        .EN_SOLID     (EN_SOLID),
        .EN_MOVING_BOX(EN_BOX),
        .EN_GRID      (EN_GRID),
        .EN_RAMP      (EN_RAMP),
        .EN_NOISE     (EN_NOISE),
        .EN_IMAGE     (0),
        .EN_BOX_IMAGE (0),
        .OUTPUT_MODE  (OUTPUT_MODE),
        .YUV_SUBSAMPLE(YUV_SUBSAMPLE),
        .RAW_BAYER    (RAW_BAYER),
        .RGB_ORDER    (RGB_ORDER),
        .BPC          (BPC),
        .PIXELS_PER_CLOCK(PIXELS_PER_CLOCK),
        .LINE_GAP_CYCLES(2)
    ) dut (
        .aclk(aclk), .aresetn(aresetn),
        .cfg_enable(cfg_enable),
        .cfg_sw_fsync(1'b0),
        .cfg_ext_sync(1'b0),
        .cfg_img_width(cfg_img_width),
        .cfg_img_height(cfg_img_height),
        .cfg_pattern(cfg_pattern),
        .cfg_solid_color(24'h3C_A5_10),
        .cfg_box_color(24'h00_FF_00),
        .cfg_box_width(16'd12),
        .cfg_box_height(16'd8),
        .cfg_box_dx(16'd1),
        .cfg_box_dy(16'd1),
        .cfg_grid_spacing(16'd7),
        .cfg_grid_color(24'hFF_FF_FF),
        .cfg_checker_size(16'd5),
        .cfg_frame_rate_div(32'd50),
        .cfg_bar_width(16'd8),
        .cfg_hg_step(16'd64),
        .cfg_vg_step(16'd128),
        .cfg_box_border_color(24'hFF_00_00),
        .cfg_box_border_width(8'd2),
        .cfg_box_img_x_step(32'h0),
        .cfg_box_img_y_step(32'h0),
        .sts_busy(),
        .sts_frame_count(),
        .m_axis_tdata(m_tdata),
        .m_axis_tvalid(m_tvalid),
        .m_axis_tready(m_tready),
        .m_axis_tlast(m_tlast),
        .m_axis_tuser(m_tuser),
        .frame_sync_in(1'b0)
    );

    integer out_fd;
    integer i;
    integer count;
    integer total_beats;
    integer max_cycles;
    integer started;
    integer width, height, pat;
    integer n_tuser, n_tlast, bad_flag;
    reg [1023:0] out_path;

    initial begin
        if (!$value$plusargs("width=%d",  width))  width  = 32;
        if (!$value$plusargs("height=%d", height)) height = 12;
        if (!$value$plusargs("pat=%d",    pat))    pat    = `VTPGZ_PAT_SOLID;
        if (!$value$plusargs("out=%s",    out_path)) out_path = "ppc_cap.hex";

        total_beats = (width / PIXELS_PER_CLOCK) * height;
        max_cycles  = total_beats * 40 + 10000;

        cfg_img_width  = width[15:0];
        cfg_img_height = height[15:0];
        cfg_pattern    = pat[3:0];
        cfg_enable     = 1'b0;
        m_tready       = 1'b1;

        // reset
        aresetn = 1'b0;
        repeat (10) @(posedge aclk);
        aresetn = 1'b1;
        repeat (5) @(posedge aclk);
        cfg_enable = 1'b1;   // internal free-run sync

        out_fd = $fopen(out_path, "w");
        if (out_fd == 0) begin
            $display("ERROR: cannot open %0s", out_path);
            $finish;
        end

        count   = 0;
        started = 0;
        i       = 0;
        n_tuser = 0;
        n_tlast = 0;
        bad_flag = 0;
        while (i < max_cycles && count < total_beats) begin
            @(posedge aclk);
            #1;
            if (m_tvalid && m_tready) begin
                if (!started) begin
                    if (m_tuser) started = 1;
                end
                if (started) begin
                    $fdisplay(out_fd, "%0h", m_tdata);
                    // Structural flag checks: tuser only on the first beat of
                    // the frame; tlast only on the last beat of each line
                    // (beat index congruent to beats_per_line-1).
                    if (m_tuser)  n_tuser = n_tuser + 1;
                    if (m_tuser && count != 0) bad_flag = 1;
                    if (m_tlast)  n_tlast = n_tlast + 1;
                    if (m_tlast != ((count % (width / PIXELS_PER_CLOCK))
                                     == (width / PIXELS_PER_CLOCK) - 1))
                        bad_flag = 1;
                    count = count + 1;
                end
            end
            i = i + 1;
        end
        if (n_tuser != 1 || n_tlast != height || bad_flag)
            $display("ERROR: flag check failed tuser=%0d(exp 1) tlast=%0d(exp %0d) bad=%0d",
                     n_tuser, n_tlast, height, bad_flag);
        $fclose(out_fd);
        if (count != total_beats)
            $display("ERROR: captured %0d of %0d beats", count, total_beats);
        else if (n_tuser != 1 || n_tlast != height || bad_flag)
            $display("ERROR: flag check failed");
        else
            $display("OK: pat=%0d %0dx%0d ppc=%0d -> %0d beats",
                     pat, width, height, PIXELS_PER_CLOCK, count);
        $finish;
    end
endmodule
