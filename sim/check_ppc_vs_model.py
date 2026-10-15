#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Leonardo Capossio - bard0 design - hello@bard0.com
# SPDX-License-Identifier: Apache-2.0
"""
iverilog(RTL) <-> Python-model beat-exact gate for the pixels-per-clock
feature (M1+M2 patterns). Builds tb_ppc_capture.v once per (ppc, mode, bpc,
...) config with iverilog -P overrides, sweeps the PPC-supported patterns,
and compares each captured frame (one hex beat per line) against
render_frame_beats().

Requires iverilog + vvp in PATH. Verilator is NOT needed here (that remains
the byte-exact gate for the PPC=1 baseline via sim/run_sim.py).

Usage:
    python sim/check_ppc_vs_model.py                 # sweep ppc x mode x pattern
    python sim/check_ppc_vs_model.py --ppc 4 --mode rgb --bpc 8
"""
from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
RTL = (HERE / ".." / "rtl").resolve()
HW_PY = (HERE / ".." / "hw" / "arty_a7_100t" / "python").resolve()
sys.path.insert(0, str(HW_PY))
sys.path.insert(0, str((HERE / ".." / "scripts").resolve()))

from vtpgz_model import (  # noqa: E402
    VtpgzConfig, render_frame_beats,
    MODE_RGB, MODE_RAW, MODE_YUV, YUV_444, YUV_422,
    RAW_PLAIN, RAW_RGGB, RAW_BGGR, RAW_GRBG, RAW_GBRG,
    RGB_ORDER_XILINX, RGB_ORDER_LEGACY,
    PAT_SOLID, PAT_GRID, PAT_CHECKER,
    PAT_COLORBAR, PAT_HGRAD, PAT_VGRAD, PAT_RAMP, PAT_NOISE, PAT_IMAGE,
    PAT_SMPTE, smpte_host_geometry, grad_step, VtpgzRegs,
    YUV_FULL, YUV_LIMITED, YUV_BT601, YUV_BT709,
)
from image_to_hex import pixel_word  # noqa: E402

# ---- IMAGE test config: a 16x16 source scaled to an 8x8 window (exercises
# the per-lane Q16 scaler at PPC>1). Deterministic RGB888 so the model and
# the $readmemh'd RTL BRAMs hold identical data.
IMG_W_T, IMG_H_T = 16, 16
IMG_OUT_T = 8


def gen_image() -> list[int]:
    data = []
    for iy in range(IMG_H_T):
        for ix in range(IMG_W_T):
            r = (ix * 16) & 0xFF
            g = (iy * 16) & 0xFF
            b = ((ix * 7 + iy * 13) * 3) & 0xFF
            data.append((r << 16) | (g << 8) | b)
    return data


IMAGE_DATA = gen_image()
IMAGE_HEX_PATH = ""  # set in main()

MODE_MAP = {"rgb": MODE_RGB, "raw": MODE_RAW, "yuv": MODE_YUV}
SUB_MAP = {"444": YUV_444, "422": YUV_422}
BAYER_MAP = {"plain": RAW_PLAIN, "rggb": RAW_RGGB, "bggr": RAW_BGGR,
             "grbg": RAW_GRBG, "gbrg": RAW_GBRG}
ORDER_MAP = {"xilinx": RGB_ORDER_XILINX, "legacy": RGB_ORDER_LEGACY}

# Patterns exercised at PPC>1 (M1 + M2 scope). The box overlay rides on top
# of every pattern (driven by the harness box_* config), so it is covered too.
PPC_PATTERNS = [
    ("solid", PAT_SOLID), ("grid", PAT_GRID), ("checker", PAT_CHECKER),
    ("colorbar", PAT_COLORBAR), ("hgrad", PAT_HGRAD),
    ("vgrad", PAT_VGRAD), ("ramp", PAT_RAMP), ("noise", PAT_NOISE),
    ("image", PAT_IMAGE), ("smpte", PAT_SMPTE),
]

# Must mirror the constant cfg_* the harness drives (tb_ppc_capture.v).
HARNESS_CFG = dict(
    solid_color=0x3CA510,
    box_color=0x00FF00,
    box_width=12, box_height=8, box_dx=1, box_dy=1,
    box_border_color=0xFF0000, box_border_width=2,
    grid_spacing=7, grid_color=0xFFFFFF,
    checker_size=5,
    # Q12.16 steps with fraction bits set, so the per-lane carries at PPC>1
    # are exercised (64.6 and 128.2 codes).
    hg_step=0x409A5B, vg_step=0x803C71, bar_width=8,
    # The tb's default SMPTE geometry. At 32x12 most widths are below 8, so
    # PPC>1 exercises the RTL's clamp of every width to >= PPC.
    smpte_side_d=3, smpte_bar_c=3, smpte_pluge_p=1, smpte_row_h=1,
    smpte_ramp_step=18000,
)


