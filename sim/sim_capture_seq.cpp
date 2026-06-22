// Multi-capture Verilator harness for the vtpgZero hardware sequence.
//
// Reproduces the host-side flow used by run_hw_test.py:
//   for each pat:
//       disable VTPGZ, configure, clear, arm, enable, poll, read BRAM
// and dumps each captured frame to a separate file. Lets us verify the
// multi-capture state-leakage bug entirely in simulation. The build-time
// output mode is fixed when the binary is compiled.
//
// SPDX-FileCopyrightText: 2026 Leonardo Capossio - bard0 design - hello@bard0.com
// SPDX-License-Identifier: Apache-2.0
#include <verilated.h>
#include "Vsim_top.h"
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <cstdlib>
#include <vector>

// Must match rtl/vtpgz_defs.vh after the 0x00 = CORE_ID insertion that
// shifted everything up by 4.
#define VTPGZ_REG_CONTROL       0x08
#define VTPGZ_REG_IMG_WIDTH     0x10
#define VTPGZ_REG_IMG_HEIGHT    0x14
#define VTPGZ_REG_PATTERN_SEL   0x18
#define VTPGZ_REG_FRAME_RATE    0x40
#define VTPGZ_REG_BAR_WIDTH     0x44
#define VTPGZ_REG_HG_STEP       0x48
#define VTPGZ_REG_VG_STEP       0x4C
#define VTPGZ_REG_CHECKER_SIZE  0x3C
#define VTPGZ_REG_GRID_SPACING  0x34
#define VTPGZ_REG_BOX_SIZE      0x28
#define VTPGZ_REG_BOX_SPEED     0x2C
#define VTPGZ_REG_BOX_BORDER    0x50

#define FC_BASE       0x00010000u
#define FC_CTRL       (FC_BASE + 0x0000u)
#define FC_STATUS     (FC_BASE + 0x0004u)
#define FC_BRAM       (FC_BASE + 0x8000u)

static vluint64_t main_time = 0;
double sc_time_stamp() { return main_time; }

static Vsim_top* dut = nullptr;

static void tick() {
    dut->aclk = 0; dut->eval(); ++main_time;
    dut->aclk = 1; dut->eval(); ++main_time;
}

// ---------- VTPGZ AXI4-Lite (single beat) ----------
static void vtpgz_write(uint8_t addr, uint32_t data) {
    dut->vtpgz_awaddr  = addr;
    dut->vtpgz_awvalid = 1;
    dut->vtpgz_wdata   = data;
    dut->vtpgz_wstrb   = 0xF;
    dut->vtpgz_wvalid  = 1;
    dut->vtpgz_bready  = 1;
    bool aw_done = false, w_done = false, b_done = false;
    for (int i = 0; i < 200; ++i) {
        tick();
        if (!aw_done && dut->vtpgz_awready) { aw_done = true; dut->vtpgz_awvalid = 0; }
        if (!w_done  && dut->vtpgz_wready)  { w_done  = true; dut->vtpgz_wvalid  = 0; }
        if (dut->vtpgz_bvalid && dut->vtpgz_bready) { b_done = true; break; }
    }
    dut->vtpgz_awvalid = 0;
    dut->vtpgz_wvalid  = 0;
    dut->vtpgz_bready  = 0;
}

// ---------- frame_capture AXI4 (single beat) ----------
static void fc_write(uint32_t addr, uint32_t data) {
    dut->fc_awaddr  = addr;
    dut->fc_awlen   = 0;
    dut->fc_awsize  = 2;
    dut->fc_awburst = 1;
    dut->fc_awprot  = 0;
    dut->fc_awvalid = 1;
    dut->fc_wdata   = data;
    dut->fc_wstrb   = 0xF;
    dut->fc_wlast   = 1;
    dut->fc_wvalid  = 1;
    dut->fc_bready  = 1;
    bool aw_done = false, w_done = false, b_done = false;
    for (int i = 0; i < 200; ++i) {
        tick();
        if (!aw_done && dut->fc_awready) { aw_done = true; dut->fc_awvalid = 0; }
        if (!w_done  && dut->fc_wready)  { w_done  = true; dut->fc_wvalid  = 0; }
        if (dut->fc_bvalid && dut->fc_bready) { b_done = true; break; }
    }
    dut->fc_awvalid = 0;
    dut->fc_wvalid  = 0;
    dut->fc_bready  = 0;
}

static uint32_t fc_read(uint32_t addr) {
    uint32_t out = 0;
    dut->fc_araddr  = addr;
    dut->fc_arlen   = 0;
    dut->fc_arsize  = 2;
    dut->fc_arburst = 1;
    dut->fc_arprot  = 0;
    dut->fc_arvalid = 1;
    dut->fc_rready  = 1;
    // Single loop: drop arvalid as soon as arready fires, then keep ticking
    // until rvalid (which may be the SAME cycle as arready for CSR reads).
    bool ar_done = false;
    bool got     = false;
    for (int i = 0; i < 200; ++i) {
        tick();
        if (!ar_done && dut->fc_arready) {
            ar_done = true;
            dut->fc_arvalid = 0;
        }
        if (dut->fc_rvalid && dut->fc_rready) {
            out = dut->fc_rdata;
            got = true;
            break;
        }
    }
    dut->fc_rready  = 0;
    dut->fc_arvalid = 0;
    return out;
}

