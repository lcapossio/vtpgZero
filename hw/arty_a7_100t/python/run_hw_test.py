#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Leonardo Capossio - bard0 design - hello@bard0.com
# SPDX-License-Identifier: Apache-2.0
"""
vtpgZero hardware integration test on Arty A7-100T.

Runs all 9 patterns through the FPGA and checks each captured frame
against the bit-exact Python model. The build-time output mode (RGB /
RAW / YUV) and BPC are read back from the COLOR_FORMAT register so the
script automatically matches whatever bitstream is loaded; CLI flags
let you override.

Pipeline per pattern:
  1. Write VTPGZ configuration registers via the fpgacapZero EJTAG-AXI bridge
  2. Arm frame_capture
  3. Enable VTPGZ (CONTROL[0])
  4. Poll CAPTURE_STATUS until done
  5. Burst-read the captured frame from BRAM
  6. Compare to render_frame(cfg) byte-exact
  7. Disable VTPGZ, clear capture for next iteration

Requires:
  - Vivado / xsdb on PATH (Xilinx hw_server backend)
  - Bitstream at hw/arty_a7_100t/build/demo_top.bit (or pass --bit)
  - Arty A7-100T board connected via USB

Usage:
  python hw/arty_a7_100t/python/run_hw_test.py
  python hw/arty_a7_100t/python/run_hw_test.py --bit other.bit --skip-program
"""
from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

# Make the repo-local vtpgz model and the fcapz submodule importable.
HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parents[2]
FCAPZ_HOST = REPO_ROOT / "fcapz" / "host"
if not (FCAPZ_HOST / "fcapz" / "ejtagaxi.py").exists():
    raise SystemExit(
        "ERROR: fcapz submodule is missing or incomplete. "
        "Run 'git submodule update --init --recursive'."
    )
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(FCAPZ_HOST))

from fcapz.transport import XilinxHwServerTransport  # noqa: E402
from fcapz.ejtagaxi import EjtagAxiController, AXIError  # noqa: E402
from vtpgz_model import (  # noqa: E402
    VtpgzConfig, VtpgzRegs, render_frame, tdata_to_bram_words,
    MODE_RGB, MODE_RAW, MODE_YUV,
    YUV_444, YUV_422,
    RAW_PLAIN, RAW_RGGB, RAW_BGGR, RAW_GRBG, RAW_GBRG,
    RGB_ORDER_XILINX, RGB_ORDER_LEGACY,
)

# Build-time mode of the loaded bitstream. The vtpgZero IP exposes the
# build configuration via the COLOR_FORMAT register read-back. Defaults
# match demo_top.v's localparams (RGB 8bpc, Xilinx packing, RGGB Bayer).
MODE_MAP = {"rgb": MODE_RGB, "raw": MODE_RAW, "yuv": MODE_YUV}
SUB_MAP  = {"444": YUV_444, "422": YUV_422}
BAYER_MAP = {"plain": RAW_PLAIN, "rggb": RAW_RGGB, "bggr": RAW_BGGR,
             "grbg": RAW_GRBG, "gbrg": RAW_GBRG}
ORDER_MAP = {"xilinx": RGB_ORDER_XILINX, "legacy": RGB_ORDER_LEGACY}

# ─── address map (must match demo_top.v) ───────────────────────────
VTPGZ_BASE = 0x0000_0000
FC_BASE  = 0x0001_0000

# VTPGZ register offsets (must match rtl/vtpgz_defs.vh)
VTPGZ_CORE_ID       = 0x00
VTPGZ_VERSION       = 0x04
VTPGZ_CONTROL       = 0x08
VTPGZ_STATUS        = 0x0C
VTPGZ_IMG_WIDTH     = 0x10
VTPGZ_IMG_HEIGHT    = 0x14
VTPGZ_PATTERN_SEL   = 0x18
VTPGZ_COLOR_FORMAT  = 0x1C
VTPGZ_SOLID_COLOR   = 0x20
VTPGZ_BOX_COLOR     = 0x24
VTPGZ_BOX_SIZE      = 0x28
VTPGZ_BOX_SPEED     = 0x2C
VTPGZ_GRID_SPACING  = 0x34
VTPGZ_GRID_COLOR    = 0x38
VTPGZ_CHECKER_SIZE  = 0x3C
VTPGZ_FRAME_RATE    = 0x40
VTPGZ_BAR_WIDTH     = 0x44
VTPGZ_HG_STEP       = 0x48
VTPGZ_VG_STEP       = 0x4C
VTPGZ_BOX_BORDER    = 0x50
VTPGZ_CORE_ID_MAGIC = 0x47505456  # little-endian "VTPG"

