#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Leonardo Capossio - bard0 design - hello@bard0.com
# SPDX-License-Identifier: Apache-2.0
"""Spec tests for YUV_RANGE and YUV_MATRIX.

Asserted here, against the Python reference model. The byte-exact sim<->model
gate carries these through to RTL: if the model meets spec and RTL byte-matches
the model, RTL meets spec.

What is checked:

  1. Palette exactness -- for each {matrix, range}, the bars at BPC 8, 10 and
     12 equal the published standard codes EXACTLY, no tolerance. The expected
     values come from the colorimetry, not from a copy of the RTL constants,
     so this can actually catch a wrong constant.

  2. Range bounds -- in a LIMITED build, over a full frame of every
     runtime-valued pattern, Y stays within 64..940 and C within 64..960 at 10
     bits, AND the extremes are actually reached on the gradients. A bound
     check that passes on an all-grey frame proves nothing, so reaching the
     ends is part of the assertion.

  3. Neutral chroma is exact -- 0x800 in, 0x800 out, in both ranges.

  4. The default is unchanged -- a FULL/BT.601 build still produces the
     historical palette, bit for bit.

Run with:
    python3 hw/arty_a7_100t/python/check_yuv_range.py
"""
from __future__ import annotations

import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from vtpgz_model import (  # noqa: E402
    MODE_YUV, YUV_444,
    YUV_FULL, YUV_LIMITED, YUV_BT601, YUV_BT709,
    PAT_HGRAD, PAT_VGRAD, PAT_CHECKER, PAT_RAMP, PAT_NOISE,
    PAT_GRID, PAT_SOLID,
    PALETTE_YUV_BY_BUILD, CHROMA_NEUTRAL,
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

# Published 10-bit standard levels, transcribed from the standards rather than
# generated, so a bug in the generator cannot hide behind agreement with it.
STD_10BIT = {
    (YUV_BT709, YUV_LIMITED): [
        (940, 512, 512), (877, 64, 553), (754, 615, 64), (691, 167, 105),
        (313, 857, 919), (250, 409, 960), (127, 960, 471), (64, 512, 512)],
    (YUV_BT601, YUV_LIMITED): [
        (940, 512, 512), (840, 64, 585), (678, 663, 64), (578, 215, 137),
        (426, 809, 887), (326, 361, 960), (164, 960, 439), (64, 512, 512)],
}

BAR_NAMES = ["white", "yellow", "cyan", "green", "magenta", "red", "blue",
             "black"]

# Limited-range legal bounds, 10-bit.
Y_LO, Y_HI = 64, 940
C_LO, C_HI = 64, 960

failures: list[str] = []


def fail(msg: str) -> None:
    failures.append(msg)


def check_palette_exact() -> None:
    """1. Every limited palette hits the published code at every BPC."""
    for (matrix, rng), std in STD_10BIT.items():
        pal = PALETTE_YUV_BY_BUILD[(matrix, rng)]
        mname = "BT.709" if matrix == YUV_BT709 else "BT.601"
        for bpc, shift in ((12, 0), (10, 2), (8, 4)):
            for i, (name, twelve) in enumerate(zip(BAR_NAMES, pal)):
                got = tuple(v >> shift for v in twelve)
                # The standard is defined at 10 bits; scale it to this BPC the
                # same way the pack stage does.
                want = tuple(v >> (shift - 2) if shift > 2 else v << (2 - shift)
                             for v in std[i])
                if got != want:
                    fail(f"palette {mname} limited BPC={bpc} bar '{name}': "
                         f"got {got}, standard says {want}")


def check_default_unchanged() -> None:
    """4. The shipped default palette is bit-identical to what it always was."""
    pal = PALETTE_YUV_BY_BUILD[(YUV_BT601, YUV_FULL)]
    for name, got, want in zip(BAR_NAMES, pal, LEGACY_601_FULL):
        if got != want:
            fail(f"DEFAULT build changed: bar '{name}' is "
                 f"{tuple(f'{v:03X}' for v in got)}, was "
                 f"{tuple(f'{v:03X}' for v in want)}")


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


def main() -> int:
    check_default_unchanged()
    check_palette_exact()
    check_range_bounds()
    check_color_registers_unscaled()
    check_neutral_chroma()

    if failures:
        for f in failures:
            print(f"FAIL: {f}")
        print(f"\n{len(failures)} failure(s)")
        return 1
    print("PASS: YUV_RANGE / YUV_MATRIX meet spec "
          "(palette exact at BPC 8/10/12, limited bounds reached exactly, "
          "neutral chroma preserved, default unchanged)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
