#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Leonardo Capossio - bard0 design - hello@bard0.com
# SPDX-License-Identifier: Apache-2.0
"""Spec tests for YUV_RANGE, YUV_MATRIX and BAR_LEVEL.

Asserted here, against the Python reference model. The byte-exact sim<->model
gate carries these through to RTL: if the model meets spec and RTL byte-matches
the model, RTL meets spec.

What is checked:

  1. Palette exactness -- for every build (RGB and YUV, each matrix and
     range, 100% and 75% bars) the colour-bar frame at BPC 8, 10 and 12,
     after the pack stage's truncation, equals the standard code EXACTLY, no
     tolerance. The expected values are published tables where one exists
     (the classic 8-bit and 10-bit limited tables, SMPTE RP 219 for 75%
     BT.709) and otherwise an exact-arithmetic implementation of the
     formulas written here, independently of the generator the RTL and
     model share -- so this can actually catch a wrong constant.

  2. Range bounds -- in a LIMITED build, over a full frame of every
     runtime-valued pattern, Y stays within 64..940 and C within 64..960 at 10
     bits, AND the extremes are actually reached on the gradients. A bound
     check that passes on an all-grey frame proves nothing, so reaching the
     ends is part of the assertion.

  3. Neutral chroma is exact -- 0x800 in, 0x800 out, in both ranges.

  4. The default is unchanged -- a FULL/BT.601 build still produces the
     historical palette, bit for bit.

  5. The image converter (scripts/image_to_hex.py --yuv) turns the eight
     pure bar colours into the published 8-bit tables, so a YUV build's
     IMAGE memory holds codes in the build's colorimetry.

Run with:
    python3 hw/arty_a7_100t/python/check_yuv_range.py
"""
from __future__ import annotations

import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parents[2] / "scripts"))

import image_to_hex  # noqa: E402

from fractions import Fraction  # noqa: E402

from vtpgz_model import (  # noqa: E402
    MODE_RGB, MODE_YUV, YUV_444, PAT_COLORBAR,
    YUV_FULL, YUV_LIMITED, YUV_BT601, YUV_BT709,
    PAT_HGRAD, PAT_VGRAD, PAT_CHECKER, PAT_RAMP, PAT_NOISE,
    PAT_GRID, PAT_SOLID,
    CHROMA_NEUTRAL, bar_palette,
    VtpgzConfig, VtpgzRegs, render_frame_native,
)

# The historical palette, frozen. Written out literally on purpose: this is a
# regression guard on the DEFAULT build, so it must be an independent copy and
# not anything derived from the code under test.
LEGACY_601_FULL = [
    (0xFFF, 0x800, 0x800), (0xE2C, 0x000, 0x94D),
    (0xB37, 0xAB3, 0x000), (0x964, 0x2B4, 0x14E),
    (0x69B, 0xD4C, 0xEB2), (0x4C8, 0x54D, 0xFFF),
    (0x1D3, 0xFFF, 0x6B3), (0x000, 0x800, 0x800),
]

# Published standard levels, transcribed from the standards rather than
# generated, so a bug in the generator cannot hide behind agreement with it.
# Keyed by (matrix, range, level, bits).
def _cols(y, cb, cr):
    return list(zip(y, cb, cr))


