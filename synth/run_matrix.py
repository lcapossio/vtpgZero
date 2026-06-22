#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Leonardo Capossio - bard0 design - hello@bard0.com
# SPDX-License-Identifier: Apache-2.0
"""
Drive Vivado synth_design over a matrix of vtpgZero parameter configurations
to produce a resource-per-feature table for the README.

Sweeps both:
  - per-pattern enables (EN_*) for the full RGB+CSC build
  - per-output-mode (RGB / RAW / YUV) at 8/10/12 bpc

Usage:
    python synth/run_matrix.py
"""
from __future__ import annotations

import re
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
TCL  = HERE / "synth_matrix.tcl"
RESULTS = HERE / "results"


# Per-pattern enables
PATTERN_FEATURES = [
    "EN_COLORBAR",
    "EN_HGRAD",
    "EN_VGRAD",
    "EN_CHECKER",
    "EN_SOLID",
    "EN_MOVING_BOX",
    "EN_GRID",
    "EN_RAMP",
    "EN_NOISE",
]

# Output-mode parameters and their defaults
MODE_PARAMS = {
    "OUTPUT_MODE":   2,   # 0=RGB 1=RAW 2=YUV
    "YUV_SUBSAMPLE": 0,   # 0=444 1=422
    "RAW_BAYER":     1,   # 0=plain 1=RGGB
    "RGB_ORDER":     0,   # 0=Xilinx 1=legacy
    "BPC":           8,
}


def make_generics(pat_overrides: dict[str, int],
                  mode_overrides: dict[str, int]) -> str:
    parts = []
    for f in PATTERN_FEATURES:
        parts.append(f"{f}={pat_overrides.get(f, 1)}")
    for k, default in MODE_PARAMS.items():
        parts.append(f"{k}={mode_overrides.get(k, default)}")
    return " ".join(parts)


def parse_util(rpt: Path) -> dict[str, int]:
    out = {"LUT": 0, "FF": 0, "BRAM36": 0, "DSP": 0}
    if not rpt.exists():
        return out
    text = rpt.read_text(errors="replace")
    for line in text.splitlines():
        m = re.match(r"\|\s*(?:Slice|CLB)\s+LUTs\*?\s*\|\s*(\d+)", line)
        if m: out["LUT"] = int(m.group(1)); continue
        m = re.match(r"\|\s*(?:Slice|CLB)\s+Registers\s*\|\s*(\d+)", line)
        if m: out["FF"] = int(m.group(1)); continue
        m = re.match(r"\|\s*Block RAM Tile\s*\|\s*(\d+)", line)
        if m: out["BRAM36"] = int(m.group(1)); continue
        m = re.match(r"\|\s*DSPs\s*\|\s*(\d+)", line)
        if m: out["DSP"] = int(m.group(1)); continue
    return out


def run_one(tag: str, pat_over: dict[str, int],
            mode_over: dict[str, int]) -> dict[str, int]:
    vivado = shutil.which("vivado") or shutil.which("vivado.bat")
    if not vivado:
        print("ERROR: vivado not in PATH", file=sys.stderr); sys.exit(2)
    generics = make_generics(pat_over, mode_over)
    print(f"\n=== {tag} ===")
    print(f"  generics: {generics}")
    cmd = [vivado, "-mode", "batch", "-source", str(TCL),
           "-nolog", "-nojournal",
           "-tclargs", tag, generics]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        print(f"  FAILED:\n{r.stdout[-2000:]}\n{r.stderr[-500:]}")
        return {}
    util = parse_util(RESULTS / f"util_{tag}.rpt")
    print(f"  LUT={util['LUT']:5d}  FF={util['FF']:5d}  BRAM={util['BRAM36']:2d}  DSP={util['DSP']:2d}")
    return util


def main() -> int:
    RESULTS.mkdir(parents=True, exist_ok=True)
    configs: list[tuple[str, dict[str, int], dict[str, int]]] = []

    # ----- Per-pattern sweeps (full YUV build, isolating each pattern) -----
    base_off = {f: 0 for f in PATTERN_FEATURES}
    base_off["EN_SOLID"] = 1
    yuv_mode = {"OUTPUT_MODE": 2, "BPC": 8}
    configs.append(("baseline_solid_yuv", dict(base_off), yuv_mode))
    for pat in PATTERN_FEATURES:
        if pat == "EN_SOLID":
            continue
        cfg = dict(base_off); cfg[pat] = 1
        tag = f"only_{pat.lower().removeprefix('en_')}_yuv"
        configs.append((tag, cfg, yuv_mode))

    # ----- All patterns enabled, sweep OUTPUT_MODE x BPC -----
    full_pats = {f: 1 for f in PATTERN_FEATURES}
    for mode_id, mode_name in [(0, "rgb"), (1, "raw"), (2, "yuv")]:
        for bpc in (8, 10, 12, 14, 16):
            tag = f"full_{mode_name}_{bpc}b"
            mode_over = {"OUTPUT_MODE": mode_id, "BPC": bpc}
            configs.append((tag, dict(full_pats), mode_over))

    # YUV422 16bpc as a special case
    configs.append(("full_yuv422_16b", dict(full_pats),
                    {"OUTPUT_MODE": 2, "BPC": 16, "YUV_SUBSAMPLE": 1}))

    # Tiniest possible build: only solid pattern + RAW Bayer 8bpc
    tiny_pats = {f: 0 for f in PATTERN_FEATURES}
    tiny_pats["EN_SOLID"] = 1
    configs.append(("tiny_raw_8b", tiny_pats, {"OUTPUT_MODE": 1, "BPC": 8}))

    results: dict[str, dict[str, int]] = {}
    for tag, pat, mo in configs:
        results[tag] = run_one(tag, pat, mo)

    # Markdown table
    print("\n\n## Resource matrix (synth-only, xc7a100tcsg324-1)\n")
    print("| Config | LUT | FF | BRAM36 | DSP |")
    print("|---|---|---|---|---|")
    for tag, _, _ in configs:
        u = results.get(tag, {})
        print(f"| `{tag}` | {u.get('LUT','?')} | {u.get('FF','?')} | {u.get('BRAM36','?')} | {u.get('DSP','?')} |")

    # CSV dump
    csv = RESULTS / "matrix.csv"
    with csv.open("w") as f:
        f.write("config,LUT,FF,BRAM36,DSP\n")
        for tag, _, _ in configs:
            u = results.get(tag, {})
            f.write(f"{tag},{u.get('LUT','')},{u.get('FF','')},{u.get('BRAM36','')},{u.get('DSP','')}\n")
    print(f"\nCSV: {csv}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
