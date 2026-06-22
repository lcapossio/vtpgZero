// Verilator capture harness — captures one full frame to a binary file.
//
// SPDX-FileCopyrightText: 2026 Leonardo Capossio - bard0 design - hello@bard0.com
// SPDX-License-Identifier: Apache-2.0
//
// The output mode (RGB / RAW / YUV) and BPC are now BUILD-TIME parameters
// of vtpgz_axilite_top — this binary is built once per (mode, bpc) combination
// and only sweeps the pattern at runtime.
//
// Each captured beat is flattened to ceil(TDATA_WIDTH/32) little-endian
// 32-bit words (low word first), so wider beats (BPC=14/16 in 3-component
// modes -> 48 bits) are preserved. Verilator emits port widths 33-64 as
// QData (uint64_t).
//
// Plusargs:
//   +pat=<0..8>
//   +width=<int>     (default 64)
//   +height=<int>    (default 32)
//   +out=<path>      (default sim_capture.bin)
//
#include <verilated.h>
#include "Vvtpgz_axilite_top.h"
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

static vluint64_t main_time = 0;
double sc_time_stamp() { return main_time; }

static Vvtpgz_axilite_top* dut = nullptr;

static void tick() {
    dut->aclk = 0; dut->eval(); ++main_time;
    dut->aclk = 1; dut->eval(); ++main_time;
}

static void axil_write(uint32_t addr, uint32_t data) {
    dut->s_axil_awaddr  = addr;
    dut->s_axil_awvalid = 1;
    dut->s_axil_wdata   = data;
    dut->s_axil_wstrb   = 0xF;
    dut->s_axil_wvalid  = 1;
    dut->s_axil_bready  = 1;
    for (int i = 0; i < 50; ++i) {
        tick();
        if (dut->s_axil_awready && dut->s_axil_wready) break;
    }
    dut->s_axil_awvalid = 0;
    dut->s_axil_wvalid  = 0;
    for (int i = 0; i < 50; ++i) {
        tick();
        if (dut->s_axil_bvalid) break;
    }
    dut->s_axil_bready = 0;
}

static int parse_plusarg_int(const char* name, int def) {
    const char* s = Verilated::commandArgsPlusMatch(name);
    if (!s || !s[0]) return def;
    // Returns "+pat=5" — skip past "+name=" prefix
    const char* eq = strchr(s, '=');
    return eq ? atoi(eq + 1) : def;
}

static const char* parse_plusarg_str(const char* name, const char* def) {
    const char* s = Verilated::commandArgsPlusMatch(name);
    if (!s || !s[0]) return def;
    const char* eq = strchr(s, '=');
    return eq ? (eq + 1) : def;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    int pat    = parse_plusarg_int("pat", 0);
    int width  = parse_plusarg_int("width", 64);
    int height = parse_plusarg_int("height", 32);
    const char* out_path = parse_plusarg_str("out", "sim_capture.bin");

    dut = new Vvtpgz_axilite_top;

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

    // Configure
    int bar_width = (width / 8) > 0 ? (width / 8) : 1;
    int hg_step   = 0xFFF / ((width  > 1) ? (width  - 1) : 1);
    int vg_step   = 0xFFF / ((height > 1) ? (height - 1) : 1);
    axil_write(VTPGZ_REG_CONTROL,      0);
    axil_write(VTPGZ_REG_IMG_WIDTH,    width);
    axil_write(VTPGZ_REG_IMG_HEIGHT,   height);
    axil_write(VTPGZ_REG_BAR_WIDTH,    bar_width);
    axil_write(VTPGZ_REG_HG_STEP,      hg_step);
    axil_write(VTPGZ_REG_VG_STEP,      vg_step);
    axil_write(VTPGZ_REG_CHECKER_SIZE, 16);
    axil_write(VTPGZ_REG_GRID_SPACING, 16);
    axil_write(VTPGZ_REG_BOX_SIZE,     (16u << 16) | 16u);
    axil_write(VTPGZ_REG_BOX_SPEED,    (1u  << 16) | 1u);
    axil_write(VTPGZ_REG_BOX_BORDER,   (1u << 24) | 0x00FFFFFF); // 1px white border
    axil_write(VTPGZ_REG_PATTERN_SEL,  pat);
    axil_write(VTPGZ_REG_FRAME_RATE,   100);
    axil_write(VTPGZ_REG_CONTROL,      1);  // enable, internal sync

    // Number of 32-bit words per beat = ceil(tdata_width / 32). Read it
    // from the COLOR_FORMAT register read-back so this stays in sync with
    // the build-time TDATA_WIDTH.
    int tdata_width = 32;
    {
        // axil_read inline (small)
        dut->s_axil_araddr  = 0x1C; // VTPGZ_REG_COLOR_FORMAT
        dut->s_axil_arvalid = 1;
        dut->s_axil_rready  = 1;
        for (int i = 0; i < 50; ++i) {
            tick();
            if (dut->s_axil_arready) break;
        }
        dut->s_axil_arvalid = 0;
        for (int i = 0; i < 50; ++i) {
            tick();
            if (dut->s_axil_rvalid) break;
        }
        tdata_width = (int)((dut->s_axil_rdata >> 16) & 0xFFFF);
        dut->s_axil_rready = 0;
    }
    int words_per_beat = (tdata_width + 31) / 32;

    std::vector<uint32_t> words;
    words.reserve((size_t)width * height * (size_t)words_per_beat);
    long total_pix = (long)width * height;

    // Run until we have captured exactly one frame's worth of pixels
    // (count from the first tuser pulse).
    bool started = false;
    long count = 0;
    long max_cycles = total_pix * 20 + 10000;
    for (long i = 0; i < max_cycles && count < total_pix; ++i) {
        tick();
        if (dut->m_axis_tvalid && dut->m_axis_tready) {
            if (!started) {
                if (dut->m_axis_tuser) started = true;
                else continue;
            }
            // Verilator: ports 1..32 bits -> CData/SData/IData (uint32_t),
            // 33..64 bits -> QData (uint64_t). Casting to uint64_t covers
            // both. For TDATA_WIDTH > 64 we'd need to read VlWide<...> --
            // not needed for BPC<=16 (max 48 bits).
            uint64_t td = (uint64_t)dut->m_axis_tdata;
            for (int w = 0; w < words_per_beat; ++w) {
                words.push_back((uint32_t)(td & 0xFFFFFFFFu));
                td >>= 32;
            }
            ++count;
        }
    }

    if (count != total_pix) {
        fprintf(stderr, "ERROR: captured only %ld of %ld pixels\n",
                count, total_pix);
        delete dut;
        return 2;
    }

    FILE* f = fopen(out_path, "wb");
    if (!f) { perror(out_path); delete dut; return 3; }
    fwrite(words.data(), sizeof(uint32_t), words.size(), f);
    fclose(f);

    printf("OK: pat=%d %dx%d -> %s (%zu words)\n",
           pat, width, height, out_path, words.size());

    delete dut;
    return 0;
}
