//-----------------------------------------------------------------------------
// tb_vtpgz_axilite_top.v - simple integration testbench for vtpgZero core
//
// Configures a small frame (32x16), color-bar pattern, RGB888, and captures
// a single frame from the AXI-Stream output. Reports pixel/line/frame counts.
//
// SPDX-FileCopyrightText: 2026 Leonardo Capossio - bard0 design - hello@bard0.com
// SPDX-License-Identifier: Apache-2.0
//-----------------------------------------------------------------------------
`timescale 1ns/1ps
`include "vtpgz_defs.vh"

module tb_vtpgz_axilite_top;

    reg         aclk;
    reg         aresetn;

    // AXI-Lite
    reg  [7:0]  awaddr;
    reg         awvalid;
    wire        awready;
    reg  [31:0] wdata;
    reg  [3:0]  wstrb;
    reg         wvalid;
    wire        wready;
    wire [1:0]  bresp;
    wire        bvalid;
    reg         bready;
    reg  [7:0]  araddr;
    reg         arvalid;
    wire        arready;
    wire [31:0] rdata;
    wire [1:0]  rresp;
    wire        rvalid;
    reg         rready;

    // AXI-Stream
    // RGB 8bpc default -> derived TDATA_WIDTH = 24
    localparam TB_TDATA_WIDTH = 24;
    localparam TB_IMG_W = 32;
    localparam TB_IMG_H = 16;
    localparam TB_FRAME_PIXELS = TB_IMG_W * TB_IMG_H;
    wire [TB_TDATA_WIDTH-1:0] m_tdata;
    wire        m_tvalid;
    reg         m_tready;
    wire        m_tlast;
    wire        m_tuser;

    reg         frame_sync_in;

    // ---------------- DUT ----------------
    vtpgz_axilite_top #(
        .C_S_AXI_ADDR_WIDTH(8),
        .C_S_AXI_DATA_WIDTH(32)
        // OUTPUT_MODE / BPC use defaults (RGB / 8bpc)
    ) dut (
        .aclk          (aclk),
        .aresetn       (aresetn),
        .s_axil_awaddr (awaddr),
        .s_axil_awprot (3'b000),
        .s_axil_awvalid(awvalid),
        .s_axil_awready(awready),
        .s_axil_wdata  (wdata),
        .s_axil_wstrb  (wstrb),
        .s_axil_wvalid (wvalid),
        .s_axil_wready (wready),
        .s_axil_bresp  (bresp),
        .s_axil_bvalid (bvalid),
        .s_axil_bready (bready),
        .s_axil_araddr (araddr),
        .s_axil_arprot (3'b000),
        .s_axil_arvalid(arvalid),
        .s_axil_arready(arready),
        .s_axil_rdata  (rdata),
        .s_axil_rresp  (rresp),
        .s_axil_rvalid (rvalid),
        .s_axil_rready (rready),
        .m_axis_tdata  (m_tdata),
        .m_axis_tvalid (m_tvalid),
        .m_axis_tready (m_tready),
        .m_axis_tlast  (m_tlast),
        .m_axis_tuser  (m_tuser),
        .frame_sync_in (frame_sync_in)
    );

    // 100 MHz clock
    initial aclk = 1'b0;
    always #5 aclk = ~aclk;

    // ---------------- AXI-Lite write task ----------------
    task axil_write;
        input [7:0]  addr;
        input [31:0] data;
        begin
            @(posedge aclk);
            awaddr  <= addr;
            awvalid <= 1'b1;
            wdata   <= data;
            wstrb   <= 4'hF;
            wvalid  <= 1'b1;
            bready  <= 1'b1;
            wait (awready && wready);
            @(posedge aclk);
            awvalid <= 1'b0;
            wvalid  <= 1'b0;
            wait (bvalid);
            @(posedge aclk);
            bready  <= 1'b0;
        end
    endtask

    // ---------------- monitor ----------------
    integer pixel_count;
    integer line_count;
    integer frame_count;
    integer completed_frames;
    integer frame_pixels;
    integer axis_x;
    integer axis_y;
    integer error_count;
    reg     in_frame;

    always @(posedge aclk) begin
        if (!aresetn) begin
            pixel_count      = 0;
            line_count       = 0;
            frame_count      = 0;
            completed_frames = 0;
            frame_pixels     = 0;
            axis_x           = 0;
            axis_y           = 0;
            error_count      = 0;
            in_frame         = 1'b0;
        end else
        if (m_tvalid && m_tready) begin
            pixel_count = pixel_count + 1;
            if (m_tuser) begin
                if (in_frame && frame_pixels != TB_FRAME_PIXELS) begin
                    $display("ERROR: short frame before SOF: pixels=%0d expected=%0d",
                             frame_pixels, TB_FRAME_PIXELS);
                    error_count = error_count + 1;
                end
                in_frame     = 1'b1;
                frame_pixels = 0;
                axis_x       = 0;
                axis_y       = 0;
                frame_count = frame_count + 1;
                $display("[%0t] SOF  frame=%0d", $time, frame_count);
            end else if (!in_frame) begin
                $display("ERROR: stream beat before first SOF");
                error_count = error_count + 1;
            end

            if (in_frame) begin
                if (m_tlast != (axis_x == TB_IMG_W-1)) begin
                    $display("ERROR: tlast mismatch frame=%0d x=%0d y=%0d got=%0d expected=%0d",
                             frame_count, axis_x, axis_y, m_tlast, axis_x == TB_IMG_W-1);
                    error_count = error_count + 1;
                end
                if (axis_y >= TB_IMG_H) begin
                    $display("ERROR: frame overrun frame=%0d y=%0d", frame_count, axis_y);
                    error_count = error_count + 1;
                end
            end
            if (m_tlast) begin
                line_count = line_count + 1;
            end
            frame_pixels = frame_pixels + 1;
            if (axis_x == TB_IMG_W-1) begin
                axis_x = 0;
                axis_y = axis_y + 1;
            end else begin
                axis_x = axis_x + 1;
            end
            if (frame_pixels == TB_FRAME_PIXELS) begin
                if (axis_y != TB_IMG_H) begin
                    $display("ERROR: completed frame has %0d lines expected=%0d", axis_y, TB_IMG_H);
                    error_count = error_count + 1;
                end
                completed_frames = completed_frames + 1;
            end
        end
    end

    // ---------------- stimulus ----------------
    initial begin
        $dumpfile("tb_vtpgz_axilite_top.vcd");
        $dumpvars(0, tb_vtpgz_axilite_top);

        aresetn       = 1'b0;
        awaddr=0; awvalid=0; wdata=0; wstrb=0; wvalid=0; bready=0;
        araddr=0; arvalid=0; rready=0;
        m_tready      = 1'b1;
        frame_sync_in = 1'b0;
        pixel_count   = 0;
        line_count    = 0;
        frame_count   = 0;
        completed_frames = 0;
        frame_pixels  = 0;
        axis_x        = 0;
        axis_y        = 0;
        error_count   = 0;
        in_frame      = 1'b0;

        repeat (10) @(posedge aclk);
        aresetn = 1'b1;
        repeat (5) @(posedge aclk);

        // Configure: 32x16 frame, color bars, RGB 8bpp, internal sync fast
        axil_write(`VTPGZ_REG_IMG_WIDTH,    TB_IMG_W);
        axil_write(`VTPGZ_REG_IMG_HEIGHT,   TB_IMG_H);
        axil_write(`VTPGZ_REG_PATTERN_SEL,  {28'h0, `VTPGZ_PAT_COLORBAR});
        // OUTPUT_MODE / BPC are build-time params now (default RGB 8bpc).
        axil_write(`VTPGZ_REG_FRAME_RATE,   32'd200);  // ~200 cycles/frame
        // Enable, internal sync
        axil_write(`VTPGZ_REG_CONTROL,      32'h0000_0001);

        // Run until two exact frames have completed.
        wait (completed_frames >= 2);

        // Test backpressure: stall for a while
        m_tready = 1'b0;
        repeat (50) @(posedge aclk);
        m_tready = 1'b1;
        wait (completed_frames >= 5);

        $display("RESULT: pixels=%0d lines=%0d frames=%0d completed=%0d errors=%0d",
                 pixel_count, line_count, frame_count, completed_frames, error_count);
        if (error_count == 0 &&
            frame_count == 5 &&
            completed_frames == 5 &&
            line_count == 5*TB_IMG_H &&
            pixel_count == 5*TB_FRAME_PIXELS)
            $display("PASS");
        else
            $display("FAIL");

        $finish;
    end

    initial begin
        #1_000_000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
