//-----------------------------------------------------------------------------
// tb_flvmon.v - flv_monitor, the instrument the board test trusts
//
// SPDX-FileCopyrightText: 2026 Leonardo Capossio - bard0 design - hello@bard0.com
// SPDX-License-Identifier: Apache-2.0
//
// run_hw_flvdval.py asserts nothing directly: it reads flv_monitor's counters
// and compares them against the geometry. So a defect in the MONITOR shows up
// as a hardware failure indistinguishable from a defect in the design, and a
// monitor that is wrong in the lenient direction would hide a real one.
//
// tb_gapfree already checks the same raster properties, but it measures them
// with its own testbench-side counters and never instantiates flv_monitor.
// That is exactly how the first-blanking-interval bug reached the board: the
// module had no simulation coverage at all.
//
// This bench instantiates the real monitor on a real core + adapter and
// checks its counters against arithmetic derived from the parameters:
//
//   * lval_min == lval_max == IMG_WIDTH/PPC
//   * lines_last == IMG_HEIGHT
//   * vblank_min == vblank_max == PERIOD - ACTIVE
//   * dval_ne_lval and timing_err_o both clear
//   * fid_hist alternates when the source is interlaced
//
// The min == max pairs are the load-bearing ones. A monitor that mismeasures
// a single interval out of many still moves min or max, and cannot average
// the error away -- which is what makes this bench catch an off-by-one that
// only ever affects the FIRST interval.
//-----------------------------------------------------------------------------

