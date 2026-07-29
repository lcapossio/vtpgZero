# SPDX-FileCopyrightText: 2026 Leonardo Capossio - bard0 design - hello@bard0.com
# SPDX-License-Identifier: Apache-2.0
"""cocotb data-path verification for the pixels-per-clock feature.

Runs under the Icarus runner (cocotb 2.x + Verilator returns a stale packed
m_axis_tdata read -- see test_tready_probe.py -- so the AXIS *data* path is
driven from cocotb via Icarus here). Programs vtpgz_axilite_top over AXI-Lite,
captures one frame of AXI-Stream beats per pattern, and compares each beat
against the Python reference model (render_frame_beats).

Build parameters (PIXELS_PER_CLOCK / OUTPUT_MODE / BPC / ...) are fixed per
build; the test sweeps the runtime PATTERN_SEL. Config is passed in via env
vars set by run_ppc.py so the test can build the matching model config.
"""
from __future__ import annotations

import os
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

# Make the reference model importable.
import sys
HW_PY = (Path(__file__).resolve().parent / ".." / ".." /
         "hw" / "arty_a7_100t" / "python").resolve()
sys.path.insert(0, str(HW_PY))
from vtpgz_model import (  # noqa: E402
    VtpgzConfig, render_frame_beats,
    PAT_SOLID, PAT_GRID, PAT_CHECKER, PAT_COLORBAR,
    PAT_HGRAD, PAT_VGRAD, PAT_RAMP, PAT_NOISE,
)

# ---- register offsets (mirror vtpgz_defs.vh) ----
REG_CONTROL      = 0x08
REG_IMG_WIDTH    = 0x10
REG_IMG_HEIGHT   = 0x14
REG_PATTERN_SEL  = 0x18
REG_PPC          = 0x30
REG_SOLID_COLOR  = 0x20
REG_BOX_COLOR    = 0x24
REG_BOX_SIZE     = 0x28
REG_BOX_SPEED    = 0x2C
REG_GRID_SPACING = 0x34
REG_GRID_COLOR   = 0x38
REG_CHECKER_SIZE = 0x3C
REG_FRAME_RATE   = 0x40
REG_BAR_WIDTH    = 0x44
REG_HG_STEP      = 0x48
REG_VG_STEP      = 0x4C
REG_BOX_BORDER   = 0x50

# ---- config (kept identical to the model cfg built below) ----
CFG = dict(
    solid_color=0x3CA510, box_color=0x00FF00,
    box_width=12, box_height=8, box_dx=1, box_dy=1,
    box_border_color=0xFF0000, box_border_width=2,
    grid_spacing=7, grid_color=0xFFFFFF, checker_size=5,
    hg_step=64, vg_step=128, bar_width=8,
)

PATTERNS = [
    ("solid", PAT_SOLID), ("grid", PAT_GRID), ("checker", PAT_CHECKER),
    ("colorbar", PAT_COLORBAR), ("hgrad", PAT_HGRAD), ("vgrad", PAT_VGRAD),
    ("ramp", PAT_RAMP), ("noise", PAT_NOISE),
]

CLK_NS = 10


def _env_int(name, default):
    return int(os.environ.get(name, str(default)))


async def _axi_write(dut, addr, data, timeout=200):
    dut.s_axi_awaddr.value  = addr
    dut.s_axi_awvalid.value = 1
    dut.s_axi_wdata.value   = data
    dut.s_axi_wstrb.value   = 0xF
    dut.s_axi_wvalid.value  = 1
    dut.s_axi_bready.value  = 1
    aw = w = b = False
    for _ in range(timeout):
        await RisingEdge(dut.aclk)
        if not aw and int(dut.s_axi_awready.value):
            dut.s_axi_awvalid.value = 0; aw = True
        if not w and int(dut.s_axi_wready.value):
            dut.s_axi_wvalid.value = 0; w = True
        if not b and int(dut.s_axi_bvalid.value):
            dut.s_axi_bready.value = 0; b = True
        if aw and w and b:
            return
    raise AssertionError(f"AXI write to 0x{addr:02X} timed out")


async def _axi_read(dut, addr, timeout=200):
    dut.s_axi_araddr.value  = addr
    dut.s_axi_arvalid.value = 1
    dut.s_axi_rready.value  = 1
    val = None
    for _ in range(timeout):
        await RisingEdge(dut.aclk)
        if int(dut.s_axi_arready.value):
            dut.s_axi_arvalid.value = 0
        if int(dut.s_axi_rvalid.value):
            val = int(dut.s_axi_rdata.value)
            dut.s_axi_rready.value = 0
            return val
    raise AssertionError(f"AXI read from 0x{addr:02X} timed out")


