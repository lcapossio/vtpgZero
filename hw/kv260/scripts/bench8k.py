#!/usr/bin/env python3
"""
bench8k.py -- Build and run the KV260 8K throughput bench.

Author: Leonardo Capossio - bard0 design - hello@bard0.com
Year:   2026

vtpgZero runs at 8 pixels per clock on a fast PL clock and streams
7680x4320 frames into axis_frame_monitor, which holds TREADY high and
records, per frame, the beat and line counts, the active time and the
frame period, mid-line bubbles and a CRC-32 of the frame. The host drives
both cores over JTAG (xsdb memory access through the PS), and checks:

  - every frame carries 960 x 4320 beats in 4320 lines, with no bubble;
  - the frame period is FRAME_RATE_DIV clocks on every frame (min == max),
    which at the build's exact clock is >= 60 fps, and the clock timed
    against the host's own clock agrees with that frequency;
  - the CRC of the first frame after enable equals the CRC of the same
    frame rendered by the bit-exact Python model (vtpgz_model.py).

Usage:
    python hw/kv260/scripts/bench8k.py build [--mhz 250]
    python hw/kv260/scripts/bench8k.py run   [--mhz 250] [--patterns 0,1,2]

`run` cold-boots the KV260 (PMUFW + FSBL of the DisplayPort demo's BSP,
see README), programs the bench bitstream and runs the patterns. The board
is picked by JTAG cable serial, so other boards on the same hw_server are
left alone. The default serial is the author's board; set
$KV260_JTAG_SERIAL to yours.
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
import zlib
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

KV_DIR = Path(__file__).resolve().parents[1]
REPO = Path(__file__).resolve().parents[3]
OUT = KV_DIR / "build" / "pl_8k"
BIT = OUT / "vtpgz_kv260_8k.bit"
BSP = KV_DIR / "build" / "bsp_vtpgzero_kv260" / "hw_platform"

sys.path.insert(0, str(REPO / "hw" / "arty_a7_100t" / "python"))
from vtpgz_model import (  # noqa: E402
    VtpgzConfig, grad_step, iter_frame_beats, smpte_host_geometry)

WIDTH, HEIGHT, PPC = 7680, 4320, 8
LINE_GAP = 1                                   # LINE_GAP_CYCLES default
BEATS = WIDTH // PPC * HEIGHT
ACTIVE = WIDTH // PPC * HEIGHT + LINE_GAP * (HEIGHT - 1)
BEAT_BYTES = 24                                # 8 x RGB888

TPG = 0xA0000000
MON = 0xA0010000

PATTERN_NAMES = {0: "colorbar", 1: "hgrad", 2: "vgrad", 3: "checker",
                 4: "solid", 5: "smpte*", 6: "grid",
                 7: "ramp", 8: "noise"}


def find_tool(names: tuple[str, ...], env: str) -> str:
    for n in names:
        p = shutil.which(n)
        if p:
            return p
    p = os.environ.get(env)
    if p and Path(p).exists():
        return p
    sys.exit(f"ERROR: {names[0]} not in PATH and ${env} is not set.")


def run_tool(exe: str, args: list[str], **kw) -> subprocess.CompletedProcess:
    cmd = [exe] + args
    if exe.lower().endswith(".bat"):
        cmd = ["cmd", "/c"] + cmd
    return subprocess.run(cmd, **kw)


# ---------------------------------------------------------------- build ---

def build(mhz: str) -> int:
    vivado = find_tool(("vivado.bat", "vivado") if os.name == "nt"
                       else ("vivado",), "VIVADO")
    OUT.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env["VTPGZ_REPO"] = str(REPO).replace("\\", "/")
    env["VTPGZ_KV260_OUT"] = str(OUT).replace("\\", "/")
    env["VTPGZ_8K_MHZ"] = mhz
    log = OUT / "vivado.log"
    print(f"[8k] building at {mhz} MHz, log: {log}")
    with open(log, "w") as f:
        rc = run_tool(vivado, ["-mode", "batch", "-nolog", "-nojournal",
                               "-source",
                               str(KV_DIR / "vivado" / "build_pl_8k.tcl")],
                      env=env, stdout=f, stderr=subprocess.STDOUT).returncode
    for line in log.read_text(errors="replace").splitlines():
        if line.startswith("RESULT"):
            print(f"[8k] {line}")
    if rc or not BIT.is_file():
        print(f"[8k] FAILED rc={rc} -- see {log}")
        return rc or 1
    print(f"[8k] bitstream: {BIT}")
    return 0


# ---------------------------------------------------------------- model ---

def cfg_for(pat: int) -> VtpgzConfig:
    return VtpgzConfig(
        width=WIDTH, height=HEIGHT, pattern=pat, pixels_per_clock=PPC,
        bar_width=WIDTH // 8,
        hg_step=grad_step(WIDTH), vg_step=grad_step(HEIGHT),
        checker_size=240, grid_spacing=240,
        box_width=480, box_height=270, box_dx=8, box_dy=4,
        **smpte_host_geometry(WIDTH, HEIGHT),
    )


def model_crc(pat: int) -> int:
    # SMPTE is not in the bench build; a stripped pattern renders black,
    # as an unused PATTERN_SEL code (15) does.
    cfg = cfg_for(15 if pat == 5 else pat)
    crc = 0
    for beat in iter_frame_beats(cfg):
        crc = zlib.crc32(beat.to_bytes(BEAT_BYTES, "little"), crc)
    return crc


# ------------------------------------------------------------------ run ---

BOOT_TCL = """\
set SER {serial}
# Select a target on this board. Right after connect the target list (and
# its cable properties) may still be filling in, so retry for a while.
proc tgt {{name}} {{
    global SER
    set f "jtag_cable_serial == \\"$SER\\" && name =~ \\"$name\\""
    for {{set i 0}} {{$i < 20}} {{incr i}} {{
        if {{![catch {{targets -set -filter $f}}]}} {{ return }}
        after 500
    }}
    targets -set -filter $f
}}
connect