`timescale 1ns/1ps

module tb_flvmon #(
    parameter integer PPC    = 1,
    parameter integer W      = 32,
    parameter integer H      = 4,
    parameter integer GAP    = 1,
    parameter integer RATE   = 400,
    parameter integer ILACE  = 0
);
    localparam integer TDW    = 24 * PPC;
    localparam integer BEATS  = W / PPC;
    localparam integer ACTIVE = BEATS * H + GAP * (H - 1);
    // Sync ticks landing inside an active frame are dropped, so the period is
    // the first multiple of RATE strictly greater than ACTIVE.
    localparam integer PERIOD = RATE * (ACTIVE / RATE + 1);
    localparam integer VBLANK = PERIOD - ACTIVE;

    integer errors = 0;
    task fail;
        input [1023:0] msg;
        begin
            $display("ERROR: %0s", msg);
            errors = errors + 1;
        end
    endtask

    reg aclk = 1'b0, aresetn = 1'b0;
    always #5 aclk = ~aclk;

    reg  [7:0]  awaddr; reg awvalid; wire awready;
    reg  [31:0] wdata;  reg [3:0] wstrb; reg wvalid; wire wready;
    wire bvalid; reg bready;

    wire [TDW-1:0] m_tdata;
    wire m_tvalid, m_tlast, m_tuser, m_eof, m_tready, m_fid;

    vtpgz_axilite_top #(
        .PIXELS_PER_CLOCK(PPC), .LINE_GAP_CYCLES(GAP), .EN_INTERLACE(1)
    ) u_dut (
        .aclk(aclk), .aresetn(aresetn),
        .s_axi_awaddr(awaddr), .s_axi_awprot(3'b000),
        .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(wstrb),
        .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bresp(), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_araddr(8'h0), .s_axi_arprot(3'b000), .s_axi_arvalid(1'b0),
        .s_axi_arready(), .s_axi_rdata(), .s_axi_rresp(), .s_axi_rvalid(),
        .s_axi_rready(1'b0),
        .m_axis_tdata(m_tdata), .m_axis_tvalid(m_tvalid),
        .m_axis_tready(m_tready), .m_axis_tlast(m_tlast),
        .m_axis_tuser(m_tuser), .eof(m_eof),
        .m_axis_tid(), .m_axis_tdest(),
        .fid(m_fid), .frame_sync_in(1'b0), .fid_in(1'b0)
    );

    reg  mon_clear;
    wire fval, lval, dval, field_id, timing_err;
    vtpgz_axis_to_flvdval #(.TDATA_WIDTH(TDW)) u_flv (
        .aclk(aclk), .aresetn(aresetn),
        .s_axis_tdata(m_tdata), .s_axis_tvalid(m_tvalid),
        .s_axis_tready(m_tready), .s_axis_tlast(m_tlast),
        .s_axis_tuser(m_tuser), .s_axis_eof(m_eof), .s_axis_fid(m_fid),
        .pix_data(), .fval(fval), .lval(lval), .dval(dval),
        .field_id(field_id), .timing_err(timing_err),
        .timing_err_clr(mon_clear)
    );

    // ---- the device under test ----
    wire [15:0] lval_min, lval_max, lines_last, vblank_min, vblank_max;
    wire [7:0]  frames, fid_hist;
    wire        dval_ne_lval, mon_timing_err;

    flv_monitor u_mon (
        .aclk(aclk), .aresetn(aresetn),
        .fval(fval), .lval(lval), .dval(dval),
        .field_id(field_id), .timing_err(timing_err),
        .clear(mon_clear),
        .lval_min(lval_min), .lval_max(lval_max), .lines_last(lines_last),
        .vblank_min(vblank_min), .vblank_max(vblank_max),
        .frames(frames), .fid_hist(fid_hist),
        .dval_ne_lval(dval_ne_lval), .timing_err_o(mon_timing_err)
    );

    task axi_write;
        input [7:0] a;
        input [31:0] d;
        begin
            @(posedge aclk);
            awaddr <= a; awvalid <= 1'b1; wdata <= d; wstrb <= 4'hF;
            wvalid <= 1'b1; bready <= 1'b1;
            wait (awready && wready);
            @(posedge aclk);
            awvalid <= 1'b0; wvalid <= 1'b0;
            wait (bvalid);
            @(posedge aclk);
            bready <= 1'b0;
        end
    endtask

    integer i, alt_errors, valid;
    reg [7:0] seen;

    initial begin
        awvalid = 1'b0; wvalid = 1'b0; bready = 1'b0; wstrb = 4'h0;
        awaddr = 8'h0; wdata = 32'h0; mon_clear = 1'b0;

        repeat (8) @(posedge aclk);
        aresetn <= 1'b1;
        repeat (4) @(posedge aclk);

        axi_write(8'h10, W);
        axi_write(8'h14, H);
        axi_write(8'h18, 32'd0);                       // colorbar
        axi_write(8'h44, (W / 8 > 0) ? W / 8 : 1);
        axi_write(8'h40, RATE);

        // Same order the host uses: clear the monitor, THEN enable the core,
        // so the measurement window holds only whole frames.
        @(posedge aclk); mon_clear <= 1'b1;
        @(posedge aclk); mon_clear <= 1'b0;

        axi_write(8'h08, ILACE ? 32'h9 : 32'h1);

        repeat (PERIOD * 6 + 400) @(posedge aclk);

        if (frames < 8'd4)
            fail("too few frames observed to conclude anything");

        if (lval_min !== BEATS[15:0] || lval_max !== BEATS[15:0])
            fail("LVAL pulse width min/max != IMG_WIDTH/PPC");

        if (lines_last !== H[15:0])
            fail("lines in the last complete frame != IMG_HEIGHT");

        // The check that catches an off-by-one on the FIRST interval only:
        // a single mismeasured gap separates min from max.
        if (vblank_min !== VBLANK[15:0] || vblank_max !== VBLANK[15:0])
            fail("vertical blanking min/max != FRAME_RATE_DIV - ACTIVE");

        if (dval_ne_lval !== 1'b0)
            fail("monitor saw DVAL differ from LVAL");
        if (mon_timing_err !== 1'b0)
            fail("adapter latched TIMING_ERR");

        // FIELD_ID at the FVAL rising edge: alternating when interlaced.
        if (ILACE) begin
            alt_errors = 0;
            seen  = fid_hist;
            // bit 0 is the newest, so bits 0..valid-1 are the entries that
            // have actually been written. Comparing the whole register would
            // pit real field IDs against the reset zeros above them.
            valid = (frames > 8'd8) ? 8 : frames;
            if (valid < 3)
                fail("too few field starts recorded to judge alternation");
            for (i = 0; i < valid - 1; i = i + 1)
                if (seen[i] === seen[i+1]) alt_errors = alt_errors + 1;
            if (alt_errors != 0)
                fail("fid_hist did not alternate for an interlaced source");
        end else if (fid_hist !== 8'h00) begin
            fail("fid_hist nonzero for a progressive source");
        end

        if (errors == 0)
            $display("PASS: tb_flvmon PPC=%0d W=%0d H=%0d GAP=%0d RATE=%0d ILACE=%0d (frames=%0d lval=%0d lines=%0d vblank=%0d fid=%b)",
                     PPC, W, H, GAP, RATE, ILACE, frames, lval_min,
                     lines_last, vblank_min, fid_hist);
        else
            $display("FAIL: tb_flvmon PPC=%0d W=%0d H=%0d RATE=%0d ILACE=%0d -- %0d error(s) lval=%0d..%0d expected %0d, lines=%0d expected %0d, vblank=%0d..%0d expected %0d, fid=%b",
                     PPC, W, H, RATE, ILACE, errors, lval_min, lval_max, BEATS,
                     lines_last, H, vblank_min, vblank_max, VBLANK, fid_hist);
        $finish;
    end

    initial begin
        #4000000;
        $display("FAIL: tb_flvmon timeout");
        $finish;
    end

endmodule