// ---------- helpers ----------
static int parse_int(const char* name, int def) {
    const char* s = Verilated::commandArgsPlusMatch(name);
    if (!s || !s[0]) return def;
    const char* eq = strchr(s, '=');
    return eq ? atoi(eq + 1) : def;
}
static const char* parse_str(const char* name, const char* def) {
    const char* s = Verilated::commandArgsPlusMatch(name);
    if (!s || !s[0]) return def;
    const char* eq = strchr(s, '=');
    return eq ? (eq + 1) : def;
}

static void configure_tpg(int width, int height, int pat) {
    int bar_w   = (width / 8) > 0 ? (width / 8) : 1;
    int hg_step = 0xFFF / ((width  > 1) ? (width  - 1) : 1);
    int vg_step = 0xFFF / ((height > 1) ? (height - 1) : 1);
    vtpgz_write(VTPGZ_REG_CONTROL,      0);
    vtpgz_write(VTPGZ_REG_IMG_WIDTH,    width);
    vtpgz_write(VTPGZ_REG_IMG_HEIGHT,   height);
    vtpgz_write(VTPGZ_REG_BAR_WIDTH,    bar_w);
    vtpgz_write(VTPGZ_REG_HG_STEP,      hg_step);
    vtpgz_write(VTPGZ_REG_VG_STEP,      vg_step);
    vtpgz_write(VTPGZ_REG_CHECKER_SIZE, 16);
    vtpgz_write(VTPGZ_REG_GRID_SPACING, 16);
    vtpgz_write(VTPGZ_REG_BOX_SIZE,     (16u << 16) | 16u);
    vtpgz_write(VTPGZ_REG_BOX_SPEED,    (1u  << 16) | 1u);
    vtpgz_write(VTPGZ_REG_BOX_BORDER,   (1u << 24) | 0x00FFFFFF);
    vtpgz_write(VTPGZ_REG_PATTERN_SEL,  pat);
    vtpgz_write(VTPGZ_REG_FRAME_RATE,   100);
}

static int do_capture(int n_words, std::vector<uint32_t>& out_words) {
    fc_write(FC_CTRL, 0x2);  // clear
    fc_write(FC_CTRL, 0x1);  // arm
    vtpgz_write(VTPGZ_REG_CONTROL, 0x1);  // enable

    // poll status (free-running ticks between polls)
    long max_cycles = (long)n_words * 200 + 100000;
    uint32_t sts = 0;
    for (long i = 0; i < max_cycles; ++i) {
        tick();
        if ((i & 0x3FF) == 0) {
            sts = fc_read(FC_STATUS);
            if (sts & 0x1) break;
        }
    }
    if (!(sts & 0x1)) {
        fprintf(stderr, "ERROR: capture timeout (status=0x%08X)\n", sts);
        return -1;
    }
    int word_count = (sts >> 16) & 0xFFFF;
    if (word_count < n_words) {
        fprintf(stderr, "ERROR: short capture got %d words expected %d (status=0x%08X)\n",
                word_count, n_words, sts);
        return -1;
    }
    vtpgz_write(VTPGZ_REG_CONTROL, 0);  // disable
    out_words.clear();
    out_words.reserve(n_words);
    for (int i = 0; i < n_words; ++i) {
        out_words.push_back(fc_read(FC_BRAM + i * 4));
    }
    return 0;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vsim_top;

    int width  = parse_int("width", 64);
    int height = parse_int("height", 32);
    int n_caps = parse_int("ncaps", 4);
    const char* out_prefix = parse_str("out", "logs/seq_cap");

    // Sweep over all 9 patterns sequentially. The original purpose of this
    // harness was to catch state-leakage between consecutive captures,
    // which is mode-independent.
    int total = 9;
    if (n_caps > total) n_caps = total;

    // Init
    dut->aresetn = 0;
    dut->vtpgz_awvalid = 0; dut->vtpgz_wvalid = 0; dut->vtpgz_bready = 0;
    dut->vtpgz_arvalid = 0; dut->vtpgz_rready = 0;
    dut->fc_awvalid = 0; dut->fc_wvalid = 0; dut->fc_bready = 0;
    dut->fc_arvalid = 0; dut->fc_rready = 0;
    dut->fc_awlen = 0; dut->fc_awsize = 2; dut->fc_awburst = 1; dut->fc_awprot = 0;
    dut->fc_arlen = 0; dut->fc_arsize = 2; dut->fc_arburst = 1; dut->fc_arprot = 0;
    dut->fc_wstrb = 0xF; dut->fc_wlast = 1;
    for (int i = 0; i < 10; ++i) tick();
    dut->aresetn = 1;
    for (int i = 0; i < 5; ++i) tick();

    int rc = 0;
    int frame_words = width * height;
    std::vector<uint32_t> words;

    for (int c = 0; c < n_caps; ++c) {
        int pat = c;
        configure_tpg(width, height, pat);
        int r = do_capture(frame_words, words);
        if (r != 0) { rc = r; break; }
        char path[256];
        snprintf(path, sizeof(path), "%s_%d.bin", out_prefix, pat);
        FILE* f = fopen(path, "wb");
        if (!f) { perror(path); rc = -2; break; }
        fwrite(words.data(), sizeof(uint32_t), words.size(), f);
        fclose(f);
        printf("CAP %d: pat=%d -> %s (%zu words)\n",
               c, pat, path, words.size());
    }

    delete dut;
    return rc;
}