PUBLISHED = {
    # 100% bars, 10 bits.
    (YUV_BT709, YUV_LIMITED, 100, 10): [
        (940, 512, 512), (877, 64, 553), (754, 615, 64), (691, 167, 105),
        (313, 857, 919), (250, 409, 960), (127, 960, 471), (64, 512, 512)],
    (YUV_BT601, YUV_LIMITED, 100, 10): [
        (940, 512, 512), (840, 64, 585), (678, 663, 64), (578, 215, 137),
        (426, 809, 887), (326, 361, 960), (164, 960, 439), (64, 512, 512)],
    # 100% bars, 8 bits: the classic tables. These are NOT the 10-bit codes
    # truncated: BT.601 cyan Y is 170, but 678 >> 2 = 169.
    (YUV_BT601, YUV_LIMITED, 100, 8): _cols(
        (235, 210, 170, 145, 106, 81, 41, 16),
        (128, 16, 166, 54, 202, 90, 240, 128),
        (128, 146, 16, 34, 222, 240, 110, 128)),
    (YUV_BT709, YUV_LIMITED, 100, 8): _cols(
        (235, 219, 188, 173, 78, 63, 32, 16),
        (128, 16, 154, 42, 214, 102, 240, 128),
        (128, 138, 16, 26, 230, 240, 118, 128)),
    # 75% bars, BT.709 limited, 10 bits: SMPTE RP 219.
    (YUV_BT709, YUV_LIMITED, 75, 10): [
        (721, 512, 512), (674, 176, 543), (581, 589, 176), (534, 253, 207),
        (251, 771, 817), (204, 435, 848), (111, 848, 481), (64, 512, 512)],
}

# RGB bars: the level of full scale, per bit depth.
RGB_LEVEL = {(100, 8): 255, (100, 10): 1023, (100, 12): 4095,
             (75, 8): 191, (75, 10): 767, (75, 12): 3071}

BARS_RGB = [(1, 1, 1), (1, 1, 0), (0, 1, 1), (0, 1, 0),
            (1, 0, 1), (1, 0, 0), (0, 0, 1), (0, 0, 0)]
KRKB = {YUV_BT601: (Fraction(299, 1000), Fraction(114, 1000)),
        YUV_BT709: (Fraction(2126, 10000), Fraction(722, 10000))}


