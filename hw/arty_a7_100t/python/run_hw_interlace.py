#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Leonardo Capossio - bard0 design - hello@bard0.com
# SPDX-License-Identifier: Apache-2.0
"""
Interlaced-video (EN_INTERLACE) hardware check for the Arty A7-100T demo.

The demo bitstream builds vtpgz_axilite_top with EN_INTERLACE=1 and routes
`fid` into frame_capture. Two observation points exist on silicon:

  * CAPTURE_STATUS[1] -- the fid latched at the SOF beat of the captured
    field;
  * FID_HIST / SOF_COUNT (0x08 / 0x0C) -- the fid of EVERY SOF beat seen on
    the stream, bit 0 = most recent.

The second register exists because frame_capture only asserts s_axis_tready
while it is capturing, and its FSM terminates on the SECOND tuser. So each
arm->done cycle consumes exactly TWO field starts (measured on the board as
a STATUS frame_count delta of 2 per capture), and consecutive captures
therefore always land on the SAME parity. That is a property of the demo
sink, not of the core: alternation has to be read out of FID_HIST, where
adjacent bits are consecutive fields and must differ.

This script:
  * programs IMG_HEIGHT with the FIELD height (frame height / 2), per the
    AMD v_tpg (PG103) convention;
  * disables the moving-box overlay so every field renders identically and
    each captured field can be required byte-exact against the model;
  * captures several fields WITHOUT disabling the core, requires each to be
    byte-exact, and requires CAPTURE_STATUS[1] to be self-consistent;
  * requires FID_HIST to alternate across every consecutive field start, and
    SOF_COUNT to equal 2 per capture (which is also the proof that no field
    was silently skipped);
  * repeats with CONTROL[3] clear and requires fid to read 0 everywhere.
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
from fcapz.ejtagaxi import EjtagAxiController, AXIError  # noqa: E402
from vtpgz_model import (  # noqa: E402
    VtpgzConfig, VtpgzRegs, render_frame_beats, tdata_to_bram_words,
)
from run_hw_test import (  # noqa: E402
    VTPGZ_BASE, FC_BASE,
    VTPGZ_CORE_ID, VTPGZ_CONTROL, VTPGZ_STATUS, VTPGZ_VERSION,
    VTPGZ_COLOR_FORMAT, VTPGZ_PIXELS_PER_CLOCK, VTPGZ_FRAME_RATE,
    VTPGZ_CORE_ID_MAGIC,
    FC_CTRL, FC_STATUS, FC_BRAM,
    configure_vtpgz, DEFAULT_BIT,
)

# Frame geometry: a 64x32 FRAME presented as two 64x16 fields.
WIDTH        = 64
FRAME_HEIGHT = 32
FIELD_HEIGHT = FRAME_HEIGHT // 2

# Core clock is 50 MHz in the PPC=4 demo build (650/13); ~0.5 s per field.
FIELD_RATE_DIV = 500_000

CTRL_ENABLE    = 0x1
CTRL_INTERLACE = 0x8

# frame_capture CSRs beyond the two run_hw_test.py already exports.
FC_ARM      = 0x1
FC_CLEAR    = 0x2
FC_HISTCLR  = 0x4
FC_FID_HIST = 0x8
FC_SOF_CNT  = 0xC


def field_cfg(pat: int, mode: int, bpc: int, sub: int, bayer: int,
              order: int, ppc: int) -> VtpgzConfig:
    """Model config for ONE field: the field height is the render height."""
    return VtpgzConfig(
        width=WIDTH, height=FIELD_HEIGHT,
        pattern=pat,
        output_mode=mode, yuv_subsample=sub, raw_bayer=bayer,
        rgb_order=order, bpc=bpc, pixels_per_clock=ppc,
        bar_width=WIDTH // 8,
        hg_step=0xFFF // (WIDTH - 1),
        vg_step=0xFFF // (FIELD_HEIGHT - 1),
        checker_size=16,
        grid_spacing=16,
        # The moving-box overlay advances once per FIELD and its state is
        # NOT reset at a field boundary, so each field differs from the last.
        # The model is stepped field by field to match (see model_fields()).
        box_width=16, box_height=16,
        box_dx=1, box_dy=1,
    )


def model_fields(cfg: VtpgzConfig, count: int) -> list[list[int]]:
    """Render `count` CONSECUTIVE fields, carrying pattern state across them.

    render_frame_beats() mutates the VtpgzRegs it is handed, so reusing one
    regs object reproduces the core's behaviour: the box overlay advances
    once per field and is not reset at a field boundary.
    """
    regs = VtpgzRegs()
    return [tdata_to_bram_words(render_frame_beats(cfg, regs),
                                cfg.beat_tdata_width)
            for _ in range(count)]


def hist_oldest_first(hist: int, count: int) -> list[int]:
    """FID_HIST has bit 0 = most recent; return `count` fields oldest first."""
    count = min(count, 32)
    return [(hist >> i) & 0x1 for i in range(count - 1, -1, -1)]


def poll_and_read(axi: EjtagAxiController, expected_words: int,
                  timeout_s: float = 5.0) -> tuple[bool, int, list[int], str]:
    """Poll an already-armed sink to done and read the field out of BRAM."""
    deadline = time.time() + timeout_s
    sts = 0
    while time.time() < deadline:
        sts = axi.axi_read(FC_BASE + FC_STATUS)
        if sts & 0x1:
            break
    else:
        return False, 0, [], f"capture timeout (status=0x{sts:08X})"
    fid        = (sts >> 1) & 0x1
    word_count = (sts >> 16) & 0xFFFF
    if word_count < expected_words:
        return False, fid, [], (f"short field: got {word_count} words, "
                                f"expected {expected_words}")
    try:
        words = axi.read_block(FC_BASE + FC_BRAM, expected_words)
    except AXIError as e:
        return False, fid, [], f"read_block failed: {e}"
    return True, fid, words, ""


def capture_one_field(axi: EjtagAxiController, expected_words: int,
                      timeout_s: float = 5.0) -> tuple[bool, int, list[int], str]:
    """Clear+arm the sink and pull the next field. The core is NOT touched.

    Note this consumes TWO field starts, not one: the FSM drains the tail of
    the field the stalled core was sitting in, captures the next field, and
    terminates on the SOF beat after it.

    Returns (ok, fid, words, error).
    """
    axi.axi_write(FC_BASE + FC_CTRL, FC_CLEAR)
    axi.axi_write(FC_BASE + FC_CTRL, FC_ARM)
    return poll_and_read(axi, expected_words)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--bit", type=Path, default=DEFAULT_BIT)
    ap.add_argument("--skip-program", action="store_true")
    ap.add_argument("--port", type=int, default=3121)
    ap.add_argument("--device", default="xc7a100t")
    ap.add_argument("--fields", type=int, default=4,
                    help="captures to take; each spans 2 field starts "
                         "(default 4 = 8 fields)")
    ap.add_argument("--pattern", type=int, default=0,
                    help="PATTERN_SEL to render (default 0 = colorbar)")
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
        ver = bridge.axi_read(VTPGZ_BASE + VTPGZ_VERSION)
        print(f"VTPGZ VERSION = 0x{ver:08X}")

        cf = bridge.axi_read(VTPGZ_BASE + VTPGZ_COLOR_FORMAT)
        mode  =  cf        & 0x3
        sub   = (cf >> 2)  & 0x1
        bayer = (cf >> 3)  & 0x7
        order = (cf >> 6)  & 0x1
        bpc   = (cf >> 8)  & 0xFF
        ppc   = bridge.axi_read(VTPGZ_BASE + VTPGZ_PIXELS_PER_CLOCK)
        print(f"Build cfg: mode={mode} sub={sub} bayer={bayer} order={order} "
              f"bpc={bpc} ppc={ppc}")
        print(f"Geometry: {WIDTH}x{FRAME_HEIGHT} frame = "
              f"2 x {WIDTH}x{FIELD_HEIGHT} fields")

        cfg = field_cfg(args.pattern, mode, bpc, sub, bayer, order, ppc)
        # Each capture consumes two field starts, so capture n lands on
        # field 2n of the sequence that begins at the enable.
        sw_fields = model_fields(cfg, 2 * args.fields)
        expected_words = len(sw_fields[0])

        # ---- interlaced ----
        bridge.axi_write(VTPGZ_BASE + VTPGZ_CONTROL, 0)
        configure_vtpgz(bridge, cfg)                    # writes IMG_HEIGHT=field
        bridge.axi_write(VTPGZ_BASE + VTPGZ_FRAME_RATE, FIELD_RATE_DIV)
        bridge.axi_write(FC_BASE + FC_CTRL, FC_HISTCLR) # reset fid history
        bridge.axi_write(FC_BASE + FC_CTRL, FC_CLEAR)
        bridge.axi_write(FC_BASE + FC_CTRL, FC_ARM)     # arm before enabling
        bridge.axi_write(VTPGZ_BASE + VTPGZ_CONTROL,
                         CTRL_ENABLE | CTRL_INTERLACE)

        seen: list[int] = []
        for n in range(args.fields):
            t0 = time.time()
            if n == 0:
                ok, fid, words, err = poll_and_read(bridge, expected_words)
            else:
                ok, fid, words, err = capture_one_field(bridge, expected_words)
            if not ok:
                failures.append(f"capture {n}: {err}")
                break
            seen.append(fid)
            data_ok = (words == sw_fields[2 * n])
            print(f"  capture {n}: fid={fid} "
                  f"data={'OK' if data_ok else 'MISMATCH'} "
                  f"[{time.time() - t0:.2f}s]")
            if not data_ok:
                exp = sw_fields[2 * n]
                first = next((i for i, (a, b) in enumerate(zip(words, exp))
                              if a != b), 0)
                failures.append(
                    f"capture {n} (field {2 * n}): pixel mismatch @{first}: "
                    f"hw=0x{words[first]:08X} sw=0x{exp[first]:08X}")

        sof_cnt = bridge.axi_read(FC_BASE + FC_SOF_CNT) & 0xFF
        hist    = bridge.axi_read(FC_BASE + FC_FID_HIST)
        bridge.axi_write(VTPGZ_BASE + VTPGZ_CONTROL, 0)

        fields = hist_oldest_first(hist, sof_cnt)
        print(f"  captured fid sequence : {seen}")
        print(f"  SOF_COUNT             : {sof_cnt} "
              f"({len(seen)} captures x 2 field starts each)")
        print(f"  FID_HIST (oldest 1st) : {fields}")

        # Each arm->done cycle consumes exactly two field starts; anything
        # else means a field was skipped or double-counted.
        if sof_cnt != 2 * len(seen):
            failures.append(f"SOF_COUNT={sof_cnt}, expected {2 * len(seen)}")
        if sof_cnt > 32:
            failures.append(f"SOF_COUNT={sof_cnt} exceeds the 32-entry history")
        # The core is enabled fresh, so the first field of the sequence is
        # the even/top field.
        if fields and fields[0] != 0:
            failures.append(f"first field after enable has fid={fields[0]}, "
                            f"expected 0")
        # The actual property under test: consecutive fields alternate.
        bad = [i for i in range(1, len(fields)) if fields[i] == fields[i - 1]]
        if bad:
            failures.append(f"fid did not alternate at field index(es) {bad}: "
                            f"{fields}")
        if len(fields) < 4:
            failures.append(f"only {len(fields)} field starts observed, "
                            f"not enough to prove alternation")
        # Captures land on every other field, so they must all share a parity
        # and that parity must match the even entries of the history.
        if seen and len(set(seen)) != 1:
            failures.append(f"captured parity was not constant: {seen} "
                            f"(each capture consumes 2 fields)")
        if seen and fields and seen[0] != fields[0]:
            failures.append(f"CAPTURE_STATUS fid={seen[0]} disagrees with "
                            f"FID_HIST first field={fields[0]}")

        # ---- progressive: fid must read 0 everywhere ----
        bridge.axi_write(FC_BASE + FC_CTRL, FC_HISTCLR)
        bridge.axi_write(FC_BASE + FC_CTRL, FC_CLEAR)
        bridge.axi_write(FC_BASE + FC_CTRL, FC_ARM)
        bridge.axi_write(VTPGZ_BASE + VTPGZ_CONTROL, CTRL_ENABLE)
        ok, prog_fid, prog_words, err = poll_and_read(bridge, expected_words)
        prog_cnt  = bridge.axi_read(FC_BASE + FC_SOF_CNT) & 0xFF
        prog_hist = bridge.axi_read(FC_BASE + FC_FID_HIST)
        bridge.axi_write(VTPGZ_BASE + VTPGZ_CONTROL, 0)
        if not ok:
            failures.append(f"progressive capture: {err}")
        else:
            prog_fields = hist_oldest_first(prog_hist, prog_cnt)
            print(f"  progressive: fid={prog_fid} (expected 0) "
                  f"data={'OK' if prog_words == sw_fields[0] else 'MISMATCH'} "
                  f"FID_HIST={prog_fields}")
            if prog_fid != 0:
                failures.append(f"progressive stream reported fid={prog_fid}")
            if any(prog_fields):
                failures.append(f"progressive FID_HIST not all zero: "
                                f"{prog_fields}")
            if prog_words != sw_fields[0]:
                failures.append("progressive capture mismatched the model")

    finally:
        try:
            bridge.close()
        except Exception:
            pass

    print()
    if failures:
        for f in failures:
            print(f"FAIL: {f}")
        return 1
    print(f"HW PASS - fid alternated across every observed field start and "
          f"all {args.fields} captured fields were byte-exact")
    return 0


if __name__ == "__main__":
    sys.exit(main())
