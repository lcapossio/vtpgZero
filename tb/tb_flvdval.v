//-----------------------------------------------------------------------------
// tb_flvdval.v - AXI4-Stream -> FVAL/LVAL/DVAL adapter regression
//
// SPDX-FileCopyrightText: 2026 Leonardo Capossio - bard0 design - hello@bard0.com
// SPDX-License-Identifier: Apache-2.0
//
// Three DUT groups:
//   u_dut  : vtpgz_axilite_top (PPC=1, LINE_GAP_CYCLES=3, EN_INTERLACE=1)
//            feeding u_flv (FVAL_LEAD=0, FVAL_TRAIL=0) -- the raster checker
//   u_flvp : a second adapter on the SAME stream with FVAL_LEAD=4,
//            FVAL_TRAIL=6 -- the front/back porch checker
//   u_flvb : a third adapter driven by a hand-built stream that contains a
//            deliberate mid-line bubble -- the TIMING_ERR checker
//
// The raster properties asserted here are the ones a parallel video sink
// actually depends on, and they are derived from the geometry alone, not
// from the adapter's own outputs.
//-----------------------------------------------------------------------------

`timescale 1ns/1ps

module tb_flvdval;

    localparam integer W        = 16;   // IMG_WIDTH  (pixels = beats at PPC=1)
    localparam integer H        = 4;    // IMG_HEIGHT (FIELD height)
    localparam integer GAP      = 3;    // LINE_GAP_CYCLES
    localparam integer LEAD     = 4;    // FVAL front porch of u_flvp
    localparam integer TRAIL    = 6;    // FVAL back porch of u_flvp
    localparam integer TDW      = 24;   // RGB888, PPC=1
    localparam integer N_FRAMES = 4;    // fields to check
    localparam integer RATE_DIV = 200;  // FRAME_RATE_DIV (field period, cycles)

    // Blanking is NOT something the adapter can invent: it has no buffer, so
    // it can only reproduce the gaps the source already leaves. Those follow
    // from the source's geometry exactly:
    //   horizontal blanking = LINE_GAP_CYCLES, after every line but the last
    //   active time per field = W*H + GAP*(H-1)
    //   vertical blanking    = FRAME_RATE_DIV - active time
    // FVAL_LEAD + FVAL_TRAIL eat into the vertical blanking, so the porches
    // are only realisable while LEAD + TRAIL < VBLANK.
    localparam integer ACTIVE = W * H + GAP * (H - 1);
    localparam integer VBLANK = RATE_DIV - ACTIVE;

    integer errors = 0;

    task fail;
        input [1023:0] msg;
        begin
            $display("ERROR: %0s", msg);
            errors = errors + 1;
        end
    endtask

    reg aclk = 1'b0;
    reg aresetn = 1'b0;
    always #5 aclk = ~aclk;

    // ---------------- AXI4-Lite master ----------------
    reg  [7:0]  awaddr;  reg awvalid;  wire awready;
    reg  [31:0] wdata;   reg [3:0] wstrb; reg wvalid; wire wready;
    wire [1:0]  bresp;   wire bvalid;  reg bready;

    // ---------------- stream under test ----------------
    wire [TDW-1:0] m_tdata;
    wire           m_tvalid, m_tlast, m_tuser, m_eof, m_fid;
    wire           m_tready;

    vtpgz_axilite_top #(
        .PIXELS_PER_CLOCK (1),
        .LINE_GAP_CYCLES  (GAP),
        .EN_INTERLACE     (1)
    ) u_dut (
        .aclk(aclk), .aresetn(aresetn),
        .s_axi_awaddr(awaddr), .s_axi_awprot(3'b000),
        .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(wstrb),
        .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_araddr(8'h0), .s_axi_arprot(3'b000), .s_axi_arvalid(1'b0),
        .s_axi_arready(), .s_axi_rdata(), .s_axi_rresp(), .s_axi_rvalid(),
        .s_axi_rready(1'b0),
        .m_axis_tdata(m_tdata), .m_axis_tvalid(m_tvalid),
        .m_axis_tready(m_tready), .m_axis_tlast(m_tlast),
        .m_axis_tuser(m_tuser), .eof(m_eof),
        .m_axis_tid(), .m_axis_tdest(),
        .fid(m_fid), .frame_sync_in(1'b0), .fid_in(1'b0)
    );

    // ---------------- adapter under test (no porches) ----------------
    wire [TDW-1:0] pix_data;
    wire           fval, lval, dval, field_id, timing_err;

    vtpgz_axis_to_flvdval #(
        .TDATA_WIDTH(TDW), .FVAL_LEAD(0), .FVAL_TRAIL(0)
    ) u_flv (
        .aclk(aclk), .aresetn(aresetn),
        .s_axis_tdata(m_tdata), .s_axis_tvalid(m_tvalid),
        .s_axis_tready(m_tready), .s_axis_tlast(m_tlast),
        .s_axis_tuser(m_tuser), .s_axis_eof(m_eof), .s_axis_fid(m_fid),
        .pix_data(pix_data), .fval(fval), .lval(lval), .dval(dval),
        .field_id(field_id),
        .timing_err(timing_err), .timing_err_clr(1'b0)
    );

    // ---------------- adapter with front/back porches ----------------
    wire [TDW-1:0] p_pix_data;
    wire           p_fval, p_lval, p_dval, p_timing_err;

    vtpgz_axis_to_flvdval #(
        .TDATA_WIDTH(TDW), .FVAL_LEAD(LEAD), .FVAL_TRAIL(TRAIL)
    ) u_flvp (
        .aclk(aclk), .aresetn(aresetn),
        .s_axis_tdata(m_tdata), .s_axis_tvalid(m_tvalid),
        .s_axis_tready(), .s_axis_tlast(m_tlast),
        .s_axis_tuser(m_tuser), .s_axis_eof(m_eof), .s_axis_fid(m_fid),
        .pix_data(p_pix_data), .fval(p_fval), .lval(p_lval), .dval(p_dval),
        .field_id(),
        .timing_err(p_timing_err), .timing_err_clr(1'b0)
    );

    // =====================================================================
    // Checker 1: raster shape on the zero-porch adapter
    //
    // Everything below is derived from W / H / GAP, never from the adapter.
    // =====================================================================
    reg        lval_q  = 1'b0;
    reg        fval_q  = 1'b0;
    integer    run_len = 0;     // cycles LVAL has been high
    integer    gap_len = 0;     // cycles LVAL has been low inside a frame
    integer    lines   = 0;     // LVAL pulses inside the current frame
    integer    frames  = 0;     // completed frames
    integer    dvals   = 0;     // DVAL cycles inside the current frame
    reg [31:0] fid_seq = 32'h0; // field_id per frame, oldest in the MSBs
    reg        saw_fval_low_between = 1'b0;

    integer vb_len = 0;     // cycles FVAL has been low
    integer vb_seen = 0;
    reg [31:0] fid_at_rise = 32'h0;
    integer    fid_rises = 0;

    // Blocking assignments in an explicit order: the end-of-line increment
    // must be visible to the end-of-frame check in the SAME cycle, because
    // with FVAL_TRAIL=0 both edges land together.
    always @(posedge aclk) begin
        if (!aresetn) begin
            lval_q = 1'b0; fval_q = 1'b0;
            run_len = 0; gap_len = 0; lines = 0; dvals = 0; vb_len = 0;
        end else begin
            // ---- illegal combinations --------------------------------
            // dval && !lval is structurally impossible at LEAD=0 (lval is
            // lval_r || dly_valid); kept as a cheap guard against future
            // refactors of the LVAL expression.
            if (dval && !lval)
                fail("DVAL asserted while LVAL low");
            if (lval && !fval)
                fail("LVAL asserted while FVAL low");
            if (dval !== lval)
                fail("DVAL and LVAL differ: the source left a mid-line gap");
            if (timing_err)
                fail("TIMING_ERR latched on a gap-free source");

            // ---- end of a line ---------------------------------------
            if (lval_q && !lval) begin
                if (run_len !== W)
                    fail("LVAL high for the wrong number of cycles");
                lines = lines + 1;
            end

            // ---- start of a line, inside a frame ----------------------
            if (!lval_q && lval && (lines > 0) && fval) begin
                if (gap_len !== GAP)
                    fail("horizontal blanking is not LINE_GAP_CYCLES wide");
            end

            // ---- end of a frame (reads the increment just made) -------
            if (fval_q && !fval) begin
                if (lines !== H)
                    fail("FVAL did not enclose IMG_HEIGHT lines");
                if (dvals !== W * H)
                    fail("wrong number of DVAL pixels in the frame");
                fid_seq = {fid_seq[30:0], field_id};
                frames  = frames + 1;
                lines   = 0;
                dvals   = 0;
            end

            // ---- start of a frame: sample FIELD_ID the way a receiver
            //      that latches on the FVAL edge would see it -------------
            if (!fval_q && fval) begin
                fid_at_rise = {fid_at_rise[30:0], field_id};
                fid_rises   = fid_rises + 1;
            end
            if (!fval_q && fval && (frames > 0)) begin
                if (vb_len !== VBLANK)
                    fail("vertical blanking is not FRAME_RATE_DIV - active");
                vb_seen = vb_seen + 1;
            end

            // ---- accumulate for THIS cycle ----------------------------
            if (lval) begin
                run_len = run_len + 1;
                gap_len = 0;
            end else begin
                run_len = 0;
                if (fval) gap_len = gap_len + 1;
            end
            if (fval) vb_len = 0;
            else      vb_len = vb_len + 1;
            if (dval) dvals = dvals + 1;

            lval_q = lval;
            fval_q = fval;
        end
    end

    // FVAL must actually go low between frames (vertical blanking exists).
    always @(posedge aclk) begin
        if (aresetn && !fval && (frames > 0))
            saw_fval_low_between <= 1'b1;
    end

    // Pixel passthrough: on every DVAL the adapter must present exactly the
    // beat the stream carried, and never invent or drop one.
    //
    // Be honest about what this proves: at FVAL_LEAD=0 pix_data is a direct
    // combinational assignment and dval is m_tvalid, so these two checks are
    // structural tautologies -- they are wiring regressions, not proof that
    // data cannot be lost or duplicated. The checks that DO bite are the
    // per-frame DVAL count against W*H (derived from the geometry, below)
    // and, on u_flvp, the comparison against an independent testbench-side
    // delay line where the adapter really can get it wrong.
    integer axis_beats = 0;
    integer dval_beats = 0;
    always @(posedge aclk) begin
        if (aresetn) begin
            if (m_tvalid && m_tready) axis_beats = axis_beats + 1;
            if (dval) begin
                dval_beats = dval_beats + 1;
                if (pix_data !== m_tdata)
                    fail("PIX_DATA does not match the AXIS beat");
            end
        end
    end

    // =====================================================================
    // Checker 2: front/back porch on u_flvp
    //
    // FVAL must rise exactly LEAD cycles before the first LVAL and fall
    // exactly TRAIL cycles after the last one. Measured, not assumed.
    // =====================================================================
    reg     p_fval_q = 1'b0, p_lval_q = 1'b0;
    integer p_lead_cnt = 0, p_trail_cnt = 0;
    reg     p_in_lead = 1'b0, p_in_trail = 1'b0;
    integer p_lead_seen = 0, p_trail_seen = 0;
    // TB-side copy of the delay line, to prove the pixel path is really
    // delayed by LEAD and not merely re-timed.
    reg [TDW-1:0] p_ref [0:LEAD-1];
    reg           p_ref_v [0:LEAD-1];
    integer       q;

    always @(posedge aclk) begin
        if (!aresetn) begin
            p_fval_q <= 1'b0; p_lval_q <= 1'b0;
            p_in_lead <= 1'b0; p_in_trail <= 1'b0;
            p_lead_cnt <= 1; p_trail_cnt <= 1;
            for (q = 0; q < LEAD; q = q + 1) begin
                p_ref[q]   <= {TDW{1'b0}};
                p_ref_v[q] <= 1'b0;
            end
        end else begin
            p_fval_q <= p_fval;
            p_lval_q <= p_lval;

            // shift the reference delay line
            p_ref[0]   <= m_tdata;
            p_ref_v[0] <= m_tvalid && m_tready;
            for (q = 1; q < LEAD; q = q + 1) begin
                p_ref[q]   <= p_ref[q-1];
                p_ref_v[q] <= p_ref_v[q-1];
            end
            if (p_dval !== p_ref_v[LEAD-1])
                fail("delayed DVAL is not the stream delayed by FVAL_LEAD");
            if (p_dval && (p_pix_data !== p_ref[LEAD-1]))
                fail("delayed PIX_DATA is not the stream delayed by FVAL_LEAD");

            // front porch: cycles from FVAL rising to LVAL rising
            if (!p_fval_q && p_fval) begin
                p_in_lead  <= 1'b1;
                p_lead_cnt <= 1;   // this cycle is already porch
            end else if (p_in_lead) begin
                if (p_lval) begin
                    p_in_lead <= 1'b0;
                    if (p_lead_cnt !== LEAD)
                        fail("FVAL front porch is not FVAL_LEAD cycles");
                    p_lead_seen = p_lead_seen + 1;
                end else begin
                    p_lead_cnt <= p_lead_cnt + 1;
                end
            end

            // back porch: cycles from the last LVAL falling to FVAL falling
            if (p_lval_q && !p_lval) begin
                p_in_trail  <= 1'b1;
                p_trail_cnt <= 1;  // this cycle is already porch
            end else if (p_in_trail) begin
                if (!p_fval) begin
                    p_in_trail <= 1'b0;
                    if (p_trail_cnt !== TRAIL)
                        fail("FVAL back porch is not FVAL_TRAIL cycles");
                    p_trail_seen = p_trail_seen + 1;
                end else if (p_lval) begin
                    p_in_trail <= 1'b0;   // not the last line after all
                end else begin
                    p_trail_cnt <= p_trail_cnt + 1;
                end
            end
        end
    end

    // =====================================================================
    // Checker 3: TIMING_ERR on a source that stalls mid-line
    //
    // Hand-built stream, so the bubble is deliberate and its position known.
    // =====================================================================
    reg  [TDW-1:0] b_tdata  = {TDW{1'b0}};
    reg            b_tvalid = 1'b0, b_tlast = 1'b0, b_tuser = 1'b0, b_eof = 1'b0;
    reg            b_clr    = 1'b0;
    wire           b_timing_err, b_lval, b_dval, b_fval;

    vtpgz_axis_to_flvdval #(
        .TDATA_WIDTH(TDW), .FVAL_LEAD(0), .FVAL_TRAIL(0)
    ) u_flvb (
        .aclk(aclk), .aresetn(aresetn),
        .s_axis_tdata(b_tdata), .s_axis_tvalid(b_tvalid),
        .s_axis_tready(), .s_axis_tlast(b_tlast),
        .s_axis_tuser(b_tuser), .s_axis_eof(b_eof), .s_axis_fid(1'b0),
        .pix_data(), .fval(b_fval), .lval(b_lval), .dval(b_dval),
        .field_id(),
        .timing_err(b_timing_err), .timing_err_clr(b_clr)
    );

    // Emit one line of `len` beats; insert `bubble_at` idle cycles after
    // beat `bubble_at` (0 = no bubble).
    task b_line;
        input integer len;
        input integer bubble_at;
        input         is_sof;
        input         is_eof;
        integer i;
        begin
            for (i = 0; i < len; i = i + 1) begin
                @(negedge aclk);
                b_tdata  <= i[TDW-1:0];
                b_tvalid <= 1'b1;
                b_tuser  <= is_sof && (i == 0);
                b_tlast  <= (i == len - 1);
                b_eof    <= is_eof && (i == len - 1);
                @(posedge aclk);
                if ((bubble_at != 0) && (i == bubble_at)) begin
                    @(negedge aclk);
                    b_tvalid <= 1'b0; b_tuser <= 1'b0;
                    b_tlast  <= 1'b0; b_eof <= 1'b0;
                    repeat (3) @(posedge aclk);
                end
            end
            @(negedge aclk);
            b_tvalid <= 1'b0; b_tuser <= 1'b0; b_tlast <= 1'b0; b_eof <= 1'b0;
        end
    endtask

    // A fourth adapter on the hand-built stream, this one with a front porch,
    // to exercise the porch-envelope violation: with FVAL_LEAD=4 a frame's
    // EOF lands 4 cycles after its last beat, so blanking shorter than that
    // makes the next SOF arrive while the previous frame is still in flight.
    reg  b_clr2 = 1'b0;
    wire e_timing_err;

    vtpgz_axis_to_flvdval #(
        .TDATA_WIDTH(TDW), .FVAL_LEAD(4), .FVAL_TRAIL(0)
    ) u_flve (
        .aclk(aclk), .aresetn(aresetn),
        .s_axis_tdata(b_tdata), .s_axis_tvalid(b_tvalid),
        .s_axis_tready(), .s_axis_tlast(b_tlast),
        .s_axis_tuser(b_tuser), .s_axis_eof(b_eof), .s_axis_fid(1'b0),
        .pix_data(), .fval(), .lval(), .dval(), .field_id(),
        .timing_err(e_timing_err), .timing_err_clr(b_clr2)
    );

    // ---------------- AXI-Lite write ----------------
    task axi_write;
        input [7:0]  addr;
        input [31:0] data;
        begin
            @(posedge aclk);
            awaddr <= addr; awvalid <= 1'b1;
            wdata  <= data; wstrb <= 4'hF; wvalid <= 1'b1;
            bready <= 1'b1;
            wait (awready && wready);
            @(posedge aclk);
            awvalid <= 1'b0; wvalid <= 1'b0;
            wait (bvalid);
            @(posedge aclk);
            bready <= 1'b0;
        end
    endtask

    // ---------------- stimulus ----------------
    integer f;
    initial begin
        awvalid = 1'b0; wvalid = 1'b0; bready = 1'b0; wstrb = 4'h0;
        awaddr  = 8'h0; wdata = 32'h0;

        repeat (8) @(posedge aclk);
        aresetn <= 1'b1;
        repeat (4) @(posedge aclk);

        // ---- case 1: gap-free source -> clean raster ----
        axi_write(8'h10, W);                 // IMG_WIDTH
        axi_write(8'h14, H);                 // IMG_HEIGHT = FIELD height
        axi_write(8'h18, 32'd0);             // PATTERN = COLORBAR
        axi_write(8'h44, W / 8);             // BAR_WIDTH
        axi_write(8'h28, {16'd4, 16'd2});    // BOX_SIZE
        axi_write(8'h40, RATE_DIV);           // FRAME_RATE_DIV (field rate)
        axi_write(8'h08, 32'h9);             // enable + interlace

        wait (frames == N_FRAMES);
        axi_write(8'h08, 32'h0);             // disable
        repeat (20) @(posedge aclk);

        if (!saw_fval_low_between)
            fail("FVAL never went low between frames (no vertical blanking)");
        if (axis_beats !== dval_beats)
            fail("DVAL count does not match the number of AXIS beats");
        if (p_lead_seen < N_FRAMES)
            fail("front porch was not observed on every frame");
        if (p_trail_seen < N_FRAMES)
            fail("back porch was not observed on every frame");
        if (vb_seen < N_FRAMES - 1)
            fail("vertical blanking was not measured between frames");
        if (LEAD + TRAIL >= VBLANK)
            fail("test geometry is invalid: porches exceed vertical blanking");
        // Interlaced source: consecutive fields must alternate, starting at 0.
        for (f = 0; f < N_FRAMES; f = f + 1) begin
            if (fid_seq[N_FRAMES-1-f] !== (f % 2))
                fail("FIELD_ID did not alternate across fields");
            // FVAL rises combinationally on SOF, so FIELD_ID must be right
            // ON that cycle -- a receiver latching it there must not see the
            // previous field's parity.
            if (fid_at_rise[N_FRAMES-1-f] !== (f % 2))
                fail("FIELD_ID wrong at the FVAL rising edge");
        end
        if (fid_rises < N_FRAMES)
            fail("FVAL rising edges were not observed for every field");

        // ---- case 2: TIMING_ERR stays clear on a gap-free hand stream ----
        b_line(8, 0, 1'b1, 1'b0);
        repeat (GAP) @(posedge aclk);
        b_line(8, 0, 1'b0, 1'b1);
        repeat (4) @(posedge aclk);
        if (b_timing_err !== 1'b0)
            fail("TIMING_ERR latched on a gap-free hand-built stream");

        // ---- case 3: a mid-line bubble must latch TIMING_ERR ----
        b_line(8, 3, 1'b1, 1'b0);            // stall after beat 3
        repeat (4) @(posedge aclk);
        if (b_timing_err !== 1'b1)
            fail("TIMING_ERR did NOT latch on a mid-line bubble");

        // ---- case 4: the sticky bit clears on request ----
        @(negedge aclk); b_clr <= 1'b1;
        @(posedge aclk);
        @(negedge aclk); b_clr <= 1'b0;
        repeat (2) @(posedge aclk);
        if (b_timing_err !== 1'b0)
            fail("TIMING_ERR did not clear on timing_err_clr");

        // ---- case 5: porch envelope violated -> TIMING_ERR --------------
        // Case 3's bubble line deliberately carries no EOF, so it left a
        // frame open in every adapter watching this stream. Close it before
        // clearing, or the first SOF below is itself a genuine violation.
        b_line(8, 0, 1'b0, 1'b1);
        repeat (12) @(posedge aclk);
        // Clear the porch instance: it has been watching the same hand-built
        // stream, including case 3's deliberate bubble.
        @(negedge aclk); b_clr2 <= 1'b1;
        @(posedge aclk);
        @(negedge aclk); b_clr2 <= 1'b0;
        repeat (2) @(posedge aclk);

        // Generous blanking (> FVAL_LEAD): must stay clean.
        b_line(8, 0, 1'b1, 1'b1);
        repeat (12) @(posedge aclk);
        b_line(8, 0, 1'b1, 1'b1);
        repeat (12) @(posedge aclk);
        if (e_timing_err !== 1'b0)
            fail("envelope TIMING_ERR latched with blanking wider than the porch");

        // Blanking shorter than FVAL_LEAD: the next SOF arrives while the
        // previous frame is still draining the delay line.
        b_line(8, 0, 1'b1, 1'b1);
        repeat (2) @(posedge aclk);
        b_line(8, 0, 1'b1, 1'b1);
        repeat (12) @(posedge aclk);
        if (e_timing_err !== 1'b1)
            fail("TIMING_ERR did NOT latch when the porch overran the blanking");

        if (errors == 0)
            $display("PASS: tb_flvdval FVAL/LVAL/DVAL adapter");
        else
            $display("FAIL: tb_flvdval -- %0d error(s)", errors);
        $finish;
    end

    initial begin
        #500000;
        $display("FAIL: tb_flvdval timeout");
        $finish;
    end

endmodule
