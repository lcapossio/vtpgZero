#!/usr/bin/env python3
"""YUV-mode spec test for vtpgZero.

When OUTPUT_MODE=2 (YUV), every grayscale-style pattern must emit neutral
chroma (Cb = Cr = 0x800 in 12-bit Q12, = 128 in 8-bit). For the grid
pattern, only off-grid (background) pixels carry neutral chroma -- on-grid
lines pass cfg_grid_color through component-by-component, which is the
documented "host fills colors in the build's color space" behaviour.

This is a *spec* test: it asserts the YUV property directly against the
Python reference model. The byte-exact RTL<->model gate transitively
covers RTL too: if the model meets spec and RTL byte-matches the model,
RTL meets spec.

The bug this catches is the class where both RTL and model emit the
wrong constant in the same way -- exactly how the grid green-background
bug slipped through `all_modes` until 2026-06-26.

Run with:
    python3 hw/arty_a7_100t/python/check_yuv_spec.py
"""
from __future__ import annotations

import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from vtpgz_model import (  # noqa: E402
    VtpgzConfig,
    VtpgzRegs,
    _comb_pixel,
    _tick,
    MODE_YUV,
    PAT_HGRAD,
    PAT_VGRAD,
    PAT_CHECKER,
    PAT_GRID,
    PAT_RAMP,
    PAT_NOISE,
    CHROMA_NEUTRAL,
)

# Patterns that must emit neutral chroma on every pixel in YUV mode.
GRAY_PATTERNS = [
    (PAT_HGRAD,   "hgrad"),
    (PAT_VGRAD,   "vgrad"),
    (PAT_CHECKER, "checker"),
    (PAT_RAMP,    "ramp"),
    (PAT_NOISE,   "noise"),
]


def _render_native(cfg: VtpgzConfig) -> list[list[tuple[int, int, int]]]:
    """Render one frame and return the per-pixel 12-bit native triples
    (Y, Cb, Cr in YUV mode). Mirrors what render_frame does up to the
    bpc-shrink + axis-pack stages, but keeps the values in 12 bits so
    the test is bpc-agnostic."""
    regs = VtpgzRegs()
    out: list[list[tuple[int, int, int]]] = []
    for y in range(cfg.height):
        row = []
        for x in range(cfg.width):
            row.append(_comb_pixel(cfg, regs, x, y))
            last_x = (x == cfg.width - 1)
            pix_sof = (x == 0 and y == 0)
            end_of_frame = (x == cfg.width - 1 and y == cfg.height - 1)
            _tick(cfg, regs, x, y, last_x, pix_sof, end_of_frame)
        out.append(row)
    return out


def _check_gray_pattern(pat: int, name: str) -> int:
    cfg = VtpgzConfig(
        width=64, height=8,
        pattern=pat,
        output_mode=MODE_YUV,
        bpc=8,
        bar_width=8,
        hg_step=64,
        vg_step=128,
        checker_size=4,
    )
    frame = _render_native(cfg)
    bad = []
    for y, row in enumerate(frame):
        for x, (Y, Cb, Cr) in enumerate(row):
            if Cb != CHROMA_NEUTRAL or Cr != CHROMA_NEUTRAL:
                bad.append((x, y, Y, Cb, Cr))
    if bad:
        print(f"FAIL: pattern '{name}': {len(bad)} of "
              f"{cfg.width * cfg.height} pixels have non-neutral chroma")
        x, y, Y, Cb, Cr = bad[0]
        print(f"  first offender: ({x},{y}) Y=0x{Y:03X} "
              f"Cb=0x{Cb:03X} Cr=0x{Cr:03X}")
        return 1
    print(f"PASS: pattern '{name}': all "
          f"{cfg.width * cfg.height} pixels have neutral chroma")
    return 0


def _check_grid_background() -> int:
    cfg = VtpgzConfig(
        width=64, height=8,
        pattern=PAT_GRID,
        output_mode=MODE_YUV,
        bpc=8,
        grid_spacing=4,
        grid_color=0x00FFFFFF,
    )
    frame = _render_native(cfg)
    bg_pixels = 0
    bad = []
    for y, row in enumerate(frame):
        for x, (Y, Cb, Cr) in enumerate(row):
            # Off-grid background: luma == 0 (the grid lines carry the
            # host-programmed cfg_grid_color luma).
            if Y == 0:
                bg_pixels += 1
                if Cb != CHROMA_NEUTRAL or Cr != CHROMA_NEUTRAL:
                    bad.append((x, y, Y, Cb, Cr))
    if bg_pixels == 0:
        print("FAIL: grid: no off-grid background pixels found "
              "(grid_spacing too tight or frame too small?)")
        return 1
    if bad:
        print(f"FAIL: grid: {len(bad)} of {bg_pixels} off-grid background "
              f"pixels have non-neutral chroma")
        x, y, Y, Cb, Cr = bad[0]
        print(f"  first offender: ({x},{y}) Y=0x{Y:03X} "
              f"Cb=0x{Cb:03X} Cr=0x{Cr:03X} -- did the grid YUV-neutral "
              f"fix get reverted?")
        return 1
    print(f"PASS: grid: all {bg_pixels} off-grid background pixels "
          f"have neutral chroma")
    return 0


def main() -> int:
    rc = 0
    for pat, name in GRAY_PATTERNS:
        rc |= _check_gray_pattern(pat, name)
    rc |= _check_grid_background()
    print()
    print("ALL YUV SPEC CHECKS PASS" if rc == 0 else "YUV SPEC CHECKS FAILED")
    return rc


if __name__ == "__main__":
    sys.exit(main())