def need(tool: str) -> str:
    p = shutil.which(tool)
    if not p:
        print(f"ERROR: '{tool}' not found in PATH", file=sys.stderr)
        sys.exit(2)
    return p


def build(ppc: int, mode: int, sub: int, bayer: int, order: int, bpc: int,
          out_vvp: Path, colorimetry: dict | None = None,
          extra: dict | None = None) -> None:
    iverilog = need("iverilog")
    top = "tb_ppc_capture"
    col = colorimetry or {}
    params = {
        "PIXELS_PER_CLOCK": ppc, "OUTPUT_MODE": mode, "YUV_SUBSAMPLE": sub,
        "RAW_BAYER": bayer, "RGB_ORDER": order, "BPC": bpc,
        "YUV_RANGE": col.get("yuv_range", YUV_FULL),
        "YUV_MATRIX": col.get("yuv_matrix", YUV_BT601),
        "BAR_LEVEL": col.get("bar_level", 100),
        # M2/M3 patterns are legal at PPC>1 now; enable them for the sweep.
        "EN_COLORBAR": 1, "EN_HGRAD": 1, "EN_VGRAD": 1, "EN_RAMP": 1,
        "EN_NOISE": 1, "EN_SMPTE": 1,
        **(extra or {}),
    }
    cmd = [iverilog, "-g2001", "-Wall", "-I", str(RTL), "-s", top,
           "-o", str(out_vvp)]
    for k, v in params.items():
        cmd += ["-P", f"{top}.{k}={v}"]
    # IMAGE pattern: enable the BRAM path with the small scaled test image.
    cmd += ["-P", f"{top}.EN_IMAGE=1",
            "-P", f"{top}.IMAGE_W={IMG_W_T}", "-P", f"{top}.IMAGE_H={IMG_H_T}",
            "-P", f"{top}.IMAGE_OUT_W={IMG_OUT_T}", "-P", f"{top}.IMAGE_OUT_H={IMG_OUT_T}",
            "-P", f'{top}.IMAGE_HEX_FILE="{IMAGE_HEX_PATH}"']
    cmd += [str(RTL / "vtpgz_core.v"), str(HERE / "tb_ppc_capture.v")]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError("iverilog build failed:\n" + r.stdout + r.stderr)


def run_capture(vvp_bin: Path, pat: int, width: int, height: int,
                out_hex: Path, smpte: dict | None = None) -> None:
    vvp = need("vvp")
    cmd = [vvp, str(vvp_bin), f"+pat={pat}", f"+width={width}",
           f"+height={height}", f"+out={out_hex}"]
    names = {"smpte_side_d": "sm_d", "smpte_bar_c": "sm_c",
             "smpte_pluge_p": "sm_p", "smpte_row_h": "sm_h",
             "smpte_ramp_step": "sm_step",
             "hg_step": "hg_step", "vg_step": "vg_step", "skip": "skip"}
    cmd += [f"+{names[k]}={v}" for k, v in (smpte or {}).items()]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0 or "OK:" not in r.stdout:
        raise RuntimeError(f"vvp capture failed (pat={pat}):\n{r.stdout}{r.stderr}")


def load_beats(path: Path) -> list[int]:
    return [int(line, 16) for line in path.read_text().split() if line.strip()]


def model_beats(pat: int, ppc: int, mode: int, sub: int, bayer: int,
                order: int, bpc: int, width: int, height: int,
                colorimetry: dict | None = None) -> list[int]:
    cfg = VtpgzConfig(width=width, height=height, pattern=pat,
                      output_mode=mode, yuv_subsample=sub, raw_bayer=bayer,
                      rgb_order=order, bpc=bpc, pixels_per_clock=ppc,
                      image_w=IMG_W_T, image_h=IMG_H_T,
                      image_out_w=IMG_OUT_T, image_out_h=IMG_OUT_T,
                      image_rgb888=IMAGE_DATA,
                      **(colorimetry or {}), **HARNESS_CFG)
    return render_frame_beats(cfg)


