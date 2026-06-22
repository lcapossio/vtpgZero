#!/usr/bin/env python3
"""
build_pl.py -- Build the vtpgZero KV260 PL bitstream + XSA from scratch.

Author: Leonardo Capossio - bard0 design - hello@bard0.com
Year:   2026

Calls Vivado in batch mode to:
  1. Create a fresh project under build/pl/project
  2. Build the PS block design (hw/kv260/vivado/build_bd.tcl)
  3. Add the repo vtpgZero RTL + KV260 DDR writer as RTL sources
  4. Synth + impl + write_bitstream
  5. Export hw/kv260/build/pl/vtpgzero_kv260.xsa

Tool resolution (PATH first, then env var):
    vivado   -- Vivado batch tool  ($VIVADO fallback)

Run:
    python hw/kv260/scripts/build_pl.py

Long-running (~25 min on a Zynq UltraScale+ design). The Vivado log goes
to build/pl/vivado.log so you can `tail -f` it from another shell.
"""

import os
import shutil
import subprocess
import sys
from pathlib import Path

KV_DIR = Path(__file__).resolve().parents[1]
REPO = Path(__file__).resolve().parents[3]
OUT = KV_DIR / "build" / "pl"

def find_vivado() -> str:
    is_win = sys.platform.startswith("win")
    cand_names = ("vivado.bat", "vivado") if is_win else ("vivado",)
    for n in cand_names:
        p = shutil.which(n)
        if p:
            return p
    p = os.environ.get("VIVADO")
    if p and Path(p).exists():
        return p
    sys.exit("ERROR: vivado not in PATH and $VIVADO is not set.")


def main() -> int:
    vivado = find_vivado()
    OUT.mkdir(parents=True, exist_ok=True)
    log = OUT / "vivado.log"

    env = os.environ.copy()
    env["VTPGZ_REPO"] = str(REPO).replace("\\", "/")
    env["VTPGZ_KV260_OUT"] = str(OUT).replace("\\", "/")

    cmd = [vivado, "-mode", "batch", "-nolog", "-nojournal",
           "-source", str((KV_DIR / "vivado" / "build_pl.tcl").resolve())]
    print(f"[pl] vivado: {vivado}")
    print(f"[pl] log:    {log}")
    print(f"[pl] cmd:    {' '.join(cmd)}")
    print(f"[pl] expect: ~20-25 min for synth+impl+bitgen on KV260")

    is_bat = vivado.lower().endswith(".bat")
    if is_bat:
        cmd = ["cmd", "/c"] + cmd

    with open(log, "w") as f:
        proc = subprocess.Popen(cmd, env=env, stdout=f, stderr=subprocess.STDOUT)
        rc = proc.wait()

    if rc != 0:
        print(f"[pl] FAILED rc={rc} -- check {log}")
        return rc
    xsa = OUT / "vtpgzero_kv260.xsa"
    if not xsa.is_file():
        print(f"[pl] ERROR: XSA not produced at {xsa}")
        return 1
    bit_src = OUT / "project" / "vtpgzero_kv260.runs" / "impl_1" / "kv260_ps_wrapper.bit"
    bit_dst = OUT / "vtpgzero_kv260.bit"
    if bit_src.is_file():
        shutil.copy2(bit_src, bit_dst)
        print(f"[pl] bit:    {bit_dst}")
    else:
        print(f"[pl] WARNING: bitstream not found at {bit_src}")
    print()
    print(f"[pl] OK: {xsa}")
    print()
    print("Next:")
    print(f"  python hw/kv260/scripts/build_bsp.py {xsa.as_posix()}")
    print(f"  KV260_BSP_DIR=<bsp dir> python hw/kv260/scripts/build.py --target box")
    return 0


if __name__ == "__main__":
    sys.exit(main())
