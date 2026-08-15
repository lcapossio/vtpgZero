#!/usr/bin/env python3
"""Run the AXI4-Stream routing sideband (TID/TDEST) regression with Icarus."""

from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "sim" / "stream_route_tb.vvp"


def run(cmd: list[str]) -> None:
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
            "-g2012",
            "-Wall",
            "-I",
            "rtl",
            "-o",
            str(OUT),
            "tb/tb_stream_route.v",
            "rtl/vtpgz_core.v",
            "rtl/vtpgz_axil_regs.v",
            "rtl/vtpgz_axilite_top.v",
        ]
    )

    print("+ vvp " + str(OUT), flush=True)
    proc = subprocess.run(
        ["vvp", str(OUT)], cwd=ROOT, check=True, capture_output=True, text=True
    )
    sys.stdout.write(proc.stdout)
    sys.stderr.write(proc.stderr)
    if "PASS: tb_stream_route" not in proc.stdout:
        print("ERROR: tb_stream_route did not report PASS.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