def check_one(ppc: int, mode_name: str, bpc: int, sub_name: str,
              bayer_name: str, order_name: str, width: int, height: int,
              tmp: Path, colorimetry: dict | None = None) -> list[str]:
    mode = MODE_MAP[mode_name]
    sub = SUB_MAP[sub_name]
    bayer = BAYER_MAP[bayer_name]
    order = ORDER_MAP[order_name]
    ctag = "".join(f"_{k[0]}{v}" for k, v in (colorimetry or {}).items())
    vvp_bin = tmp / f"ppc{ppc}_{mode_name}_{bpc}{ctag}.vvp"
    build(ppc, mode, sub, bayer, order, bpc, vvp_bin, colorimetry)
    fails: list[str] = []
    label = f"ppc={ppc} mode={mode_name} bpc={bpc}" + (
        " " + " ".join(f"{k}={v}" for k, v in colorimetry.items())
        if colorimetry else "")
    for pname, pat in PPC_PATTERNS:
        hexf = tmp / f"cap_{ppc}_{mode_name}_{bpc}{ctag}_{pname}.hex"
        run_capture(vvp_bin, pat, width, height, hexf)
        sim = load_beats(hexf)
        mod = model_beats(pat, ppc, mode, sub, bayer, order, bpc, width,
                          height, colorimetry)
        if ppc == 1 and pname == "image":
            # At PPC=1 the IMAGE pattern keeps its registered-read 1-px
            # horizontal shift (unchanged from prior releases), so the frame
            # is not beat-comparable to the shift-free model. The rows above
            # the image window are, though, and they are all padding -- which
            # must be the build's black (0x800 chroma in YUV, not zero).
            n_pad = (height - IMG_OUT_T) // 2 * width
            sim, mod = sim[:n_pad], mod[:n_pad]
            pname = "image(padding rows)"
        if sim != mod:
            first = next((i for i, (a, b) in enumerate(zip(sim, mod)) if a != b),
                         min(len(sim), len(mod)))
            fails.append(
                f"{label} pat={pname}: "
                f"len sim={len(sim)} mod={len(mod)} first_diff@{first} "
                f"sim=0x{(sim[first] if first < len(sim) else 0):X} "
                f"mod=0x{(mod[first] if first < len(mod) else 0):X}")
        else:
            print(f"  OK  {label} pat={pname} ({len(sim)} beats)")
    return fails


# Non-default YUV colorimetry and bar level, at the depths where the palette
# differs (8 and 10) and the widths where the per-lane paths differ. Covers
# the per-BPC palettes, limited-range black padding around the IMAGE window,
# and the limiter on the runtime-luma patterns, all lane by lane.
COLORIMETRY_CONFIGS = [
    # (ppc, bpc, colorimetry)
    (1, 8,  dict(yuv_range=YUV_LIMITED, yuv_matrix=YUV_BT709, bar_level=75)),
    (2, 10, dict(yuv_range=YUV_LIMITED, yuv_matrix=YUV_BT709, bar_level=75)),
    (4, 8,  dict(yuv_range=YUV_LIMITED, yuv_matrix=YUV_BT601, bar_level=100)),
    (4, 10, dict(yuv_range=YUV_FULL,    yuv_matrix=YUV_BT709, bar_level=75)),
]


# ---- BOX-IMAGE test: an 8x8 source scaled into the 12x8 moving box. ----
BIMG_W_T, BIMG_H_T = 8, 8
BIMG_X_STEP = (BIMG_W_T << 16) // 12   # box_width=12 (HARNESS_CFG)
BIMG_Y_STEP = (BIMG_H_T << 16) // 8    # box_height=8


def gen_box_image() -> list[int]:
    data = []
    for iy in range(BIMG_H_T):
        for ix in range(BIMG_W_T):
            data.append(((ix * 30) << 16) | ((iy * 30) << 8) | ((ix ^ iy) * 20 & 0xFF))
    return data


BIMG_DATA = gen_box_image()


# The box image again, converted for a YUV limited BT.709 build by the same
# code image_to_hex.py --yuv uses, and written with that script's `//`
# colorimetry header -- so the RTL's $readmemh is shown to skip it.
BIMG_YUV_DATA = [pixel_word((w >> 16) & 0xFF, (w >> 8) & 0xFF, w & 0xFF,
                            True, "709", True) for w in BIMG_DATA]
BIMG_YUV_HEADER = "// YCbCr BT.709 limited range, 8-bit codes {Y, Cb, Cr}\n"


