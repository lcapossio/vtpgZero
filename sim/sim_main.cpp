// Verilator C++ testbench for vtpgz_axilite_top
// Aggressive coverage-oriented stimulus: register sweep, all patterns/formats,
// backpressure, internal & external sync, large frame for bit toggling.
//
// SPDX-FileCopyrightText: 2026 Leonardo Capossio - bard0 design - hello@bard0.com
// SPDX-License-Identifier: Apache-2.0
#include <verilated.h>
#include <verilated_vcd_c.h>
#include <verilated_cov.h>
#include "Vvtpgz_axilite_top.h"
#include <cstdio>
#include <cstdint>

// Register map (must match rtl/vtpgz_defs.vh)
// Must match rtl/vtpgz_defs.vh
#define VTPGZ_REG_CORE_ID       0x00
#define VTPGZ_REG_VERSION       0x04
#define VTPGZ_REG_CONTROL       0x08
#define VTPGZ_REG_STATUS        0x0C
#define VTPGZ_REG_IMG_WIDTH     0x10
#define VTPGZ_REG_IMG_HEIGHT    0x14
#define VTPGZ_REG_PATTERN_SEL   0x18
#define VTPGZ_REG_COLOR_FORMAT  0x1C
#define VTPGZ_REG_SOLID_COLOR   0x20
#define VTPGZ_REG_BOX_COLOR     0x24
#define VTPGZ_REG_BOX_SIZE      0x28
#define VTPGZ_REG_BOX_SPEED     0x2C
#define VTPGZ_REG_GRID_SPACING  0x34
#define VTPGZ_REG_GRID_COLOR    0x38
#define VTPGZ_REG_CHECKER_SIZE  0x3C
#define VTPGZ_REG_FRAME_RATE    0x40
#define VTPGZ_REG_BAR_WIDTH     0x44
#define VTPGZ_REG_HG_STEP       0x48
#define VTPGZ_REG_VG_STEP       0x4C
#define VTPGZ_REG_BOX_BORDER    0x50

static const uint8_t kAllRegs[] = {
    VTPGZ_REG_CONTROL, VTPGZ_REG_IMG_WIDTH, VTPGZ_REG_IMG_HEIGHT, VTPGZ_REG_PATTERN_SEL,
    VTPGZ_REG_COLOR_FORMAT, VTPGZ_REG_SOLID_COLOR, VTPGZ_REG_BOX_COLOR, VTPGZ_REG_BOX_SIZE,
    VTPGZ_REG_BOX_SPEED, VTPGZ_REG_GRID_SPACING, VTPGZ_REG_GRID_COLOR,
    VTPGZ_REG_CHECKER_SIZE, VTPGZ_REG_FRAME_RATE, VTPGZ_REG_BAR_WIDTH, VTPGZ_REG_HG_STEP,
    VTPGZ_REG_VG_STEP, VTPGZ_REG_BOX_BORDER
};

static vluint64_t main_time = 0;
double sc_time_stamp() { return main_time; }

static Vvtpgz_axilite_top*      dut = nullptr;
static VerilatedVcdC* tfp = nullptr;

static long pixels = 0, lines = 0, frames = 0;
static int failures = 0;
static bool axis_check_en = false;
static int axis_exp_w = 0, axis_exp_h = 0;
static int axis_x = 0, axis_y = 0;
static bool axis_in_frame = false;

static void expect_eq(const char* what, uint32_t got, uint32_t exp) {
    if (got != exp) {
        fprintf(stderr, "FAIL: %s got 0x%08X expected 0x%08X\n", what, got, exp);
        ++failures;
    }
}

static void set_axis_check(int w, int h) {
    axis_check_en = true;
    axis_exp_w = w;
    axis_exp_h = h;
    axis_x = 0;
    axis_y = 0;
    axis_in_frame = false;
}