# Frame-capture CSR offsets
FC_CTRL    = 0x0000
FC_STATUS  = 0x0004
FC_BRAM    = 0x8000  # offset within FC_BASE (must match awaddr[15] split in frame_capture.v)

# Test geometry (must fit in BRAM = 8K words = 32 KB; 64x32 = 2048 words ✓)
WIDTH, HEIGHT = 64, 32

DEFAULT_BIT = HERE.parent / "build" / "demo_top.bit"


def cfg_for(pat: int, mode: int, bpc: int, sub: int,
            bayer: int, order: int) -> VtpgzConfig:
    return VtpgzConfig(
        width=WIDTH, height=HEIGHT,
        pattern=pat,
        output_mode=mode, yuv_subsample=sub, raw_bayer=bayer,
        rgb_order=order, bpc=bpc,
        bar_width=WIDTH // 8,
        hg_step=0xFFF // (WIDTH - 1),
        vg_step=0xFFF // (HEIGHT - 1),
        checker_size=16,
        grid_spacing=16,
        box_width=16, box_height=16,
        box_dx=1, box_dy=1,
    )


def configure_vtpgz(axi: EjtagAxiController, cfg: VtpgzConfig) -> None:
    axi.axi_write(VTPGZ_BASE + VTPGZ_CONTROL,      0)
    axi.axi_write(VTPGZ_BASE + VTPGZ_IMG_WIDTH,    cfg.width)
    axi.axi_write(VTPGZ_BASE + VTPGZ_IMG_HEIGHT,   cfg.height)
    axi.axi_write(VTPGZ_BASE + VTPGZ_BAR_WIDTH,    cfg.bar_width)
    axi.axi_write(VTPGZ_BASE + VTPGZ_HG_STEP,      cfg.hg_step)
    axi.axi_write(VTPGZ_BASE + VTPGZ_VG_STEP,      cfg.vg_step)
    axi.axi_write(VTPGZ_BASE + VTPGZ_CHECKER_SIZE, cfg.checker_size)
    axi.axi_write(VTPGZ_BASE + VTPGZ_GRID_SPACING, cfg.grid_spacing)
    axi.axi_write(VTPGZ_BASE + VTPGZ_BOX_SIZE,
                  ((cfg.box_width & 0xFFFF) << 16) | (cfg.box_height & 0xFFFF))
    axi.axi_write(VTPGZ_BASE + VTPGZ_BOX_SPEED,
                  ((cfg.box_dx & 0xFFFF) << 16) | (cfg.box_dy & 0xFFFF))
    axi.axi_write(VTPGZ_BASE + VTPGZ_PATTERN_SEL,  cfg.pattern)
    # COLOR_FORMAT is RO now (build-time)
    axi.axi_write(VTPGZ_BASE + VTPGZ_FRAME_RATE,   200)


