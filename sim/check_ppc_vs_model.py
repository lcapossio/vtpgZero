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

from vtpgz_model import (  # noqa: E402
    VtpgzConfig, render_frame_beats,
    MODE_RGB, MODE_RAW, MODE_YUV, YUV_444, YUV_422,
    RAW_PLAIN, RAW_RGGB, RAW_BGGR, RAW_GRBG, RAW_GBRG,
    RGB_ORDER_XILINX, RGB_ORDER_LEGACY,
    PAT_SOLID, PAT_GRID, PAT_CHECKER,
    PAT_COLORBAR, PAT_HGRAD, PAT_VGRAD, PAT_RAMP,
)

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
    ("vgrad", PAT_VGRAD), ("ramp", PAT_RAMP),
]

# Must mirror the constant cfg_* the harness drives (tb_ppc_capture.v).
HARNESS_CFG = dict(
    solid_color=0x3CA510,
    box_color=0x00FF00,
    box_width=12, box_height=8, box_dx=1, box_dy=1,
    box_border_color=0xFF0000, box_border_width=2,
    grid_spacing=7, grid_color=0xFFFFFF,
    checker_size=5,
    hg_step=64, vg_step=128, bar_width=8,
)


def need(tool: str) -> str:
    p = shutil.which(tool)
    if not p:
        print(f"ERROR: '{tool}' not found in PATH", file=sys.stderr)
        sys.exit(2)
    return p


def build(ppc: int, mode: int, sub: int, bayer: int, order: int, bpc: int,
          out_vvp: Path) -> None:
    iverilog = need("iverilog")
    top = "tb_ppc_capture"
    params = {
        "PIXELS_PER_CLOCK": ppc, "OUTPUT_MODE": mode, "YUV_SUBSAMPLE": sub,
        "RAW_BAYER": bayer, "RGB_ORDER": order, "BPC": bpc,
        # M2 patterns are legal at PPC>1 now; enable them for the sweep.
        "EN_COLORBAR": 1, "EN_HGRAD": 1, "EN_VGRAD": 1, "EN_RAMP": 1,
    }
    cmd = [iverilog, "-g2001", "-Wall", "-I", str(RTL), "-s", top,
           "-o", str(out_vvp)]
    for k, v in params.items():
        cmd += ["-P", f"{top}.{k}={v}"]
    cmd += [str(RTL / "vtpgz_core.v"), str(HERE / "tb_ppc_capture.v")]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError("iverilog build failed:\n" + r.stdout + r.stderr)


def run_capture(vvp_bin: Path, pat: int, width: int, height: int,
                out_hex: Path) -> None:
    vvp = need("vvp")
    cmd = [vvp, str(vvp_bin), f"+pat={pat}", f"+width={width}",
           f"+height={height}", f"+out={out_hex}"]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0 or "OK:" not in r.stdout:
        raise RuntimeError(f"vvp capture failed (pat={pat}):\n{r.stdout}{r.stderr}")


def load_beats(path: Path) -> list[int]:
    return [int(line, 16) for line in path.read_text().split() if line.strip()]


def model_beats(pat: int, ppc: int, mode: int, sub: int, bayer: int,
                order: int, bpc: int, width: int, height: int) -> list[int]:
    cfg = VtpgzConfig(width=width, height=height, pattern=pat,
                      output_mode=mode, yuv_subsample=sub, raw_bayer=bayer,
                      rgb_order=order, bpc=bpc, pixels_per_clock=ppc,
                      **HARNESS_CFG)
    return render_frame_beats(cfg)


def check_one(ppc: int, mode_name: str, bpc: int, sub_name: str,
              bayer_name: str, order_name: str, width: int, height: int,
              tmp: Path) -> list[str]:
    mode = MODE_MAP[mode_name]
    sub = SUB_MAP[sub_name]
    bayer = BAYER_MAP[bayer_name]
    order = ORDER_MAP[order_name]
    vvp_bin = tmp / f"ppc{ppc}_{mode_name}_{bpc}.vvp"
    build(ppc, mode, sub, bayer, order, bpc, vvp_bin)
    fails: list[str] = []
    for pname, pat in PPC_PATTERNS:
        hexf = tmp / f"cap_{ppc}_{mode_name}_{bpc}_{pname}.hex"
        run_capture(vvp_bin, pat, width, height, hexf)
        sim = load_beats(hexf)
        mod = model_beats(pat, ppc, mode, sub, bayer, order, bpc, width, height)
        if sim != mod:
            first = next((i for i, (a, b) in enumerate(zip(sim, mod)) if a != b),
                         min(len(sim), len(mod)))
            fails.append(
                f"ppc={ppc} mode={mode_name} bpc={bpc} pat={pname}: "
                f"len sim={len(sim)} mod={len(mod)} first_diff@{first} "
                f"sim=0x{(sim[first] if first < len(sim) else 0):X} "
                f"mod=0x{(mod[first] if first < len(mod) else 0):X}")
        else:
            print(f"  OK  ppc={ppc} mode={mode_name} bpc={bpc} pat={pname} "
                  f"({len(sim)} beats)")
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
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
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
