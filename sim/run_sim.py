#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Leonardo Capossio - bard0 design - hello@bard0.com
# SPDX-License-Identifier: Apache-2.0
"""
Verilator orchestration for vtpgZero (Phase 2a, no Makefile).

Replaces the legacy sim/Makefile. Drives Verilator for lint, the coverage
regression sim, the per-pattern capture binary used by the Python model
gate, and the multi-capture sequential harness.

All paths are resolved relative to this script so it works from a clean
checkout in any working directory. Tools are looked up in PATH; if a tool
is missing the script reports it immediately.

Subcommands:
    lint              run verilator lint on the active config
    build             build the coverage Verilator sim binary
    run               build + run the coverage sim, write logs/coverage.dat
    cov               summarise coverage from logs/coverage.dat
    regression        lint + run + cov + default sim<->model gate
    capture_build     build the per-pattern capture binary
    check_model       capture_build + sim<->python-model byte-exact gate
    seq_build         build the multi-capture sequential harness
    seq_run           seq_build + run the harness
    check_seq         seq_run + check_seq.py
    all_modes         sweep every (mode x bpc) and run check_model
    clean             remove obj_dir / obj_capture / obj_seq / logs

Build-time configuration is selected with --mode/--bpc/--yuv-sub/--raw-bayer/
--rgb-order. Defaults match the Phase 1 default (RGB 8bpc Xilinx-order).

Usage examples:
    python sim/run_sim.py regression
    python sim/run_sim.py --mode yuv --bpc 12 check_model
    python sim/run_sim.py all_modes
"""
from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
from pathlib import Path

HERE     = Path(__file__).resolve().parent
RTL_DIR  = (HERE / ".." / "rtl").resolve()
HW_RTL   = (HERE / ".." / "hw" / "arty_a7_100t" / "rtl").resolve()
HW_PY    = (HERE / ".." / "hw" / "arty_a7_100t" / "python").resolve()
TESTS_DIR = (HERE / ".." / "tests").resolve()

# Absolute paths to the embedded mandrill .mem images. The default values
# inside vtpgz_core.v are repo-relative (good for synthesis from the BD tcl);
# Verilator resolves $readmemh relative to the sim cwd, so we hand over
# absolute paths here to make the coverage build cwd-independent.
IMAGE_HEX_FILE_DEFAULT     = TESTS_DIR / "images" / "mandrill_128x128.mem"
BOX_IMAGE_HEX_FILE_DEFAULT = TESTS_DIR / "images" / "mandrill_32x32.mem"

TOP      = "vtpgz_axilite_top"
RTL_SRCS = [RTL_DIR / "vtpgz_axil_regs.v",
            RTL_DIR / "vtpgz_core.v",
            RTL_DIR / "vtpgz_axilite_top.v"]

OBJ_DIR          = HERE / "obj_dir"
CAPTURE_OBJ_DIR  = HERE / "obj_capture"
SEQ_OBJ_DIR      = HERE / "obj_seq"
LOGS_DIR         = HERE / "logs"

# Map enum int -> friendly name (for the Python check scripts)
MODE_NAMES   = {0: "rgb", 1: "raw", 2: "yuv"}
SUB_NAMES    = {0: "444", 1: "422"}
BAYER_NAMES  = {0: "plain", 1: "rggb", 2: "bggr", 3: "grbg", 4: "gbrg"}
ORDER_NAMES  = {0: "xilinx", 1: "legacy"}


# ---------- helpers ----------

def need_tool(name: str) -> str:
    p = shutil.which(name)
    if not p:
        print(f"ERROR: '{name}' not found in PATH. "
              f"Source the OSS-CAD-Suite environment first.", file=sys.stderr)
        sys.exit(2)
    return p


def run(cmd: list[str], cwd: Path | None = None) -> None:
    print("+ " + " ".join(str(c) for c in cmd))
    r = subprocess.run([str(c) for c in cmd], cwd=str(cwd) if cwd else None)
    if r.returncode != 0:
        sys.exit(r.returncode)


