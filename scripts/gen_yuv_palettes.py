#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Leonardo Capossio - bard0 design - hello@bard0.com
# SPDX-License-Identifier: Apache-2.0
"""Generate the four YUV colour-bar palettes from colorimetry.

{BT.601, BT.709} x {full, limited}, 100% bars, as 12-bit {Y, Cb, Cr}.

This is the single source of truth. The RTL constants in bar_palette() and
the model's tables are both produced from here, so neither is a transcription
of the other -- a model that copies the RTL cannot catch a wrong constant.

Full range   : Y = round(Y*4095),  C = clip(round(C*4095) + 2048)
Limited range: the standard 10-bit levels x 4, so the pack stage's truncation
               lands on the exact standard code at every BPC:
                   3760>>2 = 940, 3760>>4 = 235, 256>>4 = 16
               Y' = round(64 + 876*Y), C' = round(512 + 896*C), then *4.

Run with --verilog to emit the RTL case arms, --python for the model tables.
"""
from __future__ import annotations

import argparse

# 100% bars, in the conventional white->black order the RTL uses.
BARS = [
    ("white",   (1, 1, 1)),
    ("yellow",  (1, 1, 0)),
    ("cyan",    (0, 1, 1)),
    ("green",   (0, 1, 0)),
    ("magenta", (1, 0, 1)),
    ("red",     (1, 0, 0)),
    ("blue",    (0, 0, 1)),
    ("black",   (0, 0, 0)),
]

MATRICES = {"601": (0.299, 0.114), "709": (0.2126, 0.0722)}

# The BT.601 full-range palette that vtpgZero has always shipped. It is NOT
# regenerated from the formula below, and must not be: the original constants
# used a different rounding convention, and green/magenta chroma sit one LSB
# away from what the formula gives. That one LSB survives the pack stage at
# BPC>=10 (green Cb 173 vs 172 at 10 bits), so regenerating it would change
# the output of every existing 10- and 12-bit build. This palette is the
# default, and the default is required to stay bit-exact, so it is frozen
# here as data and checked -- not computed.
LEGACY_601_FULL = [
    (0xFFF, 0x800, 0x800),  # white
    (0xE2C, 0x000, 0x94D),  # yellow
    (0xB37, 0xAB3, 0x000),  # cyan
    (0x964, 0x2B4, 0x14E),  # green    (formula gives 2B3 / 14D)
    (0x69B, 0xD4C, 0xEB2),  # magenta  (formula gives D4D / EB3)
    (0x4C8, 0x54D, 0xFFF),  # red
    (0x1D3, 0xFFF, 0x6B3),  # blue
    (0x000, 0x800, 0x800),  # black
]
LEGACY_TOLERANCE = 1  # LSB, in the 12-bit internal domain


def clip12(v: int) -> int:
    return 0 if v < 0 else (4095 if v > 4095 else v)


def ycbcr(rgb, kr, kb, limited):
    """One bar as 12-bit {Y, Cb, Cr}."""
    r, g, b = rgb
    kg = 1.0 - kr - kb
    y = kr * r + kg * g + kb * b
    cb = (b - y) / (2.0 * (1.0 - kb))
    cr = (r - y) / (2.0 * (1.0 - kr))
    if limited:
        # Standard 10-bit levels, scaled to the core's 12-bit internal domain.
        return (round(64 + 876 * y) * 4,
                round(512 + 896 * cb) * 4,
                round(512 + 896 * cr) * 4)
    return (clip12(round(y * 4095)),
            clip12(round(cb * 4095) + 2048),
            clip12(round(cr * 4095) + 2048))


def palette(matrix: str, limited: bool):
    """The palette for one {matrix, range} combination.

    Every combination is computed except BT.601 full, which is the shipped
    default and returns the frozen legacy constants instead. The computed
    value is still checked against them, so if the two ever drift further
    than a rounding LSB apart this fails loudly rather than silently
    shipping a palette nobody derived.
    """
    kr, kb = MATRICES[matrix]
    computed = [ycbcr(rgb, kr, kb, limited) for _, rgb in BARS]
    if matrix == "601" and not limited:
        for (name, _), legacy, calc in zip(BARS, LEGACY_601_FULL, computed):
            for got, want in zip(legacy, calc):
                if abs(got - want) > LEGACY_TOLERANCE:
                    raise SystemExit(
                        f"legacy BT.601 full palette bar '{name}' is "
                        f"{got:#05x} but colorimetry gives {want:#05x}; "
                        f"that is more than a rounding difference")
        computed = LEGACY_601_FULL
    return [(name, t) for (name, _), t in zip(BARS, computed)]


def emit_verilog() -> None:
    for matrix in ("601", "709"):
        for limited in (False, True):
            tag = f"{matrix} {'limited' if limited else 'full'}"
            print(f"                // ---- BT.{tag} ----")
            for i, (name, (y, cb, cr)) in enumerate(palette(matrix, limited)):
                arm = "default" if i == 7 else f"3'd{i}"
                print(f"                    {arm}: bar_palette = "
                      f"{{12'h{y:03X}, 12'h{cb:03X}, 12'h{cr:03X}}}; // {name}")
            print()


def emit_python() -> None:
    for matrix in ("601", "709"):
        for limited in (False, True):
            key = f"PALETTE_YUV_{matrix}_{'LIM' if limited else 'FULL'}"
            print(f"{key} = [")
            for name, (y, cb, cr) in palette(matrix, limited):
                print(f"    (0x{y:03X}, 0x{cb:03X}, 0x{cr:03X}),  # {name}")
            print("]")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--verilog", action="store_true")
    ap.add_argument("--python", action="store_true")
    args = ap.parse_args()
    if args.verilog:
        emit_verilog()
    elif args.python:
        emit_python()
    else:
        for matrix in ("601", "709"):
            for limited in (False, True):
                print(f"=== BT.{matrix} {'limited' if limited else 'full'} ===")
                for name, t in palette(matrix, limited):
                    ten = tuple(v >> 2 for v in t)
                    print(f"  {name:8} 12b={tuple(f'{v:03X}' for v in t)} 10b={ten}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