def check_box_image(tmp: Path) -> list[str]:
    """Box-image overlay at PPC>1: build with EN_BOX_IMAGE + non-zero runtime
    steps so the box interior shows the scaled image, capture a couple of
    patterns, and compare to the model (which applies the same box overlay).
    Run in RGB, and in YUV limited BT.709 with a converted image. PPC=1 is
    skipped -- its registered read keeps the legacy 1-px shift."""
    fails: list[str] = []
    mem_rgb = tmp / "ppc_boximg.mem"
    mem_rgb.write_text("\n".join(f"{w:06x}" for w in BIMG_DATA) + "\n")
    mem_yuv = tmp / "ppc_boximg_yuv.mem"
    mem_yuv.write_text(BIMG_YUV_HEADER +
                       "\n".join(f"{w:06x}" for w in BIMG_YUV_DATA) + "\n")
    for ppc in (2, 4, 8):
        fails += _check_box_image_one(tmp, ppc, MODE_RGB, {}, mem_rgb,
                                      BIMG_DATA)
    for ppc in (2, 4):
        fails += _check_box_image_one(
            tmp, ppc, MODE_YUV,
            dict(yuv_range=YUV_LIMITED, yuv_matrix=YUV_BT709),
            mem_yuv, BIMG_YUV_DATA)
    # Runtime steps. X step 0 is the documented "solid box" sentinel; a
    # zero Y step is NOT -- the image stays on and repeats source row 0.
    # The model once treated a zero Y step as the sentinel too.
    for xs, ys in ((BIMG_X_STEP, 0), (0, BIMG_Y_STEP)):
        fails += _check_box_image_one(tmp, 4, MODE_RGB, {}, mem_rgb,
                                      BIMG_DATA, xs, ys)
    fails += _check_box_image_one(
        tmp, 4, MODE_YUV, dict(yuv_range=YUV_LIMITED, yuv_matrix=YUV_BT709),
        mem_yuv, BIMG_YUV_DATA, BIMG_X_STEP, 0)
    return fails


def _check_box_image_one(tmp: Path, ppc: int, mode: int, col: dict,
                         mem: Path, data: list[int],
                         x_step: int = BIMG_X_STEP,
                         y_step: int = BIMG_Y_STEP) -> list[str]:
    iverilog = need("iverilog")
    top = "tb_ppc_capture"
    fails: list[str] = []
    mname = {MODE_RGB: "rgb", MODE_YUV: "yuv"}[mode]
    if (x_step, y_step) != (BIMG_X_STEP, BIMG_Y_STEP):
        mname += f" xstep={x_step} ystep={y_step}"
    vvp_bin = tmp / f"boximg_{mode}_ppc{ppc}_{x_step}_{y_step}.vvp"
    cmd = [iverilog, "-g2001", "-Wall", "-I", str(RTL), "-s", top,
           "-o", str(vvp_bin),
           "-P", f"{top}.PIXELS_PER_CLOCK={ppc}",
           "-P", f"{top}.OUTPUT_MODE={mode}", "-P", f"{top}.BPC=8",
           "-P", f"{top}.YUV_RANGE={col.get('yuv_range', YUV_FULL)}",
           "-P", f"{top}.YUV_MATRIX={col.get('yuv_matrix', YUV_BT601)}",
           "-P", f"{top}.EN_BOX_IMAGE=1",
           "-P", f"{top}.BOX_IMAGE_W={BIMG_W_T}", "-P", f"{top}.BOX_IMAGE_H={BIMG_H_T}",
           "-P", f'{top}.BOX_IMAGE_HEX_FILE="{mem.as_posix()}"',
           "-P", f"{top}.BOX_IMG_X_STEP={x_step}",
           "-P", f"{top}.BOX_IMG_Y_STEP={y_step}",
           str(RTL / "vtpgz_core.v"), str(HERE / "tb_ppc_capture.v")]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        return [f"box-image {mname} ppc={ppc} build: {r.stdout}{r.stderr}"]
    for pname, pat in (("solid", PAT_SOLID), ("checker", PAT_CHECKER)):
        hexf = tmp / f"boximg_{mode}_{ppc}_{x_step}_{y_step}_{pname}.hex"
        run_capture(vvp_bin, pat, 32, 12, hexf)
        sim = load_beats(hexf)
        cfg = VtpgzConfig(width=32, height=12, pattern=pat,
                          output_mode=mode, bpc=8, pixels_per_clock=ppc,
                          box_image_w=BIMG_W_T, box_image_h=BIMG_H_T,
                          box_img_x_step=x_step, box_img_y_step=y_step,
                          box_image_rgb888=data, **col, **HARNESS_CFG)
        mod = render_frame_beats(cfg)
        if sim != mod:
            first = next((i for i, (a, b) in enumerate(zip(sim, mod)) if a != b),
                         min(len(sim), len(mod)))
            fails.append(f"box-image {mname} ppc={ppc} pat={pname}: "
                         f"first_diff@{first} "
                         f"sim=0x{sim[first]:X} mod=0x{mod[first]:X}")
        else:
            print(f"  OK  box-image {mname} ppc={ppc} pat={pname} "
                  f"({len(sim)} beats)")
    return fails


