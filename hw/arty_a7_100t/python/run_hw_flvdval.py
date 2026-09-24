#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Leonardo Capossio - bard0 design - hello@bard0.com
# SPDX-License-Identifier: Apache-2.0
"""
FVAL/LVAL/DVAL parallel-video adapter check on the Arty A7-100T.

The demo builds vtpgz_axis_to_flvdval on the same stream the capture sink
sees, plus an flv_monitor that measures the emitted raster in fabric. Only
one consumer may own TREADY: FLV_MODE[0] hands it to the adapter, which ties
it high so the core free-runs gap-free -- the condition a parallel interface
needs, since it cannot express a stall.

PIX_DATA is PIXELS_PER_CLOCK * 24 = 96 bits in this build, far wider than the
board can bring out, so the pixel bus stays on-chip and what is verified here
is the TIMING, against the same arithmetic the README gives integrators:

    ACTIVE = (IMG_WIDTH / PPC) * IMG_HEIGHT + LINE_GAP_CYCLES * (IMG_HEIGHT-1)
    PERIOD = FRAME_RATE_DIV * (ACTIVE // FRAME_RATE_DIV + 1)
    VBLANK = PERIOD - ACTIVE

Asserted on hardware, all derived from the geometry rather than read back
from the adapter:

  * LVAL pulse min == max == IMG_WIDTH / PPC  (one short or long line moves
    min or max and cannot average away)
  * lines per frame == IMG_HEIGHT
  * vertical blanking min == max == VBLANK
  * TIMING_ERR clear, and DVAL never differed from LVAL
  * FIELD_ID sampled at the FVAL rising edge alternates for an interlaced
    source and stays 0 for a progressive one

Usage:
  python hw/arty_a7_100t/python/run_hw_flvdval.py
  python hw/arty_a7_100t/python/run_hw_flvdval.py --skip-program
"""
from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

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
from fcapz.ejtagaxi import EjtagAxiController  # noqa: E402
from run_hw_test import (  # noqa: E402
    VTPGZ_BASE, FC_BASE,
    VTPGZ_CORE_ID, VTPGZ_CONTROL, VTPGZ_VERSION, VTPGZ_STATUS,
    VTPGZ_IMG_WIDTH, VTPGZ_IMG_HEIGHT, VTPGZ_PATTERN_SEL,
    VTPGZ_FRAME_RATE, VTPGZ_PIXELS_PER_CLOCK, VTPGZ_BAR_WIDTH,
    VTPGZ_CORE_ID_MAGIC, DEFAULT_BIT,
)

# frame_capture CSRs used here
FC_CTRL       = 0x00
FC_FLV_MODE   = 0x10
FC_FLV_STATUS = 0x14
FC_FLV_LVAL   = 0x18
FC_FLV_VBLANK = 0x1C
FC_FLV_FID    = 0x20

FLV_MODE_PARALLEL = 0x1
FLV_MODE_CLEAR    = 0x2

CTRL_ENABLE    = 0x1
CTRL_INTERLACE = 0x8

# demo_top builds vtpgz_axilite_top without overriding LINE_GAP_CYCLES.
LINE_GAP_CYCLES = 1


