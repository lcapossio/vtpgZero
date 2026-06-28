#!/usr/bin/env python3
"""Run the stateful-pattern AXIS alignment regression with Icarus Verilog."""

from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "sim" / "state_align_tb.vvp"


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
            "tb/tb_state_align.v",
            "rtl/vtpgz_core.v",
        ]
    )
    run(["vvp", str(OUT)])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