# ---- SMPTE RP 219 at a size where the host formulas give real widths:
# 232x48 -> d=28, c=25, p=8, h=4, so segment boundaries land mid-beat at
# every PPC and the bottom row's 5c/6 remainder is 23. Swept per PPC in the
# default RGB build and in the RP 219 target (YUV BT.709 limited 10-bit), and
# once in 4:2:2 at PPC 8.
SMPTE_W, SMPTE_H = 232, 48
SMPTE_CONFIGS = [
    # (ppc, mode, bpc, sub, colorimetry)
    (1, "rgb", 8, "444", {}),
    (2, "rgb", 8, "444", {}),
    (4, "rgb", 8, "444", {}),
    (8, "rgb", 8, "444", {}),
    (1, "yuv", 10, "444", dict(yuv_range=YUV_LIMITED, yuv_matrix=YUV_BT709)),
    (2, "yuv", 10, "444", dict(yuv_range=YUV_LIMITED, yuv_matrix=YUV_BT709)),
    (4, "yuv", 10, "444", dict(yuv_range=YUV_LIMITED, yuv_matrix=YUV_BT709)),
    (8, "yuv", 10, "444", dict(yuv_range=YUV_LIMITED, yuv_matrix=YUV_BT709)),
    (8, "yuv", 8, "422", dict(yuv_range=YUV_FULL, yuv_matrix=YUV_BT601)),
]


def check_smpte(tmp: Path) -> list[str]:
    fails: list[str] = []
    geo = smpte_host_geometry(SMPTE_W, SMPTE_H)
    for ppc, mode_name, bpc, sub_name, col in SMPTE_CONFIGS:
        mode, sub = MODE_MAP[mode_name], SUB_MAP[sub_name]
        ctag = "".join(f"_{k[0]}{v}" for k, v in col.items())
        vvp_bin = tmp / f"smpte_ppc{ppc}_{mode_name}{bpc}_{sub_name}{ctag}.vvp"
        build(ppc, mode, sub, RAW_RGGB, RGB_ORDER_XILINX, bpc, vvp_bin, col)
        hexf = vvp_bin.with_suffix(".hex")
        run_capture(vvp_bin, PAT_SMPTE, SMPTE_W, SMPTE_H, hexf, geo)
        sim = load_beats(hexf)
        cfg = VtpgzConfig(width=SMPTE_W, height=SMPTE_H, pattern=PAT_SMPTE,
                          output_mode=mode, yuv_subsample=sub, bpc=bpc,
                          pixels_per_clock=ppc,
                          **col, **{**HARNESS_CFG, **geo})
        mod = render_frame_beats(cfg)
        label = (f"smpte {SMPTE_W}x{SMPTE_H} ppc={ppc} {mode_name}{bpc} "
                 f"{sub_name} " + " ".join(f"{k}={v}" for k, v in col.items()))
        if sim != mod:
            first = next((i for i, (a, b) in enumerate(zip(sim, mod)) if a != b),
                         min(len(sim), len(mod)))
            fails.append(f"{label}: len sim={len(sim)} mod={len(mod)} "
                         f"first_diff@{first} "
                         f"sim=0x{(sim[first] if first < len(sim) else 0):X} "
                         f"mod=0x{(mod[first] if first < len(mod) else 0):X}")
        else:
            print(f"  OK  {label} ({len(sim)} beats)")
    return fails


# ---- Gradients at 8K and at the 16-bit maximum width, with the host's
# grad_step() values. A full 7680x4320 frame is 33M pixels, so the
# horizontal patterns run on a few 8K-wide lines and VGRAD on a narrow,
# 4320-line frame. Besides matching the model beat for beat, every line
# (column, for VGRAD) is checked against the ideal ramp directly, so a bug
# shared by RTL and model cannot pass: 0 at the start, exactly 0xFFF at the
# end, never decreasing, and within one code of x * 0xFFF / (n - 1).
GRAD_BIG_CONFIGS = [
    # (name, pattern, width, height, ppc)
    ("hgrad", PAT_HGRAD, 7680, 4, 1),
    ("hgrad", PAT_HGRAD, 7680, 4, 2),
    ("hgrad", PAT_HGRAD, 7680, 4, 4),
    ("hgrad", PAT_HGRAD, 7680, 4, 8),
    ("ramp",  PAT_RAMP,  7680, 4, 1),
    ("ramp",  PAT_RAMP,  7680, 4, 8),
    ("vgrad", PAT_VGRAD, 8, 4320, 1),
    ("vgrad", PAT_VGRAD, 8, 4320, 8),          # one beat per line
    ("hgrad", PAT_HGRAD, 65535, 2, 1),
]


