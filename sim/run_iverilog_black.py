#!/usr/bin/env python3
"""Check that 'black' frames are black in YUV builds, with Icarus Verilog.

Sweeps PPC 1/2/4/8 x YUV_RANGE full/limited over tb/tb_black.v.
"""

from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def run(cmd: list[str]) -> subprocess.CompletedProcess:
    print("+ " + " ".join(cmd), flush=True)
    return subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)


def main() -> int:
    for tool in ("iverilog", "vvp"):
        if shutil.which(tool) is None:
            print(f"ERROR: '{tool}' not found in PATH.", file=sys.stderr)
            return 2

    failures = 0
    for ppc in (1, 2, 4, 8):
        for rng in (0, 1):
            out = ROOT / "sim" / f"black_p{ppc}_r{rng}.vvp"
            r = run(["iverilog", "-g2012", "-Wall", "-I", "rtl",
                     f"-Ptb_black.PPC={ppc}", f"-Ptb_black.RANGE={rng}",
                     "-o", str(out), "tb/tb_black.v", "rtl/vtpgz_core.v"])
            if r.returncode != 0:
                print(r.stdout + r.stderr)
                failures += 1
                continue
            r = run(["vvp", str(out)])
            lines = [ln for ln in (r.stdout + r.stderr).splitlines()
                     if ln.startswith(("PASS", "FAIL", "ERROR"))]
            print("\n".join(lines[-9:]))
            if r.returncode != 0 or not any(ln.startswith("PASS") for ln in lines):
                failures += 1

    if failures:
        print(f"\n{failures} tb_black configuration(s) failed")
        return 1
    print("\nALL tb_black configurations pass")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
