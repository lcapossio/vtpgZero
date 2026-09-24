//-----------------------------------------------------------------------------
// tb_black.v - "black" must be black in a YUV build
//
// Selecting pattern slot 5, or a pattern stripped at build time, is documented
// to produce a black frame. In YUV, black is {Y_black, Cb=0x800, Cr=0x800};
// the all-zero triple {0,0,0} is saturated GREEN, not black. And in a LIMITED
// build Y_black is 64 (10-bit) / 16 (8-bit), not 0.
//
// The byte-exact model gate cannot see the stripped-pattern stubs, because
// the model has no notion of EN_* build flags. This bench builds the core with
// COLORBAR, SOLID, IMAGE and the box stripped, selects each of those slots plus
// slot 5, and asserts every pixel of every lane is exactly black.
//
// Parameters: PPC (1/2/4/8), RANGE (0=full 1=limited). 8 bpc, YUV 4:4:4, so
// each pixel is {Cr[7:0], Cb[7:0], Y[7:0]}.
//-----------------------------------------------------------------------------
`timescale 1ns/1ps
`include "vtpgz_defs.vh"

module tb_black;
    parameter integer PPC   = 1;
    parameter integer RANGE = 0;

    localparam integer W = 64;
    localparam integer H = 8;
    localparam integer BEATS_PER_FRAME = (W / PPC) * H;
    localparam [23:0] BLACK = {8'h80, 8'h80, (RANGE ? 8'h10 : 8'h00)};

    reg aclk = 1'b0;
    always #5 aclk = ~aclk;

    reg         aresetn = 1'b0;
    reg         cfg_enable = 1'b0;
    reg         cfg_sw_fsync = 1'b0;
    reg  [3:0]  cfg_pattern = 4'd0;
    wire        sts_busy;
    wire [7:0]  sts_frame_count;
    wire [24*PPC-1:0] m_axis_tdata;
    wire        m_axis_tvalid;
    wire        m_axis_tlast;
    wire        m_axis_tuser;

    vtpgz_core #(
        .EN_COLORBAR(0),
        .EN_HGRAD(1),
        .EN_VGRAD(0),
        .EN_CHECKER(0),
        .EN_SOLID(0),
        .EN_MOVING_BOX(0),
        .EN_GRID(0),
        .EN_RAMP(0),
        .EN_NOISE(0),
        .EN_IMAGE(0),
        .EN_BOX_IMAGE(0),
        .OUTPUT_MODE(`VTPGZ_MODE_YUV),
        .YUV_SUBSAMPLE(0),
        .YUV_RANGE(RANGE),
        .BPC(8),
        .PIXELS_PER_CLOCK(PPC),
        .LINE_GAP_CYCLES(1)
    ) dut (
        .aclk(aclk),
        .aresetn(aresetn),
        .cfg_enable(cfg_enable),
        .cfg_sw_fsync(cfg_sw_fsync),
        .cfg_ext_sync(1'b0),
        .cfg_interlace(1'b0),
        .cfg_img_width(W[15:0]),
        .cfg_img_height(H[15:0]),
        .cfg_pattern(cfg_pattern),
        // Non-zero on purpose: a stripped SOLID must ignore the register.
        .cfg_solid_color(24'h123456),
        .cfg_box_color(24'h000000),
        .cfg_box_width(16'h0001),
        .cfg_box_height(16'h0001),
        .cfg_box_dx(16'h0001),
        .cfg_box_dy(16'h0001),
        .cfg_grid_spacing(16'h0001),
        .cfg_grid_color(24'h000000),
        .cfg_checker_size(16'h0001),
        .cfg_frame_rate_div(32'd24),
        .cfg_bar_width(16'd8),
        .cfg_hg_step(16'd65),
        .cfg_vg_step(16'h0000),
        .cfg_box_border_color(24'h000000),
        .cfg_box_border_width(8'h00),
        .cfg_box_img_x_step(32'h00000000),
        .cfg_box_img_y_step(32'h00000000),
        .cfg_tid(16'h0),
        .cfg_tdest(16'h0),
        .sts_busy(sts_busy),
        .sts_frame_count(sts_frame_count),
        .m_axis_tdata(m_axis_tdata),
        .m_axis_tvalid(m_axis_tvalid),
        .m_axis_tready(1'b1),
        .m_axis_tlast(m_axis_tlast),
        .m_axis_tuser(m_axis_tuser),
        .eof(),
        .fid(),
        .m_axis_tid(),
        .m_axis_tdest(),
        .frame_sync_in(1'b0),
        .fid_in(1'b0)
    );

    integer errors = 0;
    integer beats  = 0;
    integer lane;
    reg [23:0] px;

    // TREADY is tied high, so every TVALID cycle is a beat.
    always @(posedge aclk) begin
        if (aresetn && cfg_enable && m_axis_tvalid) begin
            for (lane = 0; lane < PPC; lane = lane + 1) begin
                px = m_axis_tdata[24*lane +: 24];
                if (px !== BLACK) begin
                    if (errors < 8)
                        $display("ERROR pattern=%0d beat=%0d lane=%0d: got Y=%02h Cb=%02h Cr=%02h, black is Y=%02h Cb=%02h Cr=%02h",
                                 cfg_pattern, beats, lane,
                                 px[7:0], px[15:8], px[23:16],
                                 BLACK[7:0], BLACK[15:8], BLACK[23:16]);
                    errors = errors + 1;
                end
            end
            beats = beats + 1;
        end
    end

    task run_pattern;
        input integer pattern;
        begin
            cfg_enable = 1'b0;
            repeat (8) @(posedge aclk);
            cfg_pattern = pattern[3:0];
            beats = 0;
            @(posedge aclk);
            cfg_enable = 1'b1;
            cfg_sw_fsync = 1'b1;
            @(posedge aclk);
            cfg_sw_fsync = 1'b0;
            wait (beats >= 2 * BEATS_PER_FRAME);
            @(posedge aclk);
            cfg_enable = 1'b0;
        end
    endtask

    initial begin
        repeat (5) @(posedge aclk);
        aresetn = 1'b1;
        repeat (4) @(posedge aclk);

        run_pattern(`VTPGZ_PAT_COLORBAR);    // stripped
        run_pattern(`VTPGZ_PAT_SOLID);       // stripped
        run_pattern(5);                       // no standalone pattern
        run_pattern(`VTPGZ_PAT_IMAGE);       // stripped

        if (errors != 0) begin
            $display("FAIL: tb_black PPC=%0d RANGE=%0d: %0d non-black pixels",
                     PPC, RANGE, errors);
            $finish(1);
        end
        $display("PASS: tb_black PPC=%0d RANGE=%0d: stripped/empty slots are black",
                 PPC, RANGE);
        $finish(0);
    end

    initial begin
        #2000000;
        $display("FAIL: tb_black PPC=%0d RANGE=%0d: timeout", PPC, RANGE);
        $finish(1);
    end
endmodule