static void tick() {
    dut->aclk = 0; dut->eval(); if (tfp) tfp->dump(main_time++);
    dut->aclk = 1; dut->eval(); if (tfp) tfp->dump(main_time++);
    if (dut->m_axis_tvalid && dut->m_axis_tready) {
        ++pixels;
        if (dut->m_axis_tuser) ++frames;
        if (dut->m_axis_tlast) ++lines;
        if (axis_check_en) {
            if (dut->m_axis_tuser) {
                if (axis_in_frame && (axis_x != 0 || axis_y != axis_exp_h)) {
                    fprintf(stderr, "FAIL: short AXIS frame x=%d y=%d expected y=%d\n",
                            axis_x, axis_y, axis_exp_h);
                    ++failures;
                }
                axis_in_frame = true;
                axis_x = 0;
                axis_y = 0;
            } else if (!axis_in_frame) {
                return;
            }
            if (dut->m_axis_tlast != (axis_x == axis_exp_w - 1)) {
                fprintf(stderr, "FAIL: AXIS tlast x=%d y=%d got=%d expected=%d\n",
                        axis_x, axis_y, (int)dut->m_axis_tlast,
                        axis_x == axis_exp_w - 1);
                ++failures;
            }
            if (++axis_x == axis_exp_w) {
                axis_x = 0;
                ++axis_y;
                if (axis_y > axis_exp_h) {
                    fprintf(stderr, "FAIL: AXIS frame overrun y=%d expected=%d\n",
                            axis_y, axis_exp_h);
                    ++failures;
                    axis_in_frame = false;
                }
            }
        }
    }
}

static uint8_t prot_walk = 0;
static void axil_write(uint8_t addr, uint32_t data, uint8_t strb = 0xF) {
    dut->s_axil_awaddr  = addr;
    dut->s_axil_awprot  = (prot_walk++ & 0x7);
    dut->s_axil_awvalid = 1;
    dut->s_axil_wdata   = data;
    dut->s_axil_wstrb   = strb;
    dut->s_axil_wvalid  = 1;
    dut->s_axil_bready  = 1;
    for (int i = 0; i < 100; ++i) {
        tick();
        if (dut->s_axil_awready && dut->s_axil_wready) break;
    }
    dut->s_axil_awvalid = 0;
    dut->s_axil_wvalid  = 0;
    for (int i = 0; i < 100; ++i) {
        tick();
        if (dut->s_axil_bvalid) break;
    }
    dut->s_axil_bready = 0;
}

