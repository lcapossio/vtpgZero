//-----------------------------------------------------------------------------
// vtpgz_axis_to_flvdval.v - AXI4-Stream video -> parallel FVAL/LVAL/DVAL
//
// SPDX-FileCopyrightText: 2026 Leonardo Capossio - bard0 design - hello@bard0.com
// SPDX-License-Identifier: Apache-2.0
//
// Converts the vtpgZero AXI4-Stream video output (TUSER=SOF, TLAST=EOL, plus
// the core's `eof` frame marker) into the classic parallel video timing
// interface used by frame grabbers and camera links:
//
//   FVAL  frame valid - high for the whole frame (the whole FIELD when the
//         source is interlaced), low through vertical blanking
//   LVAL  line valid  - high for the whole active line, low through
//         horizontal blanking
//   DVAL  data valid  - qualifies one pixel (one beat) of PIX_DATA
//
// WHY THIS IS ONLY A WIRE-LEVEL ADAPTER (no FIFO)
// -----------------------------------------------
// FVAL/LVAL/DVAL has no backpressure: once a frame starts, the sink cannot
// ask the source to wait. This module therefore ties S_AXIS_TREADY high and
// relies on the source being able to run gap-free. vtpgZero can: with
// TREADY tied high it emits exactly IMG_WIDTH/PPC contiguous beats per line,
// then LINE_GAP_CYCLES of idle, then the next line, with no bubbles inside a
// line. That measured raster maps one-to-one onto FVAL/LVAL/DVAL, so no
// elastic buffer is needed.
//
// If you place this behind anything that CAN stall (a crossbar, a DMA, a CDC
// FIFO with a slower drain), that assumption breaks. It is not silent: LVAL
// stays high across a mid-line bubble while DVAL drops, and TIMING_ERR
// latches. A source that cannot guarantee gap-free lines needs a line (or
// frame) FIFO in front of this module.
//
// PIXELS PER CLOCK
// ----------------
// TDATA_WIDTH is passed through untouched, so a PIXELS_PER_CLOCK=N source
// presents N pixels per DVAL on a wide PIX_DATA bus. That is fine for an
// on-chip sink, but a true one-pixel-per-clock parallel interface needs
// PIXELS_PER_CLOCK=1 (or an external N:1 serializer running N times faster).
//
// Verilog 2001.
//-----------------------------------------------------------------------------

