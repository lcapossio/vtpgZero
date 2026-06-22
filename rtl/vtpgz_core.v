//-----------------------------------------------------------------------------
// vtpgz_core.v - vtpgZero Video Test Pattern Generator (core, port-driven)
//
// Verilog-2001. This is the substance of the design. Configuration is
// provided directly via the cfg_* input ports -- there is no AXI-Lite
// slave here. For an AXI-Lite-controlled build, instantiate
// vtpgz_axilite_top, which wraps this core with the vtpgz_axil_regs
// register file. For a fully static build, tie the cfg_* ports to
// constants and tie cfg_enable high.
//
// Contains:
//   - Timing engine (x/y counters with frame_sync support)
//   - All pattern generators (combinational, muxed by cfg_pattern)
//   - Inline pack stage (bit-shrink/grow + Xilinx PG044 reorder, no DSPs)
//   - AXI4-Stream master output stage with backpressure
//
// SPDX-FileCopyrightText: 2026 Leonardo Capossio - bard0 design - hello@bard0.com
// SPDX-License-Identifier: Apache-2.0
//-----------------------------------------------------------------------------
`include "vtpgz_defs.vh"

module vtpgz_core #(
    // ----- per-pattern build-time enables (1 = include, 0 = strip) -----
    parameter EN_COLORBAR   = 1,
    parameter EN_HGRAD      = 1,
    parameter EN_VGRAD      = 1,
    parameter EN_CHECKER    = 1,
    parameter EN_SOLID      = 1,
    parameter EN_MOVING_BOX = 1,
    parameter EN_GRID       = 1,
    parameter EN_RAMP       = 1,
    parameter EN_NOISE      = 1,
    // ----- output mode -----
    // OUTPUT_MODE = 0  RGB only, no DSPs
    //               1  RAW (single-component, see RAW_BAYER), no DSPs
    //               2  YUV (full BT.601 matrix, see YUV_SUBSAMPLE), uses DSPs
    parameter OUTPUT_MODE   = `VTPGZ_MODE_RGB,
    // ----- YUV sub-mode (only meaningful when OUTPUT_MODE=2) -----
    // 0 = 4:4:4 (3 components per pixel)
    // 1 = 4:2:2 ({Y,C} pairs, C alternates Cb/Cr by x[0])
    parameter YUV_SUBSAMPLE = `VTPGZ_YUV_444,
    // ----- RAW sub-mode (only meaningful when OUTPUT_MODE=1) -----
    // 0 = plain (monochrome, take G channel)
    // 1 = RGGB Bayer
    parameter RAW_BAYER     = `VTPGZ_RAW_RGGB,
    // ----- RGB component order -----
    // 0 = Xilinx PG044: { pad, B, G, R }    (R in LSBs) -- default
    // 1 = legacy       : { R, G, B, pad }   (R in MSBs)
    parameter RGB_ORDER     = `VTPGZ_RGB_ORDER_XILINX,
    // ----- bits per component -----
    // Allowed values: 8, 10, 12, 14, 16. Internal pattern precision is
    // 12-bit; for BPC<=12 the pack stage truncates LSBs, for BPC>12 it
    // zero-extends LSBs (the upper 12 bits carry the pattern data).
    parameter BPC           = 8,
    // ----- derived AXI-Stream tdata width (do NOT override unless you know
    // what you're doing; the default is the smallest multiple-of-8 that
    // holds the active components for the chosen mode) -----
    parameter C_AXIS_TDATA_WIDTH =
        (OUTPUT_MODE == `VTPGZ_MODE_RGB) ? (((3*BPC + 7) / 8) * 8) :
        (OUTPUT_MODE == `VTPGZ_MODE_RAW) ? (((  BPC + 7) / 8) * 8) :
        /* MODE_YUV */
            (YUV_SUBSAMPLE == `VTPGZ_YUV_444 ? (((3*BPC + 7) / 8) * 8)
                                              : (((2*BPC + 7) / 8) * 8))
)(
    input  wire                          aclk,
    input  wire                          aresetn,

    // ----- direct configuration ports (drive these from your own logic;
    // for an AXI-Lite-controlled build instantiate vtpgz_axilite_top
    // instead) -----
    input  wire        cfg_enable,
    input  wire        cfg_sw_fsync,
    input  wire        cfg_ext_sync,
    input  wire [15:0] cfg_img_width,
    input  wire [15:0] cfg_img_height,
    input  wire [3:0]  cfg_pattern,
    input  wire [23:0] cfg_solid_color,
    input  wire [23:0] cfg_box_color,
    input  wire [15:0] cfg_box_width,
    input  wire [15:0] cfg_box_height,
    input  wire [15:0] cfg_box_dx,
    input  wire [15:0] cfg_box_dy,
    input  wire [15:0] cfg_grid_spacing,
    input  wire [23:0] cfg_grid_color,
    input  wire [15:0] cfg_checker_size,
    input  wire [31:0] cfg_frame_rate_div,
    input  wire [15:0] cfg_bar_width,
    input  wire [15:0] cfg_hg_step,
    input  wire [15:0] cfg_vg_step,
    input  wire [23:0] cfg_box_border_color,
    input  wire [7:0]  cfg_box_border_width,

    // ----- status outputs -----
    output reg         sts_busy,
    output reg  [7:0]  sts_frame_count,

    // AXI4-Stream master (video out)
    /*verilator coverage_off*/ output wire [C_AXIS_TDATA_WIDTH-1:0] m_axis_tdata, /*verilator coverage_on*/
    output wire                          m_axis_tvalid,
    input  wire                          m_axis_tready,
    output wire                          m_axis_tlast,   // end of line
    output wire                          m_axis_tuser,   // SOF (first pixel of frame)

    // External frame sync
    input  wire                          frame_sync_in
);

    // ---------------- effective configuration ----------------
    // Clamp unsafe zero / over-large geometry values so malformed software
    // writes cannot underflow the timing or moving-box arithmetic.
    // img_*_eff are registered (not pure wires) for the same reason as
    // box_*_eff below: when left combinational, the zero-clamp's small
    // LUT cone gets shared across box_max_x/y arithmetic *and* the
    // last_x/last_y comparators (both have cfg_img_* as an operand),
    // pulling cfg_img_* onto the box_y/box_x reset path with high-fanout
    // shared LUTs.  cfg_img_* is host-programmed before cfg_enable, so a
    // 1-cycle clamp latency is harmless.
    reg [15:0] img_width_eff;
    reg [15:0] img_height_eff;
    always @(posedge aclk) begin
        if (!aresetn) begin
            img_width_eff  <= 16'h1;
            img_height_eff <= 16'h1;
        end else begin
            img_width_eff  <= (cfg_img_width  == 16'h0) ? 16'h1 : cfg_img_width;
            img_height_eff <= (cfg_img_height == 16'h0) ? 16'h1 : cfg_img_height;
        end
    end
    // Wrap threshold for the internal-sync divider, pre-computed and
    // registered so the 32-bit `>=` compare on every clock doesn't have
    // to chain a `cfg_frame_rate_div − 1` subtractor in front of it.
    // Same rationale as box_*_eff above: cfg_frame_rate_div is stable
    // across a frame, so a 1-cycle latency on this register is harmless.
    reg [31:0] frame_rate_wrap_thr;
    always @(posedge aclk) begin
        if (!aresetn)
            frame_rate_wrap_thr <= 32'h0;
        else
            frame_rate_wrap_thr <= (cfg_frame_rate_div == 32'h0) ? 32'h0
                                                                  : (cfg_frame_rate_div - 32'h1);
    end
    wire [15:0] bar_width_eff =
        (cfg_bar_width == 16'h0) ? 16'h1 : cfg_bar_width;
    // box_width_eff / box_height_eff are registered (not pure wires) so the
    // clamp's compare/mux cone cannot be LUT-shared with the box_max_x/y or
    // box_y_reflect cones downstream.  Without this, Vivado computes the
    // shared `img_eff − box_eff` partial sums once and high-fanouts the
    // intermediate LUTs (fo=30+) into both the FSM next-state cone *and*
    // the per-pixel border test, which costs ~6 ns of routing under any
    // moderately congested integration.  Registering the clamp output adds
    // 32 FFs, but cfg_box_* is host-programmed before cfg_enable and stable
    // across a frame, so the 1-cycle clamp latency is irrelevant.
    reg [15:0] box_width_eff;
    reg [15:0] box_height_eff;
    always @(posedge aclk) begin
        if (!aresetn) begin
            box_width_eff  <= 16'h1;
            box_height_eff <= 16'h1;
        end else begin
            box_width_eff  <= (cfg_box_width  == 16'h0) ? 16'h1 :
                              (cfg_box_width  > img_width_eff)  ? img_width_eff  : cfg_box_width;
            box_height_eff <= (cfg_box_height == 16'h0) ? 16'h1 :
                              (cfg_box_height > img_height_eff) ? img_height_eff : cfg_box_height;
        end
    end
    wire [15:0] box_max_x =
        (img_width_eff > box_width_eff) ? (img_width_eff - box_width_eff) : 16'h0;
    wire [15:0] box_max_y =
        (img_height_eff > box_height_eff) ? (img_height_eff - box_height_eff) : 16'h0;

    // ---------------- frame sync source ----------------
    // Internal sync: assert one pulse every cfg_frame_rate_div clocks.
    // External sync: rising edge of frame_sync_in.
    // verilator coverage_off
    reg [31:0] fr_div_cnt;
    // verilator coverage_on
    reg        int_sync_pulse;
    always @(posedge aclk) begin
        if (!aresetn) begin
            fr_div_cnt     <= 32'h0;
            int_sync_pulse <= 1'b0;
        end else if (cfg_enable && !cfg_ext_sync) begin
            if (fr_div_cnt >= frame_rate_wrap_thr) begin
                fr_div_cnt     <= 32'h0;
                int_sync_pulse <= 1'b1;
            end else begin
                fr_div_cnt     <= fr_div_cnt + 32'h1;
                int_sync_pulse <= 1'b0;
            end
        end else begin
            fr_div_cnt     <= 32'h0;
            int_sync_pulse <= 1'b0;
        end
    end

    reg ext_sync_q;
    always @(posedge aclk) begin
        if (!aresetn) ext_sync_q <= 1'b0;
        else          ext_sync_q <= frame_sync_in;
    end
    wire ext_sync_pulse = frame_sync_in & ~ext_sync_q;
    wire frame_start    = cfg_sw_fsync | (cfg_ext_sync ? ext_sync_pulse : int_sync_pulse);

    // ---------------- timing engine ----------------
    // States: IDLE -> ACTIVE (one frame) -> IDLE
    reg        active;
    reg [15:0] x;
    /*verilator coverage_off*/ reg [15:0] y; /*verilator coverage_on*/
    /*verilator coverage_off*/ reg [15:0] frame_num; /*verilator coverage_on*/

    // Source state advances only while a frame is active. The output pipe
    // also advances for a couple of cycles after ACTIVE drops so delayed tail
    // beats can flush instead of being stranded until the next frame.
    wire axis_can_advance = (!m_axis_tvalid || m_axis_tready);
    wire source_advance   = active && axis_can_advance;

    wire        last_x = (x == img_width_eff  - 16'd1);
    wire        last_y = (y == img_height_eff - 16'd1);
    wire        end_of_frame = last_x & last_y;

    // Frame init pulse: high for the single cycle when the FIRST frame
    // after a fresh cfg_enable is starting. Pattern counters use this to
    // clear their state at the same edge that x/y get reset, so the very
    // first pixel of a fresh enable doesn't read residual register values
    // from a previous run. After the first frame, subsequent frames within
    // the SAME enable do NOT re-trigger frame_init, so stateful patterns
    // (moving box, LFSR noise) accumulate state across frames as expected.
    reg first_frame_pending;
    wire frame_init;
    always @(posedge aclk) begin
        if (!aresetn)            first_frame_pending <= 1'b1;
        else if (!cfg_enable)    first_frame_pending <= 1'b1;
        else if (frame_init)     first_frame_pending <= 1'b0;
    end
    // frame_init only when first_pending is set, the FSM is idle, and a
    // sync pulse just arrived. Clearing of first_pending is gated on
    // frame_init itself so that a frame_start arriving while a leftover
    // frame is still in flight (active=1) doesn't consume the pending bit.
    assign frame_init = first_frame_pending & (~active) & cfg_enable & frame_start;


    always @(posedge aclk) begin
        if (!aresetn) begin
            active     <= 1'b0;
            x          <= 16'h0;
            y          <= 16'h0;
            frame_num  <= 16'h0;
            sts_busy   <= 1'b0;
            sts_frame_count <= 8'h0;
        end else begin
            if (!active) begin
                if (cfg_enable && frame_start) begin
                    active   <= 1'b1;
                    x        <= 16'h0;
                    y        <= 16'h0;
                    sts_busy <= 1'b1;
                end
            end else if (source_advance) begin
                if (end_of_frame) begin
                    active          <= 1'b0;
                    sts_busy        <= 1'b0;
                    frame_num       <= frame_num + 16'h1;
                    sts_frame_count <= sts_frame_count + 8'h1;
                end else if (last_x) begin
                    x <= 16'h0;
                    y <= y + 16'h1;
                end else begin
                    x <= x + 16'h1;
                end
            end
        end
    end

    wire pix_valid = active;
    wire pix_sof   = active && (x == 16'h0) && (y == 16'h0);
    wire pix_eol   = active && last_x;

    // ---------------- pattern generators (combinational) ----------------
    // Each pattern is wrapped in a `generate if (EN_xxx)` so disabled patterns
    // are stripped at elaboration time. Disabled patterns drive their outputs
    // to 0 so the mux is still well-formed.
    //
    // All patterns produce 12-bit RGB on these wires:
    wire [11:0] cb_r,    cb_g,    cb_b;
    wire [11:0] hg_val;
    wire [11:0] vg_val;
    wire [11:0] chk_v;
    wire [11:0] solid_r, solid_g, solid_b;
    wire [11:0] grid_r,  grid_g,  grid_b;
    wire [11:0] ramp_v;
    wire [11:0] noise_v;

    // ---- Color bars (8 SMPTE bars) ----
    // Counter-based: increment bar index every cfg_bar_width pixels.
    // Host writes BAR_WIDTH = img_width/8 once per resolution change.
    generate if (EN_COLORBAR) begin : g_colorbar
        reg [15:0] bar_pix_cnt;
        reg [2:0]  bar_idx;
        always @(posedge aclk) begin
            if (!aresetn || frame_init) begin
                bar_pix_cnt <= 16'h0;
                bar_idx     <= 3'h0;
            end else if (source_advance) begin
                if (pix_sof || last_x) begin
                    // Pix_sof: first pixel of first frame (frame_init also
                    // hits this path; redundant but harmless).
                    // last_x: force the bar walk back to bar 0 at the END
                    // of each line so the next line's pixel 0 reads bar 0
                    // combinationally. Anchoring on last_x instead of
                    // (x == 0) avoids a stale-bar_idx read at x=0 caused
                    // by the NBA delay (the prior code dropped the bar 7
                    // → bar 0 wrap when bar_width divided img_width
                    // cleanly, shifting every line's pattern right by one
                    // pixel).
                    bar_pix_cnt <= 16'h0;
                    bar_idx     <= 3'h0;
                end else if (bar_pix_cnt + 16'h1 >= bar_width_eff) begin
                    bar_pix_cnt <= 16'h0;
                    bar_idx     <= bar_idx + 3'h1;
                end else begin
                    bar_pix_cnt <= bar_pix_cnt + 16'h1;
                end
            end
        end
        // Mode-aware palette: in RGB/RAW the triple is {R,G,B}; in YUV the
        // triple is {Y,Cb,Cr}. Constants only -- no DSPs needed.
        reg [11:0] cb_c0_r, cb_c1_r, cb_c2_r;
        if (OUTPUT_MODE == `VTPGZ_MODE_YUV) begin : g_yuv_pal
            always @* begin
                case (bar_idx)
                    3'd0: begin cb_c0_r=12'hFFF; cb_c1_r=12'h800; cb_c2_r=12'h800; end // white
                    3'd1: begin cb_c0_r=12'hE2C; cb_c1_r=12'h000; cb_c2_r=12'h94D; end // yellow
                    3'd2: begin cb_c0_r=12'hB37; cb_c1_r=12'hAB3; cb_c2_r=12'h000; end // cyan
                    3'd3: begin cb_c0_r=12'h964; cb_c1_r=12'h2B4; cb_c2_r=12'h14E; end // green
                    3'd4: begin cb_c0_r=12'h69B; cb_c1_r=12'hD4C; cb_c2_r=12'hEB2; end // magenta
                    3'd5: begin cb_c0_r=12'h4C8; cb_c1_r=12'h54D; cb_c2_r=12'hFFF; end // red
                    3'd6: begin cb_c0_r=12'h1D3; cb_c1_r=12'hFFF; cb_c2_r=12'h6B3; end // blue
                    default:begin cb_c0_r=12'h000; cb_c1_r=12'h800; cb_c2_r=12'h800; end // black
                endcase
            end
        end else begin : g_rgb_pal
            always @* begin
                case (bar_idx)
                    3'd0: begin cb_c0_r=12'hFFF; cb_c1_r=12'hFFF; cb_c2_r=12'hFFF; end
                    3'd1: begin cb_c0_r=12'hFFF; cb_c1_r=12'hFFF; cb_c2_r=12'h000; end
                    3'd2: begin cb_c0_r=12'h000; cb_c1_r=12'hFFF; cb_c2_r=12'hFFF; end
                    3'd3: begin cb_c0_r=12'h000; cb_c1_r=12'hFFF; cb_c2_r=12'h000; end
                    3'd4: begin cb_c0_r=12'hFFF; cb_c1_r=12'h000; cb_c2_r=12'hFFF; end
                    3'd5: begin cb_c0_r=12'hFFF; cb_c1_r=12'h000; cb_c2_r=12'h000; end
                    3'd6: begin cb_c0_r=12'h000; cb_c1_r=12'h000; cb_c2_r=12'hFFF; end
                    default:begin cb_c0_r=12'h000; cb_c1_r=12'h000; cb_c2_r=12'h000; end
                endcase
            end
        end
        assign cb_r = cb_c0_r;
        assign cb_g = cb_c1_r;
        assign cb_b = cb_c2_r;
    end else begin : g_colorbar_off
        assign cb_r = 12'h000;
        assign cb_g = 12'h000;
        assign cb_b = 12'h000;
    end endgenerate

    // ---- Horizontal gradient ----
    // Q4.12 accumulator: increments by cfg_hg_step (Q4.12) per pixel,
    // resets at start of line. Host computes step = (4096<<8)/(width-1)>>8
    // ~ 0xFFF / width, written once per resolution change.
    generate if (EN_HGRAD) begin : g_hgrad
        reg [19:0] hg_acc;  // 4 int + 12 frac of headroom + 4 guard
        always @(posedge aclk) begin
            if (!aresetn || frame_init) hg_acc <= 20'h0;
            else if (source_advance) begin
                // Clear at last_x of the prior line (not x==0 of this one)
                // so the next line's pixel 0 reads acc=0 combinationally.
                // x==0 fires too late: the value latched at x=0's NBA only
                // takes effect at x=1, leaving hg_acc carrying ~1279*step
                // from the previous line and producing a bright artifact
                // at col 0 of every row.
                if (last_x)     hg_acc <= 20'h0;
                else            hg_acc <= hg_acc + {4'h0, cfg_hg_step};
            end
        end
        // Saturate to 12 bits
        assign hg_val = (|hg_acc[19:12]) ? 12'hFFF : hg_acc[11:0];
    end else begin : g_hgrad_off
        assign hg_val = 12'h000;
    end endgenerate

    // ---- Vertical gradient ----
    // Increments by cfg_vg_step per line.
    generate if (EN_VGRAD) begin : g_vgrad
        reg [19:0] vg_acc;
        always @(posedge aclk) begin
            if (!aresetn || frame_init) vg_acc <= 20'h0;
            else if (source_advance) begin
                if (pix_sof)              vg_acc <= 20'h0;
                else if (last_x)          vg_acc <= vg_acc + {4'h0, cfg_vg_step};
            end
        end
        assign vg_val = (|vg_acc[19:12]) ? 12'hFFF : vg_acc[11:0];
    end else begin : g_vgrad_off
        assign vg_val = 12'h000;
    end endgenerate

    // ---- Checkerboard ----
    // Two wrap-counters (one X per pixel, one Y per line) toggle a sel bit
    // each time they reach cfg_checker_size. No divider, no modulo.
    generate if (EN_CHECKER) begin : g_checker
        wire [15:0] chk_size_eff = (cfg_checker_size == 16'h0) ? 16'h1 : cfg_checker_size;
        reg [15:0] chk_x_cnt, chk_y_cnt;
        reg        chk_sel_x, chk_sel_y;
        always @(posedge aclk) begin
            if (!aresetn || frame_init) begin
                chk_x_cnt <= 16'h0;
                chk_y_cnt <= 16'h0;
                chk_sel_x <= 1'b0;
                chk_sel_y <= 1'b0;
            end else if (source_advance) begin
                // X axis -- anchor reset on last_x of the previous line
                // (same reasoning as colorbar / hgrad).
                if (last_x) begin
                    chk_x_cnt <= 16'h0;
                    chk_sel_x <= 1'b0;
                end else if (chk_x_cnt + 16'h1 >= chk_size_eff) begin
                    chk_x_cnt <= 16'h0;
                    chk_sel_x <= ~chk_sel_x;
                end else begin
                    chk_x_cnt <= chk_x_cnt + 16'h1;
                end
                // Y axis (per-line)
                if (pix_sof) begin
                    chk_y_cnt <= 16'h0;
                    chk_sel_y <= 1'b0;
                end else if (last_x) begin
                    if (chk_y_cnt + 16'h1 >= chk_size_eff) begin
                        chk_y_cnt <= 16'h0;
                        chk_sel_y <= ~chk_sel_y;
                    end else begin
                        chk_y_cnt <= chk_y_cnt + 16'h1;
                    end
                end
            end
        end
        assign chk_v = (chk_sel_x ^ chk_sel_y) ? 12'hFFF : 12'h000;
    end else begin : g_checker_off
        assign chk_v = 12'h000;
    end endgenerate

    // ---- Solid color from register ----
    generate if (EN_SOLID) begin : g_solid
        assign solid_r = {cfg_solid_color[23:16], 4'h0};
        assign solid_g = {cfg_solid_color[15:8],  4'h0};
        assign solid_b = {cfg_solid_color[7:0],   4'h0};
    end else begin : g_solid_off
        assign solid_r = 12'h000;
        assign solid_g = 12'h000;
        assign solid_b = 12'h000;
    end endgenerate

    // ---- Moving box (bouncing overlay) ----
    // The box is a POST-MUX overlay, not a standalone pattern. When
    // EN_MOVING_BOX=1, the box_in region is drawn with cfg_box_color on
    // top of whatever pattern is active (colorbar, gradient, checker...).
    // To get "box on a solid background", just select PAT_SOLID.
    //
    // The box state is reset on frame_init so each fresh enable starts
    // with the box at (0,0). This matches the Python model which
    // constructs a fresh VtpgzRegs per render_frame call.
    wire box_in;
    generate if (EN_MOVING_BOX) begin : g_box
        reg [15:0] box_x;
        reg [15:0] box_y;
        reg        box_dir_x;
        reg        box_dir_y;
        // Pre-compute the wrap / reflect thresholds from the slow cfg_*
        // registers so the end-of-frame update collapses to
        //    box_x >= box_x_wrap_thr
        // instead of chaining two 16-bit adders (box_x+box_width+box_dx)
        // into a compare against cfg_img_width, which was the critical
        // path. cfg_* are written by the host before cfg_enable and are
        // stable across a frame, so a 1-cycle registration delay is
        // harmless. Reset values are conservative; the registered thresholds
        // are refreshed before any normal end-of-frame box update.
        reg [15:0] box_x_wrap_thr;
        reg [15:0] box_y_wrap_thr;
        reg [15:0] box_x_reflect;
        reg [15:0] box_y_reflect;
        always @(posedge aclk) begin
            if (!aresetn) begin
                box_x_wrap_thr <= 16'h0;
                box_y_wrap_thr <= 16'h0;
                box_x_reflect  <= 16'h0;
                box_y_reflect  <= 16'h0;
            end else begin
                box_x_wrap_thr <= (box_max_x > cfg_box_dx) ? (box_max_x - cfg_box_dx) : 16'h0;
                box_y_wrap_thr <= (box_max_y > cfg_box_dy) ? (box_max_y - cfg_box_dy) : 16'h0;
                box_x_reflect  <= (box_max_x == 16'h0) ? 16'h0 : (box_max_x - 16'h1);
                box_y_reflect  <= (box_max_y == 16'h0) ? 16'h0 : (box_max_y - 16'h1);
            end
        end
        always @(posedge aclk) begin
            if (!aresetn || frame_init) begin
                box_x     <= 16'h0;
                box_y     <= 16'h0;
                box_dir_x <= 1'b0;
                box_dir_y <= 1'b0;
            end else if (cfg_enable && active && source_advance && end_of_frame) begin
                if (box_dir_x == 1'b0) begin
                    if (box_x >= box_x_wrap_thr) begin
                        box_dir_x <= 1'b1;
                        box_x     <= box_x_reflect;
                    end else begin
                        box_x <= box_x + cfg_box_dx;
                    end
                end else begin
                    if (box_x < cfg_box_dx) begin
                        box_dir_x <= 1'b0;
                        box_x     <= 16'h0;
                    end else begin
                        box_x <= box_x - cfg_box_dx;
                    end
                end
                if (box_dir_y == 1'b0) begin
                    if (box_y >= box_y_wrap_thr) begin
                        box_dir_y <= 1'b1;
                        box_y     <= box_y_reflect;
                    end else begin
                        box_y <= box_y + cfg_box_dy;
                    end
                end else begin
                    if (box_y < cfg_box_dy) begin
                        box_dir_y <= 1'b0;
                        box_y     <= 16'h0;
                    end else begin
                        box_y <= box_y - cfg_box_dy;
                    end
                end
            end
        end
        assign box_in = (x >= box_x) && (x < box_x + box_width_eff) &&
                        (y >= box_y) && (y < box_y + box_height_eff);
    end else begin : g_box_off
        assign box_in = 1'b0;
    end endgenerate

    // ---- Grid / crosshatch ----
    // Wrap-counters per axis, "on grid" when counter is at zero.
    generate if (EN_GRID) begin : g_grid
        wire [15:0] grid_eff = (cfg_grid_spacing == 16'h0) ? 16'h1 : cfg_grid_spacing;
        reg [15:0] gx_cnt, gy_cnt;
        always @(posedge aclk) begin
            if (!aresetn || frame_init) begin
                gx_cnt <= 16'h0;
                gy_cnt <= 16'h0;
            end else if (source_advance) begin
                if (last_x)                                  gx_cnt <= 16'h0;
                else if (gx_cnt + 16'h1 >= grid_eff)         gx_cnt <= 16'h0;
                else                                          gx_cnt <= gx_cnt + 16'h1;

                if (pix_sof)                                  gy_cnt <= 16'h0;
                else if (last_x) begin
                    if (gy_cnt + 16'h1 >= grid_eff)          gy_cnt <= 16'h0;
                    else                                      gy_cnt <= gy_cnt + 16'h1;
                end
            end
        end
        wire on_grid = (gx_cnt == 16'h0) || (gy_cnt == 16'h0);
        assign grid_r = on_grid ? {cfg_grid_color[23:16],4'h0} : 12'h000;
        assign grid_g = on_grid ? {cfg_grid_color[15:8], 4'h0} : 12'h000;
        assign grid_b = on_grid ? {cfg_grid_color[7:0],  4'h0} : 12'h000;
    end else begin : g_grid_off
        assign grid_r = 12'h000;
        assign grid_g = 12'h000;
        assign grid_b = 12'h000;
    end endgenerate

    // ---- Ramp ----
    // Same accumulator approach as hgrad. Reuses cfg_hg_step.
    generate if (EN_RAMP) begin : g_ramp
        reg [19:0] ramp_acc;
        always @(posedge aclk) begin
            if (!aresetn || frame_init) ramp_acc <= 20'h0;
            else if (source_advance) begin
                if (last_x)     ramp_acc <= 20'h0;
                else            ramp_acc <= ramp_acc + {4'h0, cfg_hg_step};
            end
        end
        assign ramp_v = (|ramp_acc[19:12]) ? 12'hFFF : ramp_acc[11:0];
    end else begin : g_ramp_off
        assign ramp_v = 12'h000;
    end endgenerate

    // ---- Noise (LFSR-16) ----
    generate if (EN_NOISE) begin : g_noise
        reg [15:0] lfsr;
        wire       lfsr_fb = lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10];
        // LFSR is re-seeded on frame_init so each fresh enable starts with
        // the same state, matching the Python model.
        always @(posedge aclk) begin
            if (!aresetn || frame_init) lfsr <= 16'hACE1;
            else if (source_advance) lfsr <= {lfsr[14:0], lfsr_fb};
        end
        assign noise_v = lfsr[11:0];
    end else begin : g_noise_off
        assign noise_v = 12'h000;
    end endgenerate

    // ---------------- pattern mux ----------------
    // Output triple {pix_c0, pix_c1, pix_c2} is in the build-time color
    // space: RGB/RAW modes -> {R,G,B}, YUV mode -> {Y,Cb,Cr}.
    // Grayscale-style patterns map their value to the luma channel and
    // leave chroma at neutral (12'h800 = 0.5 in Q12). Solid/box/grid colors
    // are host-programmed triples and pass through component-by-component
    // regardless of build mode -- the host fills them in the build's space.
    localparam [11:0] CHROMA_NEUTRAL = 12'h800;
    // verilator coverage_off
    wire is_yuv_build = (OUTPUT_MODE == `VTPGZ_MODE_YUV);
    // verilator coverage_on
    // Helpers: gray-to-triple expansion for the build's color space.
    wire [11:0] hg_c1   = is_yuv_build ? CHROMA_NEUTRAL : hg_val;
    wire [11:0] hg_c2   = is_yuv_build ? CHROMA_NEUTRAL : hg_val;
    wire [11:0] vg_c1   = is_yuv_build ? CHROMA_NEUTRAL : vg_val;
    wire [11:0] vg_c2   = is_yuv_build ? CHROMA_NEUTRAL : vg_val;
    wire [11:0] chk_c1  = is_yuv_build ? CHROMA_NEUTRAL : chk_v;
    wire [11:0] chk_c2  = is_yuv_build ? CHROMA_NEUTRAL : chk_v;
    wire [11:0] ramp_c1 = is_yuv_build ? CHROMA_NEUTRAL : ramp_v;
    wire [11:0] ramp_c2 = is_yuv_build ? CHROMA_NEUTRAL : ramp_v;
    wire [11:0] nz_c1   = is_yuv_build ? CHROMA_NEUTRAL : noise_v;
    wire [11:0] nz_c2   = is_yuv_build ? CHROMA_NEUTRAL : noise_v;

    reg [11:0] pat_c0, pat_c1, pat_c2;
    always @* begin
        case (cfg_pattern)
            `VTPGZ_PAT_COLORBAR  : begin pat_c0 = cb_r;    pat_c1 = cb_g;    pat_c2 = cb_b;    end
            `VTPGZ_PAT_HGRAD     : begin pat_c0 = hg_val;  pat_c1 = hg_c1;   pat_c2 = hg_c2;   end
            `VTPGZ_PAT_VGRAD     : begin pat_c0 = vg_val;  pat_c1 = vg_c1;   pat_c2 = vg_c2;   end
            `VTPGZ_PAT_CHECKER   : begin pat_c0 = chk_v;   pat_c1 = chk_c1;  pat_c2 = chk_c2;  end
            `VTPGZ_PAT_SOLID     : begin pat_c0 = solid_r; pat_c1 = solid_g; pat_c2 = solid_b; end
            `VTPGZ_PAT_GRID      : begin pat_c0 = grid_r;  pat_c1 = grid_g;  pat_c2 = grid_b;  end
            `VTPGZ_PAT_RAMP      : begin pat_c0 = ramp_v;  pat_c1 = ramp_c1; pat_c2 = ramp_c2; end
            `VTPGZ_PAT_NOISE     : begin pat_c0 = noise_v; pat_c1 = nz_c1;   pat_c2 = nz_c2;   end
            // verilator coverage_off
            default              : begin pat_c0 = 12'h0;   pat_c1 = 12'h0;   pat_c2 = 12'h0;   end
            // verilator coverage_on
        endcase
    end

    // ---- Box overlay (post-mux) ----
    // When EN_MOVING_BOX=1 and the current pixel is inside the box
    // region, the pattern output is replaced with cfg_box_color (fill)
    // or cfg_box_border_color (border ring). The border is drawn inside
    // the box: pixels within border_width of any edge are border, the
    // rest is fill. border_width=0 means no border (all fill).
    // When EN_MOVING_BOX=0, box_in is constant 0 and this mux is
    // stripped at elaboration.
    wire [11:0] box_fill_c0 = {cfg_box_color[23:16], 4'h0};
    wire [11:0] box_fill_c1 = {cfg_box_color[15:8],  4'h0};
    wire [11:0] box_fill_c2 = {cfg_box_color[7:0],   4'h0};
    wire [11:0] box_bdr_c0  = {cfg_box_border_color[23:16], 4'h0};
    wire [11:0] box_bdr_c1  = {cfg_box_border_color[15:8],  4'h0};
    wire [11:0] box_bdr_c2  = {cfg_box_border_color[7:0],   4'h0};

    // Border test: pixel is on the border ring if it's within
    // border_width of any box edge (but still inside box_in).
    // verilator coverage_off
    wire box_on_border;
    // verilator coverage_on
    generate if (EN_MOVING_BOX) begin : g_box_border
        wire [15:0] bw_raw = {8'h0, cfg_box_border_width};
        wire [15:0] bw_x = (bw_raw > box_width_eff)  ? box_width_eff  : bw_raw;
        wire [15:0] bw_y = (bw_raw > box_height_eff) ? box_height_eff : bw_raw;
        // Right/bottom edge tests are written as `x + bw_x >= box_x + W`
        // rather than `x >= box_x + W - bw_x` so the two adders run in
        // parallel on independent operands.  The chained form let Vivado
        // share LUT cones with the box_y_reflect / box_max_y arithmetic
        // (since both fed by box_height_eff / box_width_eff), pulling
        // cfg_img_* onto this path with fan-outs of 30+ that routed
        // poorly under heavy congestion.  Equivalent for any non-overflowing
        // input (x + bw < 2^16, satisfied by all practical resolutions).
        assign box_on_border = box_in && (
            (x          <  g_box.box_x + bw_x) ||
            (x + bw_x   >= g_box.box_x + box_width_eff) ||
            (y          <  g_box.box_y + bw_y) ||
            (y + bw_y   >= g_box.box_y + box_height_eff)
        );
    end else begin : g_box_border_off
        assign box_on_border = 1'b0;
    end endgenerate

    // ---------------- pipeline stage 1 (pre-mux register) ----------------
    // Break the long combinational fan-out from the box-position registers
    // (g_box.box_x / box_y) through the border-compare OR-tree into the
    // final pix_c0/c1/c2 mux. Registering box_in / box_on_border here
    // caps that path at the adders+compares and leaves only a 3:1 mux
    // feeding pix_cN_q in stage 2.
    reg        box_in_s1, box_on_border_s1;
    reg [11:0] pat_c0_s1, pat_c1_s1, pat_c2_s1;
    reg        pix_valid_s1, pix_sof_s1, pix_eol_s1;
    reg        pix_x_lsb_s1, pix_y_lsb_s1;
    wire       pipe_advance;
    always @(posedge aclk) begin
        if (!aresetn) begin
            box_in_s1        <= 1'b0;
            box_on_border_s1 <= 1'b0;
            pat_c0_s1        <= 12'h0;
            pat_c1_s1        <= 12'h0;
            pat_c2_s1        <= 12'h0;
            pix_valid_s1     <= 1'b0;
            pix_sof_s1       <= 1'b0;
            pix_eol_s1       <= 1'b0;
            pix_x_lsb_s1     <= 1'b0;
            pix_y_lsb_s1     <= 1'b0;
        end else if (pipe_advance) begin
            box_in_s1        <= box_in;
            box_on_border_s1 <= box_on_border;
            pat_c0_s1        <= pat_c0;
            pat_c1_s1        <= pat_c1;
            pat_c2_s1        <= pat_c2;
            pix_valid_s1     <= pix_valid;
            pix_sof_s1       <= pix_sof;
            pix_eol_s1       <= pix_eol;
            pix_x_lsb_s1     <= x[0];
            pix_y_lsb_s1     <= y[0];
        end
    end

    wire [11:0] pix_c0 = box_on_border_s1 ? box_bdr_c0 :
                          box_in_s1        ? box_fill_c0 : pat_c0_s1;
    wire [11:0] pix_c1 = box_on_border_s1 ? box_bdr_c1 :
                          box_in_s1        ? box_fill_c1 : pat_c1_s1;
    wire [11:0] pix_c2 = box_on_border_s1 ? box_bdr_c2 :
                          box_in_s1        ? box_fill_c2 : pat_c2_s1;

    // ---------------- pipeline stage 2 (post-mux register) ---------------
    // Two pipeline stages total between pattern/box state and the AXI
    // output: SOF → first pixel on AXI is delayed by 2 cycles vs. a
    // combinational core, but the per-beat value sequence is unchanged.
    (* keep = "true", dont_touch = "true" *) reg [11:0] pix_c0_q, pix_c1_q, pix_c2_q;
    reg        pix_valid_q, pix_sof_q, pix_eol_q;
    reg        pix_x_lsb_q, pix_y_lsb_q;
    assign pipe_advance = axis_can_advance && (active || pix_valid_s1 || pix_valid_q);
    always @(posedge aclk) begin
        if (!aresetn) begin
            pix_c0_q    <= 12'h0;
            pix_c1_q    <= 12'h0;
            pix_c2_q    <= 12'h0;
            pix_valid_q <= 1'b0;
            pix_sof_q   <= 1'b0;
            pix_eol_q   <= 1'b0;
            pix_x_lsb_q <= 1'b0;
            pix_y_lsb_q <= 1'b0;
        end else if (pipe_advance) begin
            pix_c0_q    <= pix_c0;
            pix_c1_q    <= pix_c1;
            pix_c2_q    <= pix_c2;
            pix_valid_q <= pix_valid_s1;
            pix_sof_q   <= pix_sof_s1;
            pix_eol_q   <= pix_eol_s1;
            pix_x_lsb_q <= pix_x_lsb_s1;
            pix_y_lsb_q <= pix_y_lsb_s1;
        end
    end

    // ---------------- pack stage (no DSPs, just bit-shrink + reorder) ------
    // Build-time pixel packing per Xilinx PG044 conventions:
    //   RGB    : { pad, B, G, R }                      (R in LSBs)        Xilinx
    //            { R, G, B, pad }                                          legacy
    //   YUV444 : { pad, Cr, Cb, Y }                    (Y in LSBs)         Xilinx
    //            { Y, Cb, Cr, pad }                                        legacy
    //   YUV422 : { pad, C, Y } where C = Cb (x even) / Cr (x odd)          Xilinx
    //            { Y, C, pad }                                              legacy
    //   RAW    : { pad, P } single component
    //            RAW_BAYER=0 -> P = c1 (G channel monochrome)
    //            RAW_BAYER=1 -> P = RGGB select on (x_lsb,y_lsb) from triple
    //
    // shrink/grow each 12-bit component to BPC bits.
    //   BPC == 12 -> pass-through
    //   BPC <  12 -> take top BPC bits (truncate LSBs)
    //   BPC >  12 -> zero-extend on the right (BPC-12 zero LSBs)
    // No DSPs in any case.
    wire [BPC-1:0] c0_s, c1_s, c2_s;
    generate
        if (BPC == 12) begin : g_bpc_pass
            assign c0_s = pix_c0_q;
            assign c1_s = pix_c1_q;
            assign c2_s = pix_c2_q;
        end else if (BPC < 12) begin : g_bpc_shrink
            assign c0_s = pix_c0_q[11 -: BPC];
            assign c1_s = pix_c1_q[11 -: BPC];
            assign c2_s = pix_c2_q[11 -: BPC];
        end else begin : g_bpc_grow
            assign c0_s = {pix_c0_q, {(BPC-12){1'b0}}};
            assign c1_s = {pix_c1_q, {(BPC-12){1'b0}}};
            assign c2_s = {pix_c2_q, {(BPC-12){1'b0}}};
        end
    endgenerate

    /*verilator coverage_off*/ reg [C_AXIS_TDATA_WIDTH-1:0] tdata_r; /*verilator coverage_on*/
    reg                          tvalid_r;
    reg                          tlast_r;
    reg                          tuser_r;

    // Combinational pack -> next-tdata
    /*verilator coverage_off*/ reg [C_AXIS_TDATA_WIDTH-1:0] tdata_next; /*verilator coverage_on*/
    generate
        if (OUTPUT_MODE == `VTPGZ_MODE_RGB || (OUTPUT_MODE == `VTPGZ_MODE_YUV
                                              && YUV_SUBSAMPLE == `VTPGZ_YUV_444)) begin : g_pack_3c
            // verilator coverage_off
            always @* begin
                if (RGB_ORDER == `VTPGZ_RGB_ORDER_XILINX) begin
                    tdata_next = {{(C_AXIS_TDATA_WIDTH-3*BPC){1'b0}}, c2_s, c1_s, c0_s};
                end else begin
                    tdata_next = {c0_s, c1_s, c2_s, {(C_AXIS_TDATA_WIDTH-3*BPC){1'b0}}};
                end
            end
            // verilator coverage_on
        end else if (OUTPUT_MODE == `VTPGZ_MODE_YUV) begin : g_pack_yuv422
            // 4:2:2 -- {Y, C} per beat, C = Cb on even-x, Cr on odd-x
            // verilator coverage_off
            wire [BPC-1:0] c_s = (pix_x_lsb_q == 1'b0) ? c1_s : c2_s;
            always @* begin
                if (RGB_ORDER == `VTPGZ_RGB_ORDER_XILINX) begin
                    tdata_next = {{(C_AXIS_TDATA_WIDTH-2*BPC){1'b0}}, c_s, c0_s};
                end else begin
                    tdata_next = {c0_s, c_s, {(C_AXIS_TDATA_WIDTH-2*BPC){1'b0}}};
                end
            end
            // verilator coverage_on
        end else begin : g_pack_raw
            // RAW: single component. RAW_BAYER selects the 2x2 mosaic.
            // Triples are always {c0=R, c1=G, c2=B} in RAW mode (RGB
            // semantics, like the RGB pack path -- the only difference
            // is that here we mux one component per pixel based on the
            // Bayer tile and (x[0], y[0])).
            //
            //   PLAIN : monochrome, take G          (c1) every pixel
            //   RGGB  : row0:[R,G] row1:[G,B]
            //   BGGR  : row0:[B,G] row1:[G,R]
            //   GRBG  : row0:[G,R] row1:[B,G]
            //   GBRG  : row0:[G,B] row1:[R,G]
            // verilator coverage_off
            reg [BPC-1:0] raw_sel;
            always @* begin
                case (RAW_BAYER)
                    `VTPGZ_RAW_RGGB: begin
                        if (pix_y_lsb_q == 1'b0)
                            raw_sel = (pix_x_lsb_q == 1'b0) ? c0_s : c1_s;
                        else
                            raw_sel = (pix_x_lsb_q == 1'b0) ? c1_s : c2_s;
                    end
                    `VTPGZ_RAW_BGGR: begin
                        if (pix_y_lsb_q == 1'b0)
                            raw_sel = (pix_x_lsb_q == 1'b0) ? c2_s : c1_s;
                        else
                            raw_sel = (pix_x_lsb_q == 1'b0) ? c1_s : c0_s;
                    end
                    `VTPGZ_RAW_GRBG: begin
                        if (pix_y_lsb_q == 1'b0)
                            raw_sel = (pix_x_lsb_q == 1'b0) ? c1_s : c0_s;
                        else
                            raw_sel = (pix_x_lsb_q == 1'b0) ? c2_s : c1_s;
                    end
                    `VTPGZ_RAW_GBRG: begin
                        if (pix_y_lsb_q == 1'b0)
                            raw_sel = (pix_x_lsb_q == 1'b0) ? c1_s : c2_s;
                        else
                            raw_sel = (pix_x_lsb_q == 1'b0) ? c0_s : c1_s;
                    end
                    default: raw_sel = c1_s; // PLAIN: G channel monochrome
                endcase
                tdata_next = {{(C_AXIS_TDATA_WIDTH-BPC){1'b0}}, raw_sel};
            end
            // verilator coverage_on
        end
    endgenerate

    // ---------------- AXI-Stream output register ----------------
    always @(posedge aclk) begin
        if (!aresetn) begin
            tdata_r  <= {C_AXIS_TDATA_WIDTH{1'b0}};
            tvalid_r <= 1'b0;
            tlast_r  <= 1'b0;
            tuser_r  <= 1'b0;
        end else if (pipe_advance) begin
            tdata_r  <= tdata_next;
            tvalid_r <= pix_valid_q;
            tlast_r  <= pix_eol_q;
            tuser_r  <= pix_sof_q;
        end else if (m_axis_tvalid && m_axis_tready) begin
            tvalid_r <= 1'b0;
            tlast_r  <= 1'b0;
            tuser_r  <= 1'b0;
        end
    end

    assign m_axis_tdata  = tdata_r;
    assign m_axis_tvalid = tvalid_r;
    assign m_axis_tlast  = tlast_r;
    assign m_axis_tuser  = tuser_r;

endmodule
