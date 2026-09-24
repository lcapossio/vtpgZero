#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Leonardo Capossio - bard0 design - hello@bard0.com
# SPDX-License-Identifier: Apache-2.0
"""Mutation check: prove check_yuv_range.py actually bites.

A spec test that passes is worth nothing until you have seen it fail for the
right reason. The proposal asks for exactly this: "swap one palette constant,
or drop the luma map, and confirm the palette and bounds tests fail."

Each mutation below is a plausible bug. For each one we assert not merely that
SOMETHING failed, but that the check which is supposed to own that bug is the
one that caught it -- otherwise a single over-broad assertion could mask the
loss of all the others.

Run with:
    python3 hw/arty_a7_100t/python/check_yuv_range_mutations.py
"""
from __future__ import annotations

import sys
from contextlib import contextmanager
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import vtpgz_model as model      # noqa: E402
import check_yuv_range as chk    # noqa: E402
import image_to_hex              # noqa: E402  (path set by check_yuv_range)

from vtpgz_model import YUV_BT601, YUV_BT709, YUV_FULL, YUV_LIMITED  # noqa: E402


def run_checks() -> list[str]:
    """Run the whole suite in-process and return the failure messages."""
    chk.failures = []
    chk.check_default_unchanged()
    chk.check_palette_exact()
    chk.check_range_bounds()
    chk.check_color_registers_unscaled()
    chk.check_black_slot()
    chk.check_neutral_chroma()
    chk.check_image_converter()
    return list(chk.failures)


@contextmanager
def mutated_palette(build, bar: int, comp: int, delta: int):
    """Perturb one component of one bar by delta, then put it back.

    build is (output_mode, matrix, range, level, bpc).
    """
    pal = model.bar_palette(*build)
    orig = pal[bar]
    pal[bar] = tuple(v + delta if i == comp else v
                     for i, v in enumerate(orig))
    try:
        yield
    finally:
        pal[bar] = orig


@contextmanager
def replaced_palette(build, source):
    """Make one build use another build's palette -- a selection bug."""
    pal = model.bar_palette(*build)
    orig = list(pal)
    pal[:] = model.bar_palette(*source)
    try:
        yield
    finally:
        pal[:] = orig


YUV = model.MODE_YUV


@contextmanager
def dropped_luma_map():
    """Make the limited-range map an identity -- i.e. forget to apply it."""
    orig = model.y_to_limited
    model.y_to_limited = lambda y: y
    try:
        yield
    finally:
        model.y_to_limited = orig


@contextmanager
def scaled_color_registers():
    """A tempting 'fix': push the raw colour registers into the legal range.

    This is wrong -- the registers are documented as raw code values -- so the
    suite must reject it.
    """
    orig = model.render_frame_native

    def patched(cfg, regs):
        px = orig(cfg, regs)
        if cfg.output_mode == model.MODE_YUV and cfg.yuv_range == YUV_LIMITED:
            return [(model.y_to_limited(p[0]), p[1], p[2]) for p in px]
        return px

    model.render_frame_native = patched
    chk.render_frame_native = patched
    try:
        yield
    finally:
        model.render_frame_native = orig
        chk.render_frame_native = orig


@contextmanager
def converter_wrong_matrix():
    """image_to_hex converts with BT.601 whatever --matrix says."""
    orig = image_to_hex.rgb_to_ycbcr8
    image_to_hex.rgb_to_ycbcr8 = \
        lambda r, g, b, matrix, limited: orig(r, g, b, "601", limited)
    try:
        yield
    finally:
        image_to_hex.rgb_to_ycbcr8 = orig


MUTATIONS = [
    # (name, context manager, substring the OWNING failure must contain)
    ("BT.709 limited green Cb off by one LSB at 10 bits",
     lambda: mutated_palette((YUV, YUV_BT709, YUV_LIMITED, 100, 10), 3, 1, 4),
     "palette BT.709 limited 100% BPC=10 bar 'green'"),
    ("BT.601 limited white Y off by one LSB at 10 bits",
     lambda: mutated_palette((YUV, YUV_BT601, YUV_LIMITED, 100, 10), 0, 0, -4),
     "palette BT.601 limited 100% BPC=10 bar 'white'"),
    ("shipped BT.601 full palette changed",
     lambda: mutated_palette((YUV, YUV_BT601, YUV_FULL, 100, 12), 2, 2, 1),
     "DEFAULT build changed at BPC=12"),
    # The bug this palette set was introduced to fix: an 8-bit build that
    # takes the 10-bit codes and lets the pack stage truncate them.
    ("8-bit BT.601 limited palette is the 10-bit one truncated",
     lambda: replaced_palette((YUV, YUV_BT601, YUV_LIMITED, 100, 8),
                              (YUV, YUV_BT601, YUV_LIMITED, 100, 10)),
     "palette BT.601 limited 100% BPC=8"),
    ("75% BT.709 limited build uses the 100% bars",
     lambda: replaced_palette((YUV, YUV_BT709, YUV_LIMITED, 75, 10),
                              (YUV, YUV_BT709, YUV_LIMITED, 100, 10)),
     "SMPTE RP 219"),
    ("RGB 75% red off by one LSB at 8 bits",
     lambda: mutated_palette((model.MODE_RGB, YUV_BT601, YUV_FULL, 75, 8),
                             5, 0, 16),
     "palette RGB 75% BPC=8 bar 'red'"),
    ("limited-range luma map dropped",
     dropped_luma_map,
     "leaves 64..940"),
    ("colour registers wrongly rescaled",
     scaled_color_registers,
     "must pass through as a raw code value"),
    ("image converter ignores --matrix",
     converter_wrong_matrix,
     "image_to_hex BT.709 limited"),
]


def main() -> int:
    baseline = run_checks()
    if baseline:
        print("FAIL: the suite does not pass before mutation; fix that first:")
        for f in baseline:
            print(f"  {f}")
        return 1
    print("baseline: clean")

    bad = 0
    for name, ctx, owner in MUTATIONS:
        with ctx():
            got = run_checks()
        if not got:
            print(f"NOT CAUGHT: {name}")
            bad += 1
        elif not any(owner in f for f in got):
            print(f"CAUGHT BY THE WRONG CHECK: {name}")
            print(f"  expected a failure mentioning {owner!r}, got:")
            for f in got:
                print(f"    {f}")
            bad += 1
        else:
            print(f"caught: {name}")

    after = run_checks()
    if after:
        print("FAIL: a mutation leaked past its context manager:")
        for f in after:
            print(f"  {f}")
        return 1

    if bad:
        print(f"\n{bad} mutation(s) not caught by the right check")
        return 1
    print(f"\nPASS: all {len(MUTATIONS)} mutations caught by the owning check")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
