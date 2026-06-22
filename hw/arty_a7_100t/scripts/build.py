#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Leonardo Capossio - bard0 design - hello@bard0.com
# SPDX-License-Identifier: Apache-2.0
"""
Build the vtpgZero Arty A7-100T bitstream by invoking Vivado in batch mode.

Locates `vivado` on PATH (per OPENSOURCE.md/PROJECTS.md), warns if missing,
runs scripts/build.tcl, and exits with the Vivado return code. Pass-through
for stdout so progress is visible.

Usage:
    python hw/arty_a7_100t/scripts/build.py
"""
from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path


def main() -> int:
    here = Path(__file__).resolve().parent
    tcl  = here / "build.tcl"
    if not tcl.exists():
        print(f"ERROR: {tcl} missing", file=sys.stderr)
        return 2

    vivado = shutil.which("vivado")
    if not vivado:
        # On Windows, the binary may be vivado.bat
        vivado = shutil.which("vivado.bat")
    if not vivado:
        print("ERROR: 'vivado' not found in PATH. Source the Vivado settings"
              " script (settings64.sh / settings64.bat) and try again.",
              file=sys.stderr)
        return 3

    print(f"Using vivado: {vivado}")
    print(f"Running: {tcl}")
    cmd = [vivado, "-mode", "batch", "-source", str(tcl), "-nojournal", "-nolog"]
    return subprocess.call(cmd)


if __name__ == "__main__":
    sys.exit(main())
