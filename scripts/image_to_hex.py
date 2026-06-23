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

Requires: Pillow (`pip install Pillow`).
"""
from __future__ import annotations

import argparse
import io
import sys
import urllib.request
from pathlib import Path

try:
    from PIL import Image
except ImportError:
    sys.exit("ERROR: Pillow not installed. Run: pip install Pillow")


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


def load_image(args: argparse.Namespace) -> Image.Image:
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
    args = ap.parse_args()

    if not is_pow2(args.width) or not is_pow2(args.height):
        sys.exit(f"ERROR: --width and --height must be powers of two "
                 f"(got {args.width}x{args.height})")

    img = load_image(args)
    print(f"[input] {img.size[0]}x{img.size[1]} {img.mode}")

    filt = {"nearest": Image.NEAREST,
            "bilinear": Image.BILINEAR,
            "lanczos": Image.LANCZOS}[args.resample]
    img = img.resize((args.width, args.height), filt)
    print(f"[resize] {args.width}x{args.height} ({args.resample})")

    out_path = Path(args.out).resolve()
    out_path.parent.mkdir(parents=True, exist_ok=True)

    with open(out_path, "w") as f:
        for y in range(args.height):
            for x in range(args.width):
                r, g, b = img.getpixel((x, y))
                f.write(f"{r:02x}{g:02x}{b:02x}\n")

    pixels = args.width * args.height
    print(f"[out] {out_path}  ({pixels} pixels, {pixels * 3} bytes raw)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