def run_one(axi: EjtagAxiController, cfg: VtpgzConfig,
            verbose: bool = False) -> tuple[bool, str]:
    """Run a single (pat, fmt, bpp) and return (passed, error_msg)."""
    # 1. Disable VTPGZ, then configure
    axi.axi_write(VTPGZ_BASE + VTPGZ_CONTROL, 0)
    configure_vtpgz(axi, cfg)
    # 2. Clear capture (resets done and word_count)
    axi.axi_write(FC_BASE + FC_CTRL, 0x2)  # clear
    sts0 = axi.axi_read(FC_BASE + FC_STATUS)
    if verbose: print(f"  after clear: status=0x{sts0:08X}")
    # 3. Arm
    axi.axi_write(FC_BASE + FC_CTRL, 0x1)  # arm
    sts1 = axi.axi_read(FC_BASE + FC_STATUS)
    if verbose: print(f"  after arm:   status=0x{sts1:08X}")
    if sts1 & 0x1:
        return False, f"done was already set after arm: status=0x{sts1:08X}"
    # 4. Enable VTPGZ
    axi.axi_write(VTPGZ_BASE + VTPGZ_CONTROL, 0x1)
    # 5. Poll done (timeout ~3 s)
    deadline = time.time() + 3.0
    word_count = 0
    sts = 0
    while time.time() < deadline:
        sts = axi.axi_read(FC_BASE + FC_STATUS)
        word_count = (sts >> 16) & 0xFFFF
        if sts & 0x1:
            break
    else:
        axi.axi_write(VTPGZ_BASE + VTPGZ_CONTROL, 0)
        return False, f"timeout (status=0x{sts:08X}, words={word_count})"
    if verbose: print(f"  after capture: status=0x{sts:08X} words={word_count}")
    # 5. Burst-read the frame
    expected_words = cfg.width * cfg.height
    if word_count < expected_words:
        axi.axi_write(VTPGZ_BASE + VTPGZ_CONTROL, 0)
        return False, f"short frame: got {word_count} expected {expected_words}"
    # Use the bridge's auto-increment read_block (batched raw_dr scans)
    # for ~80 KB/s throughput instead of ~1 KB/s from per-op burst_read.
    try:
        hw_words = axi.read_block(FC_BASE + FC_BRAM, expected_words)
    except AXIError as e:
        axi.axi_write(VTPGZ_BASE + VTPGZ_CONTROL, 0)
        return False, f"read_block failed: {e}"
    # 6. Render reference and compare
    sw_words = tdata_to_bram_words(render_frame(cfg), cfg.tdata_width)
    # 7. Disable
    axi.axi_write(VTPGZ_BASE + VTPGZ_CONTROL, 0)

    if hw_words != sw_words:
        first_diff = next(
            (i for i, (a, b) in enumerate(zip(hw_words, sw_words)) if a != b),
            min(len(hw_words), len(sw_words)),
        )
        if verbose:
            print(f"  hw[0..7] = {[f'0x{w:08X}' for w in hw_words[:8]]}")
            print(f"  sw[0..7] = {[f'0x{w:08X}' for w in sw_words[:8]]}")
            n_zero = sum(1 for w in hw_words if w == 0)
            print(f"  hw zero count = {n_zero}/{len(hw_words)}")
            # Indices of first 30 zeros
            zeros = [i for i, w in enumerate(hw_words) if w == 0][:30]
            print(f"  zero indices = {zeros}")
        return False, (
            f"mismatch @{first_diff}: "
            f"hw=0x{hw_words[first_diff]:08X} sw=0x{sw_words[first_diff]:08X}"
        )
    return True, ""


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--bit", type=Path, default=DEFAULT_BIT)
    ap.add_argument("--skip-program", action="store_true",
                    help="skip programming the FPGA (assume already loaded)")
    ap.add_argument("--port", type=int, default=3121)
    ap.add_argument("--device", default="xc7a100t")
    ap.add_argument("--only", type=int, help="only run pattern <N>")
    # Build-time mode of the loaded bitstream. The script can autodetect
    # this from the COLOR_FORMAT register read-back, but you can override.
    ap.add_argument("--mode", choices=list(MODE_MAP.keys()), default=None)
    ap.add_argument("--bpc", type=int, choices=[8, 10, 12, 14, 16], default=None)
    ap.add_argument("--yuv-sub", choices=list(SUB_MAP.keys()), default=None)
    ap.add_argument("--raw-bayer", choices=list(BAYER_MAP.keys()), default=None)
    ap.add_argument("--rgb-order", choices=list(ORDER_MAP.keys()), default=None)
    args = ap.parse_args()

    if not args.skip_program and not args.bit.exists():
        print(f"ERROR: bitstream {args.bit} not found. Run build.py first or "
              f"pass --skip-program if the board is already loaded.",
              file=sys.stderr)
        return 2

    # The fpgacapZero transport requires forward slashes in the bitfile path
    # for the embedded xsdb TCL command, even on Windows.
    bit_str = str(args.bit).replace("\\", "/") if not args.skip_program else None
    transport = XilinxHwServerTransport(
        port=args.port, fpga_name=args.device,
        bitfile=bit_str,
        # The transport's built-in post-program probe polls register 0x0000
        # on its default _active_chain (USER1) -- but our bridge lives on
        # USER4 (CHAIN=4 below).  bridge.connect() doesn't call
        # select_chain() until after transport.connect() returns, so the
        # auto-probe always reads zeros and times out.  Disable it; the
        # bridge does its own identity scan on the right chain.
        ready_probe_addr=None,
    )
    bridge = EjtagAxiController(transport, chain=4)

    fails: list[tuple[int, str]] = []
    n = 0
    try:
        # Probe identity
        info = bridge.connect()
        print(f"Bridge: id=0x{info['bridge_id']:08X} "
              f"v{info['version_major']}.{info['version_minor']} "
              f"addr_w={info['addr_w']} data_w={info['data_w']}")

        # Sanity: confirm we're talking to a vtpgZero core (CORE_ID is a
        # fixed magic at offset 0x00, ASCII "VTPG" little-endian).
        core_id = bridge.axi_read(VTPGZ_BASE + VTPGZ_CORE_ID)
        if core_id != VTPGZ_CORE_ID_MAGIC:
            print(f"ERROR: VTPGZ CORE_ID = 0x{core_id:08X} "
                  f"(expected 0x{VTPGZ_CORE_ID_MAGIC:08X} 'VTPG'). "
                  f"Wrong bitstream / wrong base address.", file=sys.stderr)
            return 2
        print(f"VTPGZ CORE_ID = 0x{core_id:08X} (\"VTPG\")")
        ver = bridge.axi_read(VTPGZ_BASE + VTPGZ_VERSION)
        print(f"VTPGZ VERSION = 0x{ver:08X}")

        # Read COLOR_FORMAT to discover the build-time configuration
        cf = bridge.axi_read(VTPGZ_BASE + VTPGZ_COLOR_FORMAT)
        rb_mode  =  cf        & 0x3
        rb_sub   = (cf >> 2)  & 0x1
        rb_bayer = (cf >> 3)  & 0x7
        rb_order = (cf >> 6)  & 0x1
        rb_bpc   = (cf >> 8)  & 0xFF
        rb_tw    = (cf >> 16) & 0xFFFF
        print(f"Build cfg: mode={rb_mode} sub={rb_sub} bayer={rb_bayer} "
              f"order={rb_order} bpc={rb_bpc} tdata_width={rb_tw}")

        # CLI overrides take precedence over the read-back, but warn the
        # user if the override actually disagrees with the loaded
        # bitstream -- otherwise the model<->HW compare silently mismatches
        # because the host is rendering against the wrong build
        # configuration.
        def _override(name: str, cli_val, rb_val, mapping=None):
            if cli_val is None:
                return rb_val
            mapped = mapping[cli_val] if mapping else cli_val
            if mapped != rb_val:
                print(f"WARNING: --{name}={cli_val} overrides bitstream "
                      f"readback ({rb_val}). The HW capture will only match "
                      f"the model if the bitstream really has that build.",
                      file=sys.stderr)
            return mapped

        mode  = _override("mode",      args.mode,      rb_mode,  MODE_MAP)
        bpc   = _override("bpc",       args.bpc,       rb_bpc)
        sub   = _override("yuv-sub",   args.yuv_sub,   rb_sub,   SUB_MAP)
        bayer = _override("raw-bayer", args.raw_bayer, rb_bayer, BAYER_MAP)
        order = _override("rgb-order", args.rgb_order, rb_order, ORDER_MAP)

        pats = [args.only] if args.only is not None else list(range(9))

        for pat in pats:
            n += 1
            cfg = cfg_for(pat, mode, bpc, sub, bayer, order)
            ok, err = run_one(bridge, cfg, verbose=(args.only is not None))
            tag = "OK  " if ok else "FAIL"
            print(f"  {tag}  pat={pat}" + (f"  {err}" if err else ""))
            if not ok:
                fails.append((pat, err))
    finally:
        try:    bridge.close()
        except Exception: pass

    print()
    print(f"Ran {n} patterns, {len(fails)} failures")
    if fails:
        for f in fails[:20]:
            print(f"  FAIL pat={f[0]}: {f[1]}")
        return 1
    print("HW PASS — byte-exact across all patterns")
    return 0


if __name__ == "__main__":
    sys.exit(main())