async def _reset(dut):
    dut.aresetn.value = 0
    dut.s_axi_awvalid.value = 0
    dut.s_axi_wvalid.value = 0
    dut.s_axi_bready.value = 0
    dut.s_axi_arvalid.value = 0
    dut.s_axi_rready.value = 0
    dut.m_axis_tready.value = 1
    dut.frame_sync_in.value = 0
    for _ in range(10):
        await RisingEdge(dut.aclk)
    dut.aresetn.value = 1
    for _ in range(5):
        await RisingEdge(dut.aclk)


async def _program(dut, width, height, pat):
    await _axi_write(dut, REG_CONTROL, 0)              # disable while programming
    await _axi_write(dut, REG_IMG_WIDTH, width)
    await _axi_write(dut, REG_IMG_HEIGHT, height)
    await _axi_write(dut, REG_BAR_WIDTH, CFG["bar_width"])
    await _axi_write(dut, REG_HG_STEP, CFG["hg_step"])
    await _axi_write(dut, REG_VG_STEP, CFG["vg_step"])
    await _axi_write(dut, REG_CHECKER_SIZE, CFG["checker_size"])
    await _axi_write(dut, REG_GRID_SPACING, CFG["grid_spacing"])
    await _axi_write(dut, REG_GRID_COLOR, CFG["grid_color"])
    await _axi_write(dut, REG_SOLID_COLOR, CFG["solid_color"])
    await _axi_write(dut, REG_BOX_COLOR, CFG["box_color"])
    await _axi_write(dut, REG_BOX_SIZE, (CFG["box_width"] << 16) | CFG["box_height"])
    await _axi_write(dut, REG_BOX_SPEED, (CFG["box_dx"] << 16) | CFG["box_dy"])
    await _axi_write(dut, REG_BOX_BORDER,
                     (CFG["box_border_width"] << 24) | CFG["box_border_color"])
    await _axi_write(dut, REG_FRAME_RATE, 50)
    await _axi_write(dut, REG_PATTERN_SEL, pat)
    await _axi_write(dut, REG_CONTROL, 1)              # enable, internal sync


async def _capture_frame(dut, n_beats, max_cycles):
    beats = []
    started = False
    cycles = 0
    while len(beats) < n_beats and cycles < max_cycles:
        await RisingEdge(dut.aclk)
        cycles += 1
        if int(dut.m_axis_tvalid.value) and int(dut.m_axis_tready.value):
            if not started:
                if int(dut.m_axis_tuser.value):
                    started = True
                else:
                    continue
            beats.append(int(dut.m_axis_tdata.value))
    return beats


@cocotb.test()
async def ppc_datapath_vs_model(dut):
    ppc    = _env_int("VTPGZ_PPC", 1)
    mode   = _env_int("VTPGZ_MODE", 0)
    bpc    = _env_int("VTPGZ_BPC", 8)
    sub    = _env_int("VTPGZ_YUV_SUB", 0)
    bayer  = _env_int("VTPGZ_RAW_BAYER", 1)
    order  = _env_int("VTPGZ_RGB_ORDER", 0)
    width  = _env_int("VTPGZ_WIDTH", 32)
    height = _env_int("VTPGZ_HEIGHT", 12)
    assert width % ppc == 0, "width must be a multiple of PIXELS_PER_CLOCK"

    cocotb.start_soon(Clock(dut.aclk, CLK_NS, unit="ns").start())
    await _reset(dut)

    # Confirm the build's PPC matches what the runner intended.
    ppc_rb = await _axi_read(dut, REG_PPC)
    assert ppc_rb == ppc, f"PPC readback {ppc_rb} != expected {ppc}"

    beats_per_frame = (width // ppc) * height
    max_cycles = beats_per_frame * 40 + 20000

    for pname, pat in PATTERNS:
        await _program(dut, width, height, pat)
        sim = await _capture_frame(dut, beats_per_frame, max_cycles)
        assert len(sim) == beats_per_frame, (
            f"{pname}: captured {len(sim)}/{beats_per_frame} beats")

        cfg = VtpgzConfig(width=width, height=height, pattern=pat,
                          output_mode=mode, yuv_subsample=sub, raw_bayer=bayer,
                          rgb_order=order, bpc=bpc, pixels_per_clock=ppc, **CFG)
        mod = render_frame_beats(cfg)
        assert len(mod) == len(sim)
        first = next((i for i, (a, b) in enumerate(zip(sim, mod)) if a != b), -1)
        assert first == -1, (
            f"{pname} ppc={ppc} mode={mode} bpc={bpc}: beat {first} "
            f"sim=0x{sim[first]:X} mod=0x{mod[first]:X}")
        dut._log.info(f"OK {pname} ppc={ppc} mode={mode} bpc={bpc} "
                      f"({len(sim)} beats)")

        # Toggle enable off so the next pattern starts a fresh frame.
        await _axi_write(dut, REG_CONTROL, 0)
        for _ in range(5):
            await RisingEdge(dut.aclk)
