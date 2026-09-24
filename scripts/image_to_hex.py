#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Leonardo Capossio - bard0 design - hello@bard0.com
# SPDX-License-Identifier: Apache-2.0
"""
Convert an image file into a $readmemh-friendly hex memory file for the
vtpgZero IMAGE pattern (PATTERN_SEL=9).

Each output line is one pixel as a 6-hex-digit value, packed
{R[7:0], G[7:0], B[7:0]} (RGB888, R in the MSBs). The vtpgZero core
expands 8 bits per component to its internal 12-bit pipeline by
MSB-replicating the upper 4 bits.

For a YUV build (OUTPUT_MODE=2) pass --yuv with the build's --matrix and
--range: each line is then {Y[7:0], Cb[7:0], Cr[7:0]}, 8-bit codes in the
build's colorimetry, which the core widens by a plain shift and passes
through untouched. The conversion is the one the colour-bar palettes use
(scripts/gen_yuv_palettes.py). The file starts with a `//` comment
recording the colorimetry; $readmemh skips comments. Converting for the
wrong matrix or range cannot be caught by the core, so keep the two in step
(the build's YUV_MATRIX / YUV_RANGE).

Width and height MUST be powers of two -- the RTL uses bit-mask wrap-
around (tile) for sub-frame images, which costs no logic only at
powers of two.

Usage:
    # Convert any image
    python scripts/image_to_hex.py input.png --width 128 --height 128 \\
        --out tests/images/mandrill_128x128.mem

    # Fetch the canonical 512x512 mandrill ("baboon.png") from a stable
    # public mirror and downscale to 128x128 in one shot
    python scripts/image_to_hex.py --fetch-mandrill --width 128 --height 128 \\
        --out tests/images/mandrill_128x128.mem

    # For a YUV limited-range BT.709 build
    python scripts/image_to_hex.py tests/images/baboon.jpg --width 128 \\
        --height 128 --yuv --matrix 709 --range limited \\
        --out build/mandrill_128x128_709lim.mem

Requires: Pillow (`pip install Pillow`).
"""
from __future__ import annotations

import argparse
import io
import sys
import urllib.request
from fractions import Fraction
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from gen_yuv_palettes import MATRICES, ycbcr_code  # noqa: E402


def rgb_to_ycbcr8(r: int, g: int, b: int, matrix: str, limited: bool):
    """One 8-bit R'G'B' pixel -> 8-bit {Y, Cb, Cr} codes.

    Exactly the conversion the colour-bar palettes use, so an image of the
    bars converts to the bars.
    """
    kr, kb = MATRICES[matrix]
    return ycbcr_code((Fraction(r, 255), Fraction(g, 255), Fraction(b, 255)),
                      kr, kb, limited, 8)


def pixel_word(r: int, g: int, b: int, yuv: bool, matrix: str = "601",
               limited: bool = False) -> int:
    """The 24-bit memory word for one pixel."""
    if yuv:
        r, g, b = rgb_to_ycbcr8(r, g, b, matrix, limited)
    return (r << 16) | (g << 8) | b


def _pil():
    try:
        from PIL import Image
    except ImportError:
        sys.exit("ERROR: Pillow not installed. Run: pip install Pillow")
    return Image


# Stable public mirrors of the canonical baboon/mandrill test image.
# The original USC SIPI photo is widely redistributed as a test pattern;
# we try a few mirrors in case one is unreachable.
MANDRILL_URLS = [
    "https://raw.githubusercontent.com/opencv/opencv/4.x/samples/data/baboon.jpg",
    "https://homepages.cae.wisc.edu/~ece533/images/baboon.png",
]


def is_pow2(n: int) -> bool:
    return n > 0 and (n & (n - 1)) == 0


def fetch_url(url: str, timeout: int = 30) -> bytes:
    # Polite UA -- some hosts 403 the default Python-urllib client.
    req = urllib.request.Request(
        url, headers={"User-Agent": "Mozilla/5.0 (vtpgZero-image-fetch)"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


def load_image(args: argparse.Namespace):
    Image = _pil()
    if args.fetch_mandrill:
        last_err = None
        for url in MANDRILL_URLS:
            try:
                print(f"[fetch] {url}")
                data = fetch_url(url)
                return Image.open(io.BytesIO(data)).convert("RGB")
            except Exception as e:
                last_err = e
                print(f"[fetch] failed: {e}")
        sys.exit(f"ERROR: all mandrill mirrors unreachable. "
                 f"Last error: {last_err}.\n"
                 f"Download baboon.png manually and pass its path as the "
                 f"positional argument.")
    if not args.input:
        sys.exit("ERROR: provide an image path or --fetch-mandrill")
    p = Path(args.input).resolve()
    if not p.is_file():
        sys.exit(f"ERROR: input image not found: {p}")
    return Image.open(p).convert("RGB")


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Convert an image into a $readmemh hex file for vtpgZero.")
    ap.add_argument("input", nargs="?",
                    help="Source image (PNG/JPG/etc.). Optional with --fetch-mandrill.")
    ap.add_argument("--fetch-mandrill", action="store_true",
                    help="Download the canonical 512x512 mandrill image and use it as the source.")
    ap.add_argument("--width", type=int, required=True,
                    help="Target width (power of two).")
    ap.add_argument("--height", type=int, required=True,
                    help="Target height (power of two).")
    ap.add_argument("--out", required=True,
                    help="Output .mem file (one pixel per line, 6-hex RGB888).")
    ap.add_argument("--resample", default="lanczos",
                    choices=["nearest", "bilinear", "lanczos"],
                    help="Resize filter (default: lanczos).")
    ap.add_argument("--yuv", action="store_true",
                    help="Write YCbCr codes, for a YUV build (OUTPUT_MODE=2).")
    ap.add_argument("--matrix", choices=sorted(MATRICES), default="601",
                    help="With --yuv: the build's YUV_MATRIX (default 601).")
    ap.add_argument("--range", dest="yuv_range", default="full",
                    choices=["full", "limited"],
                    help="With --yuv: the build's YUV_RANGE (default full).")
    args = ap.parse_args()
    if not args.yuv and (args.matrix != "601" or args.yuv_range != "full"):
        sys.exit("ERROR: --matrix/--range only apply with --yuv")

    if not is_pow2(args.width) or not is_pow2(args.height):
        sys.exit(f"ERROR: --width and --height must be powers of two "
                 f"(got {args.width}x{args.height})")

    Image = _pil()
    img = load_image(args)
    print(f"[input] {img.size[0]}x{img.size[1]} {img.mode}")

    filt = {"nearest": Image.NEAREST,
            "bilinear": Image.BILINEAR,
            "lanczos": Image.LANCZOS}[args.resample]
    img = img.resize((args.width, args.height), filt)
    print(f"[resize] {args.width}x{args.height} ({args.resample})")

    out_path = Path(args.out).resolve()
    out_path.parent.mkdir(parents=True, exist_ok=True)

    limited = args.yuv_range == "limited"
    with open(out_path, "w") as f:
        if args.yuv:
            f.write(f"// YCbCr BT.{args.matrix} {args.yuv_range} range, "
                    f"8-bit codes {{Y, Cb, Cr}} -- for YUV_MATRIX/YUV_RANGE "
                    f"builds to match\n")
        for y in range(args.height):
            for x in range(args.width):
                r, g, b = img.getpixel((x, y))
                w = pixel_word(r, g, b, args.yuv, args.matrix, limited)
                f.write(f"{w:06x}\n")

    pixels = args.width * args.height
    print(f"[out] {out_path}  ({pixels} pixels, {pixels * 3} bytes raw)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