def generics(args: argparse.Namespace) -> list[str]:
    return [
        f"-GOUTPUT_MODE={args.mode}",
        f"-GBPC={args.bpc}",
        f"-GYUV_SUBSAMPLE={args.yuv_sub}",
        f"-GRAW_BAYER={args.raw_bayer}",
        f"-GRGB_ORDER={args.rgb_order}",
    ]


def lint_flags(args: argparse.Namespace) -> list[str]:
    return ["--lint-only", "-Wall", "-Wno-UNUSED", "-Wno-WIDTH",
            "-Wno-CASEINCOMPLETE",
            "-I" + str(RTL_DIR), "--top-module", TOP] + generics(args)


def build_flags(args: argparse.Namespace) -> list[str]:
    # Coverage build also enables EN_IMAGE/EN_BOX_IMAGE so the new generate
    # blocks, the PAT_IMAGE case, and the box-image step input ports get
    # exercised in the coverage sim (sim_main.cpp drives pattern 9 and
    # writes the two step regs).
    return ["--cc", "--exe", "--build", "--trace",
            "--coverage", "--coverage-line", "--coverage-toggle",
            "--coverage-user",
            "-Wall", "-Wno-UNUSED", "-Wno-WIDTH", "-Wno-CASEINCOMPLETE",
            "-I" + str(RTL_DIR), "--top-module", TOP] + generics(args) + [
            "-GEN_IMAGE=1",
            "-GEN_BOX_IMAGE=1",
            f'-GIMAGE_HEX_FILE="{IMAGE_HEX_FILE_DEFAULT.as_posix()}"',
            f'-GBOX_IMAGE_HEX_FILE="{BOX_IMAGE_HEX_FILE_DEFAULT.as_posix()}"']


def capture_flags(args: argparse.Namespace) -> list[str]:
    return ["--cc", "--exe", "--build",
            "-Wall", "-Wno-UNUSED", "-Wno-WIDTH", "-Wno-CASEINCOMPLETE",
            "-I" + str(RTL_DIR), "--top-module", TOP,
            "-Mdir", str(CAPTURE_OBJ_DIR),
            "--prefix", "Vvtpgz_axilite_top"] + generics(args)


def seq_flags(args: argparse.Namespace) -> list[str]:
    return ["--cc", "--exe", "--build",
            "-Wall", "-Wno-UNUSED", "-Wno-WIDTH", "-Wno-CASEINCOMPLETE",
            "-Wno-DECLFILENAME", "-Wno-PINCONNECTEMPTY", "-Wno-TIMESCALEMOD",
            "-I" + str(RTL_DIR), "-I" + str(HW_RTL),
            "--top-module", "sim_top",
            "-Mdir", str(SEQ_OBJ_DIR),
            "--prefix", "Vsim_top"] + generics(args)


# ---------- subcommands ----------

def cmd_lint(args):
    verilator = need_tool("verilator")
    print(f"=== Lint MODE={args.mode} BPC={args.bpc} ===")
    run([verilator] + lint_flags(args) + [str(s) for s in RTL_SRCS], cwd=HERE)


def cmd_build(args):
    verilator = need_tool("verilator")
    run([verilator] + build_flags(args) + [str(s) for s in RTL_SRCS]
        + ["sim_main.cpp"], cwd=HERE)


def cmd_run(args):
    cmd_build(args)
    LOGS_DIR.mkdir(parents=True, exist_ok=True)
    run([str(OBJ_DIR / f"V{TOP}")], cwd=HERE)