def _ramp_errors(vals: list[int], what: str) -> list[str]:
    n = len(vals)
    errs = []
    if vals[0] != 0:
        errs.append(f"{what} starts at {vals[0]}, want 0")
    if vals[-1] != 0xFFF:
        errs.append(f"{what} ends at {vals[-1]}, want 0xFFF")
    drop = next((i for i in range(1, n) if vals[i] < vals[i - 1]), None)
    if drop is not None:
        errs.append(f"{what} decreases at {drop}")
    worst = max(range(n), key=lambda i: abs(vals[i] - i * 0xFFF / (n - 1)))
    if abs(vals[worst] - worst * 0xFFF / (n - 1)) >= 1:
        errs.append(f"{what}[{worst}] = {vals[worst]}, ideal "
                    f"{worst * 0xFFF / (n - 1):.2f}")
    return errs


def check_grad_big(tmp: Path) -> list[str]:
    fails: list[str] = []
    bpc = 12                      # 12-bit RGB: the codes come out unscaled
    built: dict[int, Path] = {}
    for name, pat, w, h, ppc in GRAD_BIG_CONFIGS:
        if ppc not in built:
            built[ppc] = tmp / f"grad_big_ppc{ppc}.vvp"
            # No box overlay: the lines must be the bare gradient.
            build(ppc, MODE_RGB, YUV_444, RAW_RGGB, RGB_ORDER_XILINX, bpc,
                  built[ppc], extra={"EN_BOX": 0})
        steps = dict(hg_step=grad_step(w), vg_step=grad_step(h))
        hexf = tmp / f"grad_big_{name}_{w}x{h}_ppc{ppc}.hex"
        run_capture(built[ppc], pat, w, h, hexf, steps)
        sim = load_beats(hexf)
        cfg = VtpgzConfig(width=w, height=h, pattern=pat,
                          output_mode=MODE_RGB, bpc=bpc, pixels_per_clock=ppc,
                          **{**HARNESS_CFG, **steps,
                             "box_width": 0, "box_height": 0})
        mod = render_frame_beats(cfg)
        label = f"{name} {w}x{h} ppc={ppc}"
        errs = []
        if sim != mod:
            first = next((i for i, (a, b) in enumerate(zip(sim, mod)) if a != b),
                         min(len(sim), len(mod)))
            errs.append(f"len sim={len(sim)} mod={len(mod)} "
                        f"first_diff@{first}")
        # Gray: every component equals the code, so take the low 12 bits of
        # each lane (lane 0 is the leftmost pixel; a lane is 40 bits, 36
        # rounded up to bytes).
        bits = cfg.tdata_width
        px = [(b >> (bits * ln)) & 0xFFF for b in sim for ln in range(ppc)]
        if len(px) != w * h:
            errs.append(f"captured {len(px)} pixels, want {w * h}")
        elif pat == PAT_VGRAD:
            errs += _ramp_errors(px[0::w], "column 0")
        else:
            for y in range(h):
                errs += _ramp_errors(px[y * w:(y + 1) * w], f"line {y}")
        if errs:
            fails += [f"{label}: {e}" for e in errs[:4]]
        else:
            print(f"  OK  {label} ({len(sim)} beats, full 0..0xFFF sweep)")
    return fails


# ---- Oversized gradient steps. A step far larger than the line needs must
# saturate the rest of the line (column, for VGRAD) to 0xFFF, as the 0.7
# integer steps did, rather than wrap the 32-bit accumulator back to black:
# 0x08000000 (2048 codes) wraps it at pixel 32, 0x0FFFFFFF (the largest
# 28-bit step) at pixel 16. The expected value is computed here, not by the
# model, so a wrap shared by RTL and model cannot pass.
GRAD_SAT_CONFIGS = [
    # (name, pattern, width, height, ppc, step)
    ("hgrad", PAT_HGRAD, 64, 2, 1, 0x08000000),
    ("hgrad", PAT_HGRAD, 64, 2, 8, 0x08000000),
    ("hgrad", PAT_HGRAD, 64, 2, 4, 0x0FFFFFFF),
    ("ramp",  PAT_RAMP,  64, 2, 1, 0x0FFFFFFF),
    ("ramp",  PAT_RAMP,  64, 2, 8, 0x08000000),
    ("vgrad", PAT_VGRAD, 8, 64, 1, 0x08000000),
    ("vgrad", PAT_VGRAD, 8, 64, 8, 0x0FFFFFFF),
]