# A PL access that hung on an earlier run leaves the DAP in an AXI-AP error
# state, with no PSU target under it. Reset the DAP to bring it back.
after 1000
if {{![catch {{targets -set -filter \\
        "jtag_cable_serial == \\"$SER\\" && name =~ \\"DAP*\\""}}]}} {{
    rst -dap
    after 1500
}}

# JTAG boot mode, system reset
tgt PSU
mwr 0xffca0010 0x0
mwr 0xff5e0200 0x0100
rst -system
after 1000
tgt PSU
mwr 0xFFCA0038 0x1FF
after 500

# PMU firmware, then the FSBL (PS init: clocks, DDR, MIO)
tgt "MicroBlaze PMU*"
catch {{stop}}
after 200
dow {pmufw}
con
after 3000
tgt "Cortex-A53 #0"
rst -processor -clear-registers
after 1000
tgt PSU
mwr 0xFD5C0040 0xFFFC0000
mwr 0xFD5C0044 0x00000000
after 100
tgt "Cortex-A53 #0"
dow {fsbl}
after 500
con
after 20000
catch {{stop}}
after 500

# PL bitstream
tgt "PS TAP"
fpga -f {bit}
after 2000
tgt PSU
set pcap [mrd -force -value 0xFFCA3010]
if {{($pcap & 0x800) == 0}} {{ puts "ERROR: PL_DONE not set"; exit 1 }}

