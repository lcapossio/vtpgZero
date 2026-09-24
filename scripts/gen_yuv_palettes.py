#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Leonardo Capossio - bard0 design - hello@bard0.com
# SPDX-License-Identifier: Apache-2.0
"""Generate the colour-bar palettes from colorimetry.

One palette per build: output colour space (RGB/RAW or YUV), YUV matrix
(BT.601 / BT.709), YUV range (full / limited), bar level (100% / 75%) and
palette bit depth (8, 10 or 12 -- the build's BPC, capped at 12).

This is the single source of truth. The RTL constants in vtpgz_core.v and the
model's tables are both produced from here, so neither is a transcription of
the other -- a model that copies the RTL cannot catch a wrong constant.

Each palette is the exact n-bit code, left-aligned in the core's 12-bit
internal domain (code << (12 - n)), so the pack stage's truncation lands on
it. An 8-bit limited code is NOT the 10-bit one truncated, which is why every
bit depth gets its own palette:

  Limited (BT.601/709 digital coding, n bits):
      Y = Round((219*E + 16) * 2^(n-8)),  C = Round((224*E + 128) * 2^(n-8))
  Full (H.273 / BT.2100 full-range coding, n bits):
      Y = Round((2^n - 1) * E),           C = Round((2^n - 1) * E + 2^(n-1))
  RGB:
      V = Round((2^n - 1) * level)

Round() is the standards' round-half-away-from-zero, not Python's
round-half-to-even, and the arithmetic is exact (fractions, not floats). Both
matter: full-range chroma of -0.5 (yellow Cb, cyan Cr) is exactly on a tie,
Round(0.5) = 1, and in floats BT.601's -0.5 comes out as -0.4999... and
rounds the other way.

Two palettes are frozen rather than computed, because they are what vtpgZero
has always shipped and the default build must stay bit-exact: RGB 100% (all
ones at every depth) and BT.601 full 100% (see LEGACY_601_FULL).

    python scripts/gen_yuv_palettes.py              # print every palette
    python scripts/gen_yuv_palettes.py --write-rtl  # regenerate vtpgz_core.v
    python scripts/gen_yuv_palettes.py --check      # CI: RTL is up to date
"""
from __future__ import annotations

import argparse
import math
import sys
from fractions import Fraction
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CORE = ROOT / "rtl" / "vtpgz_core.v"
BEGIN = "// BEGIN GENERATED PALETTES (scripts/gen_yuv_palettes.py --write-rtl)"
END = "// END GENERATED PALETTES"

# The eight bars, in the conventional white->black order the RTL uses.
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

MATRICES = {"601": (Fraction(299, 1000), Fraction(114, 1000)),
            "709": (Fraction(2126, 10000), Fraction(722, 10000))}
LEVELS = (100, 75)
PAL_BITS = (8, 10, 12)

# The BT.601 full-range 100% palette that vtpgZero has always shipped, used
# at every bit depth. It is NOT regenerated from the formula, and must not
# be: the original constants used a different rounding convention, and
# green/magenta chroma sit one LSB away from what the 12-bit formula gives.
# That LSB survives the pack stage at BPC>=10 (green Cb 173 vs 172 at 10
# bits), so regenerating it would change the output of every existing 10- and
# 12-bit build. This palette is the default, and the default is required to
# stay bit-exact, so it is frozen here as data and checked -- not computed.
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
LEGACY_TOLERANCE = 1  # LSB, against the 12-bit formula

# RGB 100%: all ones at 12 bits, which truncates to all ones at every BPC.
LEGACY_RGB_100 = [tuple(0xFFF * c for c in rgb) for _, rgb in BARS]


def pal_bits(bpc: int) -> int:
    """The palette bit depth for a build: its BPC, capped at 12.

    BPC 14/16 zero-extend the 12-bit code in the pack stage, so they use the
    12-bit palette.
    """
    return 8 if bpc <= 8 else (10 if bpc <= 10 else 12)


def _clip(v: int, bits: int) -> int:
    return max(0, min((1 << bits) - 1, v))


def _round(x: Fraction) -> int:
    """H.273 Round(): half away from zero. Every argument here is >= 0."""
    return math.floor(x + Fraction(1, 2))


def ycbcr_code(rgb, kr: Fraction, kb: Fraction, limited: bool, bits: int):
    """Non-linear R'G'B' in [0, 1] -> n-bit {Y, Cb, Cr} codes.

    Pass the components as ints or Fractions to keep the result exact.
    """
    r, g, b = (Fraction(c) for c in rgb)
    kg = 1 - kr - kb
    y = kr * r + kg * g + kb * b
    cb = (b - y) / (2 * (1 - kb))
    cr = (r - y) / (2 * (1 - kr))
    if limited:
        s = Fraction(2) ** (bits - 8)
        return (_clip(_round((219 * y + 16) * s), bits),
                _clip(_round((224 * cb + 128) * s), bits),
                _clip(_round((224 * cr + 128) * s), bits))
    fs = (1 << bits) - 1
    mid = 1 << (bits - 1)
    return (_clip(_round(fs * y), bits),
            _clip(_round(fs * cb + mid), bits),
            _clip(_round(fs * cr + mid), bits))


def _left_align(t, bits: int):
    return tuple(v << (12 - bits) for v in t)


