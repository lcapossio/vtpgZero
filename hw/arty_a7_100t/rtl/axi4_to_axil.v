// SPDX-FileCopyrightText: 2026 Leonardo Capossio - bard0 design - hello@bard0.com
// SPDX-License-Identifier: Apache-2.0
//
// axi4_to_axil.v
//
// Tiny single-beat AXI4 -> AXI4-Lite shim. The fpgacapZero EJTAG-AXI bridge
// is a full AXI4 master; the vtpgZero register file is AXI4-Lite. This shim
// rejects burst transactions with SLVERR and forwards valid single-beat
// addr/data/valid/ready straight through.
//
// Verilog 2001.

`timescale 1ns/1ps

module axi4_to_axil #(
    parameter ADDR_W = 32,
    parameter DATA_W = 32
)(
    // AXI4 slave (from bridge)
    input  wire                  s_aclk,
    input  wire                  s_aresetn,
    input  wire [ADDR_W-1:0]     s_awaddr,
    input  wire [7:0]            s_awlen,    // expected = 0
    input  wire [2:0]            s_awsize,
    input  wire [1:0]            s_awburst,
    input  wire [2:0]            s_awprot,
    input  wire                  s_awvalid,
    output wire                  s_awready,
    input  wire [DATA_W-1:0]     s_wdata,
    input  wire [DATA_W/8-1:0]   s_wstrb,
    input  wire                  s_wlast,
    input  wire                  s_wvalid,
    output wire                  s_wready,
    output wire [1:0]            s_bresp,
    output wire                  s_bvalid,
    input  wire                  s_bready,
    input  wire [ADDR_W-1:0]     s_araddr,
    input  wire [7:0]            s_arlen,    // expected = 0
    input  wire [2:0]            s_arsize,
    input  wire [1:0]            s_arburst,
    input  wire [2:0]            s_arprot,
    input  wire                  s_arvalid,
    output wire                  s_arready,
    output wire [DATA_W-1:0]     s_rdata,
    output wire [1:0]            s_rresp,
    output wire                  s_rvalid,
    output wire                  s_rlast,    // we always set 1 for single beat
    input  wire                  s_rready,

    // AXI4-Lite master (to VTPGZ regs) — narrow address (8 bits is enough)
    output wire [7:0]            m_awaddr,
    output wire [2:0]            m_awprot,
    output wire                  m_awvalid,
    input  wire                  m_awready,
    output wire [DATA_W-1:0]     m_wdata,
    output wire [DATA_W/8-1:0]   m_wstrb,
    output wire                  m_wvalid,
    input  wire                  m_wready,
    input  wire [1:0]            m_bresp,
    input  wire                  m_bvalid,
    output wire                  m_bready,
    output wire [7:0]            m_araddr,
    output wire [2:0]            m_arprot,
    output wire                  m_arvalid,
    input  wire                  m_arready,
    input  wire [DATA_W-1:0]     m_rdata,
    input  wire [1:0]            m_rresp,
    input  wire                  m_rvalid,
    output wire                  m_rready
);

    reg       bad_wr_active;
    reg       bad_bvalid;
    reg       bad_rd_active;
    reg       bad_rvalid;
    reg [8:0] bad_rd_beats_left;

    wire bad_aw_len = |s_awlen;
    wire bad_ar_len = |s_arlen;

    wire bad_aw_ready = bad_aw_len && !bad_wr_active && !bad_bvalid && !m_bvalid;
    wire bad_aw_fire  = s_awvalid && bad_aw_ready;
    wire bad_w_ready  = bad_wr_active && !bad_bvalid;
    wire bad_w_fire   = s_wvalid && bad_w_ready;

    wire bad_ar_ready = bad_ar_len && !bad_rd_active && !bad_rvalid && !m_rvalid;
    wire bad_ar_fire  = s_arvalid && bad_ar_ready;

    always @(posedge s_aclk) begin
        if (!s_aresetn) begin
            bad_wr_active     <= 1'b0;
            bad_bvalid        <= 1'b0;
            bad_rd_active     <= 1'b0;
            bad_rvalid        <= 1'b0;
            bad_rd_beats_left <= 9'h0;
        end else begin
            if (bad_aw_fire) begin
                bad_wr_active <= 1'b1;
            end
            if (bad_w_fire && s_wlast) begin
                bad_wr_active <= 1'b0;
                bad_bvalid    <= 1'b1;
            end
            if (bad_bvalid && s_bready) begin
                bad_bvalid <= 1'b0;
            end

            if (bad_ar_fire) begin
                bad_rd_active     <= 1'b1;
                bad_rvalid        <= 1'b1;
                bad_rd_beats_left <= {1'b0, s_arlen} + 9'd1;
            end else if (bad_rvalid && s_rready) begin
                if (bad_rd_beats_left <= 9'd1) begin
                    bad_rd_active     <= 1'b0;
                    bad_rvalid        <= 1'b0;
                    bad_rd_beats_left <= 9'h0;
                end else begin
                    bad_rd_beats_left <= bad_rd_beats_left - 9'd1;
                end
            end
        end
    end

    // Pass-through for legal single-beat accesses; bursts are consumed locally.
    assign m_awaddr  = s_awaddr[7:0];
    assign m_awprot  = s_awprot;
    assign m_awvalid = s_awvalid && !bad_aw_len && !bad_wr_active && !bad_bvalid;
    assign s_awready = bad_aw_len ? bad_aw_ready :
                       ((!bad_wr_active && !bad_bvalid) ? m_awready : 1'b0);

    assign m_wdata   = s_wdata;
    assign m_wstrb   = s_wstrb;
    assign m_wvalid  = s_wvalid && !bad_wr_active && !bad_bvalid &&
                       !(s_awvalid && bad_aw_len);
    assign s_wready  = bad_wr_active ? bad_w_ready :
                       ((!bad_bvalid && !(s_awvalid && bad_aw_len)) ? m_wready : 1'b0);

    assign s_bresp   = bad_bvalid ? 2'b10 : m_bresp;
    assign s_bvalid  = bad_bvalid ? 1'b1  : m_bvalid;
    assign m_bready  = s_bready && !bad_bvalid;

    assign m_araddr  = s_araddr[7:0];
    assign m_arprot  = s_arprot;
    assign m_arvalid = s_arvalid && !bad_ar_len && !bad_rd_active && !bad_rvalid;
    assign s_arready = bad_ar_len ? bad_ar_ready :
                       ((!bad_rd_active && !bad_rvalid) ? m_arready : 1'b0);

    assign s_rdata   = bad_rvalid ? {DATA_W{1'b0}} : m_rdata;
    assign s_rresp   = bad_rvalid ? 2'b10 : m_rresp;
    assign s_rvalid  = bad_rvalid ? 1'b1  : m_rvalid;
    assign s_rlast   = bad_rvalid ? (bad_rd_beats_left <= 9'd1) : 1'b1;
    assign m_rready  = s_rready && !bad_rvalid;

    // Tie-off unused
    wire _unused = &{1'b0, s_awsize, s_awburst, s_arsize, s_arburst, 1'b0};

endmodule
