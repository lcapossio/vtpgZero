// SPDX-FileCopyrightText: 2026 Leonardo Capossio - bard0 design - hello@bard0.com
// SPDX-License-Identifier: Apache-2.0
//
// demo_top.v - vtpgZero Arty A7-100T board demo
//
// Hierarchy:
//   demo_top
//   ├── clk_gen                       (100 MHz passthrough + reset sync)
//   ├── fcapz_ejtagaxi_xilinx7        (JTAG-to-AXI bridge on USER4, from fpgacapZero)
//   ├── axi4_to_axil                  (single-beat shim for the VTPGZ region)
//   ├── vtpgz_axilite_top                       (the DUT, unchanged)
//   └── frame_capture                 (AXIS sink + BRAM + AXI4 slave)
//
// Address map (32-bit byte address as seen from the JTAG-AXI master):
//   0x0000_0000..0x0000_00FF  VTPGZ AXI4-Lite registers
//   0x0001_0000               CAPTURE_CTRL
//   0x0001_0004               CAPTURE_STATUS
//   0x0001_1000..0x0001_1FFF  FRAME_BRAM (read window, 1024 words = 4 KB
//                              -- enough for 64x32 = 2048 pixels at 32 b/word
//                              wait: 2048 pixels * 4 B = 8 KB, so use up to
//                              0x0001_2FFF for an 8 KB capture)
//
// Address routing: any AXI4 transaction with addr[16]==0 goes to the VTPGZ
// register file shim, and any with addr[16]==1 goes to frame_capture.
//
// LEDs:
//   LD0 = heartbeat (~0.75 Hz)
//   LD1 = VTPGZ enable status
//   LD2 = capture done
//   LD3 = stream activity (any tvalid && tready)
//
// Verilog 2001.

