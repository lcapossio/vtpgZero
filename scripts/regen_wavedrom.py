#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Leonardo Capossio - bard0 design - hello@bard0.com
# SPDX-License-Identifier: Apache-2.0
"""
Regenerate every SVG in docs/img/ from its docs/wavedrom/ JSON5 source.

Requires `wavedrom-cli` on PATH (`npm i -g wavedrom-cli`). Run from the
repo root or any subdirectory; paths are resolved relative to this file.

Usage:
    python scripts/regen_wavedrom.py            # rebuild all
    python scripts/regen_wavedrom.py tdata_stream  # rebuild one by stem
"""
from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
SRC_DIR = REPO / "docs" / "wavedrom"
OUT_DIR = REPO / "docs" / "img"


def find_cli() -> str:
    for cand in ("wavedrom-cli", "wavedrom-cli.cmd"):
        p = shutil.which(cand)
        if p:
            return p
    sys.exit("ERROR: wavedrom-cli not on PATH. Install with: npm i -g wavedrom-cli")


def render(cli: str, src: Path) -> int:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    out = OUT_DIR / (src.stem + ".svg")
    print(f"[wavedrom] {src.relative_to(REPO)} -> {out.relative_to(REPO)}")
    r = subprocess.run([cli, "-i", str(src), "-s", str(out)],
                       capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stdout)
        print(r.stderr, file=sys.stderr)
    return r.returncode


def main() -> int:
    cli = find_cli()
    if not SRC_DIR.is_dir():
        sys.exit(f"ERROR: source dir not found: {SRC_DIR}")

    if len(sys.argv) > 1:
        targets = []
        for arg in sys.argv[1:]:
            cand = SRC_DIR / f"{arg}.json5"
            if not cand.is_file():
                cand = SRC_DIR / f"{arg}.json"
            if not cand.is_file():
                sys.exit(f"ERROR: source not found for stem '{arg}'")
            targets.append(cand)
    else:
        targets = sorted(SRC_DIR.glob("*.json5")) + sorted(SRC_DIR.glob("*.json"))
        if not targets:
            sys.exit(f"ERROR: no *.json5 or *.json files under {SRC_DIR}")

    rc = 0
    for src in targets:
        rc = render(cli, src) or rc
    return rc


if __name__ == "__main__":
    sys.exit(main())
