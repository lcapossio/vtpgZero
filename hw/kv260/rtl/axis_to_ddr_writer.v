// SPDX-FileCopyrightText: 2026 Leonardo Capossio - bard0 design - hello@bard0.com
// SPDX-License-Identifier: Apache-2.0
//
// axis_to_ddr_writer.v - AXI4-Stream -> AXI4 burst writer for DDR framebuffer
//
// Buffers BURST_LEN pixels then issues one AXI4 burst write.
// Partial bursts flush on tlast or SOF with pending data.
// The writer accepts only IMG_W*IMG_H pixels per frame; any surplus beats in
// a malformed frame are consumed and dropped until the next SOF.
// Pixel format: 24-bit {B,G,R} -> 32-bit {R,G,B,0xFF} (ABGR8888).
//
// Verilog-2001, synchronous reset active low, no vendor primitives.

`timescale 1ns/1ps

module axis_to_ddr_writer #(
    parameter [31:0] FB_BASE   = 32'h4C000000,
    parameter        IMG_W     = 1280,
    parameter        IMG_H     = 720,
    parameter        BURST_LEN = 16,
    parameter        M_AXI_ID_WIDTH   = 6,
    parameter        M_AXI_ADDR_WIDTH = 49,
    parameter        M_AXI_DATA_WIDTH = 32
)(
    input  wire                              aclk,
    input  wire                              aresetn,
    input  wire [23:0]                       s_axis_tdata,
    input  wire                              s_axis_tvalid,
    output wire                              s_axis_tready,
    input  wire                              s_axis_tlast,
    input  wire                              s_axis_tuser,
    output wire [M_AXI_ID_WIDTH-1:0]         m_axi_awid,
    output wire [M_AXI_ADDR_WIDTH-1:0]       m_axi_awaddr,
    output wire [7:0]                        m_axi_awlen,
    output wire [2:0]                        m_axi_awsize,
    output wire [1:0]                        m_axi_awburst,
    output wire                              m_axi_awlock,
    output wire [3:0]                        m_axi_awcache,
    output wire [2:0]                        m_axi_awprot,
    output wire [3:0]                        m_axi_awqos,
    output wire                              m_axi_awvalid,
    input  wire                              m_axi_awready,
    output wire [M_AXI_DATA_WIDTH-1:0]       m_axi_wdata,
    output wire [(M_AXI_DATA_WIDTH/8)-1:0]   m_axi_wstrb,
    output wire                              m_axi_wlast,
    output wire                              m_axi_wvalid,
    input  wire                              m_axi_wready,
    input  wire [M_AXI_ID_WIDTH-1:0]         m_axi_bid,
    input  wire [1:0]                        m_axi_bresp,
    input  wire                              m_axi_bvalid,
    output wire                              m_axi_bready,
    output wire [M_AXI_ID_WIDTH-1:0]         m_axi_arid,
    output wire [M_AXI_ADDR_WIDTH-1:0]       m_axi_araddr,
    output wire [7:0]                        m_axi_arlen,
    output wire [2:0]                        m_axi_arsize,
    output wire [1:0]                        m_axi_arburst,
    output wire                              m_axi_arlock,
    output wire [3:0]                        m_axi_arcache,
    output wire [2:0]                        m_axi_arprot,
    output wire [3:0]                        m_axi_arqos,
    output wire                              m_axi_arvalid,
    input  wire                              m_axi_arready,
    input  wire [M_AXI_ID_WIDTH-1:0]         m_axi_rid,
    input  wire [M_AXI_DATA_WIDTH-1:0]       m_axi_rdata,
    input  wire [1:0]                        m_axi_rresp,
    input  wire                              m_axi_rlast,
    input  wire                              m_axi_rvalid,
    output wire                              m_axi_rready
);

    function integer clog2;
        input integer val;
        integer i;
        begin
            clog2 = 0;
            for (i = val - 1; i > 0; i = i >> 1)
                clog2 = clog2 + 1;
        end
    endfunction
    localparam BUF_AW = (BURST_LEN == 1) ? 1 : clog2(BURST_LEN);
    localparam [31:0] FRAME_PIXELS = IMG_W * IMG_H;

    // Tied-off read channel
    assign m_axi_arid    = {M_AXI_ID_WIDTH{1'b0}};
    assign m_axi_araddr  = {M_AXI_ADDR_WIDTH{1'b0}};
    assign m_axi_arlen   = 8'h00;
    assign m_axi_arsize  = 3'b010;
    assign m_axi_arburst = 2'b01;
    assign m_axi_arlock  = 1'b0;
    assign m_axi_arcache = 4'b0000;
    assign m_axi_arprot  = 3'b000;
    assign m_axi_arqos   = 4'b0000;
    assign m_axi_arvalid = 1'b0;
    assign m_axi_rready  = 1'b1;

    // Pixel conversion
    wire [7:0] in_R = s_axis_tdata[ 7: 0];
    wire [7:0] in_G = s_axis_tdata[15: 8];
    wire [7:0] in_B = s_axis_tdata[23:16];
    wire [31:0] pix_word = {in_R, in_G, in_B, 8'hFF};

    // Pixel buffer
    reg [31:0] buf_data [0:BURST_LEN-1];
    reg [BUF_AW:0] buf_cnt;  // 0..BURST_LEN
    wire [7:0] buf_cnt_8 = {{(8-(BUF_AW+1)){1'b0}}, buf_cnt};

    // Address tracking: next_addr is the DDR byte address for the NEXT
    // pixel to be buffered. burst_start_addr is latched when we begin
    // a burst (= address of buf_data[0]).
    reg [M_AXI_ADDR_WIDTH-1:0] next_addr;
    reg [M_AXI_ADDR_WIDTH-1:0] burst_start_addr;
    reg [M_AXI_ADDR_WIDTH-1:0] cur_burst_addr;
    reg [31:0] pix_count;
    reg        sof_pending;

    // FSM
    localparam ST_FILL   = 2'd0;
    localparam ST_AW     = 2'd1;
    localparam ST_W      = 2'd2;
    localparam ST_WAIT_B = 2'd3;

    reg [1:0] state;
    reg [BUF_AW-1:0] beat_cnt;
    reg [7:0] burst_len_m1;

    wire frame_full = (pix_count >= FRAME_PIXELS);
    wire drop_pixel = frame_full && !s_axis_tuser;

    // tready: accept in FILL, but NOT if SOF with pending buffer data
    assign s_axis_tready = (state == ST_FILL) && !(s_axis_tuser && (buf_cnt != 0));

    // AW channel
    assign m_axi_awid    = {M_AXI_ID_WIDTH{1'b0}};
    assign m_axi_awaddr  = burst_start_addr;
    assign m_axi_awlen   = burst_len_m1;
    assign m_axi_awsize  = 3'b010;
    assign m_axi_awburst = 2'b01;
    assign m_axi_awlock  = 1'b0;
    assign m_axi_awcache = 4'b1111;
    assign m_axi_awprot  = 3'b010;
    assign m_axi_awqos   = 4'b0000;
    assign m_axi_awvalid = (state == ST_AW);

    // W channel
    assign m_axi_wdata  = buf_data[beat_cnt];
    assign m_axi_wstrb  = 4'b1111;
    assign m_axi_wlast  = (state == ST_W) && (beat_cnt == burst_len_m1[BUF_AW-1:0]);
    assign m_axi_wvalid = (state == ST_W);

    // B channel
    assign m_axi_bready = (state == ST_WAIT_B);

    wire [M_AXI_ADDR_WIDTH-1:0] fb_base_wide =
        {{(M_AXI_ADDR_WIDTH-32){1'b0}}, FB_BASE};

    integer i;
    always @(posedge aclk) begin
        if (!aresetn) begin
            state            <= ST_FILL;
            buf_cnt          <= 0;
            beat_cnt         <= 0;
            burst_len_m1     <= 8'd0;
            burst_start_addr <= {M_AXI_ADDR_WIDTH{1'b0}};
            cur_burst_addr   <= fb_base_wide;
            next_addr        <= fb_base_wide;
            pix_count        <= 32'h0;
            sof_pending      <= 1'b0;
            for (i = 0; i < BURST_LEN; i = i + 1)
                buf_data[i] <= 32'h0;
        end
        else begin
            case (state)

            ST_FILL: begin
                if (s_axis_tvalid && s_axis_tuser && (buf_cnt != 0)) begin
                    // SOF with pending data: flush partial buffer, don't consume pixel
                    burst_start_addr <= cur_burst_addr;
                    burst_len_m1     <= buf_cnt_8 - 8'd1;
                    sof_pending      <= 1'b1;
                    buf_cnt          <= 0;
                    state            <= ST_AW;
                end
                else if (s_axis_tvalid && s_axis_tready && drop_pixel) begin
                    // Consume malformed-frame overrun beats without writing
                    // past the configured framebuffer. A later SOF resumes
                    // normal writes from FB_BASE.
                end
                else if (s_axis_tvalid && s_axis_tready) begin
                    // Store pixel into buffer
                    buf_data[buf_cnt[BUF_AW-1:0]] <= pix_word;

                    // Track addresses
                    if (buf_cnt == 0) begin
                        // First pixel of this burst: latch start address
                        if (s_axis_tuser)
                            cur_burst_addr <= fb_base_wide;
                        else
                            cur_burst_addr <= next_addr;
                    end

                    // Update next_addr for the pixel AFTER this one
                    if (s_axis_tuser)
                        next_addr <= fb_base_wide + 4;
                    else
                        next_addr <= next_addr + 4;

                    if (s_axis_tuser)
                        pix_count <= 32'd1;
                    else if (!frame_full)
                        pix_count <= pix_count + 32'd1;

                    // Check flush: buffer full or end-of-line
                    if (buf_cnt + 1 == BURST_LEN[BUF_AW:0] || s_axis_tlast) begin
                        burst_start_addr <= (buf_cnt == 0)
                            ? (s_axis_tuser ? fb_base_wide : next_addr)
                            : cur_burst_addr;
                        burst_len_m1 <= buf_cnt_8;
                        buf_cnt      <= 0;
                        state        <= ST_AW;
                    end
                    else begin
                        buf_cnt <= buf_cnt + 1;
                    end
                end
            end

            ST_AW: begin
                if (m_axi_awready) begin
                    beat_cnt <= 0;
                    state    <= ST_W;
                end
            end

            ST_W: begin
                if (m_axi_wready) begin
                    if (beat_cnt == burst_len_m1[BUF_AW-1:0])
                        state <= ST_WAIT_B;
                    else
                        beat_cnt <= beat_cnt + 1;
                end
            end

            ST_WAIT_B: begin
                if (m_axi_bvalid) begin
                    if (sof_pending) begin
                        next_addr   <= fb_base_wide;
                        sof_pending <= 1'b0;
                    end
                    state <= ST_FILL;
                end
            end

            default: state <= ST_FILL;
            endcase
        end
    end

    /* verilator lint_off UNUSED */
    wire _unused = &{1'b0, m_axi_bid, m_axi_bresp,
                     m_axi_rid, m_axi_rdata, m_axi_rresp, m_axi_rlast,
                     m_axi_rvalid, m_axi_arready, IMG_W[0], IMG_H[0],
                     s_axis_tlast};
    /* verilator lint_on UNUSED */

endmodule