`timescale 1ns/1ps

module demo_top (
    input  wire CLK100MHZ,
    input  wire btn0,           // active-high reset
    output wire led0,
    output wire led1,
    output wire led2,
    output wire led3
);

    // ---------------- clock & reset ----------------
    wire clk;
    wire rst_n;
    clk_gen u_clkgen (
        .clk_in    (CLK100MHZ),
        .reset_btn (btn0),
        .clk_out   (clk),
        .rst_n     (rst_n)
    );

    // ---------------- JTAG-to-AXI4 bridge (fpgacapZero) ----------------
    wire [31:0] br_awaddr;
    wire [7:0]  br_awlen;
    wire [2:0]  br_awsize;
    wire [1:0]  br_awburst;
    wire        br_awvalid, br_awready;
    wire [2:0]  br_awprot;
    wire [31:0] br_wdata;
    wire [3:0]  br_wstrb;
    wire        br_wvalid, br_wready, br_wlast;
    wire [1:0]  br_bresp;
    wire        br_bvalid, br_bready;
    wire [31:0] br_araddr;
    wire [7:0]  br_arlen;
    wire [2:0]  br_arsize;
    wire [1:0]  br_arburst;
    wire        br_arvalid, br_arready;
    wire [2:0]  br_arprot;
    wire [31:0] br_rdata;
    wire [1:0]  br_rresp;
    wire        br_rvalid, br_rlast, br_rready;

    fcapz_ejtagaxi_xilinx7 #(
        // FIFO_DEPTH=16 keeps 16-beat bursts (and satisfies the XPM 16-min).
        // CMD/RESP at 16-deep instead of the default 2*FIFO_DEPTH=32 halves
        // their storage; forcing CMD to "distributed" moves the 16x85b CMD
        // queue out of BRAM into LUTRAM.  Together these claw back ~2 BRAM
        // tiles vs the v0.3.0-118 default, with a small LUT/FF trade-off.
        // (Matches the upstream fcapz Arty A7 reference recipe from 49769e5.)
        .ADDR_W(32), .DATA_W(32),
        .FIFO_DEPTH(16),
        .CMD_FIFO_DEPTH(16),
        .RESP_FIFO_DEPTH(16),
        .CMD_FIFO_MEMORY_TYPE("distributed"),
        .TIMEOUT(4096), .CHAIN(4)
    ) u_ejtagaxi (
        .axi_clk     (clk),
        .axi_rst     (~rst_n),
        .m_axi_awaddr(br_awaddr),  .m_axi_awlen (br_awlen),
        .m_axi_awsize(br_awsize),  .m_axi_awburst(br_awburst),
        .m_axi_awvalid(br_awvalid),.m_axi_awready(br_awready),
        .m_axi_awprot(br_awprot),
        .m_axi_wdata (br_wdata),   .m_axi_wstrb (br_wstrb),
        .m_axi_wvalid(br_wvalid),  .m_axi_wready(br_wready),
        .m_axi_wlast (br_wlast),
        .m_axi_bresp (br_bresp),   .m_axi_bvalid(br_bvalid),
        .m_axi_bready(br_bready),
        .m_axi_araddr(br_araddr),  .m_axi_arlen (br_arlen),
        .m_axi_arsize(br_arsize),  .m_axi_arburst(br_arburst),
        .m_axi_arvalid(br_arvalid),.m_axi_arready(br_arready),
        .m_axi_arprot(br_arprot),
        .m_axi_rdata (br_rdata),   .m_axi_rresp (br_rresp),
        .m_axi_rvalid(br_rvalid),  .m_axi_rlast (br_rlast),
        .m_axi_rready(br_rready)
    );

    // ---------------- address routing ----------------
    // Decode addr[16]: 0 = VTPGZ regs, 1 = frame_capture
    // Latch the AW/AR target so the response routes back correctly.
    // Writes are kept single-outstanding at this mux: W is not accepted until
    // the matching AW has selected a target, so W-before-AW cannot be routed
    // using a stale address bit.
    reg aw_target;  // 0=vtpgz, 1=fcap
    reg aw_active;
    reg ar_target;
    always @(posedge clk) begin
        if (!rst_n) begin
            aw_target <= 1'b0;
            aw_active <= 1'b0;
            ar_target <= 1'b0;
        end else begin
            if (br_awvalid && br_awready) begin
                aw_target <= br_awaddr[16];
                aw_active <= 1'b1;
            end else if (br_bvalid && br_bready) begin
                aw_active <= 1'b0;
            end
            if (br_arvalid && br_arready) ar_target <= br_araddr[16];
        end
    end

    wire vtpgz_aw_valid = br_awvalid && !aw_active && (br_awaddr[16] == 1'b0);
    wire fc_aw_valid  = br_awvalid && !aw_active && (br_awaddr[16] == 1'b1);
    wire vtpgz_ar_valid = br_arvalid && (br_araddr[16] == 1'b0);
    wire fc_ar_valid  = br_arvalid && (br_araddr[16] == 1'b1);

    // Route W only after AW is known. Same-cycle AW/W handshakes use
    // br_awaddr[16]; W-before-AW is backpressured until AW arrives.
    wire aw_accept      = br_awvalid && br_awready;
    wire aw_target_live = aw_active ? aw_target : br_awaddr[16];
    wire aw_target_known = aw_active || aw_accept;

    // ---------------- VTPGZ region (axi4 -> axil shim -> vtpgz) ----------------
    wire [7:0]  vtpgz_axil_awaddr;
    wire        vtpgz_axil_awvalid, vtpgz_axil_awready;
    wire [2:0]  vtpgz_axil_awprot;
    wire [31:0] vtpgz_axil_wdata;
    wire [3:0]  vtpgz_axil_wstrb;
    wire        vtpgz_axil_wvalid, vtpgz_axil_wready;
    wire [1:0]  vtpgz_axil_bresp;
    wire        vtpgz_axil_bvalid, vtpgz_axil_bready;
    wire [7:0]  vtpgz_axil_araddr;
    wire        vtpgz_axil_arvalid, vtpgz_axil_arready;
    wire [2:0]  vtpgz_axil_arprot;
    wire [31:0] vtpgz_axil_rdata;
    wire [1:0]  vtpgz_axil_rresp;
    wire        vtpgz_axil_rvalid, vtpgz_axil_rready;

    // Shim AXI4 outputs (from VTPGZ side)
    wire        shim_awready, shim_wready;
    wire [1:0]  shim_bresp;
    wire        shim_bvalid;
    wire        shim_arready;
    wire [31:0] shim_rdata;
    wire [1:0]  shim_rresp;
    wire        shim_rvalid;
    wire        shim_rlast;

    axi4_to_axil #(.ADDR_W(32), .DATA_W(32)) u_shim (
        .s_aclk    (clk),     .s_aresetn (rst_n),
        .s_awaddr  (br_awaddr),
        .s_awlen   (br_awlen),
        .s_awsize  (br_awsize),
        .s_awburst (br_awburst),
        .s_awprot  (br_awprot),
        .s_awvalid (vtpgz_aw_valid),
        .s_awready (shim_awready),
        .s_wdata   (br_wdata),
        .s_wstrb   (br_wstrb),
        .s_wlast   (br_wlast),
        .s_wvalid  (br_wvalid && aw_target_known && (aw_target_live == 1'b0)),
        .s_wready  (shim_wready),
        .s_bresp   (shim_bresp),
        .s_bvalid  (shim_bvalid),
        .s_bready  (br_bready && aw_active && (aw_target == 1'b0)),
        .s_araddr  (br_araddr),
        .s_arlen   (br_arlen),
        .s_arsize  (br_arsize),
        .s_arburst (br_arburst),
        .s_arprot  (br_arprot),
        .s_arvalid (vtpgz_ar_valid),
        .s_arready (shim_arready),
        .s_rdata   (shim_rdata),
        .s_rresp   (shim_rresp),
        .s_rvalid  (shim_rvalid),
        .s_rlast   (shim_rlast),
        .s_rready  (br_rready && (ar_target == 1'b0)),

        .m_awaddr  (vtpgz_axil_awaddr),
        .m_awprot  (vtpgz_axil_awprot),
        .m_awvalid (vtpgz_axil_awvalid),
        .m_awready (vtpgz_axil_awready),
        .m_wdata   (vtpgz_axil_wdata),
        .m_wstrb   (vtpgz_axil_wstrb),
        .m_wvalid  (vtpgz_axil_wvalid),
        .m_wready  (vtpgz_axil_wready),
        .m_bresp   (vtpgz_axil_bresp),
        .m_bvalid  (vtpgz_axil_bvalid),
        .m_bready  (vtpgz_axil_bready),
        .m_araddr  (vtpgz_axil_araddr),
        .m_arprot  (vtpgz_axil_arprot),
        .m_arvalid (vtpgz_axil_arvalid),
        .m_arready (vtpgz_axil_arready),
        .m_rdata   (vtpgz_axil_rdata),
        .m_rresp   (vtpgz_axil_rresp),
        .m_rvalid  (vtpgz_axil_rvalid),
        .m_rready  (vtpgz_axil_rready)
    );

    // ---------------- VTPGZ core ----------------
    // Default Arty demo build: RGB 8bpc, Xilinx PG044 packing order.
    // Override these on the command line via Vivado generics if you want
    // a RAW or YUV sensor-emulator build.
    localparam VTPGZ_OUTPUT_MODE   = 0; // 0=RGB 1=RAW 2=YUV
    localparam VTPGZ_BPC           = 8;
    localparam VTPGZ_YUV_SUBSAMPLE = 0;
    localparam VTPGZ_RAW_BAYER     = 1;
    localparam VTPGZ_RGB_ORDER     = 0; // 0=Xilinx, 1=legacy
    // Match vtpgz_axilite_top's auto-derived TDATA_WIDTH formula
    localparam VTPGZ_TDATA_WIDTH =
        (VTPGZ_OUTPUT_MODE == 0) ? (((3*VTPGZ_BPC + 7) / 8) * 8) :
        (VTPGZ_OUTPUT_MODE == 1) ? (((  VTPGZ_BPC + 7) / 8) * 8) :
        (VTPGZ_YUV_SUBSAMPLE == 0 ? (((3*VTPGZ_BPC + 7) / 8) * 8)
                                  : (((2*VTPGZ_BPC + 7) / 8) * 8));

    wire [VTPGZ_TDATA_WIDTH-1:0] vtpgz_axis_tdata;
    wire        vtpgz_axis_tvalid;
    wire        vtpgz_axis_tready;
    wire        vtpgz_axis_tlast;
    wire        vtpgz_axis_tuser;

    vtpgz_axilite_top #(
        .C_S_AXI_ADDR_WIDTH(8),
        .C_S_AXI_DATA_WIDTH(32),
        .OUTPUT_MODE  (VTPGZ_OUTPUT_MODE),
        .YUV_SUBSAMPLE(VTPGZ_YUV_SUBSAMPLE),
        .RAW_BAYER    (VTPGZ_RAW_BAYER),
        .RGB_ORDER    (VTPGZ_RGB_ORDER),
        .BPC          (VTPGZ_BPC)
    ) u_vtpgz (
        .aclk          (clk),
        .aresetn       (rst_n),
        .s_axil_awaddr (vtpgz_axil_awaddr),
        .s_axil_awprot (vtpgz_axil_awprot),
        .s_axil_awvalid(vtpgz_axil_awvalid),
        .s_axil_awready(vtpgz_axil_awready),
        .s_axil_wdata  (vtpgz_axil_wdata),
        .s_axil_wstrb  (vtpgz_axil_wstrb),
        .s_axil_wvalid (vtpgz_axil_wvalid),
        .s_axil_wready (vtpgz_axil_wready),
        .s_axil_bresp  (vtpgz_axil_bresp),
        .s_axil_bvalid (vtpgz_axil_bvalid),
        .s_axil_bready (vtpgz_axil_bready),
        .s_axil_araddr (vtpgz_axil_araddr),
        .s_axil_arprot (vtpgz_axil_arprot),
        .s_axil_arvalid(vtpgz_axil_arvalid),
        .s_axil_arready(vtpgz_axil_arready),
        .s_axil_rdata  (vtpgz_axil_rdata),
        .s_axil_rresp  (vtpgz_axil_rresp),
        .s_axil_rvalid (vtpgz_axil_rvalid),
        .s_axil_rready (vtpgz_axil_rready),
        .m_axis_tdata  (vtpgz_axis_tdata),
        .m_axis_tvalid (vtpgz_axis_tvalid),
        .m_axis_tready (vtpgz_axis_tready),
        .m_axis_tlast  (vtpgz_axis_tlast),
        .m_axis_tuser  (vtpgz_axis_tuser),
        .frame_sync_in (1'b0)
    );

    // ---------------- frame_capture ----------------
    wire        fc_awready, fc_wready;
    wire [1:0]  fc_bresp;
    wire        fc_bvalid;
    wire        fc_arready;
    wire [31:0] fc_rdata;
    wire [1:0]  fc_rresp;
    wire        fc_rvalid;
    wire        fc_rlast;
    wire        capture_busy, capture_done;

    frame_capture #(
        .DEPTH_LOG2 (13),
        .TDATA_WIDTH(VTPGZ_TDATA_WIDTH)
    ) u_fcap (
        .aclk          (clk),
        .aresetn       (rst_n),
        .s_axis_tdata  (vtpgz_axis_tdata),
        .s_axis_tvalid (vtpgz_axis_tvalid),
        .s_axis_tready (vtpgz_axis_tready),
        .s_axis_tlast  (vtpgz_axis_tlast),
        .s_axis_tuser  (vtpgz_axis_tuser),

        .s_axi_awaddr  (br_awaddr),
        .s_axi_awlen   (br_awlen),
        .s_axi_awsize  (br_awsize),
        .s_axi_awburst (br_awburst),
        .s_axi_awprot  (br_awprot),
        .s_axi_awvalid (fc_aw_valid),
        .s_axi_awready (fc_awready),
        .s_axi_wdata   (br_wdata),
        .s_axi_wstrb   (br_wstrb),
        .s_axi_wlast   (br_wlast),
        .s_axi_wvalid  (br_wvalid && aw_target_known && (aw_target_live == 1'b1)),
        .s_axi_wready  (fc_wready),
        .s_axi_bresp   (fc_bresp),
        .s_axi_bvalid  (fc_bvalid),
        .s_axi_bready  (br_bready && aw_active && (aw_target == 1'b1)),
        .s_axi_araddr  (br_araddr),
        .s_axi_arlen   (br_arlen),
        .s_axi_arsize  (br_arsize),
        .s_axi_arburst (br_arburst),
        .s_axi_arprot  (br_arprot),
        .s_axi_arvalid (fc_ar_valid),
        .s_axi_arready (fc_arready),
        .s_axi_rdata   (fc_rdata),
        .s_axi_rresp   (fc_rresp),
        .s_axi_rvalid  (fc_rvalid),
        .s_axi_rlast   (fc_rlast),
        .s_axi_rready  (br_rready && (ar_target == 1'b1)),
        .capture_busy_o(capture_busy),
        .capture_done_o(capture_done)
    );

    // ---------------- bridge response mux ----------------
    assign br_awready = !aw_active && ((br_awaddr[16] == 1'b0) ? shim_awready : fc_awready);
    assign br_wready  = aw_target_known ? ((aw_target_live == 1'b0) ? shim_wready : fc_wready) : 1'b0;
    assign br_bresp   = aw_active ? ((aw_target == 1'b0) ? shim_bresp  : fc_bresp)  : 2'b00;
    assign br_bvalid  = aw_active ? ((aw_target == 1'b0) ? shim_bvalid : fc_bvalid) : 1'b0;

    assign br_arready = (br_araddr[16] == 1'b0) ? shim_arready : fc_arready;
    assign br_rdata   = (ar_target == 1'b0)     ? shim_rdata   : fc_rdata;
    assign br_rresp   = (ar_target == 1'b0)     ? shim_rresp   : fc_rresp;
    assign br_rvalid  = (ar_target == 1'b0)     ? shim_rvalid  : fc_rvalid;
    assign br_rlast   = (ar_target == 1'b0)     ? shim_rlast   : fc_rlast;

    // ---------------- LEDs ----------------
    reg [26:0] heartbeat;
    always @(posedge clk) begin
        if (!rst_n) heartbeat <= 27'h0;
        else        heartbeat <= heartbeat + 27'h1;
    end

    reg activity_q;
    always @(posedge clk) begin
        if (!rst_n)                                       activity_q <= 1'b0;
        else if (vtpgz_axis_tvalid && vtpgz_axis_tready)     activity_q <= 1'b1;
        else                                              activity_q <= 1'b0;
    end

    assign led0 = heartbeat[26];
    assign led1 = capture_busy;
    assign led2 = capture_done;
    assign led3 = activity_q;

endmodule
