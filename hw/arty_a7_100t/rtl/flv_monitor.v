// SPDX-FileCopyrightText: 2026 Leonardo Capossio - bard0 design - hello@bard0.com
// SPDX-License-Identifier: Apache-2.0
//
// flv_monitor.v
//
// On-chip measurement of the FVAL/LVAL/DVAL raster produced by
// vtpgz_axis_to_flvdval, so the host can assert on SILICON the same
// properties tb_gapfree asserts in simulation.
//
// The demo builds the core at PIXELS_PER_CLOCK=4, so PIX_DATA is 96 bits and
// a real parallel bus cannot leave the device (the Arty's headers are nowhere
// near wide enough). Measuring the timing in fabric and reporting a few
// counters over the existing JTAG-AXI path gives the same proof without pins.
//
// What it records, from the raster alone:
//   * min/max LVAL pulse width   -> must both equal IMG_WIDTH/PPC
//   * lines per frame            -> must equal IMG_HEIGHT
//   * min/max vertical blanking  -> must both equal FRAME_RATE_DIV - ACTIVE
//   * frames seen, saturating at 255
//   * FIELD_ID at each FVAL rising edge (8-deep history, bit 0 = newest),
//     which is where a receiver would latch it
//   * whether DVAL ever differed from LVAL (a mid-line bubble), and the
//     adapter's own sticky TIMING_ERR
//
// min/max rather than a single sample on purpose: one short or long line
// anywhere in the run moves max or min and cannot average away.
//
// Verilog 2001.

`timescale 1ns/1ps

module flv_monitor (
    input  wire        aclk,
    input  wire        aresetn,

    // Raster under measurement
    input  wire        fval,
    input  wire        lval,
    input  wire        dval,
    input  wire        field_id,
    input  wire        timing_err,

    // Synchronous clear of every statistic below (not of the adapter's own
    // sticky TIMING_ERR, which the adapter clears itself).
    input  wire        clear,

    output wire [15:0] lval_min,
    output wire [15:0] lval_max,
    output wire [15:0] lines_last,   // LVAL pulses in the last complete frame
    // Blanking is counted in a 16-bit register: a configuration whose
    // vertical blanking exceeds 65535 cycles would wrap. The host picks
    // frame rates that stay inside that, and checks it before asserting.
    output wire [15:0] vblank_min,
    output wire [15:0] vblank_max,
    output wire [7:0]  frames,
    output wire [7:0]  fid_hist,     // FIELD_ID at FVAL rise, bit 0 = newest
    output wire        dval_ne_lval, // sticky: DVAL and LVAL disagreed
    output wire        timing_err_o
);

    reg [15:0] run_cnt,   lval_min_r, lval_max_r;
    reg [15:0] line_cnt,  lines_last_r;
    reg [15:0] vb_cnt,    vb_min_r,   vb_max_r;
    reg [7:0]  frames_r;
    reg [7:0]  fid_hist_r;
    reg        dval_ne_r;
    reg        lval_q, fval_q;
    reg        vb_armed;

    wire lval_fall = lval_q && !lval;
    wire fval_fall = fval_q && !fval;
    wire fval_rise = !fval_q && fval;

    always @(posedge aclk) begin
        if (!aresetn || clear) begin
            run_cnt      <= 16'h0;
            lval_min_r   <= 16'hFFFF;
            lval_max_r   <= 16'h0;
            line_cnt     <= 16'h0;
            lines_last_r <= 16'h0;
            vb_cnt       <= 16'h0;
            vb_min_r     <= 16'hFFFF;
            vb_max_r     <= 16'h0;
            frames_r     <= 8'h0;
            fid_hist_r   <= 8'h0;
            dval_ne_r    <= 1'b0;
            lval_q       <= 1'b0;
            fval_q       <= 1'b0;
            vb_armed     <= 1'b0;
        end else begin
            lval_q <= lval;
            fval_q <= fval;

            // ---- LVAL pulse width ----
            if (lval)
                run_cnt <= run_cnt + 16'd1;
            else
                run_cnt <= 16'h0;
            if (lval_fall) begin
                if (run_cnt < lval_min_r) lval_min_r <= run_cnt;
                if (run_cnt > lval_max_r) lval_max_r <= run_cnt;
                line_cnt <= line_cnt + 16'd1;
            end

            // ---- vertical blanking ----
            // Counted only between frames, so the idle time before the very
            // first frame -- which is not blanking, it is the host still
            // programming registers -- never lands in the min.
            //
            // The arm must include the FVAL falling cycle itself, because
            // that cycle is already the first blanking cycle. Gating on
            // frames_r instead would miss it: frames_r increments on that
            // same edge, so the old value is still 0 when it is read here,
            // and the FIRST interval alone would come up one cycle short --
            // enough to drag vb_min below vb_max forever.
            if (fval)
                vb_cnt <= 16'h0;
            else if (vb_armed || fval_fall)
                vb_cnt <= vb_cnt + 16'd1;

            if (fval_fall)
                vb_armed <= 1'b1;

            if (fval_rise) begin
                fid_hist_r <= {fid_hist_r[6:0], field_id};
                if (vb_armed) begin
                    if (vb_cnt < vb_min_r) vb_min_r <= vb_cnt;
                    if (vb_cnt > vb_max_r) vb_max_r <= vb_cnt;
                end
            end

            // ---- end of frame ----
            if (fval_fall) begin
                // lval_fall lands on this same cycle for a zero back porch,
                // so fold in the line that is closing right now.
                lines_last_r <= lval_fall ? (line_cnt + 16'd1) : line_cnt;
                line_cnt     <= 16'h0;
                // Saturate. A host round trip over JTAG is long enough for
                // thousands of frames, so a wrapping count would report an
                // arbitrary number; saturated it reads "many", which is all
                // the host uses it for.
                if (frames_r != 8'hFF) frames_r <= frames_r + 8'd1;
            end

            // ---- gap-free check, independent of the adapter's own ----
            if (dval != lval)
                dval_ne_r <= 1'b1;
        end
    end

    assign lval_min     = lval_min_r;
    assign lval_max     = lval_max_r;
    assign lines_last   = lines_last_r;
    assign vblank_min   = vb_min_r;
    assign vblank_max   = vb_max_r;
    assign frames       = frames_r;
    assign fid_hist     = fid_hist_r;
    assign dval_ne_lval = dval_ne_r;
    assign timing_err_o = timing_err;

endmodule