def check_grad_saturation(tmp: Path) -> list[str]:
    fails: list[str] = []
    bpc = 12
    for name, pat, w, h, ppc, step in GRAD_SAT_CONFIGS:
        vvp = tmp / f"grad_big_ppc{ppc}.vvp"
        if not vvp.is_file():
            build(ppc, MODE_RGB, YUV_444, RAW_RGGB, RGB_ORDER_XILINX, bpc,
                  vvp, extra={"EN_BOX": 0})
        steps = dict(hg_step=step, vg_step=step)
        hexf = tmp / f"grad_sat_{name}_{step:x}_ppc{ppc}.hex"
        run_capture(vvp, pat, w, h, hexf, steps)
        sim = load_beats(hexf)
        cfg = VtpgzConfig(width=w, height=h, pattern=pat,
                          output_mode=MODE_RGB, bpc=bpc, pixels_per_clock=ppc,
                          **{**HARNESS_CFG, **steps,
                             "box_width": 0, "box_height": 0})
        mod = render_frame_beats(cfg)
        label = f"{name} step=0x{step:07X} {w}x{h} ppc={ppc}"
        errs = []
        if sim != mod:
            errs.append("RTL and model differ")
        bits = cfg.tdata_width
        px = [(b >> (bits * ln)) & 0xFFF for b in sim for ln in range(ppc)]

        def want(i: int) -> int:
            return 0xFFF if i * step >= 1 << 28 else (i * step) >> 16

        if len(px) != w * h:
            errs.append(f"captured {len(px)} pixels, want {w * h}")
        else:
            for i in range(w * h):
                c = i // w if pat == PAT_VGRAD else i % w
                if px[i] != want(c):
                    errs.append(f"pixel ({i % w},{i // w}) = 0x{px[i]:03X}, "
                                f"want 0x{want(c):03X}")
                    break
        if errs:
            fails += [f"{label}: {e}" for e in errs]
        else:
            print(f"  OK  {label} (saturates, no wrap)")
    return fails


def _model_cfg(pat: int, ppc: int, width: int, height: int,
               **over) -> VtpgzConfig:
    return VtpgzConfig(width=width, height=height, pattern=pat,
                       output_mode=MODE_RGB, bpc=8, pixels_per_clock=ppc,
                       image_w=IMG_W_T, image_h=IMG_H_T,
                       image_out_w=IMG_OUT_T, image_out_h=IMG_OUT_T,
                       image_rgb888=IMAGE_DATA, **{**HARNESS_CFG, **over})


def _first_diff(a: list[int], b: list[int]) -> int | None:
    if a == b:
        return None
    return next((i for i, (x, y) in enumerate(zip(a, b)) if x != y),
                min(len(a), len(b)))


# ---- One beat per line: width == PPC, so every beat is both the first and
# the last of its line, and the first beat of a frame is also its pix_sof.
# The per-line state (VGRAD, the checker's and grid's y counters) once reset
# on pix_sof and so skipped line 0's advance. The harness box (12x8) is
# wider than these frames, which also checks that the box is clamped to the
# frame.
def check_one_beat_lines(tmp: Path) -> list[str]:
    fails: list[str] = []
    for ppc in (1, 2, 4, 8):
        vvp_bin = tmp / f"onebeat_ppc{ppc}.vvp"
        build(ppc, MODE_RGB, YUV_444, RAW_RGGB, RGB_ORDER_XILINX, 8, vvp_bin)
        for pname, pat in PPC_PATTERNS:
            if pname == "image" and ppc == 1:
                continue                        # 1-px shift at PPC=1
            hexf = tmp / f"onebeat_{ppc}_{pname}.hex"
            run_capture(vvp_bin, pat, ppc, 12, hexf)
            sim = load_beats(hexf)
            mod = render_frame_beats(_model_cfg(pat, ppc, ppc, 12))
            d = _first_diff(sim, mod)
            label = f"one beat per line {ppc}x12 ppc={ppc} pat={pname}"
            if d is not None:
                fails.append(f"{label}: first_diff@{d}")
            else:
                print(f"  OK  {label} ({len(sim)} beats)")
    return fails


# ---- A later frame of a free-running stream. Every other check captures
# the first frame after enable, which frame_init starts from reset, so the
# state a frame leaves for the next one went unchecked: the per-line state
# once reset on pix_sof, after pixel (0, 0) had already shown the previous
# frame's last line. The third frame is compared with the model run for
# three frames, and -- independently of the model, which had the same bug
# -- every pattern but NOISE (whose LFSR runs on across frames) must repeat
# the first frame exactly when the box is off.
SEAM_SKIP = 2