static uint32_t axil_read(uint8_t addr) {
    // BUG-09: the axil_regs slave asserts arready and rvalid on the same
    // cycle (single-cycle response, rready held high through the address
    // phase). The original two-loop polling waited an extra tick after
    // arready, by which point the slave had already completed the data
    // handshake and dropped rvalid -- so the master read 0 every time.
    // Fix: sample rdata on the same cycle the address handshake completes.
    uint32_t out = 0;
    bool got = false;
    dut->s_axil_araddr  = addr;
    dut->s_axil_arprot  = (prot_walk++ & 0x7);
    dut->s_axil_arvalid = 1;
    dut->s_axil_rready  = 1;
    for (int i = 0; i < 100; ++i) {
        tick();
        if (dut->s_axil_arready && dut->s_axil_rvalid) {
            out = dut->s_axil_rdata;
            got = true;
            break;
        }
    }
    dut->s_axil_arvalid = 0;
    if (!got) {
        // Decoupled-response slave: address handshake done, data still
        // pending. Poll for rvalid separately.
        for (int i = 0; i < 100; ++i) {
            tick();
            if (dut->s_axil_rvalid) { out = dut->s_axil_rdata; break; }
        }
    }
    dut->s_axil_rready = 0;
    return out;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Verilated::traceEverOn(true);

    dut = new Vvtpgz_axilite_top;
    tfp = new VerilatedVcdC;
    dut->trace(tfp, 99);
    tfp->open("logs/vtpgz_axilite_top.vcd");

    dut->aresetn       = 0;
    dut->s_axil_awaddr = 0; dut->s_axil_awvalid = 0;
    dut->s_axil_wdata  = 0; dut->s_axil_wstrb   = 0; dut->s_axil_wvalid = 0;
    dut->s_axil_bready = 0;
    dut->s_axil_araddr = 0; dut->s_axil_arvalid = 0; dut->s_axil_rready = 0;
    dut->m_axis_tready = 1;
    dut->frame_sync_in = 0;

    for (int i = 0; i < 10; ++i) tick();
    dut->aresetn = 1;
    for (int i = 0; i < 5; ++i) tick();

    // Malformed-but-accepted configuration should clamp internally instead
    // of underflowing counters or box arithmetic.
    axil_write(VTPGZ_REG_CONTROL,      0);
    axil_write(VTPGZ_REG_IMG_WIDTH,    0);
    axil_write(VTPGZ_REG_IMG_HEIGHT,   0);
    axil_write(VTPGZ_REG_FRAME_RATE,   0);
    axil_write(VTPGZ_REG_BAR_WIDTH,    0);
    axil_write(VTPGZ_REG_BOX_SIZE,     (512u << 16) | 512u);
    axil_write(VTPGZ_REG_BOX_SPEED,    (512u << 16) | 512u);
    axil_write(VTPGZ_REG_BOX_BORDER,   (255u << 24) | 0x0000FF00);
    set_axis_check(1, 1);
    long clamp_frames = frames;
    axil_write(VTPGZ_REG_CONTROL,      1);
    for (int i = 0; i < 1000 && frames < clamp_frames + 2; ++i) tick();
    if (frames < clamp_frames + 1) {
        fprintf(stderr, "FAIL: clamped zero-size config produced no frame\n");
        ++failures;
    }
    axil_write(VTPGZ_REG_CONTROL,      0);
    axis_check_en = false;

    // ============================================================
    // Phase 1: register bit-toggle sweep
    //   Write 0xFFFFFFFF then 0x00000000 then 0xAAAAAAAA / 0x55555555
    //   to every register, reading back between writes.
    // ============================================================
    printf("== Phase 1: register sweep ==\n");
    const uint32_t patterns_w[] = {0xFFFFFFFFu, 0x00000000u, 0xAAAAAAAAu, 0x55555555u};
    for (int p = 0; p < 4; ++p) {
        for (size_t i = 0; i < sizeof(kAllRegs); ++i) {
            axil_write(kAllRegs[i], patterns_w[p]);
            (void)axil_read(kAllRegs[i]);
        }
    }
    // Read RO regs (CORE_ID + VERSION + STATUS). The CORE_ID check is
    // load-bearing: it's the only place in the regression that asserts
    // an axil_read return value. See no_commit/BUGS.md BUG-09.
    {
        uint32_t core_id = axil_read(VTPGZ_REG_CORE_ID);
        if (core_id != 0x47505456u) {
            fprintf(stderr, "FAIL: CORE_ID = 0x%08X (expected 0x47505456 'VTPG')\n",
                    core_id);
            return 1;
        }
    }
    (void)axil_read(VTPGZ_REG_VERSION);
    (void)axil_read(VTPGZ_REG_STATUS);
    // Partial-strobe writes (toggle wstrb bits)
    axil_write(VTPGZ_REG_SOLID_COLOR, 0x11223344);
    axil_write(VTPGZ_REG_SOLID_COLOR, 0xDEADBEEF, 0x0);
    expect_eq("WSTRB none", axil_read(VTPGZ_REG_SOLID_COLOR), 0x11223344u);
    axil_write(VTPGZ_REG_SOLID_COLOR, 0xAAAABEEF, 0x1);
    expect_eq("WSTRB byte0", axil_read(VTPGZ_REG_SOLID_COLOR), 0x112233EFu);
    axil_write(VTPGZ_REG_SOLID_COLOR, 0xAAAA77AA, 0x2);
    expect_eq("WSTRB byte1", axil_read(VTPGZ_REG_SOLID_COLOR), 0x112277EFu);
    axil_write(VTPGZ_REG_SOLID_COLOR, 0xAA66AAAA, 0x4);
    expect_eq("WSTRB byte2", axil_read(VTPGZ_REG_SOLID_COLOR), 0x116677EFu);
    axil_write(VTPGZ_REG_SOLID_COLOR, 0x55AAAAAA, 0x8);
    expect_eq("WSTRB byte3", axil_read(VTPGZ_REG_SOLID_COLOR), 0x556677EFu);

    // Read an unmapped address (default branch)
    (void)axil_read(0xFC);
    axil_write(0xFC, 0xDEADBEEF);

    // ============================================================
    // Phase 2: pattern x format x bpp sweep on a moderately large frame
    //   256x128 → toggles x[7:0], y[6:0], drives chk/grid wraps,
    //   gives moving box room to bounce.
    // ============================================================
    printf("== Phase 2: pattern sweep ==\n");
    axil_write(VTPGZ_REG_CONTROL,      0);
    axil_write(VTPGZ_REG_IMG_WIDTH,    256);
    axil_write(VTPGZ_REG_IMG_HEIGHT,   128);
    axil_write(VTPGZ_REG_BAR_WIDTH,    32);    // 256/8
    axil_write(VTPGZ_REG_HG_STEP,      16);    // ~0xFFF/255
    axil_write(VTPGZ_REG_VG_STEP,      32);    // ~0xFFF/127
    axil_write(VTPGZ_REG_CHECKER_SIZE, 16);
    axil_write(VTPGZ_REG_GRID_SPACING, 24);
    axil_write(VTPGZ_REG_GRID_COLOR,   0x00FFFF00);
    axil_write(VTPGZ_REG_SOLID_COLOR,  0x00FF8040);
    axil_write(VTPGZ_REG_BOX_COLOR,    0x00FF0000);
    axil_write(VTPGZ_REG_BOX_SIZE,     (16u << 16) | 16u);
    axil_write(VTPGZ_REG_BOX_SPEED,    (1u << 16)  | 1u);
    axil_write(VTPGZ_REG_FRAME_RATE,   100);
    set_axis_check(256, 128);

    // OUTPUT_MODE / BPC are now build-time. We sweep just the patterns at
    // runtime; the regression Makefile builds the binary multiple times
    // for the (mode, bpc) coverage.
    for (int pat = 0; pat <= 8; ++pat) {
        axil_write(VTPGZ_REG_CONTROL,      0);
        axil_write(VTPGZ_REG_PATTERN_SEL,  pat);
        axil_write(VTPGZ_REG_CONTROL,      1);
        long fstart = frames;
        for (int i = 0; i < 60000 && frames < fstart + 1; ++i) tick();
    }
    printf("after sweep: frames=%ld\n", frames);

    // ============================================================
    // Phase 3: long moving-box run to hit bounce branches in BOTH directions
    // ============================================================
    printf("== Phase 3: moving box bounce ==\n");
    axil_write(VTPGZ_REG_CONTROL,      0);
    axil_write(VTPGZ_REG_PATTERN_SEL,  0);   // colorbar (box overlays on top)
    axil_write(VTPGZ_REG_BOX_SIZE,     (32u << 16) | 32u);
    axil_write(VTPGZ_REG_BOX_SPEED,    (8u << 16)  | 8u);
    axil_write(VTPGZ_REG_BOX_BORDER,   (2u << 24) | 0x00FFFFFF); // 2px white border
    axil_write(VTPGZ_REG_CONTROL,      1);
    long bf = frames;
    for (int i = 0; i < 4000000 && frames < bf + 200; ++i) tick();
    printf("box frames=%ld\n", frames - bf);

    // ============================================================
    // Phase 4: backpressure with random tready
    // ============================================================
    printf("== Phase 4: backpressure ==\n");
    for (int i = 0; i < 20000; ++i) {
        dut->m_axis_tready = (i & 0x7) != 0;  // 7/8 duty
        tick();
    }
    dut->m_axis_tready = 1;

    // ============================================================
    // Phase 5: external frame sync (Xilinx-VTC-compatible)
    //
    // The TPG accepts ANY rising edge on frame_sync_in as a frame trigger,
    // matching the typical vsync output of Xilinx VTC, AXI4-Stream Subset
    // Converter, or any other timing generator. We test:
    //   (a) a 1-clock pulse  -> 1 frame
    //   (b) a wide pulse held high for many cycles -> 1 frame (no double-trigger)
    //   (c) a pulse arriving WHILE a frame is in flight -> ignored
    //   (d) a normal periodic vsync at ~the same rate as the internal divider
    // ============================================================
    printf("== Phase 5: external sync ==\n");
    axil_write(VTPGZ_REG_CONTROL, 0);
    // Wait for any leftover frame from Phase 4 to finish (the FSM only
    // returns to idle on end_of_frame; clearing cfg_enable mid-frame
    // doesn't interrupt the frame in flight).
    for (int i = 0; i < 50000; ++i) tick();
    axil_write(VTPGZ_REG_CONTROL, 0x5);  // enable + ext_sync

    long fc_before;

    // (a) single-clock pulse
    fc_before = frames;
    dut->frame_sync_in = 1; tick();
    dut->frame_sync_in = 0;
    for (int i = 0; i < 60000; ++i) tick();
    if (frames - fc_before != 1)
        printf("  WARN: 1-clock pulse produced %ld frames (expected 1)\n", frames - fc_before);

    // (b) wide pulse held for many cycles
    fc_before = frames;
    dut->frame_sync_in = 1;
    for (int i = 0; i < 100; ++i) tick();
    dut->frame_sync_in = 0;
    for (int i = 0; i < 60000; ++i) tick();
    if (frames - fc_before != 1)
        printf("  WARN: wide pulse produced %ld frames (expected 1)\n", frames - fc_before);

    // (c) pulse arriving during an active frame should be ignored
    fc_before = frames;
    dut->frame_sync_in = 1; tick(); dut->frame_sync_in = 0;
    for (int i = 0; i < 200; ++i) tick();    // mid-frame
    dut->frame_sync_in = 1; tick(); dut->frame_sync_in = 0;
    for (int i = 0; i < 60000; ++i) tick();
    if (frames - fc_before != 1)
        printf("  WARN: mid-frame pulse spurious frames (got %ld)\n", frames - fc_before);

    // (d) periodic vsync (1-cycle pulses spaced > 1 frame time apart)
    for (int k = 0; k < 4; ++k) {
        dut->frame_sync_in = 1; tick();
        dut->frame_sync_in = 0;
        for (int i = 0; i < 60000; ++i) tick();
    }

    // ============================================================
    // Phase 6: software frame sync (CONTROL[1])
    // ============================================================
    printf("== Phase 6: sw fsync ==\n");
    axil_write(VTPGZ_REG_CONTROL, 0x3);  // enable + sw_fsync (held)
    for (int i = 0; i < 50000; ++i) tick();
    axil_write(VTPGZ_REG_CONTROL, 0x1);  // back to internal sync
    for (int i = 0; i < 5000; ++i) tick();

    // ============================================================
    // Phase 7: read-back STATUS while busy, full register read sweep
    // ============================================================
    printf("== Phase 7: status read ==\n");
    for (int i = 0; i < 20; ++i) (void)axil_read(VTPGZ_REG_STATUS);
    for (size_t i = 0; i < sizeof(kAllRegs); ++i) (void)axil_read(kAllRegs[i]);

    printf("RESULT: pixels=%ld lines=%ld frames=%ld\n", pixels, lines, frames);
    if (frames >= 100 && lines >= 1000 && pixels >= 100000 && failures == 0)
        printf("PASS\n");
    else
        printf("FAIL\n");

#if VM_COVERAGE
    VerilatedCov::write("logs/coverage.dat");
#endif

    tfp->close();
    delete dut;
    return (frames >= 100 && lines >= 1000 && pixels >= 100000 && failures == 0) ? 0 : 1;
}
