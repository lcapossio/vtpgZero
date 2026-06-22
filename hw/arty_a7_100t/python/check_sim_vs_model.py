#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Leonardo Capossio - bard0 design - hello@bard0.com
# SPDX-License-Identifier: Apache-2.0
"""
Sim ↔ Python-model byte-exact gate.

The Verilator binary is built once per (output_mode, bpc) configuration —
the mode/bpc are RTL build-time parameters, not runtime registers. This
script takes the binary plus its mode/bpc/sub flags and sweeps the 9
patterns at runtime, comparing each captured frame to the Python model.

Usage:
    python check_sim_vs_model.py --sim-binary path/to/Vvtpgz_top \\
                                 --mode {rgb|raw|yuv} --bpc {8|10|12} \\
                                 [--yuv-sub {444|422}] \\
                                 [--raw-bayer {plain|rggb}] \\
                                 [--rgb-order {xilinx|legacy}]
"""
from __future__ import annotations

import argparse
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

# Make vtpgz_model importable when run from anywhere
sys.path.insert(0, str(Path(__file__).resolve().parent))
from vtpgz_model import (
    VtpgzConfig, render_frame, tdata_to_bram_words,
    MODE_RGB, MODE_RAW, MODE_YUV,
    YUV_444, YUV_422,
    RAW_PLAIN, RAW_RGGB, RAW_BGGR, RAW_GRBG, RAW_GBRG,
    RGB_ORDER_XILINX, RGB_ORDER_LEGACY,
)

WIDTH, HEIGHT = 64, 32

MODE_MAP = {"rgb": MODE_RGB, "raw": MODE_RAW, "yuv": MODE_YUV}
SUB_MAP  = {"444": YUV_444, "422": YUV_422}
BAYER_MAP = {"plain": RAW_PLAIN, "rggb": RAW_RGGB, "bggr": RAW_BGGR,
             "grbg": RAW_GRBG, "gbrg": RAW_GBRG}
ORDER_MAP = {"xilinx": RGB_ORDER_XILINX, "legacy": RGB_ORDER_LEGACY}


def run_capture(sim_binary: Path, pat: int, out_file: Path) -> None:
    cmd = [
        str(sim_binary),
        f"+pat={pat}",
        f"+width={WIDTH}",
        f"+height={HEIGHT}",
        f"+out={out_file}",
    ]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(
            f"sim_capture failed (pat={pat}):\n{r.stdout}\n{r.stderr}"
        )


def load_words(path: Path) -> list[int]:
    data = path.read_bytes()
    n = len(data) // 4
    return list(struct.unpack(f"<{n}I", data))


def model_words(pat: int, mode: int, bpc: int, sub: int,
                bayer: int, order: int) -> list[int]:
    cfg = VtpgzConfig(
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
    return tdata_to_bram_words(render_frame(cfg), cfg.tdata_width)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--sim-binary", required=True, type=Path)
    ap.add_argument("--mode", choices=list(MODE_MAP.keys()), default="rgb")
    ap.add_argument("--bpc", type=int, choices=[8, 10, 12, 14, 16], default=8)
    ap.add_argument("--yuv-sub", choices=list(SUB_MAP.keys()), default="444")
    ap.add_argument("--raw-bayer", choices=list(BAYER_MAP.keys()), default="rggb")
    ap.add_argument("--rgb-order", choices=list(ORDER_MAP.keys()), default="xilinx")
    args = ap.parse_args()

    if not args.sim_binary.exists():
        alt = args.sim_binary.with_suffix(".exe")
        if alt.exists():
            args.sim_binary = alt
        else:
            print(f"ERROR: {args.sim_binary} not found", file=sys.stderr)
            return 2

    mode  = MODE_MAP[args.mode]
    sub   = SUB_MAP[args.yuv_sub]
    bayer = BAYER_MAP[args.raw_bayer]
    order = ORDER_MAP[args.rgb_order]

    print(f"Configuration: mode={args.mode} bpc={args.bpc} "
          f"sub={args.yuv_sub} bayer={args.raw_bayer} order={args.rgb_order}")

    fails = []
    n = 0
    with tempfile.TemporaryDirectory() as td:
        td_path = Path(td)
        for pat in range(9):
            n += 1
            out_file = td_path / f"f_{pat}.bin"
            try:
                run_capture(args.sim_binary, pat, out_file)
            except RuntimeError as e:
                fails.append((pat, str(e)))
                continue
            sim = load_words(out_file)
            mod = model_words(pat, mode, args.bpc, sub, bayer, order)
            if sim != mod:
                first_diff = next(
                    (i for i, (a, b) in enumerate(zip(sim, mod)) if a != b),
                    min(len(sim), len(mod)),
                )
                fails.append((
                    pat,
                    f"len sim={len(sim)} mod={len(mod)} "
                    f"first_diff@{first_diff} "
                    f"sim=0x{sim[first_diff]:08X} mod=0x{mod[first_diff]:08X}"
                ))
                continue
            print(f"  pat={pat}  OK ({len(sim)} words)")

    print()
    print(f"Checked {n} patterns")
    if fails:
        print(f"FAIL: {len(fails)} mismatches")
        for f in fails[:10]:
            print(f"  pat={f[0]}: {f[1]}")
        return 1
    print(f"PASS: sim ↔ model byte-exact for all {n} patterns")
    return 0


if __name__ == "__main__":
    sys.exit(main())