def cmd_cov(args):
    vcov = need_tool("verilator_coverage")
    print("=== Coverage report ===")
    LOGS_DIR.mkdir(parents=True, exist_ok=True)
    annotate = subprocess.run([vcov, "--annotate", str(LOGS_DIR / "annotated"),
                               "--annotate-min", "1", str(LOGS_DIR / "coverage.dat")],
                              cwd=str(HERE), capture_output=True, text=True)
    if annotate.returncode != 0:
        print(annotate.stdout)
        print(annotate.stderr, file=sys.stderr)
        sys.exit(annotate.returncode)
    summary = subprocess.run([vcov, str(LOGS_DIR / "coverage.dat")],
                             cwd=str(HERE), capture_output=True, text=True)
    if summary.returncode != 0:
        print(summary.stdout)
        print(summary.stderr, file=sys.stderr)
        sys.exit(summary.returncode)
    report = annotate.stdout + annotate.stderr + summary.stdout + summary.stderr
    print(report)
    (LOGS_DIR / "coverage_summary.txt").write_text(report)
    m = re.search(r"Total coverage\s+\(\d+/\d+\)\s+([0-9.]+)%", report)
    if not m:
        m = re.search(r"line\s+:\s+([0-9.]+)%", report)
    if not m:
        print("ERROR: could not parse total coverage from verilator_coverage output",
              file=sys.stderr)
        sys.exit(1)
    cov = float(m.group(1))
    if cov < 100.0:
        print(f"ERROR: coverage gate failed: total coverage is {cov:.2f}%, expected 100.00%",
              file=sys.stderr)
        sys.exit(1)


def cmd_regression(args):
    cmd_lint(args)
    cmd_run(args)
    cmd_cov(args)
    cmd_check_model(args)


def _config_obj_dir(args: argparse.Namespace) -> Path:
    """Per-config capture obj dir, so multiple configs can coexist /
    build in parallel without stomping on each other."""
    tag = (f"m{args.mode}_b{args.bpc}_s{args.yuv_sub}"
           f"_y{args.raw_bayer}_o{args.rgb_order}")
    return HERE / f"obj_capture_{tag}"


def _capture_flags_for(args: argparse.Namespace, obj_dir: Path) -> list[str]:
    return ["--cc", "--exe", "--build",
            "-Wall", "-Wno-UNUSED", "-Wno-WIDTH", "-Wno-CASEINCOMPLETE",
            "-I" + str(RTL_DIR), "--top-module", TOP,
            "-Mdir", str(obj_dir),
            "--prefix", "Vvtpgz_axilite_top"] + generics(args)


def cmd_capture_build(args):
    verilator = need_tool("verilator")
    # default single-config build still uses the canonical CAPTURE_OBJ_DIR
    run([verilator] + capture_flags(args) + [str(s) for s in RTL_SRCS]
        + ["sim_capture.cpp"], cwd=HERE)


def cmd_check_model(args):
    cmd_capture_build(args)
    python = need_tool("python") if shutil.which("python") else need_tool("python3")
    sim_bin = CAPTURE_OBJ_DIR / "Vvtpgz_axilite_top"
    run([python, str(HW_PY / "check_sim_vs_model.py"),
         "--sim-binary", str(sim_bin),
         "--mode",      MODE_NAMES[args.mode],
         "--bpc",       str(args.bpc),
         "--yuv-sub",   SUB_NAMES[args.yuv_sub],
         "--raw-bayer", BAYER_NAMES[args.raw_bayer],
         "--rgb-order", ORDER_NAMES[args.rgb_order]], cwd=HERE)


