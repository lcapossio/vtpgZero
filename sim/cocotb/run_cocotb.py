#!/usr/bin/env python3
"""Drive the cocotb test suite for vtpgZero with Verilator.

Lives in parallel with the C++ Verilator harness under sim/ -- C++ keeps
owning the byte-exact RTL<->model regression; cocotb is where Python-
authored spec/property tests go.

The Verilator+cocotb path needs Verilator >= ~5.030 because cocotb 2.x
uses VerilatedVpi APIs that ubuntu-24.04's apt verilator (5.020) doesn't
ship. CI installs a newer Verilator from source on demand in this job.

Usage:
    python3 sim/cocotb/run_cocotb.py [suite1 [suite2 ...]]

When no suite names are given, all suites in SUITES below are run.
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

HERE     = Path(__file__).resolve().parent
SIM_DIR  = HERE.parent
RTL_DIR  = (SIM_DIR / ".." / "rtl").resolve()
BUILD    = HERE / "build"

TOP = "vtpgz_axilite_top"
RTL_SRCS = [
    RTL_DIR / "vtpgz_axil_regs.v",
    RTL_DIR / "vtpgz_core.v",
    RTL_DIR / "vtpgz_axilite_top.v",
]

# Each suite gets its own build (parameters differ).
SUITES = [
    {
        "name": "smoke_rgb",
        "test_module": "test_smoke",
        "parameters": {
            "OUTPUT_MODE":   0,   # RGB -- simplest pack, no chroma to worry about
            "BPC":           8,
            "RGB_ORDER":     0,
            "EN_IMAGE":      0,
            "EN_BOX_IMAGE":  0,
            "LINE_GAP_CYCLES": 1,
        },
    },
    {
        "name": "tready_probe",
        "test_module": "test_tready_probe",
        "parameters": {
            "OUTPUT_MODE":   0,
            "BPC":           8,
            "RGB_ORDER":     0,
            "EN_IMAGE":      0,
            "EN_BOX_IMAGE":  0,
            "LINE_GAP_CYCLES": 1,
        },
    },
    # NOTE: a YUV spec test ran against the *Python reference model* lives
    # at hw/arty_a7_100t/python/check_yuv_spec.py and is gated under the
    # Python-smoke CI job. A cocotb-driven YUV spec test was attempted but
    # the cocotb 2.0.1 + Verilator 5.048 combination returns a sampled-once
    # value for the packed m_axis_tdata output even though the C++ harness
    # reads it correctly (see test_tready_probe.py for the diagnosis). The
    # byte-exact RTL<->model gate in sim/run_sim.py covers the data path
    # across all 20 mode/bpc configs, so cocotb is currently scoped to the
    # AXI-Lite control plane and AXIS handshake protocol.
]


def _xml_has_failures(xml_text: str) -> bool:
    """Return True iff the JUnit XML reports any failure or error."""
    return "<failure" in xml_text or "<error" in xml_text


def main(argv: list[str]) -> int:
    if not shutil.which("verilator"):
        print("ERROR: 'verilator' not found in PATH.", file=sys.stderr)
        return 2

    # Make sim/cocotb/ importable so cocotb finds the test modules.
    env_path = os.pathsep.join(filter(None, [str(HERE), os.environ.get("PYTHONPATH", "")]))
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
        name      = suite["name"]
        tm        = suite["test_module"]
        params    = suite["parameters"]
        build_dir = BUILD / name
        if build_dir.exists():
            shutil.rmtree(build_dir)
        build_dir.mkdir(parents=True, exist_ok=True)
        print(f"=== cocotb suite: {name}  module={tm}  params={params} ===",
              flush=True)
        os.environ["VTPGZ_LINE_GAP_CYCLES"] = str(params.get("LINE_GAP_CYCLES", 1))
        runner = get_runner("verilator")
        runner.build(
            sources=[str(s) for s in RTL_SRCS],
            hdl_toplevel=TOP,
            includes=[str(RTL_DIR)],
            parameters=params,
            build_dir=str(build_dir),
            build_args=["-Wno-fatal", "-Wno-WIDTH", "-Wno-UNUSED",
                        "-Wno-CASEINCOMPLETE"],
            always=True,
        )
        runner.test(
            hdl_toplevel=TOP,
            test_module=tm,
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
        print("\nFAILED SUITES:")
        for name, why in fails:
            print(f"  - {name}: {why}")
        return 1
    print("\nALL COCOTB SUITES PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