def check_frame_seams(tmp: Path) -> list[str]:
    fails: list[str] = []
    for ppc in (1, 4):
        for box in (1, 0):
            vvp_bin = tmp / f"seam_ppc{ppc}_box{box}.vvp"
            build(ppc, MODE_RGB, YUV_444, RAW_RGGB, RGB_ORDER_XILINX, 8,
                  vvp_bin, extra={"EN_BOX": box})
            over = {} if box else {"box_width": 0, "box_height": 0}
            for pname, pat in PPC_PATTERNS:
                if pname == "image" and ppc == 1:
                    continue
                hexf = tmp / f"seam_{ppc}_{box}_{pname}.hex"
                run_capture(vvp_bin, pat, 32, 12, hexf, {"skip": SEAM_SKIP})
                sim = load_beats(hexf)
                cfg = _model_cfg(pat, ppc, 32, 12, **over)
                regs = VtpgzRegs()
                frames = [render_frame_beats(cfg, regs)
                          for _ in range(SEAM_SKIP + 1)]
                label = (f"frame {SEAM_SKIP + 1} ppc={ppc} "
                         f"box={'on' if box else 'off'} pat={pname}")
                d = _first_diff(sim, frames[-1])
                if d is not None:
                    fails.append(f"{label}: vs model, first_diff@{d}")
                    continue
                if not box and pat != PAT_NOISE:
                    d = _first_diff(sim, frames[0])
                    if d is not None:
                        fails.append(f"{label}: differs from frame 1 at "
                                     f"beat {d}")
                        continue
                print(f"  OK  {label} ({len(sim)} beats)")
    return fails


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--ppc", type=int, default=None, choices=[1, 2, 4, 8])
    ap.add_argument("--mode", default=None, choices=list(MODE_MAP))
    ap.add_argument("--bpc", type=int, default=None, choices=[8, 10, 12, 14, 16])
    ap.add_argument("--yuv-sub", default="444", choices=list(SUB_MAP))
    ap.add_argument("--raw-bayer", default="rggb", choices=list(BAYER_MAP))
    ap.add_argument("--rgb-order", default="xilinx", choices=list(ORDER_MAP))
    ap.add_argument("--width", type=int, default=32)
    ap.add_argument("--height", type=int, default=12)
    args = ap.parse_args()

    ppcs = [args.ppc] if args.ppc else [1, 2, 4, 8]
    modes = [args.mode] if args.mode else ["rgb", "raw", "yuv"]
    bpcs = [args.bpc] if args.bpc else [8, 12, 16]

    all_fails: list[str] = []
    n = 0
    global IMAGE_HEX_PATH
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        # Write the test image .mem for $readmemh (forward slashes for iverilog).
        mem = tmp / "ppc_test_img.mem"
        mem.write_text("\n".join(f"{w:06x}" for w in IMAGE_DATA) + "\n")
        IMAGE_HEX_PATH = mem.as_posix()
        for ppc in ppcs:
            # width must be a multiple of ppc; pick one that is for the sweep.
            width = args.width
            if width % ppc != 0:
                width = (width // ppc) * ppc or ppc
            for mode in modes:
                for bpc in bpcs:
                    n += 1
                    try:
                        all_fails += check_one(ppc, mode, bpc, args.yuv_sub,
                                               args.raw_bayer, args.rgb_order,
                                               width, args.height, tmp)
                    except RuntimeError as e:
                        all_fails.append(f"ppc={ppc} mode={mode} bpc={bpc}: {e}")

        # Colorimetry / bar level, and the box-image overlay (only on a full
        # sweep).
        if not (args.ppc or args.mode or args.bpc):
            for ppc, bpc, col in COLORIMETRY_CONFIGS:
                n += 1
                width = (args.width // ppc) * ppc
                try:
                    all_fails += check_one(ppc, "yuv", bpc, args.yuv_sub,
                                           args.raw_bayer, args.rgb_order,
                                           width, args.height, tmp, col)
                except RuntimeError as e:
                    all_fails.append(f"ppc={ppc} yuv bpc={bpc} {col}: {e}")
        if not args.ppc:
            try:
                all_fails += check_box_image(tmp)
            except RuntimeError as e:
                all_fails.append(f"box-image: {e}")
        if not (args.ppc or args.mode or args.bpc):
            try:
                n += len(SMPTE_CONFIGS)
                all_fails += check_smpte(tmp)
            except RuntimeError as e:
                all_fails.append(f"smpte: {e}")
            try:
                n += len(GRAD_BIG_CONFIGS)
                all_fails += check_grad_big(tmp)
            except RuntimeError as e:
                all_fails.append(f"gradients at 8K: {e}")
            try:
                n += len(GRAD_SAT_CONFIGS)
                all_fails += check_grad_saturation(tmp)
            except RuntimeError as e:
                all_fails.append(f"gradient saturation: {e}")
            try:
                n += 4
                all_fails += check_one_beat_lines(tmp)
            except RuntimeError as e:
                all_fails.append(f"one beat per line: {e}")
            try:
                n += 4
                all_fails += check_frame_seams(tmp)
            except RuntimeError as e:
                all_fails.append(f"frame seams: {e}")

    print()
    if all_fails:
        print(f"FAIL: {len(all_fails)} mismatch(es) across {n} configs")
        for f in all_fails[:20]:
            print("  " + f)
        return 1
    print(f"PASS: RTL <-> model beat-exact across {n} configs")
    return 0


if __name__ == "__main__":
    sys.exit(main())
