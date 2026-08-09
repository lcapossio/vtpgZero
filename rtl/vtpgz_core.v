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
    parameter EN_IMAGE      = 0,
    // ---- IMAGE pattern (only used when EN_IMAGE=1) ----
    // IMAGE_W / IMAGE_H: source image dimensions in the BRAM. Both MUST be
    //                   powers of two so the BRAM index is a bit slice.
    //                   Stored as 24-bit packed RGB888 and 8->12 upsampled
    //                   at read time by MSB replication.
    // IMAGE_OUT_W / IMAGE_OUT_H: rendered window dimensions in the active
    //                   region. Any integer >= 1. When equal to IMAGE_W /
    //                   IMAGE_H the image is drawn 1:1 (no scaling);
    //                   otherwise a Bresenham fixed-point accumulator
    //                   nearest-neighbour-scales between source and output
    //                   per axis. Aspect is NOT preserved unless the
    //                   user-chosen ratio matches IMAGE_W:IMAGE_H. The
    //                   window is centred in the active region with black
    //                   padding outside.
    parameter IMAGE_W       = 128,
    parameter IMAGE_H       = 128,
    parameter IMAGE_OUT_W   = IMAGE_W,
    parameter IMAGE_OUT_H   = IMAGE_H,
    parameter IMAGE_HEX_FILE = "tests/images/mandrill_128x128.mem",
    // ---- BOX-image overlay (only used when EN_BOX_IMAGE=1 and
    // ----   EN_MOVING_BOX=1). Same Q16 nearest-neighbour scaler as the
    // ----   IMAGE pattern, but the source rectangle is the bouncing box
    // ----   instead of the whole active region. Step values come from
    // ----   cfg_box_img_{x,y}_step which the host computes whenever
    // ----   cfg_box_{width,height} changes.
    parameter EN_BOX_IMAGE     = 0,
    parameter BOX_IMAGE_W      = 32,
    parameter BOX_IMAGE_H      = 32,
    parameter BOX_IMAGE_HEX_FILE = "tests/images/mandrill_32x32.mem",
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
    // ----- pixels emitted per AXI-Stream beat (build-time) -----
    // 1 (default)  classic one-pixel-per-beat, netlist identical to prior
    //              releases.
    // 2 / 4 / 8    pack that many horizontally-adjacent pixels into one wider
    //              beat, lane 0 (leftmost pixel) in the tdata LSBs. cfg_img_width
    //              is clamped down to a multiple of PIXELS_PER_CLOCK.
    //
    // NOTE (M1 scope): at PIXELS_PER_CLOCK>1 only the position-combinational
    // patterns are supported -- SOLID, GRID, CHECKER, plus the moving-box
    // overlay. The accumulator/counter/stateful patterns (COLORBAR, HGRAD,
    // VGRAD, RAMP, NOISE, IMAGE, BOX_IMAGE) require PIXELS_PER_CLOCK==1 and
    // their EN_* must be 0 for a PPC>1 build -- enforced by an elaboration
    // check below (g_ppc_guard).
    parameter integer PIXELS_PER_CLOCK = 1,
    // ----- AXI4-Stream video line pacing -----
    // Insert this many TVALID-low cycles after each non-final TLAST before
    // emitting the next line. Values below 1 are clamped to the mandatory
    // one-cycle minimum gap.
    parameter integer LINE_GAP_CYCLES = 1,
    // ----- derived per-PIXEL tdata width: the smallest multiple-of-8 that
    // holds the active components for the chosen mode/bpc (do NOT override) --
    parameter PIX_TDATA_WIDTH =
        (OUTPUT_MODE == `VTPGZ_MODE_RGB) ? (((3*BPC + 7) / 8) * 8) :
        (OUTPUT_MODE == `VTPGZ_MODE_RAW) ? (((  BPC + 7) / 8) * 8) :
        /* MODE_YUV */
            (YUV_SUBSAMPLE == `VTPGZ_YUV_444 ? (((3*BPC + 7) / 8) * 8)
                                              : (((2*BPC + 7) / 8) * 8)),
    // ----- derived AXI-Stream beat width = PIXELS_PER_CLOCK per-pixel slots
    // (do NOT override) -----
    parameter C_AXIS_TDATA_WIDTH = PIXELS_PER_CLOCK * PIX_TDATA_WIDTH
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
    input  wire [31:0] cfg_box_img_x_step,
    input  wire [31:0] cfg_box_img_y_step,

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

    // ---------------- pixels-per-clock shorthands ----------------
    localparam integer NPPC = PIXELS_PER_CLOCK;

    // ---------------- elaboration guards ----------------
    // PIXELS_PER_CLOCK must be one of 1/2/4/8. As of M3 every pattern (and
    // the box + box-image overlays) is supported at PPC>1, so there is no
    // longer a per-pattern restriction -- only the legal-value check remains.
    generate
        if (!(NPPC == 1 || NPPC == 2 || NPPC == 4 || NPPC == 8)) begin : g_ppc_bad
            VTPGZ_PIXELS_PER_CLOCK_MUST_BE_1_2_4_OR_8 guard();
        end
    endgenerate

    // Bit-shrink/grow shift amounts (constant): mirror the BPC pack stage.
    localparam integer SHIFT_DN = (BPC <= 12) ? (12 - BPC) : 0;  // truncate LSBs
    localparam integer SHIFT_UP = (BPC >  12) ? (BPC - 12) : 0;  // zero-extend LSBs
    // Legacy-order (components in MSBs) left-shift amounts, clamped to be
    // non-negative for every build. Only the build's native mode is reachable;
    // in a non-native mode's dead branch these could otherwise go negative
    // (3*BPC/2*BPC > PIX_TDATA_WIDTH), so clamp to 0 to keep the dead code
    // width-legal on Verilator 5.020.
    localparam integer PAD3 = (PIX_TDATA_WIDTH >= 3*BPC) ? (PIX_TDATA_WIDTH - 3*BPC) : 0;
    localparam integer PAD2 = (PIX_TDATA_WIDTH >= 2*BPC) ? (PIX_TDATA_WIDTH - 2*BPC) : 0;

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
    // Width is clamped DOWN to a multiple of NPPC (and to at least NPPC) so a
    // whole number of beats covers each line; at NPPC==1 the mask is 0xFFFF
    // and this reduces to the original "zero -> 1" clamp exactly.
    localparam [15:0] WIDTH_ALIGN_MASK = 16'hFFFF - (NPPC - 1);
    reg [15:0] img_width_eff;
    reg [15:0] img_height_eff;
    always @(posedge aclk) begin
        if (!aresetn) begin
            img_width_eff  <= NPPC[15:0];
            img_height_eff <= 16'h1;
        end else begin
            img_width_eff  <= ((cfg_img_width & WIDTH_ALIGN_MASK) == 16'h0)
                                  ? NPPC[15:0]
                                  : (cfg_img_width & WIDTH_ALIGN_MASK);
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

    // Source state advances only while the output pipe can accept another
    // beat. The output register inserts the configured inter-line TVALID-low
    // gap after a non-final TLAST handshake and stalls the upstream pipe while
    // that bubble is emitted.
    localparam [31:0] LINE_GAP_CYCLES_MIN1 =
        (LINE_GAP_CYCLES < 1) ? 32'd1 : LINE_GAP_CYCLES;
    /*verilator coverage_off*/ reg [31:0] axis_gap_cnt; /*verilator coverage_on*/
    reg        teof_r;
    wire axis_handshake = m_axis_tvalid && m_axis_tready;
    wire axis_gap_start =
        axis_handshake && m_axis_tlast && !teof_r;
    wire axis_gap_active = (axis_gap_cnt != 32'h0);
    wire axis_can_advance =
        (!m_axis_tvalid || m_axis_tready) && !axis_gap_start && !axis_gap_active;
    wire source_advance   = active && axis_can_advance;

    // At NPPC pixels/beat the base counter x holds lane 0's coordinate and
    // advances by NPPC; the final beat of a line starts NPPC pixels before
    // the width (width is a multiple of NPPC). At NPPC==1 this is (x==W-1).
    wire        last_x = (x == img_width_eff  - NPPC[15:0]);
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
                    x <= x + NPPC[15:0];
                end
            end
        end
    end

    wire pix_valid = active;
    wire pix_sof   = pix_valid && (x == 16'h0) && (y == 16'h0);
    wire pix_eol   = pix_valid && last_x;
    wire pix_eof   = pix_valid && end_of_frame;

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
    wire [11:0] image_r, image_g, image_b;
    wire [11:0] box_img_r, box_img_g, box_img_b;

    // ---- Per-lane pattern buses (only meaningful for the M1 patterns) ----
    // Lane l (l=0..NPPC-1) occupies bits [12*l +: 12]. Lane 0 always equals
    // the corresponding scalar wire above, so the existing NPPC==1 pattern
    // mux/pipeline is byte-identical. Lanes 1..NPPC-1 carry the value the
    // per-pixel path would produce at (x+l, y) and only exist for NPPC>1.
    wire [12*NPPC-1:0] chk_v_bus;
    wire [12*NPPC-1:0] grid_r_bus, grid_g_bus, grid_b_bus;
    wire [12*NPPC-1:0] cb_r_bus, cb_g_bus, cb_b_bus;   // colorbar palette triple
    wire [12*NPPC-1:0] hg_bus, vg_bus, ramp_bus;       // gray-value patterns
    wire [12*NPPC-1:0] noise_bus;                      // per-lane LFSR value
    wire [12*NPPC-1:0] image_r_bus, image_g_bus, image_b_bus; // per-lane IMAGE
    wire [12*NPPC-1:0] box_img_r_bus, box_img_g_bus, box_img_b_bus; // per-lane box-image

    // ---- Color bars (8 SMPTE bars) ----
    // Counter-based: increment bar index every cfg_bar_width pixels.
    // Host writes BAR_WIDTH = img_width/8 once per resolution change.
    //
    // Mode-aware palette as a function so each lane can look up its own bar
    // index. In RGB/RAW the triple is {R,G,B}; in YUV it is {Y,Cb,Cr}.
    // Returns {c0[12], c1[12], c2[12]}. Constants only -- no DSPs.
    // verilator coverage_off
    // Only the build's OUTPUT_MODE arm is reachable (YUV vs RGB/RAW palette);
    // the other arm is dead code in any single-mode build. Cross-mode
    // correctness is the byte-exact all_modes model gate's job, not this
    // single-config coverage sim.
    function [35:0] bar_palette;
        input [2:0] idx;
        begin
            if (OUTPUT_MODE == `VTPGZ_MODE_YUV) begin
                case (idx)
                    3'd0: bar_palette = {12'hFFF, 12'h800, 12'h800}; // white
                    3'd1: bar_palette = {12'hE2C, 12'h000, 12'h94D}; // yellow
                    3'd2: bar_palette = {12'hB37, 12'hAB3, 12'h000}; // cyan
                    3'd3: bar_palette = {12'h964, 12'h2B4, 12'h14E}; // green
                    3'd4: bar_palette = {12'h69B, 12'hD4C, 12'hEB2}; // magenta
                    3'd5: bar_palette = {12'h4C8, 12'h54D, 12'hFFF}; // red
                    3'd6: bar_palette = {12'h1D3, 12'hFFF, 12'h6B3}; // blue
                    default: bar_palette = {12'h000, 12'h800, 12'h800}; // black
                endcase
            end else begin
                case (idx)
                    3'd0: bar_palette = {12'hFFF, 12'hFFF, 12'hFFF};  // white
                    3'd1: bar_palette = {12'hFFF, 12'hFFF, 12'h000};
                    3'd2: bar_palette = {12'h000, 12'hFFF, 12'hFFF};
                    3'd3: bar_palette = {12'h000, 12'hFFF, 12'h000};
                    3'd4: bar_palette = {12'hFFF, 12'h000, 12'hFFF};
                    3'd5: bar_palette = {12'hFFF, 12'h000, 12'h000};
                    3'd6: bar_palette = {12'h000, 12'h000, 12'hFFF};
                    default: bar_palette = {12'h000, 12'h000, 12'h000};
                endcase
            end
        end
    endfunction
    // verilator coverage_on

    generate if (EN_COLORBAR) begin : g_colorbar
        // Down-counter + parallel-threshold recurrence. bar_left is the count
        // of pixels remaining in the current bar including lane 0's pixel
        // (range [1, bar_width_eff]). Lane k sits q_k bars ahead of bar_idx,
        // where q_k counts the thresholds bar_left + m*bar_width_eff that are
        // <= k -- all NPPC compares evaluate in parallel one adder from the
        // state register, replacing the per-lane chained 16-bit recurrence
        // whose depth grew with NPPC and set the fmax of multi-pixel builds.
        // Exact for any bar width >= 1, including multiple bars per beat.
        reg  [15:0] bar_left;
        reg  [2:0]  bar_idx;

        // Quasi-static multiples of the bar width (m = 0..NPPC).
        wire [19:0] wmul [0:NPPC] /* verilator split_var */;
        assign wmul[0] = 20'h0;
        genvar cbm;
        for (cbm = 1; cbm <= NPPC; cbm = cbm + 1) begin : g_cb_wmul
            assign wmul[cbm] = wmul[cbm-1] + {4'h0, bar_width_eff};
        end

        // Thresholds: one adder each from the registered state.
        wire [19:0] thr [0:NPPC-1] /* verilator split_var */;
        genvar cbt;
        for (cbt = 0; cbt < NPPC; cbt = cbt + 1) begin : g_cb_thr
            assign thr[cbt] = {4'h0, bar_left} + wmul[cbt];
        end

        // Beat-level wrap count: thresholds <= NPPC (NPPC <= 8, 4 bits).
        wire [NPPC-1:0] wr_hit;
        genvar cbw;
        for (cbw = 0; cbw < NPPC; cbw = cbw + 1) begin : g_cb_wrap
            assign wr_hit[cbw] =
                (thr[cbw][19:4] == 16'h0) && (thr[cbw][3:0] <= NPPC[3:0]);
        end
        integer cw;
        reg [3:0] wraps;
        always @* begin
            wraps = 4'h0;
            for (cw = 0; cw < NPPC; cw = cw + 1)
                wraps = wraps + {3'h0, wr_hit[cw]};
        end

        genvar cbl;
        for (cbl = 0; cbl < NPPC; cbl = cbl + 1) begin : g_cb_chain
            // q_k: thresholds <= k (k <= 7, 3 bits).
            wire [NPPC-1:0] q_hit;
            genvar cbq;
            for (cbq = 0; cbq < NPPC; cbq = cbq + 1) begin : g_cb_q
                assign q_hit[cbq] =
                    (thr[cbq][19:3] == 17'h0) && (thr[cbq][2:0] <= cbl[2:0]);
            end
            integer cq;
            reg [2:0] q_k;
            always @* begin
                q_k = 3'h0;
                for (cq = 0; cq < NPPC; cq = cq + 1)
                    q_k = q_k + {2'h0, q_hit[cq]};
            end
            wire [35:0] pal_l = bar_palette(bar_idx + q_k);
            assign cb_r_bus[12*cbl +: 12] = pal_l[35:24];
            assign cb_g_bus[12*cbl +: 12] = pal_l[23:12];
            assign cb_b_bus[12*cbl +: 12] = pal_l[11:0];
        end

        wire [19:0] wrap_add = wmul[wraps > NPPC[3:0] ? NPPC[3:0] : wraps];
        always @(posedge aclk) begin
            if (!aresetn || frame_init) begin
                bar_left <= bar_width_eff;
                bar_idx  <= 3'h0;
            end else if (source_advance) begin
                // Force the bar walk back to bar 0 at the END of each line so
                // the next line's pixel 0 reads bar 0 combinationally (do not
                // also reset on pix_sof -- frame_init already clears the first
                // active pixel; resetting at x=0 would shift every transition
                // one pixel late). Otherwise advance the base by NPPC pixels.
                if (last_x) begin
                    bar_left <= bar_width_eff;
                    bar_idx  <= 3'h0;
                end else begin
                    bar_left <= bar_left + wrap_add[15:0] - NPPC[15:0];
                    bar_idx  <= bar_idx + wraps[2:0];
                end
            end
        end
        assign cb_r = cb_r_bus[11:0];
        assign cb_g = cb_g_bus[11:0];
        assign cb_b = cb_b_bus[11:0];
    end else begin : g_colorbar_off
        assign cb_r = 12'h000;
        assign cb_g = 12'h000;
        assign cb_b = 12'h000;
        assign cb_r_bus = {(12*NPPC){1'b0}};
        assign cb_g_bus = {(12*NPPC){1'b0}};
        assign cb_b_bus = {(12*NPPC){1'b0}};
    end endgenerate

    // ---- Horizontal gradient ----
    // Q4.12 accumulator: increments by cfg_hg_step (Q4.12) per pixel,
    // resets at start of line. Host computes step = (4096<<8)/(width-1)>>8
    // ~ 0xFFF / width, written once per resolution change.
    generate if (EN_HGRAD) begin : g_hgrad
        reg [19:0] hg_acc;  // 4 int + 12 frac of headroom + 4 guard
        // Per-lane accumulator chain: lane gl sees hg_acc + gl*step. The base
        // advances by NPPC*step per beat; at NPPC==1 this is one +step and is
        // identical to the original.
        wire [19:0] hga_l [0:NPPC] /* verilator split_var */;
        assign hga_l[0] = hg_acc;
        genvar hgl;
        for (hgl = 0; hgl < NPPC; hgl = hgl + 1) begin : g_hg_chain
            assign hga_l[hgl+1] = hga_l[hgl] + {4'h0, cfg_hg_step};
            // Saturate each lane to 12 bits.
            assign hg_bus[12*hgl +: 12] =
                (|hga_l[hgl][19:12]) ? 12'hFFF : hga_l[hgl][11:0];
        end
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
                else            hg_acc <= hga_l[NPPC];
            end
        end
        // Saturate to 12 bits (lane 0)
        assign hg_val = hg_bus[11:0];
    end else begin : g_hgrad_off
        assign hg_val = 12'h000;
        assign hg_bus = {(12*NPPC){1'b0}};
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
        // vg_acc only changes per LINE, so every lane in a beat shares the
        // same value -- replicate it across the bus.
        assign vg_val = (|vg_acc[19:12]) ? 12'hFFF : vg_acc[11:0];
        genvar vgl;
        for (vgl = 0; vgl < NPPC; vgl = vgl + 1) begin : g_vg_lane
            assign vg_bus[12*vgl +: 12] = vg_val;
        end
    end else begin : g_vgrad_off
        assign vg_val = 12'h000;
        assign vg_bus = {(12*NPPC){1'b0}};
    end endgenerate

    // ---- Checkerboard ----
    // Two wrap-counters (one X per pixel, one Y per line) toggle a sel bit
    // each time they reach cfg_checker_size. No divider, no modulo.
    generate if (EN_CHECKER) begin : g_checker
        wire [15:0] chk_size_eff = (cfg_checker_size == 16'h0) ? 16'h1 : cfg_checker_size;
        // Down-counter + parallel thresholds (see g_colorbar): chk_left is
        // the count of pixels left in the current cell including lane 0's
        // pixel; lane l's select is the base select XORed with the parity of
        // thresholds chk_left + m*size <= l. One adder from the state
        // register per threshold, no per-lane chain.
        reg  [15:0] chk_left;
        reg         chk_sel_x, chk_sel_y;
        reg  [15:0] chk_y_cnt;

        wire [19:0] cwmul [0:NPPC] /* verilator split_var */;
        assign cwmul[0] = 20'h0;
        genvar km;
        for (km = 1; km <= NPPC; km = km + 1) begin : g_chk_wmul
            assign cwmul[km] = cwmul[km-1] + {4'h0, chk_size_eff};
        end
        wire [19:0] cthr [0:NPPC-1] /* verilator split_var */;
        genvar kt;
        for (kt = 0; kt < NPPC; kt = kt + 1) begin : g_chk_thr
            assign cthr[kt] = {4'h0, chk_left} + cwmul[kt];
        end
        wire [NPPC-1:0] cwr_hit;
        genvar kw;
        for (kw = 0; kw < NPPC; kw = kw + 1) begin : g_chk_wrap
            assign cwr_hit[kw] =
                (cthr[kw][19:4] == 16'h0) && (cthr[kw][3:0] <= NPPC[3:0]);
        end
        integer kc;
        reg [3:0] cwraps;
        always @* begin
            cwraps = 4'h0;
            for (kc = 0; kc < NPPC; kc = kc + 1)
                cwraps = cwraps + {3'h0, cwr_hit[kc]};
        end

        genvar gl;
        for (gl = 0; gl < NPPC; gl = gl + 1) begin : g_chk_chain
            wire [NPPC-1:0] q_hit;
            genvar kq;
            for (kq = 0; kq < NPPC; kq = kq + 1) begin : g_chk_q
                assign q_hit[kq] =
                    (cthr[kq][19:3] == 17'h0) && (cthr[kq][2:0] <= gl[2:0]);
            end
            wire sel_l = chk_sel_x ^ (^q_hit);
            assign chk_v_bus[12*gl +: 12] =
                (sel_l ^ chk_sel_y) ? 12'hFFF : 12'h000;
        end

        wire [19:0] cwrap_add = cwmul[cwraps > NPPC[3:0] ? NPPC[3:0] : cwraps];
        always @(posedge aclk) begin
            if (!aresetn || frame_init) begin
                chk_left  <= chk_size_eff;
                chk_y_cnt <= 16'h0;
                chk_sel_x <= 1'b0;
                chk_sel_y <= 1'b0;
            end else if (source_advance) begin
                // X axis -- anchor reset on last_x of the previous line
                // (same reasoning as colorbar / hgrad).
                if (last_x) begin
                    chk_left  <= chk_size_eff;
                    chk_sel_x <= 1'b0;
                end else begin
                    chk_left  <= chk_left + cwrap_add[15:0] - NPPC[15:0];
                    chk_sel_x <= chk_sel_x ^ (^cwr_hit);
                end
                // Y axis (per-line) -- unchanged by NPPC.
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
        assign chk_v = chk_v_bus[11:0];   // lane 0
    end else begin : g_checker_off
        assign chk_v     = 12'h000;
        assign chk_v_bus = {(12*NPPC){1'b0}};
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
    wire box_in;                       // lane 0 (== box_in_bus[0])
    wire [NPPC-1:0] box_in_bus;        // per-lane box-region membership
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
        // Per-lane box membership: lane gl tests column (x+gl). The y test is
        // common to all lanes in a beat. At NPPC==1 lane 0 is exactly the
        // original expression.
        wire box_in_y = (y >= box_y) && (y < box_y + box_height_eff);
        genvar gbl;
        for (gbl = 0; gbl < NPPC; gbl = gbl + 1) begin : g_box_lane
            wire [15:0] xl = x + gbl[15:0];
            assign box_in_bus[gbl] = (xl >= box_x) && (xl < box_x + box_width_eff) &&
                                     box_in_y;
        end
        assign box_in = box_in_bus[0];
    end else begin : g_box_off
        assign box_in     = 1'b0;
        assign box_in_bus = {NPPC{1'b0}};
    end endgenerate

    // ---- Grid / crosshatch ----
    // Wrap-counters per axis, "on grid" when counter is at zero.
    generate if (EN_GRID) begin : g_grid
        wire [15:0] grid_eff = (cfg_grid_spacing == 16'h0) ? 16'h1 : cfg_grid_spacing;
        // g_nc = lanes until the next on-column pixel (0 = lane 0 is on a
        // column). Lane l is on a column iff some threshold g_nc + m*spacing
        // equals l -- parallel equality tests one adder from the state
        // register, replacing the per-lane chained wrap recurrence.
        reg  [15:0] g_nc;
        reg  [15:0] gy_cnt;

        wire [19:0] gwmul [0:NPPC] /* verilator split_var */;
        assign gwmul[0] = 20'h0;
        genvar gm;
        for (gm = 1; gm <= NPPC; gm = gm + 1) begin : g_grid_wmul
            assign gwmul[gm] = gwmul[gm-1] + {4'h0, grid_eff};
        end
        wire [19:0] gthr [0:NPPC-1] /* verilator split_var */;
        genvar gt;
        for (gt = 0; gt < NPPC; gt = gt + 1) begin : g_grid_thr
            assign gthr[gt] = {4'h0, g_nc} + gwmul[gt];
        end
        // Columns consumed this beat: thresholds < NPPC.
        wire [NPPC-1:0] gwr_hit;
        genvar gw;
        for (gw = 0; gw < NPPC; gw = gw + 1) begin : g_grid_wrap
            assign gwr_hit[gw] =
                (gthr[gw][19:4] == 16'h0) && (gthr[gw][3:0] < NPPC[3:0]);
        end
        integer gc;
        reg [3:0] gwraps;
        always @* begin
            gwraps = 4'h0;
            for (gc = 0; gc < NPPC; gc = gc + 1)
                gwraps = gwraps + {3'h0, gwr_hit[gc]};
        end
        // Per-lane on-column: some threshold equals the lane index.
        wire [NPPC-1:0] g_on_col;
        genvar gl;
        for (gl = 0; gl < NPPC; gl = gl + 1) begin : g_grid_chain
            wire [NPPC-1:0] eq_hit;
            genvar gq;
            for (gq = 0; gq < NPPC; gq = gq + 1) begin : g_grid_q
                assign eq_hit[gq] =
                    (gthr[gq][19:3] == 17'h0) && (gthr[gq][2:0] == gl[2:0]);
            end
            assign g_on_col[gl] = |eq_hit;
        end

        wire [19:0] gwrap_add = gwmul[gwraps > NPPC[3:0] ? NPPC[3:0] : gwraps];
        always @(posedge aclk) begin
            if (!aresetn || frame_init) begin
                g_nc   <= 16'h0;
                gy_cnt <= 16'h0;
            end else if (source_advance) begin
                if (last_x) g_nc <= 16'h0;
                else        g_nc <= g_nc + gwrap_add[15:0] - NPPC[15:0];

                if (pix_sof)                                  gy_cnt <= 16'h0;
                else if (last_x) begin
                    if (gy_cnt + 16'h1 >= grid_eff)          gy_cnt <= 16'h0;
                    else                                      gy_cnt <= gy_cnt + 16'h1;
                end
            end
        end
        // Off-grid background must be {Y=0, Cb=neutral, Cr=neutral} in YUV mode,
        // otherwise the receiver's YCbCr->RGB renders {0,0,0} as ~(0,135,0)
        // green. The other gray-style patterns get the same treatment in the
        // _c1/_c2 helpers below.
        wire [11:0] bg_c1 = (OUTPUT_MODE == `VTPGZ_MODE_YUV) ? 12'h800 : 12'h000;
        wire [11:0] bg_c2 = (OUTPUT_MODE == `VTPGZ_MODE_YUV) ? 12'h800 : 12'h000;
        for (gl = 0; gl < NPPC; gl = gl + 1) begin : g_grid_lane
            wire on_grid_l = g_on_col[gl] || (gy_cnt == 16'h0);
            assign grid_r_bus[12*gl +: 12] = on_grid_l ? {cfg_grid_color[23:16],4'h0} : 12'h000;
            assign grid_g_bus[12*gl +: 12] = on_grid_l ? {cfg_grid_color[15:8], 4'h0} : bg_c1;
            assign grid_b_bus[12*gl +: 12] = on_grid_l ? {cfg_grid_color[7:0],  4'h0} : bg_c2;
        end
        assign grid_r = grid_r_bus[11:0];   // lane 0
        assign grid_g = grid_g_bus[11:0];
        assign grid_b = grid_b_bus[11:0];
    end else begin : g_grid_off
        assign grid_r = 12'h000;
        assign grid_g = (OUTPUT_MODE == `VTPGZ_MODE_YUV) ? 12'h800 : 12'h000;
        assign grid_b = (OUTPUT_MODE == `VTPGZ_MODE_YUV) ? 12'h800 : 12'h000;
        // Off-lanes replicate the lane-0 background across the bus.
        genvar gof;
        for (gof = 0; gof < NPPC; gof = gof + 1) begin : g_grid_off_bus
            assign grid_r_bus[12*gof +: 12] = 12'h000;
            assign grid_g_bus[12*gof +: 12] = (OUTPUT_MODE == `VTPGZ_MODE_YUV) ? 12'h800 : 12'h000;
            assign grid_b_bus[12*gof +: 12] = (OUTPUT_MODE == `VTPGZ_MODE_YUV) ? 12'h800 : 12'h000;
        end
    end endgenerate

    // ---- Ramp ----
    // Same accumulator approach as hgrad. Reuses cfg_hg_step.
    generate if (EN_RAMP) begin : g_ramp
        reg [19:0] ramp_acc;
        // Per-lane accumulator chain (same structure as hgrad).
        wire [19:0] rmp_l [0:NPPC] /* verilator split_var */;
        assign rmp_l[0] = ramp_acc;
        genvar rml;
        for (rml = 0; rml < NPPC; rml = rml + 1) begin : g_ramp_chain
            assign rmp_l[rml+1] = rmp_l[rml] + {4'h0, cfg_hg_step};
            assign ramp_bus[12*rml +: 12] =
                (|rmp_l[rml][19:12]) ? 12'hFFF : rmp_l[rml][11:0];
        end
        always @(posedge aclk) begin
            if (!aresetn || frame_init) ramp_acc <= 20'h0;
            else if (source_advance) begin
                if (last_x)     ramp_acc <= 20'h0;
                else            ramp_acc <= rmp_l[NPPC];
            end
        end
        assign ramp_v = ramp_bus[11:0];
    end else begin : g_ramp_off
        assign ramp_v = 12'h000;
        assign ramp_bus = {(12*NPPC){1'b0}};
    end endgenerate

    // ---- Noise (LFSR-16) ----
    // The LFSR advances one step per pixel and runs continuously across a
    // frame (re-seeded only on frame_init, NOT reset per line). For NPPC>1
    // each lane needs the state N consecutive steps apart, so we leap-ahead
    // by unrolling the single-step feedback NPPC times combinationally: lane
    // gl reads lf_l[gl], and the base register jumps to lf_l[NPPC] each beat.
    // At NPPC==1 this is a single step -- identical to the original.
    generate if (EN_NOISE) begin : g_noise
        reg [15:0] lfsr;
        wire [15:0] lf_l [0:NPPC] /* verilator split_var */;
        assign lf_l[0] = lfsr;
        genvar nl;
        for (nl = 0; nl < NPPC; nl = nl + 1) begin : g_noise_chain
            wire fb_l = lf_l[nl][15] ^ lf_l[nl][13] ^ lf_l[nl][12] ^ lf_l[nl][10];
            assign lf_l[nl+1] = {lf_l[nl][14:0], fb_l};
            assign noise_bus[12*nl +: 12] = lf_l[nl][11:0];
        end
        always @(posedge aclk) begin
            if (!aresetn || frame_init) lfsr <= 16'hACE1;
            else if (source_advance)    lfsr <= lf_l[NPPC];
        end
        assign noise_v = noise_bus[11:0];
    end else begin : g_noise_off
        assign noise_v   = 12'h000;
        assign noise_bus = {(12*NPPC){1'b0}};
    end endgenerate

    // ---- IMAGE (BRAM-baked synth-time image, with optional nearest-
    //      neighbour scaling) ----
    // 24-bit packed RGB888 in inferred block RAM, init via $readmemh.
    // The image is drawn ONCE per frame, centred in the active region,
    // with black padding around it. When IMAGE_OUT_W != IMAGE_W (or
    // IMAGE_OUT_H != IMAGE_H), a per-axis Q16 accumulator nearest-
    // neighbour-scales the source to the output window. Step values are
    // computed at elaboration so the run-time cost is just two adders
    // and two registers.
    generate if (EN_IMAGE) begin : g_image
        // verilator coverage_off
        localparam IMG_LOG2W   = $clog2(IMAGE_W);
        localparam IMG_LOG2H   = $clog2(IMAGE_H);
        localparam IMG_DEPTH   = IMAGE_W * IMAGE_H;
        localparam IMG_ADDR_W  = IMG_LOG2W + IMG_LOG2H;
        // Q16 fractional step per output pixel. ACC_W = IMG_LOG2{W,H} + 16
        // so the integer part is exactly the source index width.
        localparam FRAC_BITS   = 16;
        localparam IMG_X_STEP  = (IMAGE_W * (1 << FRAC_BITS)) / IMAGE_OUT_W;
        localparam IMG_Y_STEP  = (IMAGE_H * (1 << FRAC_BITS)) / IMAGE_OUT_H;
        localparam ACC_X_W     = IMG_LOG2W + FRAC_BITS;
        localparam ACC_Y_W     = IMG_LOG2H + FRAC_BITS;

        // Centred window offsets. Clamped to 0 if the output window is
        // wider/taller than the active region (image truncated, no error).
        wire [15:0] img_x_off = (img_width_eff  > IMAGE_OUT_W)
                              ? ((img_width_eff  - IMAGE_OUT_W) >> 1) : 16'h0;
        wire [15:0] img_y_off = (img_height_eff > IMAGE_OUT_H)
                              ? ((img_height_eff - IMAGE_OUT_H) >> 1) : 16'h0;
        wire in_image_y = (y >= img_y_off) && (y < img_y_off + IMAGE_OUT_H);

        // Y accumulator (shared across lanes -- y is common to a beat). Step
        // at end of each line that lies in the image-y window. Anchor the
        // reset on end_of_frame (one cycle BEFORE the next frame's pix_sof)
        // so cycle (x=0, y=0) reads acc_y=0 combinationally.
        reg [ACC_Y_W-1:0] acc_y;
        always @(posedge aclk) begin
            if (!aresetn || frame_init)               acc_y <= {ACC_Y_W{1'b0}};
            else if (source_advance) begin
                if (end_of_frame)                     acc_y <= {ACC_Y_W{1'b0}};
                else if (last_x && in_image_y)        acc_y <= acc_y + IMG_Y_STEP[ACC_Y_W-1:0];
            end
        end
        wire [IMG_LOG2H-1:0] src_y = acc_y[ACC_Y_W-1 -: IMG_LOG2H];

        if (NPPC == 1) begin : g_img_ppc1
            // ---- NPPC==1: original single-BRAM registered-read path ----
            // Synchronous read maps into the BRAM DOUT register for timing;
            // costs a uniform 1-px horizontal shift (unchanged from before).
            (* ram_style = "block" *)
            reg [23:0] image_mem [0:IMG_DEPTH-1];
            initial begin
                $readmemh(IMAGE_HEX_FILE, image_mem);
            end
            wire in_image = in_image_y &&
                            (x >= img_x_off) && (x < img_x_off + IMAGE_OUT_W);
            reg [ACC_X_W-1:0] acc_x;
            always @(posedge aclk) begin
                if (!aresetn || frame_init)        acc_x <= {ACC_X_W{1'b0}};
                else if (source_advance) begin
                    if (last_x)                    acc_x <= {ACC_X_W{1'b0}};
                    else if (in_image)             acc_x <= acc_x + IMG_X_STEP[ACC_X_W-1:0];
                end
            end
            wire [IMG_LOG2W-1:0] src_x = acc_x[ACC_X_W-1 -: IMG_LOG2W];
            wire [IMG_ADDR_W-1:0] image_addr = {src_y, src_x};
            reg  [23:0] image_word_q;
            reg         in_image_q;
            always @(posedge aclk) begin
                image_word_q <= image_mem[image_addr];
                in_image_q   <= in_image;
            end
            wire [7:0] img_r8 = image_word_q[23:16];
            wire [7:0] img_g8 = image_word_q[15:8];
            wire [7:0] img_b8 = image_word_q[7:0];
            assign image_r = in_image_q ? {img_r8, img_r8[7:4]} : 12'h000;
            assign image_g = in_image_q ? {img_g8, img_g8[7:4]} : 12'h000;
            assign image_b = in_image_q ? {img_b8, img_b8[7:4]} : 12'h000;
            assign image_r_bus = image_r;   // NPPC==1: bus == lane 0
            assign image_g_bus = image_g;
            assign image_b_bus = image_b;
        end else begin : g_img_ppcN
            // ---- NPPC>1: N replicated memories, combinational read ----
            // Each lane reads its own copy at column (x+lane), so the image
            // is shift-free and matches the reference model exactly (the
            // NPPC==1 registered read's 1-px shift does not apply). Cost is
            // N image copies -- keep IMAGE_W/H modest for high PPC.
            reg [ACC_X_W-1:0] acc_x;   // base = lane 0 acc at pixel x
            wire [ACC_X_W-1:0] axc [0:NPPC] /* verilator split_var */;
            assign axc[0] = acc_x;
            genvar il;
            for (il = 0; il < NPPC; il = il + 1) begin : g_img_lane
                wire [15:0] xl = x + il[15:0];
                wire in_img_l = in_image_y &&
                                (xl >= img_x_off) && (xl < img_x_off + IMAGE_OUT_W);
                // Advance the accumulator only across in-window columns, so
                // lane gl sees acc = (col - off)*step, i.e. src = model's
                // ((X-off)*step>>16) & (IMAGE_W-1).
                assign axc[il+1] = in_img_l ? (axc[il] + IMG_X_STEP[ACC_X_W-1:0])
                                            : axc[il];
                wire [IMG_LOG2W-1:0] sx_l = axc[il][ACC_X_W-1 -: IMG_LOG2W];
                wire [IMG_ADDR_W-1:0] addr_l = {src_y, sx_l};
                (* ram_style = "block" *)
                reg [23:0] mem_l [0:IMG_DEPTH-1];
                initial begin
                    $readmemh(IMAGE_HEX_FILE, mem_l);
                end
                reg [23:0] word_l;
                always @* word_l = mem_l[addr_l];
                wire [7:0] r8 = word_l[23:16];
                wire [7:0] g8 = word_l[15:8];
                wire [7:0] b8 = word_l[7:0];
                assign image_r_bus[12*il +: 12] = in_img_l ? {r8, r8[7:4]} : 12'h000;
                assign image_g_bus[12*il +: 12] = in_img_l ? {g8, g8[7:4]} : 12'h000;
                assign image_b_bus[12*il +: 12] = in_img_l ? {b8, b8[7:4]} : 12'h000;
            end
            always @(posedge aclk) begin
                if (!aresetn || frame_init) acc_x <= {ACC_X_W{1'b0}};
                else if (source_advance) begin
                    if (last_x) acc_x <= {ACC_X_W{1'b0}};
                    else        acc_x <= axc[NPPC];
                end
            end
            assign image_r = image_r_bus[11:0];
            assign image_g = image_g_bus[11:0];
            assign image_b = image_b_bus[11:0];
        end
        // verilator coverage_on
    end else begin : g_image_off
        assign image_r = 12'h000;
        assign image_g = 12'h000;
        assign image_b = 12'h000;
        assign image_r_bus = {(12*NPPC){1'b0}};
        assign image_g_bus = {(12*NPPC){1'b0}};
        assign image_b_bus = {(12*NPPC){1'b0}};
    end endgenerate

    // ---- BOX-image overlay ----
    // Same Q16 scaler as the IMAGE pattern, but the source rectangle is
    // the bouncing box. Source-pixel index runs from 0..BOX_IMAGE_{W,H}-1
    // across the box's current width/height (which are runtime cfg_*
    // values, so the per-pixel step is a runtime register -- host computes
    // cfg_box_img_x_step = (BOX_IMAGE_W << 16) / cfg_box_width whenever
    // the box geometry changes, mirroring how HG_STEP / VG_STEP work).
    // Output is muxed into the pixel mux below at the same point as
    // cfg_box_color; the border (when border_width > 0) still draws on top
    // and remains the solid cfg_box_border_color.
    generate if (EN_BOX_IMAGE && EN_MOVING_BOX) begin : g_box_image
        // verilator coverage_off
        localparam BIMG_LOG2W  = $clog2(BOX_IMAGE_W);
        localparam BIMG_LOG2H  = $clog2(BOX_IMAGE_H);
        localparam BIMG_DEPTH  = BOX_IMAGE_W * BOX_IMAGE_H;
        localparam BIMG_ADDR_W = BIMG_LOG2W + BIMG_LOG2H;
        localparam BIMG_FRAC   = 16;
        localparam BIMG_ACC_X_W = BIMG_LOG2W + BIMG_FRAC;
        localparam BIMG_ACC_Y_W = BIMG_LOG2H + BIMG_FRAC;

        // Y accumulator (shared across lanes). Zero on end_of_frame, step at
        // last_x of each line inside box-y.
        wire bimg_in_y = (y >= g_box.box_y) &&
                         (y <  g_box.box_y + box_height_eff);
        reg [BIMG_ACC_Y_W-1:0] bimg_acc_y;
        always @(posedge aclk) begin
            if (!aresetn || frame_init) bimg_acc_y <= {BIMG_ACC_Y_W{1'b0}};
            else if (source_advance) begin
                if (end_of_frame)                 bimg_acc_y <= {BIMG_ACC_Y_W{1'b0}};
                else if (last_x && bimg_in_y)     bimg_acc_y <= bimg_acc_y +
                                                                cfg_box_img_y_step[BIMG_ACC_Y_W-1:0];
            end
        end
        wire [BIMG_LOG2H-1:0] bimg_src_y = bimg_acc_y[BIMG_ACC_Y_W-1 -: BIMG_LOG2H];

        if (NPPC == 1) begin : g_bimg_ppc1
            // ---- NPPC==1: original single-BRAM registered-read path ----
            (* ram_style = "block" *)
            reg [23:0] box_image_mem [0:BIMG_DEPTH-1];
            initial begin
                $readmemh(BOX_IMAGE_HEX_FILE, box_image_mem);
            end
            wire bimg_in_x = (x >= g_box.box_x) &&
                             (x <  g_box.box_x + box_width_eff);
            reg [BIMG_ACC_X_W-1:0] bimg_acc_x;
            always @(posedge aclk) begin
                if (!aresetn || frame_init) bimg_acc_x <= {BIMG_ACC_X_W{1'b0}};
                else if (source_advance) begin
                    if (last_x)                bimg_acc_x <= {BIMG_ACC_X_W{1'b0}};
                    else if (bimg_in_x)        bimg_acc_x <= bimg_acc_x +
                                                              cfg_box_img_x_step[BIMG_ACC_X_W-1:0];
                end
            end
            wire [BIMG_LOG2W-1:0] bimg_src_x = bimg_acc_x[BIMG_ACC_X_W-1 -: BIMG_LOG2W];
            wire [BIMG_ADDR_W-1:0] bimg_addr = {bimg_src_y, bimg_src_x};
            // Synchronous read (BRAM DOUT reg) -- costs the same uniform 1-px
            // shift as the IMAGE pattern (kept identical to prior releases).
            reg [23:0] bimg_word_q;
            always @(posedge aclk) begin
                bimg_word_q <= box_image_mem[bimg_addr];
            end
            wire [7:0] bimg_r8 = bimg_word_q[23:16];
            wire [7:0] bimg_g8 = bimg_word_q[15:8];
            wire [7:0] bimg_b8 = bimg_word_q[7:0];
            assign box_img_r = {bimg_r8, bimg_r8[7:4]};
            assign box_img_g = {bimg_g8, bimg_g8[7:4]};
            assign box_img_b = {bimg_b8, bimg_b8[7:4]};
            assign box_img_r_bus = box_img_r;
            assign box_img_g_bus = box_img_g;
            assign box_img_b_bus = box_img_b;
        end else begin : g_bimg_ppcN
            // ---- NPPC>1: N replicated memories, combinational shift-free ----
            reg [BIMG_ACC_X_W-1:0] bimg_acc_x;   // base = lane 0 acc at pixel x
            wire [BIMG_ACC_X_W-1:0] bxc [0:NPPC] /* verilator split_var */;
            assign bxc[0] = bimg_acc_x;
            genvar bil;
            for (bil = 0; bil < NPPC; bil = bil + 1) begin : g_bimg_lane
                wire [15:0] xl = x + bil[15:0];
                wire bin_x_l = (xl >= g_box.box_x) &&
                               (xl <  g_box.box_x + box_width_eff);
                assign bxc[bil+1] = bin_x_l ? (bxc[bil] +
                                               cfg_box_img_x_step[BIMG_ACC_X_W-1:0])
                                            : bxc[bil];
                wire [BIMG_LOG2W-1:0] sx_l = bxc[bil][BIMG_ACC_X_W-1 -: BIMG_LOG2W];
                wire [BIMG_ADDR_W-1:0] addr_l = {bimg_src_y, sx_l};
                (* ram_style = "block" *)
                reg [23:0] mem_l [0:BIMG_DEPTH-1];
                initial begin
                    $readmemh(BOX_IMAGE_HEX_FILE, mem_l);
                end
                reg [23:0] word_l;
                always @* word_l = mem_l[addr_l];
                wire [7:0] r8 = word_l[23:16];
                wire [7:0] g8 = word_l[15:8];
                wire [7:0] b8 = word_l[7:0];
                assign box_img_r_bus[12*bil +: 12] = {r8, r8[7:4]};
                assign box_img_g_bus[12*bil +: 12] = {g8, g8[7:4]};
                assign box_img_b_bus[12*bil +: 12] = {b8, b8[7:4]};
            end
            always @(posedge aclk) begin
                if (!aresetn || frame_init) bimg_acc_x <= {BIMG_ACC_X_W{1'b0}};
                else if (source_advance) begin
                    if (last_x) bimg_acc_x <= {BIMG_ACC_X_W{1'b0}};
                    else        bimg_acc_x <= bxc[NPPC];
                end
            end
            assign box_img_r = box_img_r_bus[11:0];
            assign box_img_g = box_img_g_bus[11:0];
            assign box_img_b = box_img_b_bus[11:0];
        end
        // verilator coverage_on
    end else begin : g_box_image_off
        assign box_img_r = 12'h000;
        assign box_img_g = 12'h000;
        assign box_img_b = 12'h000;
        assign box_img_r_bus = {(12*NPPC){1'b0}};
        assign box_img_g_bus = {(12*NPPC){1'b0}};
        assign box_img_b_bus = {(12*NPPC){1'b0}};
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
            `VTPGZ_PAT_IMAGE     : begin pat_c0 = image_r; pat_c1 = image_g; pat_c2 = image_b; end
            // verilator coverage_off
            default              : begin pat_c0 = 12'h0;   pat_c1 = 12'h0;   pat_c2 = 12'h0;   end
            // verilator coverage_on
        endcase
    end

    // ---- Per-lane pattern mux (NPPC>1 only) ----
    // Lanes 1..NPPC-1 select among the M1 patterns (SOLID / GRID / CHECKER)
    // for column (x+l). Lane 0 uses the full pat_c0/c1/c2 mux above, so the
    // NPPC==1 datapath is untouched. The stateful/accumulator patterns are
    // elaboration-forbidden at NPPC>1 (g_ppc_guard), so a black default here
    // is never selected in a legal build.
    // Gated on NPPC>1: at NPPC==1 the pipeline latches lane 0 from the scalar
    // pat_c0/c1/c2 above and never reads this bus, so building it would be
    // dead logic. Explicitly stripping it (rather than leaning on synthesis
    // DCE) keeps the 1ppc build provably identical to prior releases. The
    // loop also starts at lane 1 -- lane 0 of the bus is always sourced from
    // the scalar mux -- so no lane's mux is duplicated at any NPPC.
    // verilator coverage_off
    // At NPPC==1 these per-lane pattern buses are tied to 0 (g_pat_lanes_off)
    // and never toggle; they carry real data only at NPPC>1, which the
    // coverage sim (PPC=1) does not build. PPC>1 is verified by the cocotb
    // data-path suite and the iverilog beat-exact gate.
    wire [12*NPPC-1:0] pat_c0_bus, pat_c1_bus, pat_c2_bus;
    // verilator coverage_on
    genvar gpl;
    generate if (NPPC > 1) begin : g_pat_lanes
      assign pat_c0_bus[11:0] = 12'h0;   // lane 0 unused (scalar path drives it)
      assign pat_c1_bus[11:0] = 12'h0;
      assign pat_c2_bus[11:0] = 12'h0;
      for (gpl = 1; gpl < NPPC; gpl = gpl + 1) begin : g_pat_lane
        wire [11:0] chkl  = chk_v_bus[12*gpl +: 12];
        wire [11:0] hgl   = hg_bus  [12*gpl +: 12];
        wire [11:0] vgl   = vg_bus  [12*gpl +: 12];
        wire [11:0] rmpl  = ramp_bus[12*gpl +: 12];
        wire [11:0] nzl   = noise_bus[12*gpl +: 12];
        // Gray-to-triple chroma for the build's color space (see the scalar
        // hg_c1/hg_c2 helpers): luma in c0, neutral chroma in c1/c2 for YUV.
        wire [11:0] chkl_c = is_yuv_build ? CHROMA_NEUTRAL : chkl;
        wire [11:0] hgl_c  = is_yuv_build ? CHROMA_NEUTRAL : hgl;
        wire [11:0] vgl_c  = is_yuv_build ? CHROMA_NEUTRAL : vgl;
        wire [11:0] rmpl_c = is_yuv_build ? CHROMA_NEUTRAL : rmpl;
        wire [11:0] nzl_c  = is_yuv_build ? CHROMA_NEUTRAL : nzl;
        reg [11:0] p0, p1, p2;
        always @* begin
            case (cfg_pattern)
                `VTPGZ_PAT_COLORBAR: begin p0 = cb_r_bus[12*gpl +: 12];
                                           p1 = cb_g_bus[12*gpl +: 12];
                                           p2 = cb_b_bus[12*gpl +: 12]; end
                `VTPGZ_PAT_HGRAD   : begin p0 = hgl;     p1 = hgl_c;   p2 = hgl_c;   end
                `VTPGZ_PAT_VGRAD   : begin p0 = vgl;     p1 = vgl_c;   p2 = vgl_c;   end
                `VTPGZ_PAT_CHECKER : begin p0 = chkl;    p1 = chkl_c;  p2 = chkl_c;  end
                `VTPGZ_PAT_SOLID   : begin p0 = solid_r; p1 = solid_g; p2 = solid_b; end
                `VTPGZ_PAT_GRID    : begin p0 = grid_r_bus[12*gpl +: 12];
                                           p1 = grid_g_bus[12*gpl +: 12];
                                           p2 = grid_b_bus[12*gpl +: 12]; end
                `VTPGZ_PAT_RAMP    : begin p0 = rmpl;    p1 = rmpl_c;  p2 = rmpl_c;  end
                `VTPGZ_PAT_NOISE   : begin p0 = nzl;     p1 = nzl_c;   p2 = nzl_c;   end
                `VTPGZ_PAT_IMAGE   : begin p0 = image_r_bus[12*gpl +: 12];
                                           p1 = image_g_bus[12*gpl +: 12];
                                           p2 = image_b_bus[12*gpl +: 12]; end
                default            : begin p0 = 12'h0;   p1 = 12'h0;   p2 = 12'h0;   end
            endcase
        end
        assign pat_c0_bus[12*gpl +: 12] = p0;
        assign pat_c1_bus[12*gpl +: 12] = p1;
        assign pat_c2_bus[12*gpl +: 12] = p2;
      end
    end else begin : g_pat_lanes_off
      assign pat_c0_bus = 12'h0;
      assign pat_c1_bus = 12'h0;
      assign pat_c2_bus = 12'h0;
    end endgenerate

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
    wire box_on_border;                       // lane 0 (== box_on_border_bus[0])
    // verilator coverage_on
    wire [NPPC-1:0] box_on_border_bus;        // per-lane border-ring membership
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
        // Per-lane: lane gl tests column (x+gl); the y-edge terms are common.
        genvar gbb;
        for (gbb = 0; gbb < NPPC; gbb = gbb + 1) begin : g_border_lane
            wire [15:0] xl = x + gbb[15:0];
            assign box_on_border_bus[gbb] = box_in_bus[gbb] && (
                (xl          <  g_box.box_x + bw_x) ||
                (xl + bw_x   >= g_box.box_x + box_width_eff) ||
                (y           <  g_box.box_y + bw_y) ||
                (y + bw_y    >= g_box.box_y + box_height_eff)
            );
        end
        assign box_on_border = box_on_border_bus[0];
    end else begin : g_box_border_off
        assign box_on_border     = 1'b0;
        assign box_on_border_bus = {NPPC{1'b0}};
    end endgenerate

    // ---------------- pipeline stage 1 (pre-mux register) ----------------
    // Break the long combinational fan-out from the box-position registers
    // (g_box.box_x / box_y) through the border-compare OR-tree into the
    // final pix_c0/c1/c2 mux. Registering box_in / box_on_border here
    // caps that path at the adders+compares and leaves only a 3:1 mux
    // feeding pix_cN_q in stage 2.
    // Per-lane at NPPC>1: lane l occupies bit l (flags) / [12*l +: 12] (triples).
    // Lane 0 latches the existing scalar signals so the NPPC==1 path is
    // byte-identical; lanes 1..NPPC-1 latch the per-lane buses.
    reg [NPPC-1:0]     box_in_s1, box_on_border_s1;
    reg [12*NPPC-1:0]  pat_c0_s1, pat_c1_s1, pat_c2_s1;
    // Box-image colours land in their own s1 registers so the mux at this
    // stage gets a value computed from the SAME cycle's x,y as box_in_s1
    // (the combinational box_img_* would otherwise be one cycle ahead).
    // Per-lane like the pattern buses: lane 0 in [11:0], lanes 1..N-1 above.
    reg [12*NPPC-1:0] box_img_r_s1, box_img_g_s1, box_img_b_s1;
    reg        pix_valid_s1, pix_sof_s1, pix_eol_s1, pix_eof_s1;
    reg        pix_x_lsb_s1, pix_y_lsb_s1;
    wire       pipe_advance;
    // Single-driver latch: lane 0 from the scalar mux, lanes 1..NPPC-1 from
    // the per-lane buses, all in ONE always block. A separate generate always
    // block per lane (the prior structure) leaves each packed s1 register
    // multi-driven; Vivado then preserves the reset/GND driver for the upper
    // lanes and silently drops the per-lane driver (Synth 8-6858/8-6859),
    // zeroing lanes 1..N-1 in silicon while sim tolerates the slice writes.
    // The loop bound is a constant, so at NPPC==1 it unrolls to nothing and
    // the 1ppc build stays byte-identical to prior releases.
    integer li_s1;
    always @(posedge aclk) begin
        if (!aresetn) begin
            box_in_s1        <= {NPPC{1'b0}};
            box_on_border_s1 <= {NPPC{1'b0}};
            pat_c0_s1        <= {(12*NPPC){1'b0}};
            pat_c1_s1        <= {(12*NPPC){1'b0}};
            pat_c2_s1        <= {(12*NPPC){1'b0}};
            box_img_r_s1     <= {(12*NPPC){1'b0}};
            box_img_g_s1     <= {(12*NPPC){1'b0}};
            box_img_b_s1     <= {(12*NPPC){1'b0}};
            pix_valid_s1     <= 1'b0;
            pix_sof_s1       <= 1'b0;
            pix_eol_s1       <= 1'b0;
            pix_eof_s1       <= 1'b0;
            pix_x_lsb_s1     <= 1'b0;
            pix_y_lsb_s1     <= 1'b0;
        end else if (pipe_advance) begin
            // lane 0 from the existing scalar mux/comparators
            box_in_s1[0]        <= box_in;
            box_on_border_s1[0] <= box_on_border;
            pat_c0_s1[11:0]     <= pat_c0;
            pat_c1_s1[11:0]     <= pat_c1;
            pat_c2_s1[11:0]     <= pat_c2;
            box_img_r_s1[11:0]  <= box_img_r;
            box_img_g_s1[11:0]  <= box_img_g;
            box_img_b_s1[11:0]  <= box_img_b;
            pix_valid_s1     <= pix_valid;
            pix_sof_s1       <= pix_sof;
            pix_eol_s1       <= pix_eol;
            pix_eof_s1       <= pix_eof;
            pix_x_lsb_s1     <= x[0];
            pix_y_lsb_s1     <= y[0];
            // lanes 1..NPPC-1 latch the per-lane buses. This behavioural loop
            // has zero iterations at NPPC==1 (unlike the old generate block it
            // is not elaborated away), so its body is dead in the PPC=1
            // coverage sim -- exclude it, like the PPC>1-only pat_c*_bus logic.
            // PPC>1 is covered by the cocotb data-path suite and iverilog gate.
            // verilator coverage_off
            for (li_s1 = 1; li_s1 < NPPC; li_s1 = li_s1 + 1) begin
                box_in_s1[li_s1]        <= box_in_bus[li_s1];
                box_on_border_s1[li_s1] <= box_on_border_bus[li_s1];
                pat_c0_s1[12*li_s1 +: 12] <= pat_c0_bus[12*li_s1 +: 12];
                pat_c1_s1[12*li_s1 +: 12] <= pat_c1_bus[12*li_s1 +: 12];
                pat_c2_s1[12*li_s1 +: 12] <= pat_c2_bus[12*li_s1 +: 12];
                box_img_r_s1[12*li_s1 +: 12] <= box_img_r_bus[12*li_s1 +: 12];
                box_img_g_s1[12*li_s1 +: 12] <= box_img_g_bus[12*li_s1 +: 12];
                box_img_b_s1[12*li_s1 +: 12] <= box_img_b_bus[12*li_s1 +: 12];
            end
            // verilator coverage_on
        end
    end

    // When EN_BOX_IMAGE=1 the box interior shows the scaled image instead
    // of cfg_box_color -- but only while the host has programmed non-zero
    // step values; cfg_box_img_x_step==0 is the runtime "fall back to
    // solid box" sentinel (any real step is > 0). Border (when
    // border_width > 0) still wins because box_on_border_s1 is checked
    // first.
    wire box_image_active = (EN_BOX_IMAGE != 0) && (cfg_box_img_x_step != 32'h0);
    // Per-lane box interior: the scaled box-image when active, else solid fill.
    // Lane 0 keeps the exact NPPC==1 expression (bus == lane 0 there).
    wire [11:0] box_inside_c0 = box_image_active ? box_img_r_s1[11:0] : box_fill_c0;
    wire [11:0] box_inside_c1 = box_image_active ? box_img_g_s1[11:0] : box_fill_c1;
    wire [11:0] box_inside_c2 = box_image_active ? box_img_b_s1[11:0] : box_fill_c2;

    // Per-lane composited pixel. Lane 0 uses box_inside_c* (with box-image);
    // at NPPC==1 pix_c*_bus[11:0] is exactly the original pix_c*.
    wire [12*NPPC-1:0] pix_c0_bus, pix_c1_bus, pix_c2_bus;
    assign pix_c0_bus[11:0] = box_on_border_s1[0] ? box_bdr_c0 :
                              box_in_s1[0]        ? box_inside_c0 : pat_c0_s1[11:0];
    assign pix_c1_bus[11:0] = box_on_border_s1[0] ? box_bdr_c1 :
                              box_in_s1[0]        ? box_inside_c1 : pat_c1_s1[11:0];
    assign pix_c2_bus[11:0] = box_on_border_s1[0] ? box_bdr_c2 :
                              box_in_s1[0]        ? box_inside_c2 : pat_c2_s1[11:0];
    generate
        genvar gpc;
        for (gpc = 1; gpc < NPPC; gpc = gpc + 1) begin : g_pix_lane
            wire [11:0] insd_c0 = box_image_active ? box_img_r_s1[12*gpc +: 12] : box_fill_c0;
            wire [11:0] insd_c1 = box_image_active ? box_img_g_s1[12*gpc +: 12] : box_fill_c1;
            wire [11:0] insd_c2 = box_image_active ? box_img_b_s1[12*gpc +: 12] : box_fill_c2;
            assign pix_c0_bus[12*gpc +: 12] = box_on_border_s1[gpc] ? box_bdr_c0 :
                                              box_in_s1[gpc]        ? insd_c0
                                                                    : pat_c0_s1[12*gpc +: 12];
            assign pix_c1_bus[12*gpc +: 12] = box_on_border_s1[gpc] ? box_bdr_c1 :
                                              box_in_s1[gpc]        ? insd_c1
                                                                    : pat_c1_s1[12*gpc +: 12];
            assign pix_c2_bus[12*gpc +: 12] = box_on_border_s1[gpc] ? box_bdr_c2 :
                                              box_in_s1[gpc]        ? insd_c2
                                                                    : pat_c2_s1[12*gpc +: 12];
        end
    endgenerate

    // ---------------- pipeline stage 2 (post-mux register) ---------------
    // Two pipeline stages total between pattern/box state and the AXI
    // output: SOF → first pixel on AXI is delayed by 2 cycles vs. a
    // combinational core, but the per-beat value sequence is unchanged.
    (* keep = "true", dont_touch = "true" *) reg [12*NPPC-1:0] pix_c0_q, pix_c1_q, pix_c2_q;
    reg        pix_valid_q, pix_sof_q, pix_eol_q, pix_eof_q;
    reg        pix_x_lsb_q, pix_y_lsb_q;
    assign pipe_advance = axis_can_advance && (active || pix_valid_s1 || pix_valid_q);
    always @(posedge aclk) begin
        if (!aresetn) begin
            pix_c0_q    <= {(12*NPPC){1'b0}};
            pix_c1_q    <= {(12*NPPC){1'b0}};
            pix_c2_q    <= {(12*NPPC){1'b0}};
            pix_valid_q <= 1'b0;
            pix_sof_q   <= 1'b0;
            pix_eol_q   <= 1'b0;
            pix_eof_q   <= 1'b0;
            pix_x_lsb_q <= 1'b0;
            pix_y_lsb_q <= 1'b0;
        end else if (pipe_advance) begin
            pix_c0_q    <= pix_c0_bus;
            pix_c1_q    <= pix_c1_bus;
            pix_c2_q    <= pix_c2_bus;
            pix_valid_q <= pix_valid_s1;
            pix_sof_q   <= pix_sof_s1;
            pix_eol_q   <= pix_eol_s1;
            pix_eof_q   <= pix_eof_s1;
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
    // pack_pixel: shrink/grow each 12-bit component to BPC and pack ONE pixel
    // into a PIX_TDATA_WIDTH slot per the build-time mode. This is the exact
    // logic that was previously three parallel `generate ... always` blocks,
    // now a reusable function so each of the NPPC lanes packs independently.
    // xlsb/ylsb are the packed pixel's (x[0], y[0]) parity used by the
    // YUV422 chroma phase and the RAW Bayer 2x2 select.
    // verilator coverage_off
    // Only the build's OUTPUT_MODE / RGB_ORDER / RAW_BAYER arm is reachable;
    // the other mode/order/bayer arms are dead code in any single-config
    // build. All 20 mode/bpc configs are verified byte-exact by the
    // all_modes model gate, so packing correctness is covered there.
    function [PIX_TDATA_WIDTH-1:0] pack_pixel;
        input [11:0] c0_12, c1_12, c2_12;
        input        xlsb, ylsb;
        reg [BPC-1:0] c0, c1, c2, cc, raw_sel;
        reg [PIX_TDATA_WIDTH-1:0] p;
        begin
            // Bit-shrink (BPC<=12: truncate LSBs) / grow (BPC>12: zero-extend).
            // Truncation to [BPC-1:0] happens on assignment; SHIFT_DN/SHIFT_UP
            // are non-negative constants so both arms are legal for any BPC.
            c0 = (BPC <= 12) ? (c0_12 >> SHIFT_DN) : (c0_12 << SHIFT_UP);
            c1 = (BPC <= 12) ? (c1_12 >> SHIFT_DN) : (c1_12 << SHIFT_UP);
            c2 = (BPC <= 12) ? (c2_12 >> SHIFT_DN) : (c2_12 << SHIFT_UP);
            // Assign the component concat to the full-width word (auto
            // zero-extends for the Xilinx order = components in the LSBs) or
            // left-shift it by a clamped pad (legacy order = components in the
            // MSBs). This avoids both `{0{1'b0}}` zero-width replications
            // (which crash Verilator 5.020) and out-of-range part selects in
            // the non-native mode's dead branches. Width mismatches in dead
            // branches are truncations only (covered by -Wno-WIDTH).
            if (OUTPUT_MODE == `VTPGZ_MODE_RGB ||
                (OUTPUT_MODE == `VTPGZ_MODE_YUV && YUV_SUBSAMPLE == `VTPGZ_YUV_444)) begin
                if (RGB_ORDER == `VTPGZ_RGB_ORDER_XILINX) begin
                    p = {c2, c1, c0};
                end else begin
                    p = {c0, c1, c2};
                    p = p << PAD3;
                end
            end else if (OUTPUT_MODE == `VTPGZ_MODE_YUV) begin
                // 4:2:2 -- {Y, C}; C = Cb on even-x, Cr on odd-x
                cc = (xlsb == 1'b0) ? c1 : c2;
                if (RGB_ORDER == `VTPGZ_RGB_ORDER_XILINX) begin
                    p = {cc, c0};
                end else begin
                    p = {c0, cc};
                    p = p << PAD2;
                end
            end else begin
                // RAW: single component, RAW_BAYER selects the 2x2 mosaic.
                //   PLAIN : monochrome, take G (c1) every pixel
                //   RGGB  : row0:[R,G] row1:[G,B]      BGGR : row0:[B,G] row1:[G,R]
                //   GRBG  : row0:[G,R] row1:[B,G]      GBRG : row0:[G,B] row1:[R,G]
                case (RAW_BAYER)
                    `VTPGZ_RAW_RGGB: raw_sel = (ylsb==1'b0) ? ((xlsb==1'b0)?c0:c1)
                                                            : ((xlsb==1'b0)?c1:c2);
                    `VTPGZ_RAW_BGGR: raw_sel = (ylsb==1'b0) ? ((xlsb==1'b0)?c2:c1)
                                                            : ((xlsb==1'b0)?c1:c0);
                    `VTPGZ_RAW_GRBG: raw_sel = (ylsb==1'b0) ? ((xlsb==1'b0)?c1:c0)
                                                            : ((xlsb==1'b0)?c2:c1);
                    `VTPGZ_RAW_GBRG: raw_sel = (ylsb==1'b0) ? ((xlsb==1'b0)?c1:c2)
                                                            : ((xlsb==1'b0)?c0:c1);
                    default:         raw_sel = c1; // PLAIN
                endcase
                p = raw_sel;   // single component in LSBs, high bits zero
            end
            pack_pixel = p;
        end
    endfunction
    // verilator coverage_on

    /*verilator coverage_off*/ reg [C_AXIS_TDATA_WIDTH-1:0] tdata_r; /*verilator coverage_on*/
    reg                          tvalid_r;
    reg                          tlast_r;
    reg                          tuser_r;

    // Combinational pack -> next-tdata. Each lane packs into its own
    // PIX_TDATA_WIDTH slot; lane 0 (leftmost pixel) lands in the LSBs. At
    // NPPC==1 this is a single pack_pixel of lane 0 == the original tdata_next.
    /*verilator coverage_off*/ wire [C_AXIS_TDATA_WIDTH-1:0] tdata_next; /*verilator coverage_on*/
    generate
        genvar gpk;
        for (gpk = 0; gpk < NPPC; gpk = gpk + 1) begin : g_pack_lane
            // lane gpk parity: x_base[0] ^ (gpk&1); y is common to the beat.
            assign tdata_next[PIX_TDATA_WIDTH*gpk +: PIX_TDATA_WIDTH] =
                pack_pixel(pix_c0_q[12*gpk +: 12],
                           pix_c1_q[12*gpk +: 12],
                           pix_c2_q[12*gpk +: 12],
                           pix_x_lsb_q ^ (gpk & 1),
                           pix_y_lsb_q);
        end
    endgenerate

    always @(posedge aclk) begin
        if (!aresetn) begin
            axis_gap_cnt <= 32'h0;
        end else begin
            if (axis_gap_start)
                axis_gap_cnt <= LINE_GAP_CYCLES_MIN1 - 32'd1;
            else if (axis_gap_active)
                axis_gap_cnt <= axis_gap_cnt - 32'd1;
        end
    end

    // ---------------- AXI-Stream output register ----------------
    always @(posedge aclk) begin
        if (!aresetn) begin
            tdata_r  <= {C_AXIS_TDATA_WIDTH{1'b0}};
            tvalid_r <= 1'b0;
            tlast_r  <= 1'b0;
            tuser_r  <= 1'b0;
            teof_r    <= 1'b0;
        end else if (axis_gap_start || axis_gap_active) begin
            tvalid_r <= 1'b0;
            tlast_r  <= 1'b0;
            tuser_r  <= 1'b0;
            teof_r    <= 1'b0;
        end else if (pipe_advance) begin
            tdata_r  <= tdata_next;
            tvalid_r <= pix_valid_q;
            tlast_r  <= pix_eol_q;
            tuser_r  <= pix_sof_q;
            teof_r    <= pix_eof_q;
        end else if (m_axis_tvalid && m_axis_tready) begin
            tvalid_r <= 1'b0;
            tlast_r  <= 1'b0;
            tuser_r  <= 1'b0;
            teof_r    <= 1'b0;
        end
    end

    assign m_axis_tdata  = tdata_r;
    assign m_axis_tvalid = tvalid_r;
    assign m_axis_tlast  = tlast_r;
    assign m_axis_tuser  = tuser_r;

endmodule
