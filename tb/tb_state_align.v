//-----------------------------------------------------------------------------
// tb_state_align.v - stateful-pattern/AXIS metadata alignment regression
//
// Exercises patterns whose pixel value comes from per-pixel state machines and
// checks that every emitted AXIS beat matches its x coordinate, especially the
// beat carrying tlast at end-of-line.
//-----------------------------------------------------------------------------
`timescale 1ns/1ps
`include "vtpgz_defs.vh"

module tb_state_align;
    localparam integer W = 16;
    localparam integer H = 8;
    localparam integer BAR_W = 2;
    localparam integer HG_STEP = 16'h0111;
    localparam integer FRAMES_PER_PATTERN = 2;

    reg aclk = 1'b0;
    always #5 aclk = ~aclk;

    reg         aresetn = 1'b0;
    reg         cfg_enable = 1'b0;
    reg         cfg_sw_fsync = 1'b0;
    reg  [3:0]  cfg_pattern = `VTPGZ_PAT_COLORBAR;
    wire        sts_busy;
    wire [7:0]  sts_frame_count;
    wire [23:0] m_axis_tdata;
    wire        m_axis_tvalid;
    wire        m_axis_tlast;
    wire        m_axis_tuser;

    vtpgz_core #(
        .EN_COLORBAR(1),
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
        .OUTPUT_MODE(`VTPGZ_MODE_RGB),
        .BPC(8)
    ) dut (
        .aclk(aclk),
        .aresetn(aresetn),
        .cfg_enable(cfg_enable),
        .cfg_sw_fsync(cfg_sw_fsync),
        .cfg_ext_sync(1'b0),
        .cfg_img_width(W[15:0]),
        .cfg_img_height(H[15:0]),
        .cfg_pattern(cfg_pattern),
        .cfg_solid_color(24'h000000),
        .cfg_box_color(24'h000000),
        .cfg_box_width(16'h0001),
        .cfg_box_height(16'h0001),
        .cfg_box_dx(16'h0001),
        .cfg_box_dy(16'h0001),
        .cfg_grid_spacing(16'h0001),
        .cfg_grid_color(24'h000000),
        .cfg_checker_size(16'h0001),
        .cfg_frame_rate_div(32'd24),
        .cfg_bar_width(BAR_W[15:0]),
        .cfg_hg_step(HG_STEP[15:0]),
        .cfg_vg_step(16'h0000),
        .cfg_box_border_color(24'h000000),
        .cfg_box_border_width(8'h00),
        .cfg_box_img_x_step(32'h00000000),
        .cfg_box_img_y_step(32'h00000000),
        .sts_busy(sts_busy),
        .sts_frame_count(sts_frame_count),
        .m_axis_tdata(m_axis_tdata),
        .m_axis_tvalid(m_axis_tvalid),
        .m_axis_tready(1'b1),
        .m_axis_tlast(m_axis_tlast),
        .m_axis_tuser(m_axis_tuser),
        .frame_sync_in(1'b0)
    );

    integer errors = 0;
    integer axis_x = 0;
    integer axis_y = 0;
    integer frame_pix = 0;
    integer completed_frames = 0;
    integer in_frame = 0;
    integer active_pattern = `VTPGZ_PAT_COLORBAR;

    function [23:0] colorbar_expected;
        input integer x_pos;
        integer idx;
        begin
            idx = x_pos / BAR_W;
            case (idx)
                0: colorbar_expected = 24'hffffff;
                1: colorbar_expected = 24'h00ffff;
                2: colorbar_expected = 24'hffff00;
                3: colorbar_expected = 24'h00ff00;
                4: colorbar_expected = 24'hff00ff;
                5: colorbar_expected = 24'h0000ff;
                6: colorbar_expected = 24'hff0000;
                default: colorbar_expected = 24'h000000;
            endcase
        end
    endfunction

    function [23:0] hgrad_expected;
        input integer x_pos;
        integer v12;
        integer v8;
        begin
            v12 = x_pos * HG_STEP;
            if (v12 > 4095)
                v12 = 4095;
            v8 = (v12 >> 4) & 8'hff;
            hgrad_expected = {v8[7:0], v8[7:0], v8[7:0]};
        end
    endfunction

    function [23:0] expected_pixel;
        input integer pattern;
        input integer x_pos;
        begin
            case (pattern)
                `VTPGZ_PAT_COLORBAR: expected_pixel = colorbar_expected(x_pos);
                `VTPGZ_PAT_HGRAD:    expected_pixel = hgrad_expected(x_pos);
                default:             expected_pixel = 24'hxxxxxx;
            endcase
        end
    endfunction

    task reset_monitor;
        input integer pattern;
        begin
            axis_x = 0;
            axis_y = 0;
            frame_pix = 0;
            completed_frames = 0;
            in_frame = 0;
            active_pattern = pattern;
        end
    endtask

    task error_at;
        input [127:0] what;
        input integer exp;
        input integer got;
        begin
            errors = errors + 1;
            $display("ERROR %0s pattern=%0d x=%0d y=%0d expected=0x%0h got=0x%0h",
                     what, active_pattern, axis_x, axis_y, exp, got);
        end
    endtask

    reg [23:0] exp_data;
    always @(posedge aclk) begin
        if (!aresetn) begin
            axis_x <= 0;
            axis_y <= 0;
            frame_pix <= 0;
            completed_frames <= 0;
            in_frame <= 0;
        end else if (m_axis_tvalid) begin
            if (m_axis_tuser) begin
                if (in_frame && frame_pix != W * H)
                    error_at("short-frame", W * H, frame_pix);
                in_frame <= 1;
                axis_x <= 0;
                axis_y <= 0;
                frame_pix <= 0;
            end else if (!in_frame) begin
                error_at("missing-sof", 1, 0);
            end

            exp_data = expected_pixel(active_pattern, m_axis_tuser ? 0 : axis_x);
            if (m_axis_tdata !== exp_data)
                error_at("pixel", exp_data, m_axis_tdata);

            if (m_axis_tlast !== ((m_axis_tuser ? 0 : axis_x) == W - 1))
                error_at("tlast", ((m_axis_tuser ? 0 : axis_x) == W - 1), m_axis_tlast);

            if ((m_axis_tuser ? 0 : axis_x) == W - 1) begin
                axis_x <= 0;
                axis_y <= (m_axis_tuser ? 0 : axis_y) + 1;
            end else begin
                axis_x <= (m_axis_tuser ? 0 : axis_x) + 1;
            end
            frame_pix <= (m_axis_tuser ? 0 : frame_pix) + 1;

            if ((m_axis_tuser ? 0 : frame_pix) + 1 == W * H) begin
                if (((m_axis_tuser ? 0 : axis_y) + 1) != H)
                    error_at("height", H, (m_axis_tuser ? 0 : axis_y) + 1);
                completed_frames <= completed_frames + 1;
                in_frame <= 0;
            end
        end
    end

    task pulse_fsync;
        begin
            cfg_sw_fsync = 1'b1;
            @(posedge aclk);
            cfg_sw_fsync = 1'b0;
        end
    endtask

    task run_pattern;
        input integer pattern;
        begin
            cfg_enable = 1'b0;
            repeat (8) @(posedge aclk);
            cfg_pattern = pattern[3:0];
            reset_monitor(pattern);
            @(posedge aclk);
            cfg_enable = 1'b1;
            pulse_fsync();
            wait (completed_frames >= FRAMES_PER_PATTERN);
            @(posedge aclk);
            cfg_enable = 1'b0;
            repeat (8) @(posedge aclk);
        end
    endtask

    initial begin
        repeat (5) @(posedge aclk);
        aresetn = 1'b1;
        repeat (4) @(posedge aclk);

        run_pattern(`VTPGZ_PAT_COLORBAR);
        run_pattern(`VTPGZ_PAT_HGRAD);

        if (errors != 0) begin
            $display("FAIL: tb_state_align saw %0d alignment errors", errors);
            $finish(1);
        end

        $display("PASS: tb_state_align COLORBAR/HGRAD AXIS alignment");
        $finish(0);
    end
endmodule