def _round_half_up(q: Fraction) -> int:
    """H.273 Round() for q >= 0: half away from zero."""
    return int((q + Fraction(1, 2)) // 1)


def formula(matrix: int, rng: int, level: int, bits: int):
    """The bars from BT.601/BT.709 and H.273, in exact rational arithmetic.

    Written independently of scripts/gen_yuv_palettes.py (which uses floats
    and a different code path), so the two agreeing means something.
    """
    kr, kb = KRKB[matrix]
    e = Fraction(level, 100)
    top = 2 ** bits - 1
    out = []
    for r, g, b in BARS_RGB:
        r, g, b = r * e, g * e, b * e
        y = kr * r + (1 - kr - kb) * g + kb * b
        cb = (b - y) / (2 * (1 - kb))
        cr = (r - y) / (2 * (1 - kr))
        if rng == YUV_LIMITED:
            s = Fraction(2) ** (bits - 8)
            t = ((219 * y + 16) * s, (224 * cb + 128) * s, (224 * cr + 128) * s)
            out.append(tuple(_round_half_up(v) for v in t))
        else:
            mid = 2 ** (bits - 1)
            # H.273: the offset is inside Round(), so chroma -0.5 is 1.
            out.append((_round_half_up(top * y),
                        min(top, _round_half_up(top * cb + mid)),
                        min(top, _round_half_up(top * cr + mid))))
    return out

BAR_NAMES = ["white", "yellow", "cyan", "green", "magenta", "red", "blue",
             "black"]

# Limited-range legal bounds, 10-bit.
Y_LO, Y_HI = 64, 940
C_LO, C_HI = 64, 960

failures: list[str] = []


def fail(msg: str) -> None:
    failures.append(msg)


def colorbar_codes(mode: int, matrix: int, rng: int, level: int,
                   bpc: int) -> list[tuple[int, int, int]]:
    """The 8 bars of a model-rendered colour-bar frame, as BPC-bit codes.

    Renders a real frame, so the model's palette SELECTION (by mode, matrix,
    range, level and BPC) is under test too, not just the tables.
    """
    cfg = VtpgzConfig(width=64, height=2, pattern=PAT_COLORBAR,
                      output_mode=mode, yuv_subsample=YUV_444,
                      yuv_range=rng, yuv_matrix=matrix, bar_level=level,
                      bpc=bpc, bar_width=8)
    px = render_frame_native(cfg, VtpgzRegs())
    shift = 12 - bpc
    return [tuple(v >> shift for v in px[8 * i + 4]) for i in range(8)]


def check_palette_exact() -> None:
    """1. Every build's bars hit the standard code at BPC 8, 10 and 12."""
    for matrix in (YUV_BT601, YUV_BT709):
        mname = "BT.709" if matrix == YUV_BT709 else "BT.601"
        for rng in (YUV_FULL, YUV_LIMITED):
            rname = "limited" if rng == YUV_LIMITED else "full"
            for level in (100, 75):
                if (matrix, rng, level) == (YUV_BT601, YUV_FULL, 100):
                    continue    # the frozen default: check_default_unchanged
                for bits in (8, 10, 12):
                    got = colorbar_codes(MODE_YUV, matrix, rng, level, bits)
                    tag = f"palette {mname} {rname} {level}% BPC={bits}"
                    wants = [("formula", formula(matrix, rng, level, bits))]
                    pub = PUBLISHED.get((matrix, rng, level, bits))
                    if pub is not None:
                        src = ("SMPTE RP 219" if level == 75
                               else "published table")
                        wants.append((src, pub))
                    for src, want in wants:
                        for name, g, w in zip(BAR_NAMES, got, want):
                            if g != w:
                                fail(f"{tag} bar '{name}': got {g}, "
                                     f"{src} says {w}")

    # RGB (and RAW, which shares the palette): each primary is 0 or the
    # level's code, per bit depth.
    for level in (100, 75):
        for bits in (8, 10, 12):
            got = colorbar_codes(MODE_RGB, YUV_BT601, YUV_FULL, level, bits)
            full = RGB_LEVEL[(level, bits)]
            want = [tuple(full * c for c in rgb) for rgb in BARS_RGB]
            for name, g, w in zip(BAR_NAMES, got, want):
                if g != w:
                    fail(f"palette RGB {level}% BPC={bits} bar '{name}': "
                         f"got {g}, expected {w}")


def check_default_unchanged() -> None:
    """4. The shipped default palettes are bit-identical to what they were,
    at every BPC: YUV BT.601 full 100%, and RGB 100%."""
    for bits in (8, 10, 12):
        got = colorbar_codes(MODE_YUV, YUV_BT601, YUV_FULL, 100, bits)
        for name, g, w in zip(BAR_NAMES, got, LEGACY_601_FULL):
            w = tuple(v >> (12 - bits) for v in w)
            if g != w:
                fail(f"DEFAULT build changed at BPC={bits}: bar '{name}' is "
                     f"{g}, was {w}")
    for name, g, rgb in zip(BAR_NAMES, bar_palette(MODE_RGB), BARS_RGB):
        if g != tuple(0xFFF * c for c in rgb):
            fail(f"DEFAULT RGB build changed: bar '{name}' is "
                 f"{tuple(f'{v:03X}' for v in g)}")


def frame_native(pattern: int, rng: int, matrix: int, w: int = 64,
                 h: int = 32, **over) -> list[tuple[int, int, int]]:
    cfg = VtpgzConfig(width=w, height=h, pattern=pattern,
                      output_mode=MODE_YUV, yuv_subsample=YUV_444,
                      yuv_range=rng, yuv_matrix=matrix, bpc=10, **over)
    regs = VtpgzRegs()
    return render_frame_native(cfg, regs)


# Steps that provably sweep the accumulator across the whole 12-bit scale
# for the frame size used here. The defaults do NOT: vg_step=132 over 32 rows
# tops out at 4092, so a ceiling assertion against the default would be
# testing the step arithmetic, not the range map.
HG_STEP_FULLSWEEP = 0xFFF // 63     # 65 * 63 = 4095 exactly, over w=64
VG_STEP_FULLSWEEP = 133             # 133 * 31 = 4123, clamps at 0xFFF, over h=32


def check_range_bounds() -> None:
    """2. LIMITED keeps every runtime-valued pattern inside the legal box.

    GRID is deliberately absent from this group. Its line colour is
    cfg_grid_color, a raw register the core passes through unscaled by design,
    so a host writing 0xFFFFFF legitimately produces out-of-range codes. That
    contract is asserted separately in check_color_registers_unscaled().
    """
    runtime = [("hgrad", PAT_HGRAD), ("vgrad", PAT_VGRAD),
               ("checker", PAT_CHECKER), ("ramp", PAT_RAMP),
               ("noise", PAT_NOISE)]
    for name, pat in runtime:
        px = frame_native(pat, YUV_LIMITED, YUV_BT601)
        ys = [p[0] >> 2 for p in px]          # to 10-bit
        cs = [v >> 2 for p in px for v in p[1:]]
        if min(ys) < Y_LO or max(ys) > Y_HI:
            fail(f"LIMITED {name}: luma {min(ys)}..{max(ys)} leaves "
                 f"{Y_LO}..{Y_HI}")
        if min(cs) < C_LO or max(cs) > C_HI:
            fail(f"LIMITED {name}: chroma {min(cs)}..{max(cs)} leaves "
                 f"{C_LO}..{C_HI}")

    # The bounds above would pass on a flat grey frame, which would prove
    # nothing. Driven with a full sweep, the gradients must land on BOTH ends
    # exactly -- that is what makes this a test of the map and not of clipping.
    for name, pat, over in (
            ("hgrad", PAT_HGRAD, {"hg_step": HG_STEP_FULLSWEEP}),
            ("vgrad", PAT_VGRAD, {"vg_step": VG_STEP_FULLSWEEP})):
        ys = [p[0] >> 2
              for p in frame_native(pat, YUV_LIMITED, YUV_BT601, **over)]
        if min(ys) != Y_LO:
            fail(f"LIMITED {name}: luma floor is {min(ys)}, expected exactly "
                 f"{Y_LO} -- the map does not reach the bottom of the range")
        if max(ys) != Y_HI:
            fail(f"LIMITED {name}: luma ceiling is {max(ys)}, expected exactly "
                 f"{Y_HI} -- the map does not reach the top of the range")

        # And FULL must still span the whole scale, or LIMITED leaked into it.
        ys = [p[0] >> 2
              for p in frame_native(pat, YUV_FULL, YUV_BT601, **over)]
        if min(ys) != 0 or max(ys) != 1023:
            fail(f"FULL {name}: luma {min(ys)}..{max(ys)}, expected 0..1023")

    # The GRID background is a constant black, and must sit at limited black.
    ys = [p[0] >> 2 for p in frame_native(PAT_GRID, YUV_LIMITED, YUV_BT601)]
    if min(ys) != Y_LO:
        fail(f"LIMITED grid: background luma is {min(ys)}, expected {Y_LO}")


def check_color_registers_unscaled() -> None:
    """The colour registers stay raw code values, in both ranges.

    This is a contract, not an oversight: a host that writes an exact code
    expects to read that code back out. In a LIMITED build it is the host's
    job to write legal values, and the README says so. Asserting it here stops
    a future change from "helpfully" scaling them.
    """
    # Grid line colour: full-scale white must survive LIMITED untouched.
    px = frame_native(PAT_GRID, YUV_LIMITED, YUV_BT601,
                      grid_color=0x00FFFFFF)
    if max(p[0] for p in px) >> 2 != 1020:
        fail("LIMITED grid: cfg_grid_color was rescaled; it must pass "
             "through as a raw code value")

    # Solid colour likewise.
    px = frame_native(PAT_SOLID, YUV_LIMITED, YUV_BT601,
                      solid_color=0x00FFFFFF)
    if {p[0] >> 2 for p in px} != {1020}:
        fail("LIMITED solid: cfg_solid_color was rescaled; it must pass "
             "through as a raw code value")


def check_black_slot() -> None:
    """Pattern slot 5 is documented as black. In YUV that means neutral
    chroma and range-correct Y -- the all-zero triple is saturated green.
    (Stripped-pattern stubs are the same constant; the model has no EN_*
    flags, so tb/tb_black.v covers those in RTL.)"""
    for rng, label, y_black in ((YUV_FULL, "FULL", 0x000),
                                (YUV_LIMITED, "LIMITED", 0x100)):
        want = (y_black, CHROMA_NEUTRAL, CHROMA_NEUTRAL)
        px = frame_native(5, rng, YUV_BT601)
        bad = [p for p in px if p != want]
        if bad:
            fail(f"{label} slot 5: {len(bad)} pixels are not black; first is "
                 f"{tuple(hex(v) for v in bad[0])}, black is "
                 f"{tuple(hex(v) for v in want)}")


def check_neutral_chroma() -> None:
    """3. Grey patterns keep chroma exactly neutral in both ranges."""
    for rng, label in ((YUV_FULL, "FULL"), (YUV_LIMITED, "LIMITED")):
        for name, pat in (("hgrad", PAT_HGRAD), ("vgrad", PAT_VGRAD),
                          ("checker", PAT_CHECKER), ("ramp", PAT_RAMP),
                          ("noise", PAT_NOISE)):
            px = frame_native(pat, rng, YUV_BT601)
            bad = [p for p in px if p[1] != CHROMA_NEUTRAL
                   or p[2] != CHROMA_NEUTRAL]
            if bad:
                fail(f"{label} {name}: {len(bad)} pixels have non-neutral "
                     f"chroma, first is {tuple(hex(v) for v in bad[0])}")


def check_image_converter() -> None:
    """5. image_to_hex --yuv converts the bar colours to the published codes."""
    for matrix, mstr in ((YUV_BT601, "601"), (YUV_BT709, "709")):
        want = PUBLISHED[(matrix, YUV_LIMITED, 100, 8)]
        for name, rgb, w in zip(BAR_NAMES, BARS_RGB, want):
            word = image_to_hex.pixel_word(*(255 * c for c in rgb), True,
                                           mstr, True)
            got = ((word >> 16) & 0xFF, (word >> 8) & 0xFF, word & 0xFF)
            if got != w:
                fail(f"image_to_hex BT.{mstr} limited: bar '{name}' "
                     f"converts to {got}, published table says {w}")
        # Full range has no published 8-bit table; use the formula.
        want = formula(matrix, YUV_FULL, 100, 8)
        for name, rgb, w in zip(BAR_NAMES, BARS_RGB, want):
            word = image_to_hex.pixel_word(*(255 * c for c in rgb), True,
                                           mstr, False)
            got = ((word >> 16) & 0xFF, (word >> 8) & 0xFF, word & 0xFF)
            if got != w:
                fail(f"image_to_hex BT.{mstr} full: bar '{name}' "
                     f"converts to {got}, formula says {w}")
    # And without --yuv, the word is the RGB888 input, untouched.
    if image_to_hex.pixel_word(0x12, 0x34, 0x56, False) != 0x123456:
        fail("image_to_hex RGB: pixel word is not the RGB888 input")


def main() -> int:
    check_default_unchanged()
    check_palette_exact()
    check_range_bounds()
    check_color_registers_unscaled()
    check_black_slot()
    check_neutral_chroma()
    check_image_converter()

    if failures:
        for f in failures:
            print(f"FAIL: {f}")
        print(f"\n{len(failures)} failure(s)")
        return 1
    print("PASS: YUV_RANGE / YUV_MATRIX / BAR_LEVEL meet spec "
          "(bars exact at BPC 8/10/12 for every build, limited bounds "
          "reached exactly, neutral chroma preserved, defaults unchanged)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