def active_cycles(width: int, height: int, ppc: int) -> int:
    return (width // ppc) * height + LINE_GAP_CYCLES * (height - 1)


def expected_vblank(width: int, height: int, ppc: int, rate: int) -> int:
    """Vertical blanking, accounting for dropped sync ticks.

    A sync tick landing inside an active frame is ignored by the timing
    engine (including one coincident with the final active cycle), so the
    period is the first multiple of rate strictly greater than ACTIVE.
    """
    a = active_cycles(width, height, ppc)
    return rate * (a // rate + 1) - a


# flv_monitor counts blanking in a 16-bit register. A frame rate slow enough
# to blank for longer than this would wrap it and the comparison below would
# be meaningless, so every case is checked against it up front rather than
# silently mis-asserting.
VBLANK_COUNTER_MAX = 0xFFFF


def read_stats(axi: EjtagAxiController) -> dict:
    sts = axi.axi_read(FC_BASE + FC_FLV_STATUS)
    lv  = axi.axi_read(FC_BASE + FC_FLV_LVAL)
    vb  = axi.axi_read(FC_BASE + FC_FLV_VBLANK)
    fid = axi.axi_read(FC_BASE + FC_FLV_FID)
    return {
        "timing_err":  sts & 0x1,
        "dval_ne":    (sts >> 1) & 0x1,
        "frames":     (sts >> 8) & 0xFF,
        "lines":      (sts >> 16) & 0xFFFF,
        "lval_min":    lv & 0xFFFF,
        "lval_max":   (lv >> 16) & 0xFFFF,
        "vb_min":      vb & 0xFFFF,
        "vb_max":     (vb >> 16) & 0xFFFF,
        "fid_hist":    fid & 0xFF,
    }


STATUS_BUSY = 0x1


def quiesce(axi: EjtagAxiController) -> None:
    """Disable the core and let any in-flight frame drain before reprogramming.

    This is the core's documented reconfiguration contract: CONTROL=0, wait
    for the in-flight frame to finish, then reprogram. Skipping the wait is
    not harmless here. A test that ran before this one (run_hw_interlace, or
    run_hw_test) can leave a frame stalled mid-line, because frame_capture
    drops TREADY once its capture is done. Reprogramming over that frame and
    re-enabling makes the monitor measure its remainder -- on the board that
    read as a 14-beat line and a 36911-cycle blanking gap, a false failure.

    The drain needs TREADY, so hand it to the adapter (which ties it high)
    for the duration.
    """
    axi.axi_write(VTPGZ_BASE + VTPGZ_CONTROL, 0)
    axi.axi_write(FC_BASE + FC_FLV_MODE, FLV_MODE_PARALLEL)
    for _ in range(100):
        if not (axi.axi_read(VTPGZ_BASE + VTPGZ_STATUS) & STATUS_BUSY):
            return
        time.sleep(0.01)
    raise RuntimeError("core still busy 1 s after disable with TREADY high; "
                       "the in-flight frame never drained")


def run_case(axi: EjtagAxiController, name: str, width: int, height: int,
             ppc: int, rate: int, interlaced: bool,
             failures: list[str]) -> None:
    """Emit frames in parallel mode and check the measured raster."""
    quiesce(axi)
    axi.axi_write(VTPGZ_BASE + VTPGZ_IMG_WIDTH, width)
    axi.axi_write(VTPGZ_BASE + VTPGZ_IMG_HEIGHT, height)
    axi.axi_write(VTPGZ_BASE + VTPGZ_PATTERN_SEL, 0)      # colorbar
    axi.axi_write(VTPGZ_BASE + VTPGZ_BAR_WIDTH, max(width // 8, 1))
    axi.axi_write(VTPGZ_BASE + VTPGZ_FRAME_RATE, rate)

    # Hand TREADY to the adapter and zero the statistics, THEN enable, so the
    # measurement window contains only whole frames.
    axi.axi_write(FC_BASE + FC_FLV_MODE, FLV_MODE_PARALLEL | FLV_MODE_CLEAR)
    ctrl = CTRL_ENABLE | (CTRL_INTERLACE if interlaced else 0)
    axi.axi_write(VTPGZ_BASE + VTPGZ_CONTROL, ctrl)

    # Let frames accumulate. A JTAG round trip alone is far longer than a
    # frame at these rates, so this window holds many; the monitor's frame
    # count saturates at 255 rather than wrapping.
    time.sleep(0.2)
    st = read_stats(axi)
    axi.axi_write(VTPGZ_BASE + VTPGZ_CONTROL, 0)
    axi.axi_write(FC_BASE + FC_FLV_MODE, 0)               # back to capture

    exp_run = width // ppc
    exp_vb  = expected_vblank(width, height, ppc, rate)
    assert exp_vb <= VBLANK_COUNTER_MAX, (
        f"{name}: expected blanking {exp_vb} exceeds the monitor's 16-bit "
        f"counter; pick a faster FRAME_RATE_DIV for this geometry")
    fids    = [(st["fid_hist"] >> i) & 1 for i in range(7, -1, -1)]

    print(f"  {name}: frames={st['frames']} "
          f"LVAL={st['lval_min']}..{st['lval_max']} (exp {exp_run}) "
          f"lines={st['lines']} (exp {height}) "
          f"vblank={st['vb_min']}..{st['vb_max']} (exp {exp_vb}) "
          f"FID={fids} err={st['timing_err']}{st['dval_ne']}")

    if st["frames"] < 4:
        failures.append(f"{name}: only {st['frames']} frames seen")
        return
    if st["lval_min"] != exp_run or st["lval_max"] != exp_run:
        failures.append(
            f"{name}: LVAL pulse {st['lval_min']}..{st['lval_max']}, "
            f"expected exactly {exp_run} -- the source is not gap-free")
    if st["lines"] != height:
        failures.append(
            f"{name}: {st['lines']} lines per frame, expected {height}")
    if st["vb_min"] != exp_vb or st["vb_max"] != exp_vb:
        failures.append(
            f"{name}: vertical blanking {st['vb_min']}..{st['vb_max']}, "
            f"expected {exp_vb}")
    if st["timing_err"]:
        failures.append(f"{name}: adapter latched TIMING_ERR")
    if st["dval_ne"]:
        failures.append(f"{name}: DVAL differed from LVAL (mid-line bubble)")

    # FIELD_ID at the FVAL rising edge: alternating when interlaced, 0 when not.
    seen = fids[-8:] if st["frames"] >= 8 else fids[-st["frames"]:]
    if interlaced:
        bad = [i for i in range(1, len(seen)) if seen[i] == seen[i - 1]]
        if bad:
            failures.append(f"{name}: FIELD_ID did not alternate: {seen}")
    elif any(seen):
        failures.append(f"{name}: progressive stream reported FIELD_ID {seen}")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--bit", type=Path, default=DEFAULT_BIT)
    ap.add_argument("--skip-program", action="store_true")
    ap.add_argument("--port", type=int, default=3121)
    ap.add_argument("--device", default="xc7a100t")
    args = ap.parse_args()

    bit_str = (str(args.bit).replace("\\", "/")
               if not args.skip_program else None)
    transport = XilinxHwServerTransport(
        port=args.port, fpga_name=args.device, bitfile=bit_str,
        ready_probe_addr=None,
    )
    bridge = EjtagAxiController(transport, chain=4)

    failures: list[str] = []
    try:
        info = bridge.connect()
        print(f"Bridge: id=0x{info['bridge_id']:08X} "
              f"v{info['version_major']}.{info['version_minor']}")
        core_id = bridge.axi_read(VTPGZ_BASE + VTPGZ_CORE_ID)
        if core_id != VTPGZ_CORE_ID_MAGIC:
            print(f"ERROR: CORE_ID = 0x{core_id:08X}, wrong bitstream",
                  file=sys.stderr)
            return 2
        print(f"VTPGZ VERSION = 0x{bridge.axi_read(VTPGZ_BASE + VTPGZ_VERSION):08X}")
        ppc = bridge.axi_read(VTPGZ_BASE + VTPGZ_PIXELS_PER_CLOCK)
        print(f"PIXELS_PER_CLOCK = {ppc}, LINE_GAP_CYCLES = {LINE_GAP_CYCLES}")

        # Geometry sweep. Widths are multiples of ppc so nothing is clamped;
        # the rates bracket generous and near-minimum vertical blanking.
        # Rates are chosen so the expected blanking stays inside the
        # monitor's 16-bit counter (asserted in run_case), and bracket
        # generous blanking against the 1-cycle minimum.
        run_case(bridge, "progressive 64x32 slow", 64, 32, ppc,
                 4_000, False, failures)
        run_case(bridge, "progressive 64x32 tight", 64, 32, ppc,
                 active_cycles(64, 32, ppc) + 4, False, failures)
        run_case(bridge, "progressive 32x16", 32, 16, ppc,
                 1_000, False, failures)
        run_case(bridge, "interlaced 64x16 field", 64, 16, ppc,
                 2_000, True, failures)

    finally:
        try:
            bridge.axi_write(FC_BASE + FC_FLV_MODE, 0)
            bridge.close()
        except Exception:
            pass

    print()
    if failures:
        for f in failures:
            print(f"FAIL: {f}")
        return 1
    print("HW PASS - FVAL/LVAL/DVAL raster matches the documented arithmetic "
          "on silicon")
    return 0


if __name__ == "__main__":
    sys.exit(main())
