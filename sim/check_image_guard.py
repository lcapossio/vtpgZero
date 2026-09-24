#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Leonardo Capossio - bard0 design - hello@bard0.com
# SPDX-License-Identifier: Apache-2.0
"""Check the YUV image elaboration guard, with Icarus Verilog.

A YUV build's image memories must hold YCbCr codes (image_to_hex.py --yuv).
The core refuses a YUV build that enables IMAGE or BOX_IMAGE while pointing
at the shipped RGB mandrill files, by file name, and must accept everything
else. Each case below elaborates vtpgz_core and checks it fails, or does
not, as expected -- and that a failure is the guard, not something else.
"""
from __future__ import annotations

import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ABS_RGB = (ROOT / "tests" / "images" / "mandrill_128x128.mem").as_posix()

# (name, parameters, guard module expected in the error or None to pass)
IMG_GUARD = "VTPGZ_YUV_IMAGE_NEEDS_YCBCR_HEX_FILE_SEE_IMAGE_TO_HEX_YUV"
BIMG_GUARD = "VTPGZ_YUV_BOX_IMAGE_NEEDS_YCBCR_HEX_FILE_SEE_IMAGE_TO_HEX_YUV"
CASES = [
    ("YUV, IMAGE on, default file", dict(OUTPUT_MODE=2, EN_IMAGE=1), IMG_GUARD),
    ("YUV, IMAGE on, RGB file by absolute path",
     dict(OUTPUT_MODE=2, EN_IMAGE=1, IMAGE_HEX_FILE=f'"{ABS_RGB}"'), IMG_GUARD),
    ("YUV, BOX_IMAGE on, default file",
     dict(OUTPUT_MODE=2, EN_BOX_IMAGE=1), BIMG_GUARD),
    ("YUV, IMAGE on, converted file",
     dict(OUTPUT_MODE=2, EN_IMAGE=1,
          IMAGE_HEX_FILE='"build/mandrill_128x128_709lim.mem"'), None),
    ("YUV, IMAGE on, path shorter than the name",
     dict(OUTPUT_MODE=2, EN_IMAGE=1, IMAGE_HEX_FILE='"a.mem"'), None),
    ("YUV, IMAGE off, default file", dict(OUTPUT_MODE=2), None),
    ("RGB, IMAGE and BOX_IMAGE on, default files",
     dict(OUTPUT_MODE=0, EN_IMAGE=1, EN_BOX_IMAGE=1), None),
    ("RAW, IMAGE on, default file", dict(OUTPUT_MODE=1, EN_IMAGE=1), None),
]


def main() -> int:
    if shutil.which("iverilog") is None:
        print("ERROR: 'iverilog' not found in PATH.", file=sys.stderr)
        return 2
    bad = 0
    with tempfile.TemporaryDirectory() as td:
        for name, params, guard in CASES:
            cmd = ["iverilog", "-g2012", "-I", "rtl", "-s", "vtpgz_core",
                   "-o", str(Path(td) / "g.vvp")]
            for k, v in params.items():
                cmd += ["-P", f"vtpgz_core.{k}={v}"]
            cmd.append("rtl/vtpgz_core.v")
            r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
            log = r.stdout + r.stderr
            if guard is None:
                ok = r.returncode == 0
                why = "" if ok else f": did not elaborate\n{log}"
            else:
                ok = r.returncode != 0 and guard in log
                why = "" if ok else (
                    ": elaborated, guard did not fire" if r.returncode == 0
                    else f": failed, but not on the guard\n{log}")
            print(f"{'OK  ' if ok else 'FAIL'}  {name}{why}")
            bad += not ok
    if bad:
        print(f"\n{bad} case(s) wrong")
        return 1
    print(f"\nPASS: YUV image guard, {len(CASES)} cases")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
