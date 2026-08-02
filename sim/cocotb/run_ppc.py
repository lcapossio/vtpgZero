#!/usr/bin/env python3
"""Drive the cocotb pixels-per-clock data-path suite with Icarus Verilog.

The Verilator+cocotb path (run_cocotb.py) can't read the packed
m_axis_tdata output -- cocotb 2.0.1 + Verilator 5.048 returns a
sampled-once value (see test_tready_probe.py). Icarus reads the packed
output correctly, so the PPC data-path verification -- which must compare
every AXIS beat against the reference model -- runs here under Icarus.

Each suite is one build (OUTPUT_MODE / BPC / PIXELS_PER_CLOCK differ) and
the test module (test_ppc) sweeps every runtime pattern within it. The
config is passed to the test via VTPGZ_* env vars so it can construct the
matching model config.

Usage:
    python3 sim/cocotb/run_ppc.py [suite1 [suite2 ...]]

With no arguments every suite in SUITES runs.
"""
from __future__ import annotations

import os
import shutil
import sys
from pathlib import Path

try:
    from cocotb_tools.runner import get_runner
except ImportError:
    from cocotb.runner import get_runner  # type: ignore

HERE    = Path(__file__).resolve().parent
SIM_DIR = HERE.parent
RTL_DIR = (SIM_DIR / ".." / "rtl").resolve()
BUILD   = HERE / "build_ppc"

TOP = "vtpgz_axilite_top"
RTL_SRCS = [
    RTL_DIR / "vtpgz_axil_regs.v",
    RTL_DIR / "vtpgz_core.v",
    RTL_DIR / "vtpgz_axilite_top.v",
]

WIDTH  = 32   # multiple of 8 so every PPC divides it evenly
HEIGHT = 12

# (mode, bpc, yuv_sub, raw_bayer) triples to cross with each PPC.
MODE_RGB, MODE_RAW, MODE_YUV = 0, 1, 2
YUV_422 = 1
RAW_RGGB = 1
_MODES = [
    ("rgb8",   dict(mode=MODE_RGB, bpc=8,  sub=0,       bayer=0)),
    ("raw12",  dict(mode=MODE_RAW, bpc=12, sub=0,       bayer=RAW_RGGB)),
    ("yuv422", dict(mode=MODE_YUV, bpc=8,  sub=YUV_422, bayer=0)),
]
_PPCS = [1, 2, 4, 8]


def _build_suites() -> list[dict]:
    suites = []
    for mname, m in _MODES:
        for ppc in _PPCS:
            suites.append({
                "name": f"ppc{ppc}_{mname}",
                "ppc": ppc,
                "mode": m,
            })
    return suites


SUITES = _build_suites()


def _xml_has_failures(xml_text: str) -> bool:
    return "<failure" in xml_text or "<error" in xml_text


def main(argv: list[str]) -> int:
    if not shutil.which("iverilog"):
        print("ERROR: 'iverilog' not found in PATH.", file=sys.stderr)
        return 2

    env_path = os.pathsep.join(
        filter(None, [str(HERE), os.environ.get("PYTHONPATH", "")]))
    os.environ["PYTHONPATH"] = env_path

    requested = set(argv) if argv else None
    if requested:
        unknown = requested - {s["name"] for s in SUITES}
        if unknown:
            print(f"ERROR: unknown suite(s): {sorted(unknown)}", file=sys.stderr)
            return 2

    fails: list[tuple[str, str]] = []
    for suite in SUITES:
        if requested is not None and suite["name"] not in requested:
            continue
        name = suite["name"]
        ppc  = suite["ppc"]
        m    = suite["mode"]
        params = {
            "OUTPUT_MODE":      m["mode"],
            "BPC":              m["bpc"],
            "YUV_SUBSAMPLE":    m["sub"],
            "RAW_BAYER":        m["bayer"],
            "RGB_ORDER":        0,
            "PIXELS_PER_CLOCK": ppc,
            "EN_IMAGE":         0,
            "EN_BOX_IMAGE":     0,
            "LINE_GAP_CYCLES":  1,
        }
        build_dir = BUILD / name
        if build_dir.exists():
            shutil.rmtree(build_dir)
        build_dir.mkdir(parents=True, exist_ok=True)
        print(f"=== cocotb PPC suite: {name}  params={params} ===", flush=True)

        # Config the test needs to build the matching model cfg.
        os.environ["VTPGZ_PPC"]       = str(ppc)
        os.environ["VTPGZ_MODE"]      = str(m["mode"])
        os.environ["VTPGZ_BPC"]       = str(m["bpc"])
        os.environ["VTPGZ_YUV_SUB"]   = str(m["sub"])
        os.environ["VTPGZ_RAW_BAYER"] = str(m["bayer"])
        os.environ["VTPGZ_RGB_ORDER"] = "0"
        os.environ["VTPGZ_WIDTH"]     = str(WIDTH)
        os.environ["VTPGZ_HEIGHT"]    = str(HEIGHT)

        runner = get_runner("icarus")
        runner.build(
            sources=[str(s) for s in RTL_SRCS],
            hdl_toplevel=TOP,
            includes=[str(RTL_DIR)],
            parameters=params,
            build_dir=str(build_dir),
            timescale=("1ns", "1ps"),
            always=True,
        )
        runner.test(
            hdl_toplevel=TOP,
            test_module="test_ppc",
            build_dir=str(build_dir),
        )
        results = build_dir / "results.xml"
        if not results.exists():
            fails.append((name, "no results.xml emitted"))
            continue
        text = results.read_text(encoding="utf-8", errors="replace")
        if _xml_has_failures(text):
            fails.append((name, "see results.xml"))
            print(text[-3000:])

    if fails:
        print("\nFAILED PPC SUITES:")
        for name, why in fails:
            print(f"  - {name}: {why}")
        return 1
    print(f"\nALL {len([s for s in SUITES if requested is None or s['name'] in requested])} COCOTB PPC SUITES PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
