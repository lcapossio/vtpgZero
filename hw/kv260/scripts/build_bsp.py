#!/usr/bin/env python3
"""
build_bsp.py -- Build a fresh standalone BSP from a Vitis XSA via XSCT.

Author: Leonardo Capossio - bard0 design - hello@bard0.com
Year:   2026

Creates a Vitis workspace at hw/kv260/build/bsp_<xsa-name>, runs
`platform create + platform generate`, and produces a libxil.a + headers
that hw/kv260/scripts/build.py can link against.

Usage:
    python hw/kv260/scripts/build_bsp.py hw/kv260/build/pl/vtpgzero_kv260.xsa

Env var fallback:
    KV260_XSA=/path/to/file.xsa python hw/kv260/scripts/build_bsp.py

After it succeeds, set $KV260_BSP_DIR to the printed path and rebuild the
apps with `python hw/kv260/scripts/build.py --target box`.
"""

import os
import shutil
import subprocess
import sys
from pathlib import Path

KV_DIR = Path(__file__).resolve().parents[1]

def find_xsct() -> str:
    is_win = sys.platform.startswith("win")
    wanted = "xsct.bat" if is_win else "xsct"
    p = shutil.which(wanted) or shutil.which("xsct")
    if p:
        return p
    p = os.environ.get("XSCT")
    if p and Path(p).exists():
        return p
    sys.exit("ERROR: xsct not found in PATH and $XSCT is not set.")


def main() -> int:
    xsa_arg = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("KV260_XSA")
    if not xsa_arg:
        sys.exit("Usage: build_bsp.py <path-to-xsa>  (or set $KV260_XSA)")
    xsa = Path(xsa_arg).resolve()
    if not xsa.is_file():
        sys.exit(f"ERROR: XSA not found: {xsa}")

    ws = KV_DIR / "build" / f"bsp_{xsa.stem}"
    if ws.exists():
        print(f"[bsp] removing stale workspace {ws}")
        shutil.rmtree(ws)
    ws.mkdir(parents=True)

    xsct = find_xsct()

    tcl = f"""\
setws {ws.as_posix()}
platform create -name hw_platform -hw {xsa.as_posix()} -proc psu_cortexa53_0 -os standalone
platform generate
puts "BSP generation complete"
"""
    tcl_file = ws / "_build.tcl"
    tcl_file.write_text(tcl)

    print(f"[bsp] xsct {tcl_file}")
    if xsct.lower().endswith(".bat"):
        rc = subprocess.call(["cmd", "/c", xsct, str(tcl_file)])
    else:
        rc = subprocess.call([xsct, str(tcl_file)])
    if rc != 0:
        print(f"[bsp] xsct failed (rc={rc})")
        return rc

    # Vitis 2025.2 layout: ws/hw_platform/...
    bsp_root = ws / "hw_platform"
    libxil = bsp_root / "psu_cortexa53_0" / "standalone_domain" / "bsp" / \
             "psu_cortexa53_0" / "lib" / "libxil.a"
    if not libxil.is_file():
        print(f"[bsp] ERROR: libxil.a not produced at {libxil}")
        return 1

    # Patch xdppsu_serdes.c::XDpPsu_SetVswingPreemp to skip the SERDES drive-
    # strength register writes (they hang AXI under -clear-registers boot)
    # and replace memset() with scalar fills (memset traps under
    # -mgeneral-regs-only). This is the same patch as the one in the prior
    # KV260 DP bring-up; we apply it programmatically so a fresh BSP always
    # works without manual editing.
    serdes = bsp_root / "psu_cortexa53_0" / "standalone_domain" / "bsp" / \
             "psu_cortexa53_0" / "libsrc" / "dppsu_v1_7" / "src" / "xdppsu_serdes.c"
    if serdes.is_file():
        text = serdes.read_text()
        marker = "PATCH (bard0 design"
        if marker not in text:
            old = ("\tmemset(AuxData, Data, 4);\n"
                   "\n"
                   "\tXDpPsu_SetSerdesVswingPreemp(InstancePtr);\n"
                   "\treturn;")
            new = ("\t/* PATCH (bard0 design 2026): scalar fill instead of\n"
                   "\t * memset() (NEON-incompatible) and skip the SERDES\n"
                   "\t * drive-strength writes which hang AXI under our\n"
                   "\t * -clear-registers boot context. */\n"
                   "\tAuxData[0] = Data;\n"
                   "\tAuxData[1] = Data;\n"
                   "\tAuxData[2] = Data;\n"
                   "\tAuxData[3] = Data;\n"
                   "\treturn;")
            if old in text:
                serdes.write_text(text.replace(old, new))
                print(f"[bsp] patched {serdes.name}")
            else:
                print(f"[bsp] WARNING: could not find patch site in {serdes.name}")
        else:
            print(f"[bsp] {serdes.name} already patched")
    print()
    print(f"[bsp] OK: {bsp_root}")
    print(f"[bsp] libxil.a: {libxil}")
    print()
    print("Set this and rebuild the apps:")
    print(f'  export KV260_BSP_DIR="{bsp_root.as_posix()}"   # bash')
    print(f'  set KV260_BSP_DIR={bsp_root}                   # cmd')
    return 0


if __name__ == "__main__":
    sys.exit(main())
