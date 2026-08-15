//-----------------------------------------------------------------------------
// tb_stream_route.v - AXI4-Stream routing sideband (TID/TDEST) regression
//
// Drives vtpgz_axilite_top with TID_WIDTH/TDEST_WIDTH > 0, programs the
// STREAM_ROUTE register (0x5C = {tdest[31:16], tid[15:0]}) over AXI-Lite, and
// verifies that every emitted AXIS beat carries the configured tid/tdest on
// m_axis_tid / m_axis_tdest. Also checks that writing 0 clears them and that a
// parallel TID_WIDTH=0 instance ties both sidebands to 0 (feature stripped).
//
// SPDX-FileCopyrightText: 2026 Leonardo Capossio - bard0 design - hello@bard0.com
// SPDX-License-Identifier: Apache-2.0
//-----------------------------------------------------------------------------
`timescale 1ns/1ps
`include "vtpgz_defs.vh"

module tb_stream_route;
    localparam integer TID_W   = 4;   // routed instance sideband widths
    localparam integer TDEST_W = 3;
    localparam integer IMG_W   = 16;
    localparam integer IMG_H   = 8;
    localparam integer FRAME_BEATS = IMG_W * IMG_H;

    reg aclk = 1'b0;
    always #5 aclk = ~aclk;
    reg aresetn = 1'b0;

    // AXI-Lite
    reg  [7:0]  awaddr;   reg awvalid;  wire awready;
    reg  [31:0] wdata;    reg [3:0] wstrb; reg wvalid; wire wready;
    wire [1:0]  bresp;    wire bvalid;  reg bready;
    reg  [7:0]  araddr;   reg arvalid;  wire arready;
    wire [31:0] rdata;    wire [1:0] rresp; wire rvalid; reg rready;

    // AXI-Stream (routed instance: TID_WIDTH/TDEST_WIDTH > 0)
    wire [23:0]        m_tdata;
    wire               m_tvalid;
    reg                m_tready;
    wire               m_tlast;
    wire               m_tuser;
    wire [TID_W-1:0]   m_tid;
    wire [TDEST_W-1:0] m_tdest;

    vtpgz_axilite_top #(
        .C_S_AXI_ADDR_WIDTH(8),
        .C_S_AXI_DATA_WIDTH(32),
        .TID_WIDTH  (TID_W),
        .TDEST_WIDTH(TDEST_W)
    ) dut (
        .aclk(aclk), .aresetn(aresetn),
        .s_axi_awaddr(awaddr), .s_axi_awprot(3'b000), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_araddr(araddr), .s_axi_arprot(3'b000), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid), .s_axi_rready(rready),
        .m_axis_tdata(m_tdata), .m_axis_tvalid(m_tvalid), .m_axis_tready(m_tready),
        .m_axis_tlast(m_tlast), .m_axis_tuser(m_tuser),
        .m_axis_tid(m_tid), .m_axis_tdest(m_tdest),
        .frame_sync_in(1'b0)
    );

    // Parallel stripped instance (TID_WIDTH=0/TDEST_WIDTH=0 defaults) sharing
    // the same AXI-Lite writes: its sidebands must stay tied to 0.
    wire [23:0] m_tdata0;
    wire        m_tvalid0, m_tlast0, m_tuser0;
    wire        m_tid0;    // 1-bit tie-off when width is 0
    wire        m_tdest0;

    vtpgz_axilite_top #(
        .C_S_AXI_ADDR_WIDTH(8),
        .C_S_AXI_DATA_WIDTH(32)
        // TID_WIDTH / TDEST_WIDTH default to 0 -> feature stripped
    ) dut0 (
        .aclk(aclk), .aresetn(aresetn),
        .s_axi_awaddr(awaddr), .s_axi_awprot(3'b000), .s_axi_awvalid(awvalid), .s_axi_awready(),
        .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid), .s_axi_wready(),
        .s_axi_bresp(), .s_axi_bvalid(), .s_axi_bready(bready),
        .s_axi_araddr(8'h0), .s_axi_arprot(3'b000), .s_axi_arvalid(1'b0), .s_axi_arready(),
        .s_axi_rdata(), .s_axi_rresp(), .s_axi_rvalid(), .s_axi_rready(1'b0),
        .m_axis_tdata(m_tdata0), .m_axis_tvalid(m_tvalid0), .m_axis_tready(m_tready),
        .m_axis_tlast(m_tlast0), .m_axis_tuser(m_tuser0),
        .m_axis_tid(m_tid0), .m_axis_tdest(m_tdest0),
        .frame_sync_in(1'b0)
    );

    // ---------------- AXI-Lite write task ----------------
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

    // ---------------- AXI-Lite read task ----------------
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

    // ---------------- sideband checker ----------------
    integer errors = 0;
    integer beats  = 0;
    reg check_en = 1'b0;
    reg [TID_W-1:0]   exp_tid   = {TID_W{1'b0}};
    reg [TDEST_W-1:0] exp_tdest = {TDEST_W{1'b0}};

    always @(posedge aclk) begin
        if (check_en && m_tvalid && m_tready) begin
            beats = beats + 1;
            if (m_tid !== exp_tid) begin
                errors = errors + 1;
                $display("ERROR: m_axis_tid=0x%0h expected 0x%0h (beat %0d)", m_tid, exp_tid, beats);
            end
            if (m_tdest !== exp_tdest) begin
                errors = errors + 1;
                $display("ERROR: m_axis_tdest=0x%0h expected 0x%0h (beat %0d)", m_tdest, exp_tdest, beats);
            end
            // Stripped instance must always drive 0 regardless of STREAM_ROUTE.
            if (m_tvalid0 && (m_tid0 !== 1'b0 || m_tdest0 !== 1'b0)) begin
                errors = errors + 1;
                $display("ERROR: stripped instance tid0=%0b tdest0=%0b (expected 0)", m_tid0, m_tdest0);
            end
        end
    end

    // ---------------- stimulus ----------------
    integer rb;
    task program_frame;
        begin
            axi_write(`VTPGZ_REG_CONTROL,     32'h0);           // disable
            axi_write(`VTPGZ_REG_IMG_WIDTH,   IMG_W);
            axi_write(`VTPGZ_REG_IMG_HEIGHT,  IMG_H);
            axi_write(`VTPGZ_REG_PATTERN_SEL, {28'h0, `VTPGZ_PAT_SOLID});
            axi_write(`VTPGZ_REG_SOLID_COLOR, 24'h20_40_60);
            axi_write(`VTPGZ_REG_FRAME_RATE,  32'd80);
        end
    endtask

    // Run one frame's worth of beats and require FRAME_BEATS clean beats.
    task run_frame;
        integer guard;
        begin
            beats = 0;
            check_en = 1'b1;
            axi_write(`VTPGZ_REG_CONTROL, 32'h1);   // enable, internal sync
            guard = 0;
            while (beats < FRAME_BEATS && guard < 200000) begin
                @(posedge aclk);
                guard = guard + 1;
            end
            check_en = 1'b0;
            axi_write(`VTPGZ_REG_CONTROL, 32'h0);
            if (beats < FRAME_BEATS) begin
                errors = errors + 1;
                $display("ERROR: only %0d/%0d beats seen (timeout)", beats, FRAME_BEATS);
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

        program_frame();

        // ---- Case 1: nonzero tid/tdest ----
        exp_tid   = 4'hA;
        exp_tdest = 3'h5;
        axi_write(`VTPGZ_REG_STREAM_ROUTE, (32'h0005 << 16) | 32'h000A);
        axi_read(`VTPGZ_REG_STREAM_ROUTE, rb);
        if (rb !== 32'h0005_000A) begin
            errors = errors + 1;
            $display("ERROR: STREAM_ROUTE readback=0x%08h expected 0x0005000A", rb);
        end
        run_frame();

        // ---- Case 2: different value, take effect on next stream ----
        exp_tid   = 4'h3;
        exp_tdest = 3'h6;
        axi_write(`VTPGZ_REG_STREAM_ROUTE, (32'h0006 << 16) | 32'h0003);
        run_frame();

        // ---- Case 3: clear to 0 ----
        exp_tid   = 4'h0;
        exp_tdest = 3'h0;
        axi_write(`VTPGZ_REG_STREAM_ROUTE, 32'h0);
        run_frame();

        if (errors == 0)
            $display("PASS: tb_stream_route TID/TDEST sideband routing");
        else
            $display("FAIL: tb_stream_route saw %0d errors", errors);
        $finish;
    end

    initial begin
        #5_000_000;
        $display("FAIL: tb_stream_route TIMEOUT");
        $finish;
    end
endmodule