def _build_and_check_one(cfg: dict) -> tuple[dict, bool, str]:
    """Worker for parallel all_modes: build a per-config Verilator binary
    in its own obj dir and run check_sim_vs_model against it. Returns
    (cfg, ok, log_tail)."""
    args = argparse.Namespace(**cfg)
    obj_dir = _config_obj_dir(args)
    verilator = shutil.which("verilator")
    python = shutil.which("python") or shutil.which("python3")
    if not verilator or not python:
        return cfg, False, "verilator/python not in PATH"
    build_cmd = ([verilator] + _capture_flags_for(args, obj_dir)
                 + [str(s) for s in RTL_SRCS] + ["sim_capture.cpp"])
    r = subprocess.run(build_cmd, cwd=str(HERE),
                       capture_output=True, text=True)
    if r.returncode != 0:
        return cfg, False, (r.stdout + r.stderr)[-2000:]
    sim_bin = obj_dir / "Vvtpgz_axilite_top"
    check_cmd = [python, str(HW_PY / "check_sim_vs_model.py"),
                 "--sim-binary", str(sim_bin),
                 "--mode",      MODE_NAMES[args.mode],
                 "--bpc",       str(args.bpc),
                 "--yuv-sub",   SUB_NAMES[args.yuv_sub],
                 "--raw-bayer", BAYER_NAMES[args.raw_bayer],
                 "--rgb-order", ORDER_NAMES[args.rgb_order]]
    r = subprocess.run(check_cmd, cwd=str(HERE),
                       capture_output=True, text=True)
    return cfg, r.returncode == 0, (r.stdout + r.stderr)[-2000:]


def cmd_seq_build(args):
    verilator = need_tool("verilator")
    seq_srcs = [str(s) for s in RTL_SRCS] + [
        str(HW_RTL / "bram_sdp.v"),
        str(HW_RTL / "frame_capture.v"),
        "sim_top.v",
    ]
    run([verilator] + seq_flags(args) + seq_srcs + ["sim_capture_seq.cpp"],
        cwd=HERE)


def cmd_seq_run(args):
    cmd_seq_build(args)
    LOGS_DIR.mkdir(parents=True, exist_ok=True)
    run([str(SEQ_OBJ_DIR / "Vsim_top"), "+ncaps=9",
         "+out=" + str(LOGS_DIR / "seq_cap")], cwd=HERE)


def cmd_check_seq(args):
    cmd_seq_run(args)
    python = need_tool("python") if shutil.which("python") else need_tool("python3")
    run([python, str(HW_PY / "check_seq.py"),
         "--mode",      MODE_NAMES[args.mode],
         "--bpc",       str(args.bpc),
         "--yuv-sub",   SUB_NAMES[args.yuv_sub],
         "--raw-bayer", BAYER_NAMES[args.raw_bayer],
         "--rgb-order", ORDER_NAMES[args.rgb_order]], cwd=HERE)


def cmd_check_seq_modes(args):
    """Run the multi-capture sequential gate across RGB/RAW/YUV at 8bpc.

    Catches state-leakage regressions in the per-mode pattern paths
    (BUG-07 was originally only caught at RGB; this widens the gate so
    a future drift in RAW or YUV native palettes also gets flagged).
    """
    sub_configs = [
        dict(mode=0, bpc=8, yuv_sub=0, raw_bayer=1, rgb_order=0),
        dict(mode=1, bpc=8, yuv_sub=0, raw_bayer=1, rgb_order=0),
        dict(mode=2, bpc=8, yuv_sub=0, raw_bayer=1, rgb_order=0),
    ]
    for cfg in sub_configs:
        print("============================================")
        print(f"  check_seq MODE={cfg['mode']} BPC={cfg['bpc']}")
        print("============================================")
        cmd_clean(args)
        sub_args = argparse.Namespace(**cfg)
        cmd_check_seq(sub_args)
    print("\nALL CHECK_SEQ MODES PASS")


