#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Leonardo Capossio - bard0 design - hello@bard0.com
# SPDX-License-Identifier: Apache-2.0
"""
Check sequential capture binaries dumped by sim_capture_seq.cpp against
the bit-exact Python model. Mode/bpc are CLI args because they are
build-time parameters of the simulation binary.

Usage:
    python check_seq.py [logs/seq_cap]
                        [--mode rgb|raw|yuv]
                        [--bpc 8|10|12]
                        [--yuv-sub 444|422]
                        [--raw-bayer plain|rggb]
                        [--rgb-order xilinx|legacy]
"""
from __future__ import annotations

import argparse
import struct
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from vtpgz_model import (
    VtpgzConfig, render_frame, tdata_to_bram_words,
    MODE_RGB, MODE_RAW, MODE_YUV,
    YUV_444, YUV_422,
    RAW_PLAIN, RAW_RGGB, RAW_BGGR, RAW_GRBG, RAW_GBRG,
    RGB_ORDER_XILINX, RGB_ORDER_LEGACY,
)

WIDTH, HEIGHT = 64, 32

MODE_MAP  = {"rgb": MODE_RGB, "raw": MODE_RAW, "yuv": MODE_YUV}
SUB_MAP   = {"444": YUV_444, "422": YUV_422}
BAYER_MAP = {"plain": RAW_PLAIN, "rggb": RAW_RGGB, "bggr": RAW_BGGR,
             "grbg": RAW_GRBG, "gbrg": RAW_GBRG}
ORDER_MAP = {"xilinx": RGB_ORDER_XILINX, "legacy": RGB_ORDER_LEGACY}


def cfg_for(pat: int, mode: int, bpc: int, sub: int,
            bayer: int, order: int) -> VtpgzConfig:
    return VtpgzConfig(
        width=WIDTH, height=HEIGHT,
        pattern=pat,
        output_mode=mode, yuv_subsample=sub, raw_bayer=bayer,
        rgb_order=order, bpc=bpc,
        bar_width=WIDTH // 8,
        hg_step=0xFFF // (WIDTH - 1),
        vg_step=0xFFF // (HEIGHT - 1),
        checker_size=16,
        grid_spacing=16,
        box_width=16, box_height=16,
        box_dx=1, box_dy=1,
        box_border_color=0x00FFFFFF, box_border_width=1,
    )


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("prefix", nargs="?", default="logs/seq_cap")
    ap.add_argument("--mode", choices=list(MODE_MAP.keys()), default="rgb")
    ap.add_argument("--bpc", type=int, choices=[8, 10, 12], default=8)
    ap.add_argument("--yuv-sub", choices=list(SUB_MAP.keys()), default="444")
    ap.add_argument("--raw-bayer", choices=list(BAYER_MAP.keys()), default="rggb")
    ap.add_argument("--rgb-order", choices=list(ORDER_MAP.keys()), default="xilinx")
    args = ap.parse_args()

    sim_dir = (HERE.parents[2] / "sim").resolve()
    base = (sim_dir / args.prefix).resolve()
    mode  = MODE_MAP[args.mode]
    sub   = SUB_MAP[args.yuv_sub]
    bayer = BAYER_MAP[args.raw_bayer]
    order = ORDER_MAP[args.rgb_order]

    fails = 0
    n = 0
    for pat in range(9):
        path = base.parent / f"{base.name}_{pat}.bin"
        if not path.exists():
            continue
        n += 1
        data = path.read_bytes()
        words = list(struct.unpack(f"<{len(data) // 4}I", data))
        cfg = cfg_for(pat, mode, args.bpc, sub, bayer, order)
        sw = tdata_to_bram_words(render_frame(cfg), cfg.tdata_width)
        if words == sw:
            print(f"  CAP {pat} pat={pat}  OK ({len(words)} words)")
        else:
            fails += 1
            first_diff = next(
                (i for i, (a, b) in enumerate(zip(words, sw)) if a != b),
                min(len(words), len(sw)),
            )
            print(f"  CAP {pat} pat={pat}  FAIL @{first_diff} "
                  f"hw=0x{words[first_diff]:08X} sw=0x{sw[first_diff]:08X}")
            print(f"    hw[0..7] = {[f'0x{w:08X}' for w in words[:8]]}")
            print(f"    sw[0..7] = {[f'0x{w:08X}' for w in sw[:8]]}")

    print(f"\nChecked {n} captures, {fails} failures")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
