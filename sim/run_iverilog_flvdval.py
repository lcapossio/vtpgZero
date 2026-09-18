#!/usr/bin/env python3
"""Run the FVAL/LVAL/DVAL parallel-video adapter regressions with Icarus.

Two benches: tb_flvdval (the adapter itself) and tb_gapfree, swept over
configurations, which pins down the gap-free-line assumption the adapter has
no FIFO to survive without.
"""

from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "sim" / "flvdval_tb.vvp"
OUT_GF = ROOT / "sim" / "gapfree_tb.vvp"

# (ppc, w, h, gap, rate, pattern, en_image)
GAPFREE_SWEEP = [
    (1, 32, 4, 1, 400, 0, 0),   # baseline
    (2, 32, 4, 1, 400, 0, 0),   # the pack stage at PPC>1
    (4, 32, 4, 1, 400, 0, 0),
    (8, 32, 4, 1, 400, 0, 0),
    (4, 32, 4, 3, 400, 8, 0),   # NOISE: leap-ahead LFSR
    (1, 32, 4, 1, 400, 9, 1),   # IMAGE: BRAM read in the pixel path
    (4, 32, 4, 1, 400, 9, 1),
    (4, 30, 4, 1, 400, 0, 0),   # width not a multiple of PPC (clamped)
    (1, 32, 1, 1, 400, 0, 0),   # single-line frame
    (1, 32, 4, 1, 132, 0, 0),   # minimum vertical blanking (1 cycle)
    (1, 32, 4, 1, 100, 0, 0),   # sync ticks dropped: period is a multiple
]


def run(cmd: list[str], quiet: bool = False) -> None:
    if not quiet:
        print("+ " + " ".join(cmd), flush=True)
    subprocess.run(cmd, cwd=ROOT, check=True)


def main() -> int:
    if shutil.which("iverilog") is None:
        print("ERROR: 'iverilog' not found in PATH.", file=sys.stderr)
        return 2
    if shutil.which("vvp") is None:
        print("ERROR: 'vvp' not found in PATH.", file=sys.stderr)
        return 2

    run(
        [
            "iverilog",
            "-g2001",
            "-Wall",
            "-I",
            "rtl",
            "-o",
            str(OUT),
            "tb/tb_flvdval.v",
            "rtl/vtpgz_core.v",
            "rtl/vtpgz_axil_regs.v",
            "rtl/vtpgz_axilite_top.v",
            "rtl/vtpgz_axis_to_flvdval.v",
        ]
    )

    print("+ vvp " + str(OUT), flush=True)
    proc = subprocess.run(
        ["vvp", str(OUT)], cwd=ROOT, check=True, capture_output=True, text=True
    )
    sys.stdout.write(proc.stdout)
    sys.stderr.write(proc.stderr)
    if "PASS: tb_flvdval" not in proc.stdout:
        print("ERROR: tb_flvdval did not report PASS.", file=sys.stderr)
        return 1

    # ---- the gap-free assumption, swept over configurations ----
    for ppc, w, h, gap, rate, pat, img in GAPFREE_SWEEP:
        run(
            [
                "iverilog", "-g2001", "-Wall", "-I", "rtl", "-o", str(OUT_GF),
                "-s", "tb_gapfree",
                f"-Ptb_gapfree.PPC={ppc}", f"-Ptb_gapfree.W={w}",
                f"-Ptb_gapfree.H={h}", f"-Ptb_gapfree.GAP={gap}",
                f"-Ptb_gapfree.RATE={rate}", f"-Ptb_gapfree.PAT={pat}",
                f"-Ptb_gapfree.ENIMG={img}",
                "tb/tb_gapfree.v",
                "rtl/vtpgz_core.v",
                "rtl/vtpgz_axil_regs.v",
                "rtl/vtpgz_axilite_top.v",
                "rtl/vtpgz_axis_to_flvdval.v",
            ],
            quiet=True,
        )
        p = subprocess.run(
            ["vvp", str(OUT_GF)], cwd=ROOT, check=True,
            capture_output=True, text=True,
        )
        line = next((ln for ln in p.stdout.splitlines()
                     if ln.startswith(("PASS: tb_gapfree", "FAIL: tb_gapfree",
                                       "ERROR:"))), "")
        print("  " + (line or p.stdout.strip()), flush=True)
        if "PASS: tb_gapfree" not in p.stdout:
            print("ERROR: tb_gapfree did not report PASS.", file=sys.stderr)
            return 1

    print("PASS: parallel video adapter + gap-free assumption "
          f"({len(GAPFREE_SWEEP)} configs)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
