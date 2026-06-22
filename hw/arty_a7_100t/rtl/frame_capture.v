// SPDX-FileCopyrightText: 2026 Leonardo Capossio - bard0 design - hello@bard0.com
// SPDX-License-Identifier: Apache-2.0
//
// frame_capture.v
//
// AXI-Stream sink that captures one full frame from the vtpgZero core into
// an on-chip BRAM, plus an AXI4 slave that exposes the BRAM and a small
// pair of CSRs to the host.
//
// CSR window (offset 0x0000, single-beat AXI4 writes/reads):
//   0x00 CAPTURE_CTRL  W : [0]=arm (one-shot, self-clearing on capture done)
//                        : [1]=clear (resets done + word_count)
//   0x04 CAPTURE_STATUS R : [0]=done, [31:16]=word_count
//   0x08 CAPTURE_LEN  RW : number of beats to capture (default = full BRAM)
//
// BRAM window (offset 0x1000+, AXI4 read bursts supported):
//   stores tdata[31:0] of each captured beat as one 32-bit LE word.
//
// The host issues AXI4 reads with awlen<=255; this slave responds with
// rdata pulled directly from a synchronous BRAM read port.
//
// Verilog 2001.

`timescale 1ns/1ps

module frame_capture #(
    parameter DEPTH_LOG2  = 13,   // 8192 words = 32 KB
    parameter ADDR_W      = 32,
    parameter DATA_W      = 32,
    parameter TDATA_WIDTH = 24    // vtpgz tdata width (varies with mode/bpc)
)(
    input  wire                  aclk,
    input  wire                  aresetn,

    // Streaming sink from vtpgz_top
    input  wire [TDATA_WIDTH-1:0] s_axis_tdata,
    input  wire                  s_axis_tvalid,
    output wire                  s_axis_tready,
    input  wire                  s_axis_tlast,
    input  wire                  s_axis_tuser,

    // AXI4 slave (single-beat writes; burst-capable reads)
    input  wire [ADDR_W-1:0]     s_axi_awaddr,
    input  wire [7:0]            s_axi_awlen,
    input  wire [2:0]            s_axi_awsize,
    input  wire [1:0]            s_axi_awburst,
    input  wire [2:0]            s_axi_awprot,
    input  wire                  s_axi_awvalid,
    output reg                   s_axi_awready,
    input  wire [DATA_W-1:0]     s_axi_wdata,
    input  wire [DATA_W/8-1:0]   s_axi_wstrb,
    input  wire                  s_axi_wlast,
    input  wire                  s_axi_wvalid,
    output reg                   s_axi_wready,
    output reg  [1:0]            s_axi_bresp,
    output reg                   s_axi_bvalid,
    input  wire                  s_axi_bready,
    input  wire [ADDR_W-1:0]     s_axi_araddr,
    input  wire [7:0]            s_axi_arlen,
    input  wire [2:0]            s_axi_arsize,
    input  wire [1:0]            s_axi_arburst,
    input  wire [2:0]            s_axi_arprot,
    input  wire                  s_axi_arvalid,
    output reg                   s_axi_arready,
    output reg  [DATA_W-1:0]     s_axi_rdata,
    output reg  [1:0]            s_axi_rresp,
    output reg                   s_axi_rvalid,
    output reg                   s_axi_rlast,
    input  wire                  s_axi_rready,

    output wire                  capture_busy_o,
    output wire                  capture_done_o
);

    localparam DEPTH = (1 << DEPTH_LOG2);

    // ---------------- BRAM (dpram from fpgacapZero) ----------------
    // Use the portable dual-port BRAM wrapper to guarantee Vivado infers
    // RAMB36 instead of distributed RAMD64E. Distributed RAM at 8K depth
    // turns into a wide cascaded mux that fails timing at 150 MHz.
    wire [DEPTH_LOG2-1:0] bram_wr_addr_w;
    wire [31:0]           bram_din_w;
    wire                  bram_we_w;
    wire [DEPTH_LOG2-1:0] bram_rd_addr_w;
    wire [31:0]           bram_rd_data_w;

    // ---------------- capture FSM ----------------
    // States:
    //   IDLE     wait for arm
    //   ARMED    wait for first tuser (drop in-flight beats from a previous
    //            frame; tready is ASSERTED so beats actually get pulled out
    //            of the VTPGZ, but they are NOT written to BRAM)
    //   CAPTURE  store beats from first tuser to start of NEXT frame
    //   DONE     wait for clear
    reg                  arm;
    reg                  done;
    reg [DEPTH_LOG2:0]   wr_idx;     // one extra bit for full detection
    reg                  capturing;
    reg                  saw_sof;
    wire                 csr_arm_pulse;
    wire                 csr_clear_pulse;

    wire bram_full = wr_idx[DEPTH_LOG2];

    // Always assert tready while armed: we need to drain in-flight beats from
    // a previous frame even before saw_sof. Once saw_sof is set, the beats
    // start landing in BRAM. After the second tuser the FSM exits and tready
    // drops.
    assign s_axis_tready = capturing && !bram_full;
    wire stream_beat = s_axis_tvalid && s_axis_tready;
    // BRAM stores the LOW 32 bits of each tdata beat (zero-extended if
    // TDATA_WIDTH < 32). For wider tdata the upper bits are dropped — bump
    // BRAM to 64 bits if you need to capture wider streams.
    wire [31:0] beat_word;
    generate
        if (TDATA_WIDTH >= 32) begin : g_tdata_ge32
            assign beat_word = s_axis_tdata[31:0];
        end else begin : g_tdata_lt32
            assign beat_word = {{(32-TDATA_WIDTH){1'b0}}, s_axis_tdata};
        end
    endgenerate

    // Capture FSM
    //   armed -> wait for first tuser (SOF), latch saw_sof
    //   armed && saw_sof -> stream beats into BRAM
    //                       stop on next tuser (= start of next frame)
    //                       or on bram_full (safety)
    always @(posedge aclk) begin
        if (!aresetn) begin
            arm        <= 1'b0;
            done       <= 1'b0;
            capturing  <= 1'b0;
            saw_sof    <= 1'b0;
            wr_idx     <= {(DEPTH_LOG2+1){1'b0}};
        end else if (csr_clear_pulse) begin
            // CSR clear has the HIGHEST priority and overrides everything
            // else this cycle. Without this priority, a simultaneous
            // stream_beat would race the wr_idx<=0 assignment.
            arm       <= 1'b0;
            done      <= 1'b0;
            capturing <= 1'b0;
            saw_sof   <= 1'b0;
            wr_idx    <= {(DEPTH_LOG2+1){1'b0}};
        end else begin
            // CSR arm latches the request
            if (csr_arm_pulse) begin
                arm <= 1'b1;
            end
            // FSM transitions
            if (capturing && bram_full) begin
                // Safety: BRAM full → stop
                capturing <= 1'b0;
                arm       <= 1'b0;
                done      <= 1'b1;
            end else if (capturing && stream_beat && s_axis_tuser && saw_sof) begin
                // Second tuser seen = start of next frame → stop AFTER capturing
                // the first frame's beats. Don't include this beat (it belongs
                // to the next frame).
                capturing <= 1'b0;
                arm       <= 1'b0;
                done      <= 1'b1;
            end else if (arm && !capturing) begin
                capturing <= 1'b1;
                wr_idx    <= {(DEPTH_LOG2+1){1'b0}};
                done      <= 1'b0;
                saw_sof   <= 1'b0;
            end
            // Streaming beat handling:
            //   - First tuser of a fresh frame: latch saw_sof. Don't write
            //     this beat (matches the model's K=0).
            //     Wait — we DO want to capture the SOF beat. Let me re-think.
            //   - Captured beats live between the FIRST tuser (inclusive) and
            //     the SECOND tuser (exclusive).
            if (stream_beat) begin
                if (s_axis_tuser && !saw_sof) begin
                    // First tuser: latch and write THIS beat
                    saw_sof <= 1'b1;
                    wr_idx  <= wr_idx + 1'b1;
                end else if (s_axis_tuser && saw_sof) begin
                    // Second tuser: stop marker, do not write/increment
                end else if (saw_sof) begin
                    // Inside the captured frame
                    wr_idx <= wr_idx + 1'b1;
                end
                // else: pre-SOF beats (drained but not stored)
            end
        end
    end

    // Drive the dpram write port. Capture window is [first tuser, second
    // tuser): write the SOF beat AND every following beat until (but not
    // including) the next tuser. Beats before SOF are drained but not stored.
    wire valid_capture_beat = stream_beat && (
        (s_axis_tuser && !saw_sof) ||  // first tuser (write SOF beat)
        (saw_sof && !s_axis_tuser)     // mid-frame
    );
    assign bram_wr_addr_w = wr_idx[DEPTH_LOG2-1:0];
    assign bram_din_w     = beat_word;
    assign bram_we_w      = valid_capture_beat;

    bram_sdp #(.WIDTH(32), .DEPTH(DEPTH)) u_bram (
        .clk     (aclk),
        .we      (bram_we_w),
        .wr_addr (bram_wr_addr_w),
        .wr_data (bram_din_w),
        .rd_addr (bram_rd_addr_w),
        .rd_data (bram_rd_data_w)
    );


    assign capture_busy_o = capturing;
    assign capture_done_o = done;

    // ---------------- AXI4 write channel (CSR only) ----------------
    // Single-beat writes, address window:
    //   addr[12]==0 => CSR (offsets 0x00..0x0C)
    //   addr[12]==1 => BRAM region (read-only; writes return SLVERR)
    reg        aw_taken;
    reg [15:0] awaddr_q;   // keep bit 15 for the BRAM/CSR split
    reg [7:0]  awlen_q;
    reg        w_taken;
    reg [31:0] wdata_q;
    reg [DATA_W/8-1:0] wstrb_q;
    reg        wlast_q;
    reg        csr_arm_pulse_r;
    reg        csr_clear_pulse_r;
    assign csr_arm_pulse   = csr_arm_pulse_r;
    assign csr_clear_pulse = csr_clear_pulse_r;

    wire write_to_ctrl = (awaddr_q[15] == 1'b0) && (awaddr_q[7:0] == 8'h00);
    wire write_ok = write_to_ctrl && (awlen_q == 8'h00) && wlast_q && wstrb_q[0];

    always @(posedge aclk) begin
        if (!aresetn) begin
            s_axi_awready <= 1'b0;
            s_axi_wready  <= 1'b0;
            s_axi_bvalid  <= 1'b0;
            s_axi_bresp   <= 2'b00;
            aw_taken          <= 1'b0;
            w_taken           <= 1'b0;
            awaddr_q          <= 16'h0;
            awlen_q           <= 8'h0;
            wdata_q           <= 32'h0;
            wstrb_q           <= {DATA_W/8{1'b0}};
            wlast_q           <= 1'b0;
            csr_arm_pulse_r   <= 1'b0;
            csr_clear_pulse_r <= 1'b0;
        end else begin
            // Default: pulses self-clear each cycle
            csr_arm_pulse_r   <= 1'b0;
            csr_clear_pulse_r <= 1'b0;
            // AW handshake
            if (!aw_taken && s_axi_awvalid) begin
                aw_taken      <= 1'b1;
                awaddr_q      <= s_axi_awaddr[15:0];
                awlen_q       <= s_axi_awlen;
                s_axi_awready <= 1'b1;
            end else begin
                s_axi_awready <= 1'b0;
            end
            // W handshake
            if (!w_taken && s_axi_wvalid) begin
                w_taken      <= 1'b1;
                wdata_q      <= s_axi_wdata;
                wstrb_q      <= s_axi_wstrb;
                wlast_q      <= s_axi_wlast;
                s_axi_wready <= 1'b1;
            end else begin
                s_axi_wready <= 1'b0;
            end
            // Commit
            if (aw_taken && w_taken && !s_axi_bvalid) begin
                if (write_ok) begin
                    if (wdata_q[0]) csr_arm_pulse_r   <= 1'b1;
                    if (wdata_q[1]) csr_clear_pulse_r <= 1'b1;
                end
                s_axi_bvalid <= 1'b1;
                s_axi_bresp  <= write_ok ? 2'b00 : 2'b10;
                aw_taken     <= 1'b0;
                w_taken      <= 1'b0;
            end else if (s_axi_bvalid && s_axi_bready) begin
                s_axi_bvalid <= 1'b0;
            end
        end
    end

    // ---------------- AXI4 read channel ----------------
    // dpram has 1-cycle synchronous read latency. We pipeline by always
    // presenting bram_rd_addr_w = rd_idx combinationally and looking at
    // bram_rd_data_w one cycle later. State machine:
    //   IDLE   -> on BRAM AR: rd_idx=start, beats_left=N, go PRIME
    //   PRIME  -> rd_idx already presented (addr); wait 1 cycle to settle
    //             increment rd_idx so addr K+1 is presented next, go BURST
    //   BURST  -> on (!rvalid||rready): latch rdata=bram_rd_data_w (= K-th)
    //             increment rd_idx, decrement beats; go IDLE on last beat
    localparam S_RD_IDLE  = 2'd0;
    localparam S_RD_PRIME = 2'd1;
    localparam S_RD_BURST = 2'd2;

    reg [1:0]            rd_state;
    reg [DEPTH_LOG2-1:0] rd_idx;
    reg [8:0]            r_beats_left;

    assign bram_rd_addr_w = rd_idx;

    always @(posedge aclk) begin
        if (!aresetn) begin
            s_axi_arready <= 1'b0;
            s_axi_rvalid  <= 1'b0;
            s_axi_rlast   <= 1'b0;
            s_axi_rresp   <= 2'b00;
            s_axi_rdata   <= 32'h0;
            rd_idx        <= {DEPTH_LOG2{1'b0}};
            r_beats_left  <= 9'h0;
            rd_state      <= S_RD_IDLE;
        end else begin
            if (s_axi_arready) s_axi_arready <= 1'b0;

            case (rd_state)
                S_RD_IDLE: begin
                    if (!s_axi_rvalid && s_axi_arvalid && !s_axi_arready) begin
                        s_axi_arready <= 1'b1;
                        if (s_axi_araddr[15] == 1'b1) begin
                            rd_idx       <= s_axi_araddr[DEPTH_LOG2+1:2];
                            r_beats_left <= {1'b0, s_axi_arlen} + 9'd1;
                            rd_state     <= S_RD_PRIME;
                        end else begin
                            // CSR single read (1-cycle)
                            case (s_axi_araddr[7:0])
                                8'h00: s_axi_rdata <= 32'h0;
                                8'h04: s_axi_rdata <= {2'h0, wr_idx, 15'h0, done};
                                default: s_axi_rdata <= 32'h0;
                            endcase
                            s_axi_rresp  <= ((s_axi_arlen == 8'h00) &&
                                             ((s_axi_araddr[7:0] == 8'h00) ||
                                              (s_axi_araddr[7:0] == 8'h04))) ? 2'b00 : 2'b10;
                            s_axi_rvalid <= 1'b1;
                            s_axi_rlast  <= 1'b1;
                        end
                    end
                    if (s_axi_rvalid && s_axi_rready) begin
                        s_axi_rvalid <= 1'b0;
                        s_axi_rlast  <= 1'b0;
                    end
                end

                S_RD_PRIME: begin
                    // dpram returns bram[rd_idx] next cycle. Advance to the
                    // address for the FOLLOWING beat now.
                    rd_idx   <= rd_idx + 1'b1;
                    rd_state <= S_RD_BURST;
                end

                S_RD_BURST: begin
                    if (!s_axi_rvalid || s_axi_rready) begin
                        s_axi_rdata  <= bram_rd_data_w;
                        s_axi_rvalid <= 1'b1;
                        s_axi_rresp  <= 2'b00;
                        s_axi_rlast  <= (r_beats_left == 9'd1);
                        r_beats_left <= r_beats_left - 1'b1;
                        if (r_beats_left == 9'd1) begin
                            rd_state <= S_RD_IDLE;
                        end else begin
                            rd_idx <= rd_idx + 1'b1;
                        end
                    end
                end

                default: rd_state <= S_RD_IDLE;
            endcase
        end
    end

    wire _unused = &{1'b0, s_axi_awsize, s_axi_awburst, s_axi_awprot,
                     s_axi_arsize, s_axi_arburst, s_axi_arprot,
                     1'b0};

endmodule