# PS-PL isolation removal and a pl_resetn0 pulse (docs/PS_PL_ISOLATION.md)
mwr -force 0xFFD80118 [expr {{[mrd -force -value 0xFFD80118] | 0x00800000}}]
mwr -force 0xFFD80120 [expr {{[mrd -force -value 0xFFD80120] | 0x00800000}}]
after 100
mwr -force 0xFF0A002C 0x80000000
mwr -force 0xFF0A0344 0x80000000
mwr -force 0xFF0A0348 0x80000000
mwr -force 0xFF0A0054 0x80000000
after 50
mwr -force 0xFF0A0054 0x00000000
after 50
mwr -force 0xFF0A0054 0x80000000
after 200
puts "BOOT done"
"""

MEASURE_TCL = """\
set SER {serial}
# Select a target on this board. Right after connect the target list (and
# its cable properties) may still be filling in, so retry for a while.
proc tgt {{name}} {{
    global SER
    set f "jtag_cable_serial == \\"$SER\\" && name =~ \\"$name\\""
    for {{set i 0}} {{$i < 20}} {{incr i}} {{
        if {{![catch {{targets -set -filter $f}}]}} {{ return }}
        after 500
    }}
    targets -set -filter $f
}}
connect
tgt PSU
proc w {{a v}} {{ mwr -force $a $v }}
proc r {{a}} {{ return [mrd -force -value $a] }}
set T {tpg:#x}
set M {mon:#x}
puts [format "ID tpg=%08x ver=%08x ppc=%d mon=%08x" \\
    [r [expr {{$T+0x00}}]] [r [expr {{$T+0x04}}]] [r [expr {{$T+0x30}}]] \\
    [r [expr {{$M+0x00}}]]]

proc snap {{}} {{
    global M
    w [expr {{$M+0x04}}] 2
    set t [clock microseconds]
    set f [r [expr {{$M+0x34}}]]
    set lo [r [expr {{$M+0x38}}]]
    set hi [r [expr {{$M+0x3C}}]]
    return [list $t $f [expr {{($hi << 32) | $lo}}]]
}}

proc run_pattern {{tag pat div secs}} {{
    global T M
    w [expr {{$T+0x08}}] 0
    after 100
    w [expr {{$T+0x10}}] {width}
    w [expr {{$T+0x14}}] {height}
    w [expr {{$T+0x44}}] {bar_width}
    w [expr {{$T+0x48}}] {hg_step}
    w [expr {{$T+0x4C}}] {vg_step}
    w [expr {{$T+0x3C}}] {checker}
    w [expr {{$T+0x34}}] {grid}
    w [expr {{$T+0x28}}] {box_size}
    w [expr {{$T+0x2C}}] {box_speed}
    w [expr {{$T+0x18}}] $pat
    w [expr {{$T+0x40}}] $div
    w [expr {{$M+0x04}}] 1
    w [expr {{$T+0x08}}] 1
    after 500
    set a [snap]
    after [expr {{int($secs * 1000)}}]
    set b [snap]
    set out "RES $tag pat=$pat div=$div"
    append out " t0=[lindex $a 0] f0=[lindex $a 1] c0=[lindex $a 2]"
    append out " t1=[lindex $b 0] f1=[lindex $b 1] c1=[lindex $b 2]"
    foreach {{k o}} {{frames 0x08 beats 0x0C lines 0x10 active 0x14 period 0x18
                    last_crc 0x1C first_crc 0x20 crc_changes 0x24
                    min_period 0x28 max_period 0x2C bubbles 0x30}} {{
        append out " $k=[r [expr {{$M+$o}}]]"
    }}
    w [expr {{$T+0x08}}] 0
    puts $out
}}
{runs}
puts "MEASURE done"
"""


def xsdb_run(xsdb: str, tcl: str) -> str:
    with tempfile.NamedTemporaryFile("w", suffix=".tcl", delete=False) as f:
        f.write(tcl)
        path = Path(f.name)
    try:
        p = run_tool(xsdb, [str(path)], capture_output=True, text=True)
    finally:
        path.unlink(missing_ok=True)
    out = p.stdout + p.stderr
    if p.returncode:
        print(out)
        sys.exit(f"ERROR: xsdb exited {p.returncode}")
    return out


def parse_res(line: str) -> dict:
    toks = line.split()
    d = {"tag": toks[1]}
    for t in toks[2:]:
        k, v = t.split("=", 1)
        d[k] = int(v, 0)
    return d


def run(args) -> int:
    # The exact fast clock: pl_clk0 is 99.999001 MHz, not 100, so the MMCM
    # output is a hair under its nominal value. The build records it.
    hz_file = OUT / "clock_hz.txt"
    clk = float(hz_file.read_text().strip()) if hz_file.is_file() \
        else float(args.mhz) * 1e6
    mhz = clk / 1e6
    div60 = int(clk // 60)                     # >= 60 fps at that clock
    if div60 < ACTIVE:
        sys.exit(f"ERROR: {mhz} MHz cannot reach 60 fps: a frame is "
                 f"{ACTIVE} clocks, 60 fps allows {div60}")
    pats = [int(p) for p in args.patterns.split(",")]
    xsdb = find_tool(("xsdb.bat", "xsdb") if os.name == "nt" else ("xsdb",),
                     "XSDB")
    serial = os.environ.get("KV260_JTAG_SERIAL", "XFL11Y1YXRV0A")

    # Model CRCs in the background while the board boots and runs.
    pool = ProcessPoolExecutor(max_workers=min(len(pats), os.cpu_count() or 1))
    futs = {p: pool.submit(model_crc, p) for p in pats}

    if not args.no_boot:
        if not BIT.is_file():
            sys.exit(f"ERROR: {BIT} not found; run `bench8k.py build` first")
        pmufw = BSP / "zynqmp_pmufw" / "pmufw.elf"
        fsbl = BSP / "zynqmp_fsbl" / "fsbl_a53.elf"
        for f in (pmufw, fsbl):
            if not f.is_file():
                sys.exit(f"ERROR: {f} not found (build the DisplayPort demo "
                         f"BSP: hw/kv260/scripts/build_bsp.py)")
        print(f"[8k] cold boot + program ({serial})")
        out = xsdb_run(xsdb, BOOT_TCL.format(
            serial=serial, pmufw=pmufw.as_posix(), fsbl=fsbl.as_posix(),
            bit=BIT.as_posix()))
        if "BOOT done" not in out:
            print(out)
            return 1

    c = cfg_for(0)
    runs = [f"run_pattern p{p} {p} {div60} {args.secs}" for p in pats]
    # Smallest FRAME_RATE_DIV that still starts a frame on every pulse:
    # the core's real ceiling at this clock.
    runs += [f"run_pattern max{k} 0 {ACTIVE + k} 2" for k in (2, 4, 8, 16)]
    tcl = MEASURE_TCL.format(
        serial=serial, tpg=TPG, mon=MON, width=WIDTH, height=HEIGHT,
        bar_width=c.bar_width, hg_step=c.hg_step, vg_step=c.vg_step,
        checker=c.checker_size, grid=c.grid_spacing,
        box_size=(c.box_width << 16) | c.box_height,
        box_speed=(c.box_dx << 16) | c.box_dy,
        runs="\n".join(runs))
    out = xsdb_run(xsdb, tcl)
    for line in out.splitlines():
        if line.startswith("ID "):
            print(f"[8k] {line}")
    res = [parse_res(l) for l in out.splitlines() if l.startswith("RES ")]
    if not res:
        print(out)
        return 1

    fails = 0
    print(f"\n7680x4320, {PPC} px/clk, clock {mhz:.4f} MHz, "
          f"FRAME_RATE_DIV={div60}, active frame = {ACTIVE} clocks")
    print(f"{'pattern':<10} {'fps':>9} {'host fps':>9} {'host MHz':>9} "
          f"{'frames':>6} {'beats':>8} {'lines':>5} {'period min/max':>17} "
          f"{'bubbles':>7} {'first CRC':>9} {'model':>9}  result")
    max_ok = None
    for d in res:
        dt = (d["t1"] - d["t0"]) * 1e-6
        f_meas = (d["c1"] - d["c0"]) / dt / 1e6
        fps = (d["f1"] - d["f0"]) / dt
        if d["tag"].startswith("max"):
            if d["min_period"] == d["max_period"] == d["div"] and \
                    d["beats"] == BEATS and max_ok is None:
                max_ok = d
            continue
        p = d["pat"]
        want = futs[p].result()
        # The frame rate is the fabric's: every SOF-to-SOF period, counted
        # in clocks, is at most clk/60 (min == max == FRAME_RATE_DIV). The
        # host-timed rate and clock carry JTAG latency jitter, so they are
        # only a cross-check that the clock really runs at its nominal rate.
        fps_fab = clk / d["max_period"] if d["max_period"] else 0.0
        ok = (d["beats"] == BEATS and d["lines"] == HEIGHT
              and d["bubbles"] == 0 and d["active"] == ACTIVE
              and d["min_period"] == d["max_period"] == d["div"]
              and d["first_crc"] == want and fps_fab >= 60.0
              and abs(f_meas / mhz - 1) < 0.005)
        fails += not ok
        print(f"{PATTERN_NAMES.get(p, p):<10.10} {fps_fab:9.4f} {fps:9.3f} "
              f"{f_meas:9.3f} "
              f"{d['frames']:6d} {d['beats']:8d} {d['lines']:5d} "
              f"{d['min_period']:>8d}/{d['max_period']:<8d} {d['bubbles']:7d} "
              f" {d['first_crc']:08x}  {want:08x}  {'OK' if ok else 'FAIL'}")
    pool.shutdown()
    if max_ok:
        print(f"\nFree-running: FRAME_RATE_DIV={max_ok['div']} "
              f"(active + {max_ok['div'] - ACTIVE}) holds every frame, "
              f"{clk / max_ok['div']:.3f} fps at {mhz:g} MHz")
    if 5 in pats:
        print("* SMPTE RP 219 is not in this build (EN_SMPTE=0): pattern 5 "
              "renders black, as the model does.")
    print(f"\n{'PASS' if not fails else 'FAIL'}: {len(pats) - fails}/"
          f"{len(pats)} patterns at 8Kp60")
    return 1 if fails else 0


def main() -> int:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("build")
    b.add_argument("--mhz", default="250")
    r = sub.add_parser("run")
    r.add_argument("--mhz", default="250",
                   help="fast clock in MHz, used only when the build's "
                        "clock_hz.txt is missing")
    r.add_argument("--patterns", default="0,1,2,3,4,5,6,7,8")
    r.add_argument("--secs", type=float, default=4.0,
                   help="measurement window per pattern")
    r.add_argument("--no-boot", action="store_true",
                   help="board already booted and programmed")
    args = ap.parse_args()
    if args.cmd == "build":
        return build(args.mhz)
    return run(args)


if __name__ == "__main__":
    sys.exit(main())
