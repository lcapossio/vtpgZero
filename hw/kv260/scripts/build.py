#!/usr/bin/env python3
"""
build.py -- Build the vtpgZero KV260 bare-metal DP demo.

Author: Leonardo Capossio - bard0 design - hello@bard0.com
Year:   2026

Tool resolution (PATH first, then env vars, then error):
  - aarch64-none-elf-gcc       (or $AARCH64_GCC)
  - BSP include + lib dirs     ($KV260_BSP_DIR pointing at hw_platform/)

The BSP path is required because this app links against an existing Vitis-built
libxil.a containing the dppsu/avbuf drivers. Set:
  KV260_BSP_DIR=/path/to/hw_platform
where hw_platform contains
  export/hw_platform/sw/hw_platform/standalone_domain/bspinclude/include
  psu_cortexa53_0/standalone_domain/bsp/psu_cortexa53_0/lib
"""

import os
import shutil
import subprocess
import sys
from pathlib import Path

KV_DIR = Path(__file__).resolve().parents[1]

TARGETS = {
    # name -> (src, out_elf, fp_enabled)
    # Reason: MMU is OFF after rst -clear-registers, so DDR is treated as
    # device memory which does not allow unaligned ldp/stp (libc memcpy
    # crashes). Keep -mgeneral-regs-only and use the scalar memcpy override
    # in the application.
    "box": (KV_DIR / "src" / "dp_vtpgzero_box.c",
            KV_DIR / "build" / "dp_vtpgzero_box.elf",
            False),
}


def resolve_tool(name: str, env_var: str, well_known: list[Path]) -> str:
    p = shutil.which(name)
    if p:
        return p
    p = os.environ.get(env_var)
    if p and Path(p).exists():
        return p
    for cand in well_known:
        if cand.is_file():
            return str(cand)
    sys.exit(f"ERROR: '{name}' not in PATH and ${env_var} is not set.")


def resolve_bsp() -> tuple[Path, Path]:
    bsp = os.environ.get("KV260_BSP_DIR")
    if not bsp:
        sys.exit("ERROR: $KV260_BSP_DIR not set. Point it at the Vitis "
                 "hw_platform/ directory containing bspinclude/ and the "
                 "psu_cortexa53_0 standalone BSP lib/.")
    bsp_path = Path(bsp).resolve()
    inc = bsp_path / "export" / "hw_platform" / "sw" / "hw_platform" / \
          "standalone_domain" / "bspinclude" / "include"
    lib = bsp_path / "psu_cortexa53_0" / "standalone_domain" / "bsp" / \
          "psu_cortexa53_0" / "lib"
    if not inc.is_dir():
        sys.exit(f"ERROR: BSP include dir not found: {inc}")
    if not (lib / "libxil.a").is_file():
        sys.exit(f"ERROR: libxil.a not found under: {lib}")
    return inc, lib


def find_dppsu_sources(bsp_root: Path) -> list[Path]:
    """The libxil.a in this BSP does not contain the patched xdppsu_serdes /
    xdppsu sources needed for bare-metal link training. Compile them inline so
    they override the archive at link time."""
    libsrc = bsp_root / "psu_cortexa53_0" / "standalone_domain" / "bsp" / \
             "psu_cortexa53_0" / "libsrc"
    # dppsu_v1_7: xdppsu.c carries the patches; xdppsu_serdes.c needs the
    # SetVswingPreemp no-op patch. Skip xdppsu_spm.c (uses FP, breaks
    # -mgeneral-regs-only).
    pattern = libsrc / "dppsu_v1_7" / "src"
    if not pattern.is_dir():
        return []
    files = [pattern / "xdppsu.c", pattern / "xdppsu_serdes.c"]
    # Local patched copy of xdppsu_spm.c with nearbyint() replaced by integer
    # math. The original uses FP/SIMD which is incompatible with our
    # -mgeneral-regs-only build context. Skipping it entirely (the original
    # behaviour) means XDpPsu_SetColorEncode / CfgMsaSetBpc /
    # CfgMsaUseStandardVideoMode get pulled from libxil.a's stale .o which
    # crashes for the same NEON-codegen reason as the other dppsu files.
    spm_patched = KV_DIR / "src" / "xdppsu_spm_patched.c"
    if spm_patched.is_file():
        files.append(spm_patched)
    # dpdma_v1_6: the libxil.a copy was compiled with FP enabled and uses
    # NEON q-regs in struct copies / memsets. Recompile here with our flags
    # so it falls back to scalar moves. Without this, XDpDma_CfgInitialize
    # traps at PC=0x200 from a `movi v0.4s, #0` instruction.
    dpdma_dir = libsrc / "dpdma_v1_6" / "src"
    for n in ("xdpdma.c", "xdpdma_intr.c"):
        f = dpdma_dir / n
        if f.is_file():
            files.append(f)
    # avbuf_v2_6: same NEON-in-libxil.a problem. xavbuf.c is the main offender;
    # xavbuf_videoformats.c provides format tables. xavbuf_clk.c is left in the
    # archive (it has its own AVBuf_PllInitialize trace prints we want).
    avbuf = libsrc / "avbuf_v2_6" / "src"
    for n in ("xavbuf.c", "xavbuf_videoformats.c"):
        f = avbuf / n
        if f.is_file():
            files.append(f)
    return files


def main() -> int:
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--target", choices=sorted(TARGETS.keys()), default="box",
                    help="Which app to build (default: box)")
    args = ap.parse_args()
    src, out, fp = TARGETS[args.target]

    gcc = resolve_tool("aarch64-none-elf-gcc", "AARCH64_GCC", [])
    inc, lib = resolve_bsp()
    bsp_root = Path(os.environ["KV260_BSP_DIR"]).resolve()
    extra = find_dppsu_sources(bsp_root)
    out.parent.mkdir(parents=True, exist_ok=True)
    if out.exists():
        out.unlink()  # avoid running stale ELF if gcc fails

    cmd = [
        gcc,
        "-Wall", "-Wextra", "-O0", "-g3",
        "-nostartfiles",
        "-Wl,-e,_start",
        "-I", str(inc),
        str(src),
        *[str(p) for p in extra],
        "-L", str(lib),
        "-Wl,--start-group", "-lxil", "-lgcc", "-lc", "-lstdc++",
        "-Wl,--end-group",
        "-o", str(out),
    ]
    if not fp:
        cmd.insert(5, "-mgeneral-regs-only")
    print("[build]", " ".join(cmd))
    rc = subprocess.call(cmd)
    if rc != 0:
        return rc
    print(f"[build] OK: {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
