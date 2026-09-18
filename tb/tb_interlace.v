//-----------------------------------------------------------------------------
// tb_interlace.v - interlaced-video field ID (fid) regression
//
// Drives vtpgz_axilite_top with EN_INTERLACE=1 and checks the AMD/Xilinx
// AXI4-Stream video field convention (v_tpg PG103 / UG934):
//   * IMG_HEIGHT holds the FIELD height, so each sync pulse emits one field
//     of IMG_W*IMG_H beats with TUSER (SOF) on its first beat;
//   * fid is stable for every beat of a field and changes only at SOF;
//   * with internal sync the core alternates fid 0,1,0,1... (0 = even/top);
//   * with external sync fid follows fid_in, sampled on the sync edge;
//   * with CONTROL.interlace clear the stream is progressive and fid is 0;
//   * an EN_INTERLACE=0 build ties fid to 0 no matter what is programmed.
//
// SPDX-FileCopyrightText: 2026 Leonardo Capossio - bard0 design - hello@bard0.com
// SPDX-License-Identifier: Apache-2.0
//-----------------------------------------------------------------------------
`timescale 1ns/1ps
`include "vtpgz_defs.vh"

module tb_interlace;
    localparam integer IMG_W       = 16;
    localparam integer FIELD_H     = 8;    // lines per FIELD (frame height/2)
    localparam integer FIELD_BEATS = IMG_W * FIELD_H;

    // checker modes
    localparam integer CHK_PROG  = 0;   // fid must be 0 on every beat
    localparam integer CHK_ALT   = 1;   // fid alternates, first field = 0
    localparam integer CHK_EXT   = 2;   // fid must match exp_fid at each SOF

    reg aclk = 1'b0;
    always #5 aclk = ~aclk;
    reg aresetn = 1'b0;

    // AXI-Lite
    reg  [7:0]  awaddr;   reg awvalid;  wire awready;
    reg  [31:0] wdata;    reg [3:0] wstrb; reg wvalid; wire wready;
    wire [1:0]  bresp;    wire bvalid;  reg bready;
    reg  [7:0]  araddr;   reg arvalid;  wire arready;
    wire [31:0] rdata;    wire [1:0] rresp; wire rvalid; reg rready;

    // external sync stimulus
    reg frame_sync = 1'b0;
    reg fid_drive  = 1'b0;

    // AXI-Stream (interlace-capable instance)
    wire [23:0] m_tdata;
    wire        m_tvalid;
    reg         m_tready;
    wire        m_tlast, m_tuser, m_fid;

    vtpgz_axilite_top #(
        .C_S_AXI_ADDR_WIDTH(8),
        .C_S_AXI_DATA_WIDTH(32),
        .EN_INTERLACE(1)
    ) dut (
        .aclk(aclk), .aresetn(aresetn),
        .s_axi_awaddr(awaddr), .s_axi_awprot(3'b000), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_araddr(araddr), .s_axi_arprot(3'b000), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid), .s_axi_rready(rready),
        .m_axis_tdata(m_tdata), .m_axis_tvalid(m_tvalid), .m_axis_tready(m_tready),
        .m_axis_tlast(m_tlast), .m_axis_tuser(m_tuser), .eof(),
        .m_axis_tid(), .m_axis_tdest(), .fid(m_fid),
        .frame_sync_in(frame_sync), .fid_in(fid_drive)
    );

    // Parallel stripped instance (EN_INTERLACE=0) sharing the same writes:
    // its fid must stay tied to 0 even with CONTROL.interlace set.
    wire [23:0] m_tdata0;
    wire        m_tvalid0, m_tlast0, m_tuser0, m_fid0;

    vtpgz_axilite_top #(
        .C_S_AXI_ADDR_WIDTH(8),
        .C_S_AXI_DATA_WIDTH(32)
        // EN_INTERLACE defaults to 0 -> feature stripped
    ) dut0 (
        .aclk(aclk), .aresetn(aresetn),
        .s_axi_awaddr(awaddr), .s_axi_awprot(3'b000), .s_axi_awvalid(awvalid), .s_axi_awready(),
        .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid), .s_axi_wready(),
        .s_axi_bresp(), .s_axi_bvalid(), .s_axi_bready(bready),
        .s_axi_araddr(8'h0), .s_axi_arprot(3'b000), .s_axi_arvalid(1'b0), .s_axi_arready(),
        .s_axi_rdata(), .s_axi_rresp(), .s_axi_rvalid(), .s_axi_rready(1'b0),
        .m_axis_tdata(m_tdata0), .m_axis_tvalid(m_tvalid0), .m_axis_tready(m_tready),
        .m_axis_tlast(m_tlast0), .m_axis_tuser(m_tuser0), .eof(),
        .m_axis_tid(), .m_axis_tdest(), .fid(m_fid0),
        .frame_sync_in(frame_sync), .fid_in(fid_drive)
    );

    // Third instance: PIXELS_PER_CLOCK=4 + LINE_GAP_CYCLES=3, driven with a
    // randomized tready. Its checker is an INDEPENDENT oracle -- it derives
    // where SOF/EOL/fid must land from the count of accepted beats alone,
    // never from the DUT's own tuser, so a uniform one-beat shift of the
    // whole sideband group cannot hide.
    localparam integer G_PPC        = 4;
    localparam integer G_LINE_GAP   = 3;
    localparam integer G_BEATS_LINE = IMG_W / G_PPC;
    localparam integer G_FIELD_BEATS = G_BEATS_LINE * FIELD_H;

    reg             g_stall_hold = 1'b0;
    wire [4*24-1:0] g_tdata;
    wire            g_tvalid;
    reg             g_tready_r;
    wire            g_tready = g_tready_r && !g_stall_hold;
    wire            g_tlast, g_tuser, g_fid;

    vtpgz_axilite_top #(
        .C_S_AXI_ADDR_WIDTH(8),
        .C_S_AXI_DATA_WIDTH(32),
        .EN_INTERLACE(1),
        .PIXELS_PER_CLOCK(G_PPC),
        .LINE_GAP_CYCLES(G_LINE_GAP)
    ) dutg (
        .aclk(aclk), .aresetn(aresetn),
        .s_axi_awaddr(awaddr), .s_axi_awprot(3'b000), .s_axi_awvalid(awvalid), .s_axi_awready(),
        .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid), .s_axi_wready(),
        .s_axi_bresp(), .s_axi_bvalid(), .s_axi_bready(bready),
        .s_axi_araddr(8'h0), .s_axi_arprot(3'b000), .s_axi_arvalid(1'b0), .s_axi_arready(),
        .s_axi_rdata(), .s_axi_rresp(), .s_axi_rvalid(), .s_axi_rready(1'b0),
        .m_axis_tdata(g_tdata), .m_axis_tvalid(g_tvalid), .m_axis_tready(g_tready),
        .m_axis_tlast(g_tlast), .m_axis_tuser(g_tuser), .eof(),
        .m_axis_tid(), .m_axis_tdest(), .fid(g_fid),
        .frame_sync_in(frame_sync), .fid_in(fid_drive)
    );

    // ---------------- AXI-Lite tasks ----------------
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

    task axi_read;
        input  [7:0]  addr;
        output [31:0] data;
        begin
            @(posedge aclk);
            araddr <= addr; arvalid <= 1'b1; rready <= 1'b1;
            wait (arready && rvalid);
            data = rdata;
            @(posedge aclk);
            arvalid <= 1'b0; rready <= 1'b0;
        end
    endtask

    // ---------------- field checker ----------------
    integer errors       = 0;
    integer beats        = 0;   // beats seen so far in the current field
    integer fields       = 0;   // fields completed since check_en rose
    integer total_beats  = 0;
    reg     check_en     = 1'b0;
    integer chk_mode     = CHK_PROG;
    reg     exp_fid      = 1'b0;   // expected fid of the NEXT field to start
    reg     cur_fid      = 1'b0;   // fid latched at the SOF of this field
    reg     in_field     = 1'b0;

    always @(posedge aclk) begin
        if (!check_en) begin
            in_field <= 1'b0;
            beats     = 0;
        end else if (m_tvalid && m_tready) begin
            // Index-based oracle, independent of the DUT's own sidebands:
            // beat N of the stream must be SOF exactly when it opens a field
            // and TLAST exactly when it closes a line. This applies in every
            // mode, so a uniform one-beat shift of {tuser,tlast,fid} cannot
            // hide behind a self-consistent tuser.
            if (m_tuser !== ((total_beats % FIELD_BEATS) == 0)) begin
                errors = errors + 1;
                $display("ERROR: beat %0d tuser=%0b expected %0b",
                         total_beats, m_tuser, (total_beats % FIELD_BEATS) == 0);
            end
            if (m_tlast !== ((total_beats % IMG_W) == IMG_W - 1)) begin
                errors = errors + 1;
                $display("ERROR: beat %0d tlast=%0b expected %0b",
                         total_beats, m_tlast, (total_beats % IMG_W) == IMG_W - 1);
            end
            total_beats = total_beats + 1;
            if (m_tuser) begin
                // Start of a new field: the previous one must have been
                // exactly FIELD_BEATS long.
                if (in_field && beats != FIELD_BEATS) begin
                    errors = errors + 1;
                    $display("ERROR: field %0d had %0d beats, expected %0d",
                             fields, beats, FIELD_BEATS);
                end
                if (in_field) fields = fields + 1;
                if (m_fid !== exp_fid) begin
                    errors = errors + 1;
                    $display("ERROR: field %0d SOF fid=%0b expected %0b",
                             fields, m_fid, exp_fid);
                end
                cur_fid  <= m_fid;
                in_field <= 1'b1;
                beats     = 1;
                // Internal sync alternates; external sync follows fid_in
                // (the stimulus sets exp_fid before each pulse).
                if (chk_mode == CHK_ALT) exp_fid <= ~m_fid;
            end else begin
                beats = beats + 1;
                if (m_fid !== cur_fid) begin
                    errors = errors + 1;
                    $display("ERROR: fid changed mid-field (beat %0d, field %0d): %0b != %0b",
                             beats, fields, m_fid, cur_fid);
                end
            end
            if (chk_mode == CHK_PROG && m_fid !== 1'b0) begin
                errors = errors + 1;
                $display("ERROR: progressive stream drove fid=%0b", m_fid);
            end
        end
        // The stripped build must never assert fid.
        if (check_en && m_tvalid0 && m_tready && m_fid0 !== 1'b0) begin
            errors = errors + 1;
            $display("ERROR: EN_INTERLACE=0 instance drove fid=%0b", m_fid0);
        end
    end

    // ---------- independent scoreboard for the PPC=4 instance ----------
    // Every accepted beat index tells us, by itself, which field it belongs
    // to and where in that field it sits. fid must be the field parity,
    // tuser must be set exactly on the field's first beat, tlast exactly on
    // each line's last beat. Nothing here is derived from the DUT sidebands.
    integer g_idx      = 0;     // accepted beats since g_check_en rose
    reg     g_check_en = 1'b0;
    reg     g_hold_fid = 1'b0;  // 1 = expect a fixed fid (mid-field disable)
    reg     g_fid_held = 1'b0;
    integer g_lfsr     = 1;

    // Pseudo-random backpressure, including multi-cycle stalls. The coverage
    // counters below then PROVE that stalls actually landed on the SOF and
    // EOL beats -- the places a sideband-stability bug would hide -- instead
    // of leaving it to chance.
    // g_stall_hold is driven by the scoreboard block (which owns g_idx) to
    // FORCE a stall on the beats that matter -- SOF, EOL and the field's
    // final beat -- so the stability monitor is never left to chance. It is
    // a registered signal, so reading it here is ordering-safe.
    always @(posedge aclk) begin
        if (!aresetn) begin
            g_tready_r <= 1'b1;
            g_lfsr      = 1;
        end else begin
            g_lfsr     = {g_lfsr[30:0], g_lfsr[30] ^ g_lfsr[27]};
            g_tready_r <= (g_lfsr[2:0] != 3'b000);
        end
    end

    // AXI4-Stream stability: while a beat is offered and not accepted, none
    // of tdata/tuser/tlast/fid may change. This is what actually proves fid
    // is constant through the field rather than only on accepted beats.
    reg              g_stab_arm = 1'b0;
    reg [4*24-1:0]   g_stab_data;
    reg              g_stab_user, g_stab_last, g_stab_fid;
    always @(posedge aclk) begin
        if (!aresetn) begin
            g_stab_arm <= 1'b0;
        end else begin
            if (g_stab_arm && g_tvalid) begin
                if (g_tdata !== g_stab_data || g_tuser !== g_stab_user ||
                    g_tlast !== g_stab_last || g_fid   !== g_stab_fid) begin
                    errors = errors + 1;
                    $display("ERROR: ppc4 sideband changed while stalled (beat %0d)", g_idx);
                end
            end
            if (g_tvalid && !g_tready) begin
                g_stab_arm  <= 1'b1;
                g_stab_data <= g_tdata;
                g_stab_user <= g_tuser;
                g_stab_last <= g_tlast;
                g_stab_fid  <= g_fid;
            end else begin
                g_stab_arm  <= 1'b0;
            end
            // TVALID may not be deasserted before the beat is accepted.
            if (g_stab_arm && !g_tvalid) begin
                errors = errors + 1;
                $display("ERROR: ppc4 tvalid dropped before handshake (beat %0d)", g_idx);
            end
        end
    end

    integer g_gap_cnt = 0;
    reg     g_gap_arm = 1'b0;

    // Forced-stall state and the coverage it produces. Everything here lives
    // in the scoreboard block so it can use g_idx without racing it.
    integer g_stall_seen    = 0;   // cycles this target beat has been stalled
    integer g_cov_stall_sof = 0;
    integer g_cov_stall_eol = 0;
    integer g_cov_stall_eof = 0;

    always @(posedge aclk) begin
        // ---- coverage: did a stall actually land on those beats? ----
        if (g_check_en && g_tvalid && !g_tready) begin
            if ((g_idx % G_FIELD_BEATS) == 0)
                g_cov_stall_sof = g_cov_stall_sof + 1;
            if ((g_idx % G_BEATS_LINE) == G_BEATS_LINE - 1)
                g_cov_stall_eol = g_cov_stall_eol + 1;
            if ((g_idx % G_FIELD_BEATS) == G_FIELD_BEATS - 1)
                g_cov_stall_eof = g_cov_stall_eof + 1;
        end

        // Inter-line gap: after a non-final TLAST handshake the core must
        // insert exactly LINE_GAP_CYCLES TVALID-low cycles before the next
        // line. Checked in THIS block so it shares g_idx with the scoreboard
        // and cannot race it.
        if (!g_check_en) begin
            g_gap_arm <= 1'b0;
            g_gap_cnt  = 0;
        end else if (g_gap_arm) begin
            if (g_tvalid) begin
                if (g_gap_cnt != G_LINE_GAP) begin
                    errors = errors + 1;
                    $display("ERROR: ppc4 inter-line gap was %0d cycles, expected %0d (before beat %0d)",
                             g_gap_cnt, G_LINE_GAP, g_idx);
                end
                g_gap_arm <= 1'b0;
            end else begin
                g_gap_cnt = g_gap_cnt + 1;
            end
        end else if (g_tvalid && g_tready && g_tlast &&
                     ((g_idx % G_FIELD_BEATS) != G_FIELD_BEATS - 1)) begin
            g_gap_arm <= 1'b1;
            g_gap_cnt  = 0;
        end

        if (g_check_en && g_tvalid && g_tready) begin
            if (g_fid !== (g_hold_fid ? g_fid_held
                                      : ((g_idx / G_FIELD_BEATS) % 2) != 0)) begin
                errors = errors + 1;
                $display("ERROR: ppc4 beat %0d fid=%0b expected %0b",
                         g_idx, g_fid,
                         g_hold_fid ? g_fid_held
                                    : (((g_idx / G_FIELD_BEATS) % 2) != 0));
            end
            if (g_tuser !== ((g_idx % G_FIELD_BEATS) == 0)) begin
                errors = errors + 1;
                $display("ERROR: ppc4 beat %0d tuser=%0b expected %0b",
                         g_idx, g_tuser, (g_idx % G_FIELD_BEATS) == 0);
            end
            if (g_tlast !== ((g_idx % G_BEATS_LINE) == G_BEATS_LINE - 1)) begin
                errors = errors + 1;
                $display("ERROR: ppc4 beat %0d tlast=%0b expected %0b",
                         g_idx, g_tlast,
                         (g_idx % G_BEATS_LINE) == G_BEATS_LINE - 1);
            end
            g_idx = g_idx + 1;
            g_stall_seen = 0;      // re-arm the forced stall for the new index
        end

        // ---- forced stall, evaluated AFTER the index update so the hold is
        // ---- already asserted in the cycle the target beat is presented ----
        if (!g_check_en) begin
            g_stall_hold <= 1'b0;
            g_stall_seen  = 0;
        end else if (((g_idx % G_FIELD_BEATS) == 0) ||
                     ((g_idx % G_BEATS_LINE)  == G_BEATS_LINE - 1) ||
                     ((g_idx % G_FIELD_BEATS) == G_FIELD_BEATS - 1)) begin
            // Hold until the beat has actually been offered for a few cycles
            // (it may still be behind a line gap), then let it through.
            if (g_stall_seen < 4) begin
                g_stall_hold <= 1'b1;
                if (g_tvalid) g_stall_seen = g_stall_seen + 1;
            end else begin
                g_stall_hold <= 1'b0;
            end
        end else begin
            g_stall_hold <= 1'b0;
            g_stall_seen  = 0;
        end
    end

    // Checker-control handoffs happen on the NEGEDGE so they can never race
    // the scoreboard, which samples on the posedge.
    task g_start;
        begin
            @(negedge aclk);
            g_idx      = 0;
            g_hold_fid = 1'b0;
            g_cov_stall_sof = 0;
            g_cov_stall_eol = 0;
            g_cov_stall_eof = 0;
            g_check_en = 1'b1;
        end
    endtask

    task g_stop;
        begin
            @(negedge aclk);
            g_check_en = 1'b0;
            g_hold_fid = 1'b0;
        end
    endtask

    task g_hold_at;
        input f;
        begin
            @(negedge aclk);
            g_fid_held = f;
            g_hold_fid = 1'b1;
        end
    endtask

    // Wait until the PPC4 instance has been quiet for 64 straight cycles,
    // instead of assuming a fixed delay is enough to drain it.
    task g_wait_idle;
        integer quiet;
        begin
            quiet = 0;
            guard = 0;
            while (quiet < 64 && guard < 400000) begin
                @(posedge aclk);
                guard = guard + 1;
                if (g_tvalid) quiet = 0;
                else          quiet = quiet + 1;
            end
            if (quiet < 64) begin
                errors = errors + 1;
                $display("ERROR: ppc4 instance never went idle");
            end
        end
    endtask

    // ---------------- stimulus ----------------
    integer rb;
    integer guard;
    integer drain_idx;

    task program_geometry;
        begin
            axi_write(`VTPGZ_REG_CONTROL,     32'h0);          // disable
            axi_write(`VTPGZ_REG_IMG_WIDTH,   IMG_W);
            axi_write(`VTPGZ_REG_IMG_HEIGHT,  FIELD_H);        // FIELD height
            axi_write(`VTPGZ_REG_PATTERN_SEL, {28'h0, `VTPGZ_PAT_SOLID});
            axi_write(`VTPGZ_REG_SOLID_COLOR, 24'h20_40_60);
            axi_write(`VTPGZ_REG_FRAME_RATE,  32'd80);
        end
    endtask

    // Wait until n fields worth of beats have been emitted (or time out).
    task wait_fields;
        input integer n;
        begin
            guard = 0;
            while (total_beats < n * FIELD_BEATS && guard < 400000) begin
                @(posedge aclk);
                guard = guard + 1;
            end
            if (total_beats < n * FIELD_BEATS) begin
                errors = errors + 1;
                $display("ERROR: only %0d/%0d beats seen (timeout)",
                         total_beats, n * FIELD_BEATS);
            end
        end
    endtask

    // One external sync pulse with fid_in = f, then wait for that field.
    task ext_field;
        input f;
        integer want;
        begin
            exp_fid   = f;
            want      = total_beats + FIELD_BEATS;
            // Drive the sync/fid inputs with non-blocking assignments so the
            // DUT cannot sample them in the same delta as the clock edge.
            @(posedge aclk);
            fid_drive  <= f;
            frame_sync <= 1'b1;
            @(posedge aclk);
            frame_sync <= 1'b0;
            // Flip fid_in straight after the accepted edge: the field must
            // keep the parity sampled AT the edge, proving the core latched
            // it there rather than tracking the pin.
            @(posedge aclk);
            fid_drive <= ~f;
            guard = 0;
            while (total_beats < want && guard < 400000) begin
                @(posedge aclk);
                guard = guard + 1;
            end
            if (total_beats < want) begin
                errors = errors + 1;
                $display("ERROR: external-sync field (fid=%0b) timed out", f);
            end
        end
    endtask

    initial begin
        awaddr=0; awvalid=0; wdata=0; wstrb=0; wvalid=0; bready=0;
        araddr=0; arvalid=0; rready=0;
        m_tready = 1'b1;

        repeat (10) @(posedge aclk);
        aresetn = 1'b1;
        repeat (5) @(posedge aclk);

        program_geometry();

        // ---- Case 1: progressive (CONTROL.interlace = 0) ----
        chk_mode    = CHK_PROG;
        exp_fid     = 1'b0;
        total_beats = 0; fields = 0;
        check_en    = 1'b1;
        axi_write(`VTPGZ_REG_CONTROL, 32'h1);         // enable, internal sync
        wait_fields(3);
        check_en = 1'b0;
        axi_write(`VTPGZ_REG_CONTROL, 32'h0);
        repeat (20) @(posedge aclk);

        // ---- Case 2: interlaced, internal sync -> fid alternates 0,1,0,1 ----
        chk_mode    = CHK_ALT;
        exp_fid     = 1'b0;
        total_beats = 0; fields = 0;
        check_en    = 1'b1;
        axi_write(`VTPGZ_REG_CONTROL, 32'h9);         // enable | interlace
        wait_fields(4);
        if (fields < 3) begin
            errors = errors + 1;
            $display("ERROR: only %0d complete fields observed", fields);
        end
        // STATUS.field_id mirrors the source-side field.
        axi_read(`VTPGZ_REG_STATUS, rb);
        if (rb[1] !== 1'b0 && rb[1] !== 1'b1) begin
            errors = errors + 1;
            $display("ERROR: STATUS.field_id is not a valid bit (0x%08h)", rb);
        end
        check_en = 1'b0;
        axi_write(`VTPGZ_REG_CONTROL, 32'h0);
        repeat (20) @(posedge aclk);

        // ---- Case 3: interlaced, external sync -> fid follows fid_in ----
        chk_mode    = CHK_EXT;
        total_beats = 0; fields = 0;
        check_en    = 1'b1;
        axi_write(`VTPGZ_REG_CONTROL, 32'hD);         // enable | ext_sync | interlace
        ext_field(1'b0);
        ext_field(1'b1);
        ext_field(1'b1);   // a repeated field must NOT be auto-toggled
        ext_field(1'b0);
        check_en = 1'b0;
        axi_write(`VTPGZ_REG_CONTROL, 32'h0);

        repeat (20) @(posedge aclk);

        // ---- Case 4: PPC=4 + LINE_GAP_CYCLES=3 + random backpressure ----
        // Checked against the independent beat-index oracle above.
        g_start;
        axi_write(`VTPGZ_REG_CONTROL, 32'h9);         // enable | interlace
        guard = 0;
        while (g_idx < 3 * G_FIELD_BEATS && guard < 400000) begin
            @(posedge aclk);
            guard = guard + 1;
        end
        if (g_idx < 3 * G_FIELD_BEATS) begin
            errors = errors + 1;
            $display("ERROR: ppc4 only %0d/%0d beats seen (timeout)",
                     g_idx, 3 * G_FIELD_BEATS);
        end
        // The stability monitor above is only meaningful if stalls actually
        // landed on the SOF and EOL beats -- require that they did.
        if (g_cov_stall_sof == 0) begin
            errors = errors + 1;
            $display("ERROR: no stall ever landed on a SOF beat (stability check was vacuous)");
        end
        if (g_cov_stall_eol == 0) begin
            errors = errors + 1;
            $display("ERROR: no stall ever landed on an EOL beat (stability check was vacuous)");
        end
        if (g_cov_stall_eof == 0) begin
            errors = errors + 1;
            $display("ERROR: no stall ever landed on a field's final beat (stability check was vacuous)");
        end
        axi_write(`VTPGZ_REG_CONTROL, 32'h0);
        g_stop;
        g_wait_idle;

        // ---- Case 5: disable mid-field -> the draining field keeps its fid --
        // The timing engine runs an in-flight field to completion after
        // CONTROL is cleared (the documented reprogramming sequence). Every
        // beat of that tail must still carry the field's own fid.
        g_start;
        axi_write(`VTPGZ_REG_CONTROL, 32'h9);         // enable | interlace
        // Run into the middle of field 1 (the ODD field, fid=1).
        guard = 0;
        while (g_idx < G_FIELD_BEATS + (G_FIELD_BEATS / 2) && guard < 400000) begin
            @(posedge aclk);
            guard = guard + 1;
        end
        if (guard >= 400000) begin
            errors = errors + 1;
            $display("ERROR: ppc4 could not reach the middle of field 1");
        end
        // From here on every accepted beat must carry fid=1 until the field
        // drains -- including the beats emitted after the disable.
        g_hold_at(1'b1);
        axi_write(`VTPGZ_REG_CONTROL, 32'h0);         // disable MID-FIELD
        guard = 0;
        while (g_idx < 2 * G_FIELD_BEATS && guard < 400000) begin
            @(posedge aclk);
            guard = guard + 1;
        end
        if (g_idx < 2 * G_FIELD_BEATS) begin
            errors = errors + 1;
            $display("ERROR: field draining after mid-field disable stopped at beat %0d/%0d",
                     g_idx, 2 * G_FIELD_BEATS);
        end
        // ...and then generation must actually STOP: no further beat for
        // well over a frame-sync divider period (FRAME_RATE_DIV = 80).
        drain_idx = g_idx;
        repeat (1000) @(posedge aclk);
        if (g_idx != drain_idx) begin
            errors = errors + 1;
            $display("ERROR: %0d beat(s) emitted after the field drained (disable ignored)",
                     g_idx - drain_idx);
        end
        g_stop;

        // ---- Case 6: re-enable after a full stop restarts at the EVEN field --
        // cfg_enable went low across an idle edge, so the field parity is
        // reset; the first field of a fresh enable is field 0 (fid=0).
        g_start;
        axi_write(`VTPGZ_REG_CONTROL, 32'h9);
        guard = 0;
        while (g_idx < G_FIELD_BEATS && guard < 400000) begin
            @(posedge aclk);
            guard = guard + 1;
        end
        if (g_idx < G_FIELD_BEATS) begin
            errors = errors + 1;
            $display("ERROR: no field after re-enable (%0d beats)", g_idx);
        end
        axi_write(`VTPGZ_REG_CONTROL, 32'h0);
        g_stop;

        if (errors == 0)
            $display("PASS: tb_interlace field ID (fid)");
        else
            $display("FAIL: tb_interlace saw %0d errors", errors);
        $finish;
    end

    initial begin
        #10_000_000;
        $display("FAIL: tb_interlace TIMEOUT");
        $finish;
    end
endmodule
