#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Leonardo Capossio - bard0 design - hello@bard0.com
# SPDX-License-Identifier: Apache-2.0
"""Cycle-accurate Python reference model for the vtpgZero core.

Mirrors the RTL in ../../../../rtl/vtpgz_top.v register-by-register. As of
Phase 2a there is no separate CSC module: patterns produce native triples in
the build's color space (RGB/RAW -> {R,G,B}, YUV -> {Y,Cb,Cr}) and the pack
stage just shrinks + reorders -- 0 DSPs in every mode.

The K-th AXI-Stream beat (K = 0 .. width*height-1) corresponds to the value
the RTL output register holds at cycle K+2 of the active frame, computed
from the *current* state of the pattern registers at that cycle. After we
read the registers we then "tick" them with the same x_reg value to get
the state for the next cycle.

This produces byte-exact agreement with Verilator simulation for all
9 patterns x 4 formats x 3 bit depths.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Iterable

# ----- enums (must match vtpgz_defs.vh) -----
PAT_COLORBAR   = 0
PAT_HGRAD      = 1
PAT_VGRAD      = 2
PAT_CHECKER    = 3
PAT_SOLID      = 4
PAT_MOVING_BOX = 5
PAT_GRID       = 6
PAT_RAMP       = 7
PAT_NOISE      = 8
PAT_IMAGE      = 9

# Build-time output modes (must match vtpgz_defs.vh)
MODE_RGB = 0
MODE_RAW = 1
MODE_YUV = 2

YUV_444 = 0
YUV_422 = 1

RAW_PLAIN = 0
RAW_RGGB  = 1
RAW_BGGR  = 2
RAW_GRBG  = 3
RAW_GBRG  = 4

RGB_ORDER_XILINX = 0  # {pad, B, G, R}, R in LSBs
RGB_ORDER_LEGACY = 1  # {R, G, B, pad}, R in MSBs


def derived_tdata_width(output_mode: int, bpc: int,
                        yuv_subsample: int = YUV_444) -> int:
    """Mirror the localparam in vtpgz_top.v: smallest multiple of 8 that
    holds the active components for the chosen mode."""
    def round8(n: int) -> int:
        return ((n + 7) // 8) * 8
    if output_mode == MODE_RGB:
        return round8(3 * bpc)
    if output_mode == MODE_RAW:
        return round8(bpc)
    # MODE_YUV
    if yuv_subsample == YUV_444:
        return round8(3 * bpc)
    return round8(2 * bpc)


@dataclass
class VtpgzConfig:
    width: int = 64
    height: int = 32
    pattern: int = PAT_COLORBAR
    # Build-time output mode (was: runtime fmt)
    output_mode: int = MODE_RGB
    yuv_subsample: int = YUV_444
    raw_bayer: int = RAW_RGGB
    rgb_order: int = RGB_ORDER_XILINX
    bpc: int = 8
    bar_width: int = 8
    hg_step: int = 0xFFF // 63
    vg_step: int = 0xFFF // 31
    solid_color: int = 0x00FFFFFF
    box_color: int = 0x00FF0000
    box_width: int = 0
    box_height: int = 0
    box_dx: int = 1
    box_dy: int = 1
    box_border_color: int = 0x00000000
    box_border_width: int = 0
    grid_spacing: int = 16
    grid_color: int = 0x00FFFFFF
    checker_size: int = 16
    # IMAGE pattern: 24-bit packed RGB888 from $readmemh, dimensions and
    # the raw 8-bit-per-component buffer are baked in at synth time.
    # image_out_w / image_out_h define the on-screen window size; when they
    # differ from image_w / image_h, a Q16 nearest-neighbour scaler maps
    # the source to the output window. 0 here means "no IMAGE pattern".
    image_w: int = 0
    image_h: int = 0
    image_out_w: int = 0
    image_out_h: int = 0
    image_rgb888: list = field(default_factory=list)  # length = image_w * image_h

    @property
    def tdata_width(self) -> int:
        return derived_tdata_width(self.output_mode, self.bpc, self.yuv_subsample)


@dataclass
class VtpgzRegs:
    """Mirrors all the pattern-related RTL registers."""
    # colorbar
    bar_pix_cnt: int = 0
    bar_idx: int = 0
    # hgrad
    hg_acc: int = 0
    # vgrad
    vg_acc: int = 0
    # checker
    chk_x_cnt: int = 0
    chk_y_cnt: int = 0
    chk_sel_x: int = 0
    chk_sel_y: int = 0
    # grid
    gx_cnt: int = 0
    gy_cnt: int = 0
    # ramp
    ramp_acc: int = 0
    # noise (LFSR-16)
    lfsr: int = 0xACE1
    # moving box (per-frame state). box_x_max / box_y_max are precomputed
    # in the RTL to keep the per-pixel comparator off the critical path,
    # so they update at end_of_frame and start at zero (no box on the very
    # first frame after enable).
    box_x: int = 0
    box_y: int = 0
    box_x_max: int = 0
    box_y_max: int = 0
    box_dir_x: int = 0
    box_dir_y: int = 0


# ============================================================================
# Combinational pattern outputs (read current registers, return RGB12)
# ============================================================================

# RGB palette (build OUTPUT_MODE in {RGB, RAW}): {R, G, B}
PALETTE_RGB = [
    (0xFFF, 0xFFF, 0xFFF),  # 0 white
    (0xFFF, 0xFFF, 0x000),  # 1 yellow
    (0x000, 0xFFF, 0xFFF),  # 2 cyan
    (0x000, 0xFFF, 0x000),  # 3 green
    (0xFFF, 0x000, 0xFFF),  # 4 magenta
    (0xFFF, 0x000, 0x000),  # 5 red
    (0x000, 0x000, 0xFFF),  # 6 blue
    (0x000, 0x000, 0x000),  # 7 black
]
# YUV palette (build OUTPUT_MODE = YUV): {Y, Cb, Cr}, 12-bit, BT.601 full-range
# Constants must match the case statement in vtpgz_top.v g_yuv_pal.
PALETTE_YUV = [
    (0xFFF, 0x800, 0x800),  # 0 white
    (0xE2C, 0x000, 0x94D),  # 1 yellow
    (0xB37, 0xAB3, 0x000),  # 2 cyan
    (0x964, 0x2B4, 0x14E),  # 3 green
    (0x69B, 0xD4C, 0xEB2),  # 4 magenta
    (0x4C8, 0x54D, 0xFFF),  # 5 red
    (0x1D3, 0xFFF, 0x6B3),  # 6 blue
    (0x000, 0x800, 0x800),  # 7 black
]
CHROMA_NEUTRAL = 0x800  # 12-bit Q12 neutral chroma (0.5)


def _comb_pixel(cfg: VtpgzConfig, regs: VtpgzRegs, x: int, y: int) -> tuple[int, int, int]:
    """Compute the 12-bit native triple {c0,c1,c2} for the build's color space.
    RGB/RAW modes return {R,G,B}; YUV mode returns {Y,Cb,Cr}.
    """
    is_yuv = (cfg.output_mode == MODE_YUV)
    pat = cfg.pattern

    def gray(v: int) -> tuple[int, int, int]:
        if is_yuv:
            return (v, CHROMA_NEUTRAL, CHROMA_NEUTRAL)
        return (v, v, v)

    if pat == PAT_COLORBAR:
        pal = PALETTE_YUV if is_yuv else PALETTE_RGB
        return pal[regs.bar_idx & 0x7]

    if pat == PAT_HGRAD:
        v = 0xFFF if (regs.hg_acc >> 12) else (regs.hg_acc & 0xFFF)
        return gray(v)

    if pat == PAT_VGRAD:
        v = 0xFFF if (regs.vg_acc >> 12) else (regs.vg_acc & 0xFFF)
        return gray(v)

    if pat == PAT_CHECKER:
        v = 0xFFF if (regs.chk_sel_x ^ regs.chk_sel_y) else 0x000
        return gray(v)

    if pat == PAT_SOLID:
        r = ((cfg.solid_color >> 16) & 0xFF) << 4
        g = ((cfg.solid_color >> 8)  & 0xFF) << 4
        b = ( cfg.solid_color        & 0xFF) << 4
        return (r, g, b)

    # PAT_MOVING_BOX is no longer a standalone pattern; the box is a
    # post-mux overlay (see _box_overlay below). Selecting pattern 5
    # produces black.

    if pat == PAT_GRID:
        on = (regs.gx_cnt == 0) or (regs.gy_cnt == 0)
        if on:
            r = ((cfg.grid_color >> 16) & 0xFF) << 4
            g = ((cfg.grid_color >> 8)  & 0xFF) << 4
            b = ( cfg.grid_color        & 0xFF) << 4
        else:
            r = g = b = 0
        return (r, g, b)

    if pat == PAT_RAMP:
        v = 0xFFF if (regs.ramp_acc >> 12) else (regs.ramp_acc & 0xFFF)
        return gray(v)

    if pat == PAT_NOISE:
        v = regs.lfsr & 0xFFF
        return gray(v)

    if pat == PAT_IMAGE:
        # Centred, scaled with Q16 nearest-neighbour. Source pixel index
        # for output pixel k (0..image_out_w - 1) is (k * step) >> 16,
        # where step = (image_w << 16) // image_out_w, mirroring the RTL.
        if cfg.image_w == 0 or cfg.image_h == 0 or not cfg.image_rgb888:
            return (0, 0, 0)
        out_w = cfg.image_out_w or cfg.image_w
        out_h = cfg.image_out_h or cfg.image_h
        x_off = (cfg.width  - out_w) // 2 if cfg.width  > out_w else 0
        y_off = (cfg.height - out_h) // 2 if cfg.height > out_h else 0
        if not (x_off <= x < x_off + out_w and
                y_off <= y < y_off + out_h):
            return (0, 0, 0)
        step_x = (cfg.image_w << 16) // out_w
        step_y = (cfg.image_h << 16) // out_h
        ix = (((x - x_off) * step_x) >> 16) & (cfg.image_w - 1)
        iy = (((y - y_off) * step_y) >> 16) & (cfg.image_h - 1)
        word = cfg.image_rgb888[iy * cfg.image_w + ix]
        r8 = (word >> 16) & 0xFF
        g8 = (word >> 8)  & 0xFF
        b8 =  word        & 0xFF
        return ((r8 << 4) | (r8 >> 4),
                (g8 << 4) | (g8 >> 4),
                (b8 << 4) | (b8 >> 4))

    return (0, 0, 0)


# ============================================================================
# Sequential register update (mirrors `always @(posedge aclk) if (advance)`)
# Called with the CURRENT x_reg / y_reg values; produces the NEW register
# state for the next cycle.
# ============================================================================

def _tick(cfg: VtpgzConfig, regs: VtpgzRegs, x_reg: int, y_reg: int,
          last_x: bool, pix_sof: bool, end_of_frame: bool) -> None:
    """Update all registers in-place, mirroring the RTL update gating."""
    # ---- colorbar ----
    # Anchor the wrap on last_x (end of line) instead of (x_reg == 0).
    # NBA-equivalent: register state set this tick reflects what the next
    # cycle sees; if we cleared at x==0 the pattern at x=0 had already been
    # read using the prior bar_idx and the bar 7->0 wrap was lost.
    if pix_sof or last_x:
        regs.bar_pix_cnt = 0
        regs.bar_idx = 0
    elif regs.bar_pix_cnt + 1 >= cfg.bar_width:
        regs.bar_pix_cnt = 0
        regs.bar_idx = (regs.bar_idx + 1) & 0x7
    else:
        regs.bar_pix_cnt += 1

    # ---- hgrad ----
    # Anchor on last_x: see colorbar comment. Clearing at x==0 left
    # hg_acc carrying ~width*step into the next line's pixel 0.
    if last_x:
        regs.hg_acc = 0
    else:
        regs.hg_acc = (regs.hg_acc + cfg.hg_step) & 0xFFFFF

    # ---- vgrad ----
    if pix_sof:
        regs.vg_acc = 0
    elif last_x:
        regs.vg_acc = (regs.vg_acc + cfg.vg_step) & 0xFFFFF

    # ---- checker ----
    chk_size_eff = max(1, cfg.checker_size)
    if last_x:
        regs.chk_x_cnt = 0
        regs.chk_sel_x = 0
    elif regs.chk_x_cnt + 1 >= chk_size_eff:
        regs.chk_x_cnt = 0
        regs.chk_sel_x ^= 1
    else:
        regs.chk_x_cnt += 1

    if pix_sof:
        regs.chk_y_cnt = 0
        regs.chk_sel_y = 0
    elif last_x:
        if regs.chk_y_cnt + 1 >= chk_size_eff:
            regs.chk_y_cnt = 0
            regs.chk_sel_y ^= 1
        else:
            regs.chk_y_cnt += 1

    # ---- grid ----
    grid_eff = max(1, cfg.grid_spacing)
    if last_x:
        regs.gx_cnt = 0
    elif regs.gx_cnt + 1 >= grid_eff:
        regs.gx_cnt = 0
    else:
        regs.gx_cnt += 1

    if pix_sof:
        regs.gy_cnt = 0
    elif last_x:
        if regs.gy_cnt + 1 >= grid_eff:
            regs.gy_cnt = 0
        else:
            regs.gy_cnt += 1

    # ---- ramp ----
    if last_x:
        regs.ramp_acc = 0
    else:
        regs.ramp_acc = (regs.ramp_acc + cfg.hg_step) & 0xFFFFF

    # ---- LFSR (always advances when advance=1) ----
    fb = ((regs.lfsr >> 15) ^ (regs.lfsr >> 13)
          ^ (regs.lfsr >> 12) ^ (regs.lfsr >> 10)) & 1
    regs.lfsr = ((regs.lfsr << 1) | fb) & 0xFFFF

    # ---- moving box (only at end_of_frame) ----
    if end_of_frame:
        # Compute next box_x / box_y combinationally (matches RTL).
        new_x, new_dx = regs.box_x, regs.box_dir_x
        if regs.box_dir_x == 0:
            if regs.box_x + cfg.box_width + cfg.box_dx >= cfg.width:
                new_dx = 1
                new_x = cfg.width - cfg.box_width - 1
            else:
                new_x = regs.box_x + cfg.box_dx
        else:
            if regs.box_x < cfg.box_dx:
                new_dx = 0
                new_x = 0
            else:
                new_x = regs.box_x - cfg.box_dx
        new_y, new_dy = regs.box_y, regs.box_dir_y
        if regs.box_dir_y == 0:
            if regs.box_y + cfg.box_height + cfg.box_dy >= cfg.height:
                new_dy = 1
                new_y = cfg.height - cfg.box_height - 1
            else:
                new_y = regs.box_y + cfg.box_dy
        else:
            if regs.box_y < cfg.box_dy:
                new_dy = 0
                new_y = 0
            else:
                new_y = regs.box_y - cfg.box_dy
        regs.box_x     = new_x
        regs.box_y     = new_y
        regs.box_dir_x = new_dx
        regs.box_dir_y = new_dy


# ============================================================================
# Pack stage (mirrors the inline pack stage in vtpgz_top.v)
# Patterns now produce native triples in the build's color space, so the
# packer just shrinks each component to BPC and reorders. No CSC, no DSPs.
# ============================================================================

def _shrink(v12: int, bpc: int) -> int:
    """Map a 12-bit pattern value to bpc bits.
    bpc <= 12: drop the low (12-bpc) LSBs (truncate).
    bpc >  12: zero-extend on the right by (bpc-12) bits.
    Mirrors the BPC shrink/grow generate in vtpgz_core.v.
    """
    if bpc <= 12:
        return (v12 >> (12 - bpc)) & ((1 << bpc) - 1)
    return (v12 << (bpc - 12)) & ((1 << bpc) - 1)


def _pack_tdata(c0_12: int, c1_12: int, c2_12: int, x: int, y: int,
                cfg: VtpgzConfig) -> int:
    """Pack one pixel triple into tdata according to the build-time output mode.

    For RGB/RAW: triple is {R,G,B}. For YUV: triple is {Y,Cb,Cr}.
    Mirrors the pack generate in vtpgz_top.v exactly.
    """
    bpc = cfg.bpc
    tw  = cfg.tdata_width
    c0  = _shrink(c0_12, bpc)
    c1  = _shrink(c1_12, bpc)
    c2  = _shrink(c2_12, bpc)

    # 3-component pack: RGB or YUV444
    if cfg.output_mode == MODE_RGB or (
            cfg.output_mode == MODE_YUV and cfg.yuv_subsample == YUV_444):
        if cfg.rgb_order == RGB_ORDER_XILINX:
            # {pad, c2, c1, c0}  ({pad,B,G,R} or {pad,Cr,Cb,Y})
            return (c2 << (2 * bpc)) | (c1 << bpc) | c0
        else:
            pad = tw - 3 * bpc
            return (c0 << (2 * bpc + pad)) | (c1 << (bpc + pad)) | (c2 << pad)

    if cfg.output_mode == MODE_YUV:
        # YUV422: {pad, C, Y}; C = c1 (Cb) on even-x, c2 (Cr) on odd-x
        c = c1 if (x & 1) == 0 else c2
        if cfg.rgb_order == RGB_ORDER_XILINX:
            return (c << bpc) | c0
        else:
            pad = tw - 2 * bpc
            return (c0 << (bpc + pad)) | (c << pad)

    # MODE_RAW. Triples are {c0=R, c1=G, c2=B}; mux per Bayer tile.
    yo = y & 1
    xo = x & 1
    if cfg.raw_bayer == RAW_RGGB:
        # row0:[R,G] row1:[G,B]
        if yo == 0:
            comp = c0 if xo == 0 else c1
        else:
            comp = c1 if xo == 0 else c2
    elif cfg.raw_bayer == RAW_BGGR:
        # row0:[B,G] row1:[G,R]
        if yo == 0:
            comp = c2 if xo == 0 else c1
        else:
            comp = c1 if xo == 0 else c0
    elif cfg.raw_bayer == RAW_GRBG:
        # row0:[G,R] row1:[B,G]
        if yo == 0:
            comp = c1 if xo == 0 else c0
        else:
            comp = c2 if xo == 0 else c1
    elif cfg.raw_bayer == RAW_GBRG:
        # row0:[G,B] row1:[R,G]
        if yo == 0:
            comp = c1 if xo == 0 else c2
        else:
            comp = c0 if xo == 0 else c1
    else:
        comp = c1   # PLAIN: monochrome, take G
    return comp & ((1 << tw) - 1)


# ============================================================================
# Box overlay (post-pattern-mux, mirrors the RTL box overlay in vtpgz_core.v)
# ============================================================================

def _box_overlay(c0: int, c1: int, c2: int, x: int, y: int,
                 cfg: VtpgzConfig, regs: VtpgzRegs) -> tuple[int, int, int]:
    """If (x,y) is inside the box region, replace the triple with
    cfg_box_color (fill) or cfg_box_border_color (border ring).
    Border is drawn inside the box: pixels within border_width of any
    box edge are border, the rest is fill. border_width=0 → no border."""
    bx, by = regs.box_x, regs.box_y
    inside = (bx <= x < bx + cfg.box_width) and \
             (by <= y < by + cfg.box_height)
    if not inside:
        return (c0, c1, c2)
    bw = cfg.box_border_width
    on_border = bw > 0 and (
        x < bx + bw or
        x >= bx + cfg.box_width - bw or
        y < by + bw or
        y >= by + cfg.box_height - bw
    )
    if on_border:
        col = cfg.box_border_color
    else:
        col = cfg.box_color
    r = ((col >> 16) & 0xFF) << 4
    g = ((col >> 8)  & 0xFF) << 4
    b = ( col        & 0xFF) << 4
    return (r, g, b)


# ============================================================================
# Frame renderer
# ============================================================================

def render_frame(cfg: VtpgzConfig, regs: VtpgzRegs | None = None) -> list[int]:
    """Render one full frame and return list of 48-bit tdata words.

    The simulation models the AXI output register: each beat reflects the
    pattern registers at the cycle when tdata_next was loaded into tdata_r.

    Sequence per pixel K (K = 0..W*H-1):
      1. x_reg = K % W, y_reg = K // W
      2. Compute pixel from current registers (combinational)
      3. Pack tdata, append to output
      4. Tick registers using current x_reg/y_reg (mirrors rising edge)
    """
    if regs is None:
        regs = VtpgzRegs()

    out: list[int] = []
    W, H = cfg.width, cfg.height
    total = W * H

    for K in range(total):
        x_reg = K % W
        y_reg = K // W
        last_x = (x_reg == W - 1)
        pix_sof = (x_reg == 0 and y_reg == 0)
        end_of_frame = last_x and (y_reg == H - 1)

        c0_12, c1_12, c2_12 = _comb_pixel(cfg, regs, x_reg, y_reg)
        # Box overlay: if box dimensions are non-zero and (x,y) is inside
        # the box region, the pixel triple is replaced with box_color.
        if cfg.box_width > 0 and cfg.box_height > 0:
            c0_12, c1_12, c2_12 = _box_overlay(
                c0_12, c1_12, c2_12, x_reg, y_reg, cfg, regs)
        out.append(_pack_tdata(c0_12, c1_12, c2_12, x_reg, y_reg, cfg))

        _tick(cfg, regs, x_reg, y_reg, last_x, pix_sof, end_of_frame)

    return out


def tdata_to_bram_words(tdata_list: Iterable[int],
                        tdata_width: int = 32) -> list[int]:
    """Flatten a list of tdata beats to little-endian 32-bit words.

    For tdata_width <= 32 each beat becomes one word (any high padding
    bits are zero anyway). For wider beats each beat becomes
    ceil(tdata_width/32) words, low 32 bits first. This matches what
    sim_capture.cpp writes to its capture file (and what
    frame_capture.v stores in BRAM at PPC=1, when its TDATA_WIDTH is
    sized for the build).
    """
    n_words = (tdata_width + 31) // 32
    out: list[int] = []
    for td in tdata_list:
        v = td
        for _ in range(n_words):
            out.append(v & 0xFFFFFFFF)
            v >>= 32
    return out


# ============================================================================
# Self-test
# ============================================================================
if __name__ == "__main__":
    # Smoke: RGB 8bpc colorbar should produce {0xFF, 0xFF, 0xFF} packed
    # in Xilinx order = 0x00FFFFFF
    cfg = VtpgzConfig(width=64, height=32, pattern=PAT_COLORBAR,
                      output_mode=MODE_RGB, bpc=8, bar_width=8)
    f = render_frame(cfg)
    assert len(f) == 64 * 32
    first = f[0]
    assert first == 0x00FFFFFF, f"first pixel = 0x{first:08X} (expected 0x00FFFFFF)"
    print(f"PASS: colorbar 64x32 RGB8 first pixel = 0x{first:08X}")

    # Sweep all (mode, bpc) combos
    n = 0
    for pat in range(9):
        for output_mode in (MODE_RGB, MODE_RAW, MODE_YUV):
            for bpc in (8, 10, 12, 14, 16):
                for sub in (YUV_444, YUV_422) if output_mode == MODE_YUV else (0,):
                    c = VtpgzConfig(width=16, height=8, pattern=pat,
                                    output_mode=output_mode,
                                    yuv_subsample=sub,
                                    bpc=bpc,
                                    bar_width=2,
                                    hg_step=0xFFF // 15,
                                    vg_step=0xFFF // 7,
                                    checker_size=4, grid_spacing=4,
                                    box_width=4, box_height=4)
                    render_frame(c)
                    n += 1
    print(f"PASS: all {n} (pattern x mode x bpc x sub) combinations render")