def palette(yuv: bool, matrix: str = "601", limited: bool = False,
            level: int = 100, bits: int = 12):
    """One build's palette: [(name, 12-bit {c0, c1, c2})] for bars 0..7.

    RGB/RAW builds return {R, G, B}; YUV builds {Y, Cb, Cr}. `matrix` and
    `limited` are ignored for RGB.
    """
    if level not in LEVELS:
        raise ValueError(f"bar level must be one of {LEVELS}, not {level}")
    if bits not in PAL_BITS:
        raise ValueError(f"palette bits must be one of {PAL_BITS}, not {bits}")
    e = Fraction(level, 100)
    if not yuv:
        if level == 100:
            out = LEGACY_RGB_100
        else:
            fs = (1 << bits) - 1
            out = [_left_align(tuple(_round(fs * e * c) for c in rgb), bits)
                   for _, rgb in BARS]
        return [(name, t) for (name, _), t in zip(BARS, out)]

    kr, kb = MATRICES[matrix]
    if matrix == "601" and not limited and level == 100:
        calc = [ycbcr_code(rgb, kr, kb, False, 12) for _, rgb in BARS]
        for (name, _), legacy, want in zip(BARS, LEGACY_601_FULL, calc):
            for got, w in zip(legacy, want):
                if abs(got - w) > LEGACY_TOLERANCE:
                    raise SystemExit(
                        f"legacy BT.601 full palette bar '{name}' is "
                        f"{got:#05x} but colorimetry gives {w:#05x}; "
                        f"that is more than a rounding difference")
        out = LEGACY_601_FULL
    else:
        out = [_left_align(ycbcr_code(tuple(e * c for c in rgb), kr, kb,
                                      limited, bits), bits)
               for _, rgb in BARS]
    return [(name, t) for (name, _), t in zip(BARS, out)]


# ---------------------------------------------------------------- RTL ----
def _all_builds():
    """(localparam name, condition, palette, bits) for every palette."""
    out = []
    for level in LEVELS:
        if level == 100:
            out.append(("PAL_RGB_100", "!PAL_YUV && PAL_LEVEL == 100",
                        palette(False, level=100), 12))
        else:
            for bits in PAL_BITS:
                out.append((f"PAL_RGB_{level}_{bits}",
                            f"!PAL_YUV && PAL_LEVEL == {level} && PAL_BITS == {bits}",
                            palette(False, level=level, bits=bits), bits))
    for matrix in ("601", "709"):
        for limited in (False, True):
            rng = "LIM" if limited else "FULL"
            cond = (f"PAL_YUV && {'' if matrix == '709' else '!'}PAL_709 && "
                    f"{'' if limited else '!'}PAL_LIM")
            for level in LEVELS:
                if matrix == "601" and not limited and level == 100:
                    out.append(("PAL_601_FULL_100",
                                f"{cond} && PAL_LEVEL == 100",
                                palette(True, "601", False, 100), 12))
                    continue
                for bits in PAL_BITS:
                    out.append((f"PAL_{matrix}_{rng}_{level}_{bits}",
                                f"{cond} && PAL_LEVEL == {level} && PAL_BITS == {bits}",
                                palette(True, matrix, limited, level, bits),
                                bits))
    return out


def rtl_block(indent: str = "    ") -> str:
    """The generated region of vtpgz_core.v, markers included."""
    lines = [BEGIN,
             "// Each palette is 8 bars x {c0, c1, c2} x 12 bits, bar 7 (black)",
             "// in the MSBs down to bar 0 (white) in the LSBs. Do not edit by",
             "// hand; change the generator and re-run it."]
    builds = _all_builds()
    for name, _, pal, _ in builds:
        hexes = "_".join(f"{a:03X}{b:03X}{c:03X}" for _, (a, b, c) in reversed(pal))
        lines.append(f"localparam [287:0] {name:<18} = 288'h{hexes};")
    lines.append("localparam [287:0] PAL_TABLE =")
    for name, cond, _, _ in builds[:-1]:
        lines.append(f"    ({cond}) ? {name} :")
    lines.append(f"    {builds[-1][0]};  // {builds[-1][1]}")
    lines.append(END)
    return "\n".join(indent + ln for ln in lines)


def _splice(src: str) -> str:
    a = src.index(BEGIN)
    a = src.rindex("\n", 0, a) + 1
    b = src.index(END, a)
    b = src.index("\n", b)
    indent = src[a:src.index(BEGIN)]
    return src[:a] + rtl_block(indent) + src[b:]


# --------------------------------------------------------------- main ----
def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--write-rtl", action="store_true",
                   help="regenerate the palettes in rtl/vtpgz_core.v")
    g.add_argument("--check", action="store_true",
                   help="fail if rtl/vtpgz_core.v is not up to date")
    args = ap.parse_args()

    if args.write_rtl or args.check:
        src = CORE.read_text(encoding="utf-8")
        new = _splice(src)
        if args.check:
            if new != src:
                print(f"{CORE.relative_to(ROOT)}: palettes are stale; run "
                      "python scripts/gen_yuv_palettes.py --write-rtl",
                      file=sys.stderr)
                return 1
            print("palettes in vtpgz_core.v are up to date")
            return 0
        if new != src:
            CORE.write_bytes(new.encode("utf-8"))
            print(f"rewrote palettes in {CORE.relative_to(ROOT)}")
        else:
            print("palettes already up to date")
        return 0

    for name, _, pal, bits in _all_builds():
        print(f"=== {name} ===")
        for bar, t in pal:
            print(f"  {bar:8} 12b={' '.join(f'{v:03X}' for v in t)}  "
                  f"{bits}b={tuple(v >> (12 - bits) for v in t)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
