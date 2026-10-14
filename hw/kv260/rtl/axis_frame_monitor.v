// SPDX-FileCopyrightText: 2026 Leonardo Capossio - bard0 design - hello@bard0.com
// SPDX-License-Identifier: Apache-2.0
//
// axis_frame_monitor.v - AXI4-Stream video sink that measures a stream at
// full rate and fingerprints every frame.
//
// TREADY is held high, so the source runs as fast as it can. Per frame
// (SOF to the next SOF) the monitor records the beat and TLAST counts, the
// active time (SOF beat to the frame's last TLAST beat) and the period
// (SOF to SOF), the number of mid-line bubbles (cycles with TVALID low
// between a non-TLAST beat and the line's TLAST), and a CRC-32 of the
// frame's TDATA. The CRC is the zlib/IEEE one (reflected 0xEDB88320, init
// and final XOR 0xFFFFFFFF) over the beats as little-endian bytes, so a
// host computes the same value with zlib.crc32 over
// b"".join(beat.to_bytes(DATA_W // 8, "little") for beat in frame).
//
// A frame is closed by the next SOF; the first SOF after a clear only opens
// one. The CRC is split as crc' = S(crc) ^ D(tdata) (it is linear), with
// D(tdata) registered a stage ahead, so the wide XOR tree is off the
// CRC's feedback loop.
//
// AXI4-Lite registers (32-bit):
//   0x00 ID           RO 0x4D4F4E31 ("MON1")
//   0x04 CTRL         WO [0] clear all counters, [1] snapshot FRAMES/CYCLES
//   0x08 FRAMES       RO frames closed since clear
//   0x0C LAST_BEATS   RO beats in the last closed frame
//   0x10 LAST_LINES   RO TLAST beats in the last closed frame
//   0x14 LAST_ACTIVE  RO cycles from SOF beat to last TLAST beat, inclusive
//   0x18 LAST_PERIOD  RO cycles from SOF to the next SOF
//   0x1C LAST_CRC     RO CRC-32 of the last closed frame
//   0x20 FIRST_CRC    RO CRC-32 of the first frame closed after clear
//   0x24 CRC_CHANGES  RO closed frames whose CRC differs from the frame before
//   0x28 MIN_PERIOD   RO smallest LAST_PERIOD since clear
//   0x2C MAX_PERIOD   RO largest LAST_PERIOD since clear
//   0x30 BUBBLES      RO mid-line bubble cycles since clear
//   0x34 SNAP_FRAMES  RO FRAMES at the last snapshot
//   0x38 SNAP_CYC_LO  RO cycles since clear at the last snapshot, [31:0]
//   0x3C SNAP_CYC_HI  RO ... [47:32]
//
// Verilog-2001, synchronous reset active low, no vendor primitives.

