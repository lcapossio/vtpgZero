//-----------------------------------------------------------------------------
// tb_gapfree.v - the assumption the FVAL/LVAL/DVAL adapter rests on
//
// SPDX-FileCopyrightText: 2026 Leonardo Capossio - bard0 design - hello@bard0.com
// SPDX-License-Identifier: Apache-2.0
//
// vtpgz_axis_to_flvdval has no FIFO. It ties TREADY high and assumes the core
// emits every line as a CONTIGUOUS run of beats, because FVAL/LVAL/DVAL has
// no way to express a mid-line stall. This bench pins that assumption down
// for one configuration per run (swept by the runner):
//
//   * every LVAL pulse is exactly IMG_WIDTH/PPC cycles -- min == max, so a
//     single short or long line anywhere in the run fails;
//   * TIMING_ERR never latches, which is the adapter's own bubble detector;
//   * vertical blanking matches FRAME_RATE_DIV - ACTIVE, the arithmetic the
//     README tells integrators to size their blanking with.
//
// The interesting parameter sweeps are PIXELS_PER_CLOCK (the pack stage),
// the pattern (NOISE has a leap-ahead LFSR, IMAGE reads a BRAM with fixed
// latency), and the frame rate relative to the active time.
//-----------------------------------------------------------------------------

`timescale 1ns/1ps

module tb_gapfree #(
    parameter integer PPC   = 1,
    parameter integer W     = 32,
    parameter integer H     = 4,
    parameter integer GAP   = 1,
    parameter integer RATE  = 400,
    parameter integer PAT   = 0,
    parameter integer ENIMG = 0
);
    localparam integer TDW = 24 * PPC;
    // Width is clamped down to a whole number of PPC-wide beats by the core.
    localparam integer BEATS  = W / PPC;
    localparam integer ACTIVE = BEATS * PPC * H / PPC + GAP * (H - 1);
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
    wire m_tvalid, m_tlast, m_tuser, m_eof, m_tready;

    vtpgz_axilite_top #(
        .PIXELS_PER_CLOCK(PPC), .LINE_GAP_CYCLES(GAP), .EN_INTERLACE(1),
        .EN_IMAGE(ENIMG), .EN_BOX_IMAGE(ENIMG)
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
        .fid(), .frame_sync_in(1'b0), .fid_in(1'b0)
    );

    wire fval, lval, dval, timing_err;
    vtpgz_axis_to_flvdval #(.TDATA_WIDTH(TDW)) u_flv (
        .aclk(aclk), .aresetn(aresetn),
        .s_axis_tdata(m_tdata), .s_axis_tvalid(m_tvalid),
        .s_axis_tready(m_tready), .s_axis_tlast(m_tlast),
        .s_axis_tuser(m_tuser), .s_axis_eof(m_eof), .s_axis_fid(1'b0),
        .pix_data(), .fval(fval), .lval(lval), .dval(dval), .field_id(),
        .timing_err(timing_err), .timing_err_clr(1'b0)
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

    integer run, runmin, runmax, lines;
    integer vb, vbmin, vbmax, vbn;
    reg     lq, fq, armed;

    always @(posedge aclk) if (armed) begin
        if (lval) run = run + 1;
        if (lq && !lval) begin
            if (run > runmax) runmax = run;
            if (run < runmin) runmin = run;
            run = 0;
            lines = lines + 1;
        end
        if (!fval) vb = vb + 1;
        if (!fq && fval && (lines > 0)) begin
            if (vb > vbmax) vbmax = vb;
            if (vb < vbmin) vbmin = vb;
            vbn = vbn + 1;
        end
        if (fval) vb = 0;
        lq = lval;
        fq = fval;
    end

    initial begin
        awvalid = 1'b0; wvalid = 1'b0; bready = 1'b0; wstrb = 4'h0;
        awaddr = 8'h0; wdata = 32'h0;
        armed = 1'b0; run = 0; runmax = 0; runmin = 999999; lines = 0;
        vb = 0; vbmin = 999999; vbmax = 0; vbn = 0; lq = 1'b0; fq = 1'b0;

        repeat (8) @(posedge aclk);
        aresetn <= 1'b1;
        repeat (4) @(posedge aclk);

        axi_write(8'h10, W);
        axi_write(8'h14, H);
        axi_write(8'h18, PAT);
        axi_write(8'h44, (W / 8 > 0) ? W / 8 : 1);
        axi_write(8'h28, {16'd4, 16'd2});
        axi_write(8'h48, 32'd130);
        axi_write(8'h4C, 32'd1365);
        axi_write(8'h40, RATE);
        axi_write(8'h08, 32'h9);
        armed = 1'b1;

        repeat (PERIOD * 5 + 200) @(posedge aclk);

        if (lines < 4)
            fail("too few lines observed to conclude anything");
        if (runmin !== BEATS || runmax !== BEATS)
            fail("a line was not exactly IMG_WIDTH/PPC beats: source NOT gap-free");
        if (timing_err !== 1'b0)
            fail("adapter latched TIMING_ERR: mid-line bubble in the source");
        if (vbn < 2)
            fail("vertical blanking was not observed");
        else if (vbmin !== VBLANK || vbmax !== VBLANK)
            fail("vertical blanking does not match FRAME_RATE_DIV - ACTIVE");

        if (errors == 0)
            $display("PASS: tb_gapfree PPC=%0d W=%0d H=%0d GAP=%0d RATE=%0d PAT=%0d IMG=%0d (lines=%0d run=%0d vblank=%0d)",
                     PPC, W, H, GAP, RATE, PAT, ENIMG, lines, runmin, vbmin);
        else
            $display("FAIL: tb_gapfree PPC=%0d PAT=%0d IMG=%0d -- %0d error(s) run=%0d..%0d expected %0d, vblank=%0d..%0d expected %0d",
                     PPC, PAT, ENIMG, errors, runmin, runmax, BEATS,
                     vbmin, vbmax, VBLANK);
        $finish;
    end

    initial begin
        #2000000;
        $display("FAIL: tb_gapfree timeout");
        $finish;
    end

endmodule