`timescale 1ns/1ps

module vtpgz_axis_to_flvdval #(
    // Width of one AXI-Stream beat. At PIXELS_PER_CLOCK=1 this is one pixel.
    parameter integer TDATA_WIDTH = 24,
    // Cycles FVAL rises BEFORE the first LVAL of the frame (front porch).
    // Implemented by delaying the pixel path, so it costs FVAL_LEAD cycles of
    // latency and FVAL_LEAD * (TDATA_WIDTH+3) flops. 0 = FVAL and LVAL rise
    // together (no delay line is generated at all).
    parameter integer FVAL_LEAD = 0,
    // Cycles FVAL stays high AFTER the last LVAL of the frame (back porch).
    // Free: it only extends a counter, the pixel path is untouched.
    parameter integer FVAL_TRAIL = 0
)(
    input  wire                   aclk,
    input  wire                   aresetn,

    // ---- AXI4-Stream video sink -------------------------------------------
    // TREADY is a constant 1: see the header. Connect this directly to a
    // vtpgz_axilite_top / vtpgz_top master.
    input  wire [TDATA_WIDTH-1:0] s_axis_tdata,
    input  wire                   s_axis_tvalid,
    output wire                   s_axis_tready,
    input  wire                   s_axis_tlast,   // end of line
    input  wire                   s_axis_tuser,   // start of frame
    input  wire                   s_axis_eof,     // vtpgZero `eof` sideband
    input  wire                   s_axis_fid,     // vtpgZero `fid` sideband

    // ---- parallel video source --------------------------------------------
    output wire [TDATA_WIDTH-1:0] pix_data,
    output wire                   fval,
    output wire                   lval,
    output wire                   dval,
    // Field ID of the frame FVAL currently encloses, latched at its SOF and
    // held for the whole field. Constant 0 for a progressive source.
    output wire                   field_id,

    // ---- diagnostics -------------------------------------------------------
    // Sticky: the emitted raster is not the one the sink expects -- either
    // the source left a gap INSIDE a line, or the FVAL porches overran the
    // vertical blanking so consecutive frames overlap in the delay line.
    // Cleared by reset or timing_err_clr.
    output wire                   timing_err,
    input  wire                   timing_err_clr
);

    // Clamp the porch parameters: negative is meaningless and would make the
    // generate bounds below misbehave.
    localparam integer LEAD  = (FVAL_LEAD  < 0) ? 0 : FVAL_LEAD;
    localparam integer TRAIL = (FVAL_TRAIL < 0) ? 0 : FVAL_TRAIL;

    // Size the back-porch counter from TRAIL itself. A fixed width would wrap
    // silently: at a width of 16, FVAL_TRAIL=65536 loads zero and FVAL would
    // never clear after EOF.
    function integer clogb2;
        input integer value;
        integer v;
        begin
            v = value;
            clogb2 = 0;
            while (v > 0) begin
                v = v >> 1;
                clogb2 = clogb2 + 1;
            end
        end
    endfunction
    localparam integer TRAIL_W = (TRAIL < 2) ? 1 : clogb2(TRAIL);

    // No backpressure exists downstream, so never apply any upstream.
    assign s_axis_tready = 1'b1;
    // With TREADY tied high, every cycle with TVALID is a transfer.
    wire in_beat = s_axis_tvalid;
    wire in_sof  = s_axis_tvalid && s_axis_tuser;

    // ---------------- pixel-path delay line (FVAL front porch) -------------
    // FVAL must rise before the first pixel, and the first pixel is not
    // announced in advance, so the only way to lead is to hold the pixels
    // back. FVAL is driven from the UNDELAYED SOF, LVAL/DVAL/PIX_DATA from
    // the delayed stream; the difference is exactly LEAD cycles.
    wire                   dly_valid;
    wire                   dly_last;
    wire                   dly_eof;
    wire [TDATA_WIDTH-1:0] dly_data;

    generate
    if (LEAD == 0) begin : g_no_lead
        assign dly_valid = in_beat;
        assign dly_last  = s_axis_tlast;
        assign dly_eof   = s_axis_eof;
        assign dly_data  = s_axis_tdata;
    end else begin : g_lead
        // Each stage carries {tdata, eof, tlast, valid}.
        localparam integer SW = TDATA_WIDTH + 3;
        reg [SW-1:0] sr [0:LEAD-1];
        integer k;
        always @(posedge aclk) begin
            if (!aresetn) begin
                for (k = 0; k < LEAD; k = k + 1)
                    sr[k] <= {SW{1'b0}};
            end else begin
                sr[0] <= {s_axis_tdata, s_axis_eof, s_axis_tlast, in_beat};
                for (k = 1; k < LEAD; k = k + 1)
                    sr[k] <= sr[k-1];
            end
        end
        assign dly_valid = sr[LEAD-1][0];
        assign dly_last  = sr[LEAD-1][1];
        assign dly_eof   = sr[LEAD-1][2];
        assign dly_data  = sr[LEAD-1][SW-1:3];
    end
    endgenerate

    // ---------------- LVAL --------------------------------------------------
    // LVAL spans the ACTIVE LINE, not the individual pixels: it goes high on
    // the first beat of a line and stays high through the last one, so a
    // mid-line bubble leaves LVAL high while DVAL drops -- which is the
    // Camera Link meaning of the two signals, and what makes the bubble
    // detectable below. With a gap-free source LVAL == DVAL exactly.
    reg lval_r;
    always @(posedge aclk) begin
        if (!aresetn)
            lval_r <= 1'b0;
        else if (dly_valid && dly_last)
            lval_r <= 1'b0;             // end of line: drop after this beat
        else if (dly_valid)
            lval_r <= 1'b1;             // inside a line
    end
    // OR in the current beat so LVAL covers the FIRST beat too (lval_r only
    // takes effect on the cycle after it).
    assign lval = lval_r || dly_valid;

    // ---------------- DVAL --------------------------------------------------
    assign dval     = dly_valid;
    assign pix_data = dly_data;

    // ---------------- FVAL --------------------------------------------------
    // Rises on the undelayed SOF (hence LEAD cycles ahead of LVAL), falls
    // TRAIL cycles after the delayed end-of-frame beat.
    reg              fval_r;
    reg [TRAIL_W-1:0] trail_cnt;
    wire             eof_beat = dly_valid && dly_eof;

    always @(posedge aclk) begin
        if (!aresetn) begin
            fval_r    <= 1'b0;
            trail_cnt <= {TRAIL_W{1'b0}};
        end else if (in_sof) begin
            // A new SOF re-arms FVAL and cancels any back porch still
            // counting. Note this does NOT rescue the case where the porches
            // overrun the vertical blanking: EOF is delayed by LEAD but SOF
            // is not, so a previous frame's delayed EOF can still arrive
            // AFTER this SOF and clear FVAL under the new frame. That is
            // unrepresentable rather than fixable -- the two frames overlap
            // inside the delay line -- so it is detected instead, see
            // envelope_err below.
            fval_r    <= 1'b1;
            trail_cnt <= {TRAIL_W{1'b0}};
        end else if (eof_beat) begin
            if (TRAIL == 0)
                fval_r <= 1'b0;         // drop right after the last pixel
            else
                trail_cnt <= TRAIL[TRAIL_W-1:0];
        end else if (trail_cnt != {TRAIL_W{1'b0}}) begin
            trail_cnt <= trail_cnt - 1'b1;
            if (trail_cnt == {{(TRAIL_W-1){1'b0}}, 1'b1})
                fval_r <= 1'b0;
        end
    end
    // OR in the SOF beat so FVAL covers the first pixel when LEAD == 0.
    assign fval = fval_r || in_sof;

    // ---------------- field ID ----------------------------------------------
    // fid is stable for every beat of a field (UG934), so latching it at SOF
    // and holding it presents it to the sink for the whole of FVAL.
    //
    // The registered copy alone is NOT enough: FVAL rises combinationally on
    // the SOF cycle, while field_id_r only updates on the following edge. A
    // receiver that latches the field ID on the FVAL rising edge -- the
    // normal thing to do -- would then sample the PREVIOUS field's parity on
    // every field. So drive the incoming fid directly on the SOF cycle, the
    // same way fval and lval fold in the current beat.
    reg field_id_r;
    always @(posedge aclk) begin
        if (!aresetn)
            field_id_r <= 1'b0;
        else if (in_sof)
            field_id_r <= s_axis_fid;
    end
    assign field_id = in_sof ? s_axis_fid : field_id_r;

    // ---------------- gap-free check ----------------------------------------
    // lval_r is high only strictly between a line's first and last beat, so
    // a cycle with lval_r high and no data is a bubble the parallel sink
    // cannot represent. Latch it rather than corrupting the raster silently.
    wire bubble = lval_r && !dly_valid;

    // ---------------- porch envelope check ----------------------------------
    // The porches are carved out of the vertical blanking, so they are only
    // realisable while FVAL_LEAD + FVAL_TRAIL is smaller than it. Past that,
    // FVAL cannot frame the two frames separately: a new SOF arrives while
    // the previous frame is still draining the delay line, and the frames
    // merge or the stale EOF cuts the new FVAL short. Flag it -- otherwise
    // the only symptom is a subtly wrong FVAL that looks plausible.
    reg frame_inflight;
    always @(posedge aclk) begin
        if (!aresetn)
            frame_inflight <= 1'b0;
        else if (in_sof)
            frame_inflight <= 1'b1;
        else if (eof_beat)
            frame_inflight <= 1'b0;
    end
    // A SOF while the previous frame has not reached its (delayed) EOF, or an
    // EOF with no frame open, both mean the envelope was violated.
    wire envelope_err = (in_sof && frame_inflight && !eof_beat) ||
                        (eof_beat && !frame_inflight && !in_sof);

    reg  timing_err_r;
    always @(posedge aclk) begin
        if (!aresetn)
            timing_err_r <= 1'b0;
        else if (timing_err_clr)
            timing_err_r <= 1'b0;
        else if (bubble || envelope_err)
            timing_err_r <= 1'b1;
    end
    assign timing_err = timing_err_r;

endmodule