def cmd_all_modes(args):
    """Sweep every (output_mode x bpc) and run check_model on each.

    Builds each (mode x bpc x sub x bayer) config in its own obj dir
    so we can run them in parallel without stomping on each other and
    without losing the per-config Verilator artifacts when the next
    one starts. Speedup over the old serial+clean approach is ~Nx
    where N is min(workers, ncores).
    """
    import concurrent.futures
    import os

    configs = []
    for mode in (0, 1, 2):
        for bpc in (8, 10, 12, 14, 16):
            configs.append(dict(mode=mode, bpc=bpc, yuv_sub=0,
                                raw_bayer=1, rgb_order=0))
    configs.append(dict(mode=2, bpc=16, yuv_sub=1, raw_bayer=1, rgb_order=0))
    # RAW mode: also sweep every Bayer tile (PLAIN/RGGB/BGGR/GRBG/GBRG)
    # at 8bpc to exercise the full 4-way Bayer mux.
    for bayer in (0, 2, 3, 4):  # 1 already covered above
        configs.append(dict(mode=1, bpc=8, yuv_sub=0,
                            raw_bayer=bayer, rgb_order=0))

    # Cap workers so we don't fork ncores parallel g++ processes per
    # Verilator build (each Verilator build itself spawns a few jobs).
    n_workers = max(1, min(len(configs), (os.cpu_count() or 4) // 2))
    print(f"Running {len(configs)} configs across {n_workers} workers")

    fails: list[tuple[dict, str]] = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=n_workers) as ex:
        futures = {ex.submit(_build_and_check_one, cfg): cfg
                   for cfg in configs}
        done = 0
        for fut in concurrent.futures.as_completed(futures):
            cfg, ok, log_tail = fut.result()
            done += 1
            tag = (f"mode={cfg['mode']} bpc={cfg['bpc']} "
                   f"sub={cfg['yuv_sub']} bayer={cfg['raw_bayer']}")
            mark = "OK  " if ok else "FAIL"
            print(f"  [{done:2d}/{len(configs)}] {mark}  {tag}")
            if not ok:
                fails.append((cfg, log_tail))

    if fails:
        print(f"\n{len(fails)} CONFIG(S) FAILED:")
        for cfg, log_tail in fails:
            print(f"--- {cfg} ---")
            print(log_tail)
        sys.exit(1)
    print("\nALL MODES PASS")


def cmd_clean(args):
    for d in (OBJ_DIR, CAPTURE_OBJ_DIR, SEQ_OBJ_DIR, LOGS_DIR):
        if d.exists():
            shutil.rmtree(d)
    # also wipe per-config dirs created by all_modes
    for d in HERE.glob("obj_capture_m*"):
        if d.is_dir():
            shutil.rmtree(d)


# ---------- main ----------

def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--mode", type=int, default=0,
                    help="OUTPUT_MODE: 0=RGB, 1=RAW, 2=YUV (default 0)")
    ap.add_argument("--bpc", type=int, default=8, choices=[8, 10, 12, 14, 16],
                    help="bits per component (default 8)")
    ap.add_argument("--yuv-sub", dest="yuv_sub", type=int, default=0,
                    choices=[0, 1], help="0=444, 1=422 (default 0)")
    ap.add_argument("--raw-bayer", dest="raw_bayer", type=int, default=1,
                    choices=[0, 1, 2, 3, 4],
                    help="0=PLAIN 1=RGGB 2=BGGR 3=GRBG 4=GBRG (default 1)")
    ap.add_argument("--rgb-order", dest="rgb_order", type=int, default=0,
                    choices=[0, 1], help="0=Xilinx, 1=legacy (default 0)")
    ap.add_argument("subcommand", choices=[
        "lint", "build", "run", "cov", "regression",
        "capture_build", "check_model",
        "seq_build", "seq_run", "check_seq", "check_seq_modes",
        "all_modes", "clean",
    ])
    args = ap.parse_args()

    handlers = {
        "lint": cmd_lint, "build": cmd_build, "run": cmd_run,
        "cov": cmd_cov, "regression": cmd_regression,
        "capture_build": cmd_capture_build, "check_model": cmd_check_model,
        "seq_build": cmd_seq_build, "seq_run": cmd_seq_run,
        "check_seq": cmd_check_seq, "check_seq_modes": cmd_check_seq_modes,
        "all_modes": cmd_all_modes, "clean": cmd_clean,
    }
    handlers[args.subcommand](args)
    return 0


if __name__ == "__main__":
    sys.exit(main())