`timescale 1ns/1ps

module axis_frame_monitor #(
    parameter integer DATA_W = 192,
    parameter integer C_S_AXI_ADDR_WIDTH = 8
)(
    input  wire                          aclk,
    input  wire                          aresetn,

    input  wire [DATA_W-1:0]             s_axis_tdata,
    input  wire                          s_axis_tvalid,
    output wire                          s_axis_tready,
    input  wire                          s_axis_tlast,
    input  wire                          s_axis_tuser,

    input  wire [C_S_AXI_ADDR_WIDTH-1:0] s_axi_awaddr,
    input  wire [2:0]                    s_axi_awprot,
    input  wire                          s_axi_awvalid,
    output reg                           s_axi_awready,
    input  wire [31:0]                   s_axi_wdata,
    input  wire [3:0]                    s_axi_wstrb,
    input  wire                          s_axi_wvalid,
    output reg                           s_axi_wready,
    output wire [1:0]                    s_axi_bresp,
    output reg                           s_axi_bvalid,
    input  wire                          s_axi_bready,
    input  wire [C_S_AXI_ADDR_WIDTH-1:0] s_axi_araddr,
    input  wire [2:0]                    s_axi_arprot,
    input  wire                          s_axi_arvalid,
    output reg                           s_axi_arready,
    output reg  [31:0]                   s_axi_rdata,
    output wire [1:0]                    s_axi_rresp,
    output reg                           s_axi_rvalid,
    input  wire                          s_axi_rready
);

    localparam [31:0] POLY = 32'hEDB88320;

    // CRC of DATA_W zero bits from state c (the state half).
    function [31:0] crc_s;
        input [31:0] c;
        integer i;
        reg [31:0] v;
        begin
            v = c;
            for (i = 0; i < DATA_W; i = i + 1)
                v = v[0] ? ((v >> 1) ^ POLY) : (v >> 1);
            crc_s = v;
        end
    endfunction

    // CRC of d from a zero state (the data half), bit 0 first.
    function [31:0] crc_d;
        input [DATA_W-1:0] d;
        integer i;
        reg [31:0] v;
        begin
            v = 32'h0;
            for (i = 0; i < DATA_W; i = i + 1)
                v = (v[0] ^ d[i]) ? ((v >> 1) ^ POLY) : (v >> 1);
            crc_d = v;
        end
    endfunction

    localparam [31:0] CRC_OPEN = crc_s(32'hFFFFFFFF);

    assign s_axis_tready = 1'b1;
    assign s_axi_bresp   = 2'b00;
    assign s_axi_rresp   = 2'b00;

    // ---- control ----
    reg clr, snap;

    // ---- stage 0: register the stream ----
    reg              s0_v, s0_sof, s0_last;
    reg [DATA_W-1:0] s0_d;
    always @(posedge aclk) begin
        s0_v    <= aresetn & s_axis_tvalid;
        s0_sof  <= s_axis_tuser;
        s0_last <= s_axis_tlast;
        s0_d    <= s_axis_tdata;
    end

    // ---- stage 1: counters, and the data half of the CRC ----
    reg [47:0] cyc;
    reg        open;          // an SOF has been seen since clear
    reg        in_line;       // between a non-TLAST beat and the TLAST
    reg [31:0] beats, lines, sof_cyc, tlast_cyc;
    reg [31:0] frames, last_beats, last_lines, last_active, last_period;
    reg [31:0] min_period, max_period, bubbles;
    reg [31:0] snap_frames;
    reg [47:0] snap_cyc;
    reg        s1_v, s1_sof;
    reg [31:0] s1_d;

    wire [31:0] period = cyc[31:0] - sof_cyc;

    always @(posedge aclk) begin
        s1_v   <= s0_v;
        s1_sof <= s0_v & s0_sof;
        s1_d   <= crc_d(s0_d);
        if (!aresetn || clr) begin
            cyc         <= 48'h0;
            open        <= 1'b0;
            in_line     <= 1'b0;
            beats       <= 32'h0;
            lines       <= 32'h0;
            sof_cyc     <= 32'h0;
            tlast_cyc   <= 32'h0;
            frames      <= 32'h0;
            last_beats  <= 32'h0;
            last_lines  <= 32'h0;
            last_active <= 32'h0;
            last_period <= 32'h0;
            min_period  <= 32'hFFFFFFFF;
            max_period  <= 32'h0;
            bubbles     <= 32'h0;
        end else begin
            cyc <= cyc + 48'h1;
            if (s0_v) begin
                if (s0_sof) begin
                    if (open) begin
                        frames      <= frames + 32'h1;
                        last_beats  <= beats;
                        last_lines  <= lines;
                        last_active <= tlast_cyc - sof_cyc + 32'h1;
                        last_period <= period;
                        if (period < min_period) min_period <= period;
                        if (period > max_period) max_period <= period;
                    end
                    open    <= 1'b1;
                    sof_cyc <= cyc[31:0];
                    beats   <= 32'h1;
                    lines   <= {31'h0, s0_last};
                end else begin
                    beats <= beats + 32'h1;
                    lines <= lines + {31'h0, s0_last};
                end
                if (s0_last) tlast_cyc <= cyc[31:0];
                in_line <= ~s0_last;
            end else if (open && in_line) begin
                bubbles <= bubbles + 32'h1;
            end
        end
        if (!aresetn) begin
            snap_frames <= 32'h0;
            snap_cyc    <= 48'h0;
        end else if (snap) begin
            snap_frames <= frames;
            snap_cyc    <= cyc;
        end
    end

    // ---- stage 2: the CRC loop ----
    reg [31:0] crc, last_crc, first_crc, crc_changes;
    reg        crc_open, have_first;
    always @(posedge aclk) begin
        if (!aresetn || clr) begin
            crc         <= 32'h0;
            crc_open    <= 1'b0;
            have_first  <= 1'b0;
            last_crc    <= 32'h0;
            first_crc   <= 32'h0;
            crc_changes <= 32'h0;
        end else if (s1_v) begin
            if (s1_sof) begin
                if (crc_open) begin
                    last_crc   <= ~crc;
                    have_first <= 1'b1;
                    if (!have_first)
                        first_crc <= ~crc;
                    else if (~crc != last_crc)
                        crc_changes <= crc_changes + 32'h1;
                end
                crc_open <= 1'b1;
                crc      <= CRC_OPEN ^ s1_d;
            end else if (crc_open) begin
                crc <= crc_s(crc) ^ s1_d;
            end
        end
    end

    // ---- AXI4-Lite slave ----
    always @(posedge aclk) begin
        clr  <= 1'b0;
        snap <= 1'b0;
        if (!aresetn) begin
            s_axi_awready <= 1'b0;
            s_axi_wready  <= 1'b0;
            s_axi_bvalid  <= 1'b0;
        end else begin
            s_axi_awready <= 1'b0;
            s_axi_wready  <= 1'b0;
            if (s_axi_awvalid && s_axi_wvalid && !s_axi_bvalid &&
                !s_axi_awready) begin
                s_axi_awready <= 1'b1;
                s_axi_wready  <= 1'b1;
                s_axi_bvalid  <= 1'b1;
                if (s_axi_awaddr[7:2] == 6'h01 && s_axi_wstrb[0]) begin
                    clr  <= s_axi_wdata[0];
                    snap <= s_axi_wdata[1];
                end
            end else if (s_axi_bvalid && s_axi_bready) begin
                s_axi_bvalid <= 1'b0;
            end
        end
    end

    always @(posedge aclk) begin
        if (!aresetn) begin
            s_axi_arready <= 1'b0;
            s_axi_rvalid  <= 1'b0;
            s_axi_rdata   <= 32'h0;
        end else begin
            s_axi_arready <= 1'b0;
            if (s_axi_arvalid && !s_axi_rvalid && !s_axi_arready) begin
                s_axi_arready <= 1'b1;
                s_axi_rvalid  <= 1'b1;
                case (s_axi_araddr[7:2])
                    6'h00: s_axi_rdata <= 32'h4D4F4E31;
                    6'h02: s_axi_rdata <= frames;
                    6'h03: s_axi_rdata <= last_beats;
                    6'h04: s_axi_rdata <= last_lines;
                    6'h05: s_axi_rdata <= last_active;
                    6'h06: s_axi_rdata <= last_period;
                    6'h07: s_axi_rdata <= last_crc;
                    6'h08: s_axi_rdata <= first_crc;
                    6'h09: s_axi_rdata <= crc_changes;
                    6'h0A: s_axi_rdata <= min_period;
                    6'h0B: s_axi_rdata <= max_period;
                    6'h0C: s_axi_rdata <= bubbles;
                    6'h0D: s_axi_rdata <= snap_frames;
                    6'h0E: s_axi_rdata <= snap_cyc[31:0];
                    6'h0F: s_axi_rdata <= {16'h0, snap_cyc[47:32]};
                    default: s_axi_rdata <= 32'h0;
                endcase
            end else if (s_axi_rvalid && s_axi_rready) begin
                s_axi_rvalid <= 1'b0;
            end
        end
    end

endmodule
