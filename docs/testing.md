# Testing vtpgZero

Full detail on the simulation and hardware regressions. For a quick start
see the [Testing](../README.md#how-to-test-it) section of the main README.

All simulation is orchestrated by a single Python script — there is no
Makefile.

## Icarus Verilog (smoke test)

A minimal smoke test that brings the core out of reset, programs a 32×16
color-bar frame, and checks one frame is emitted:

```sh
iverilog -g2001 -o tb_vtpgz_axilite_top.vvp -I rtl \
    rtl/vtpgz_axil_regs.v rtl/vtpgz_core.v rtl/vtpgz_axilite_top.v \
    tb/tb_vtpgz_axilite_top.v
vvp tb_vtpgz_axilite_top.vvp
```

Expected: `RESULT: pixels=2560 lines=80 frames=5 completed=5 errors=0`
followed by `PASS`.

## Lint

Lint is the first stage of the regression. Run standalone with:

```sh
python sim/run_sim.py lint
```

## Verilator (full simulation + 100% coverage)

Requires `verilator` and a host C++ toolchain on `PATH`.

```sh
python sim/run_sim.py regression   # = lint + build + run + coverage + model gate
```

To sweep every `(OUTPUT_MODE × BPC)` build and run the byte-exact
sim↔model gate on each:

```sh
python sim/run_sim.py all_modes
```

The C++ harness runs **7 phases** for full coverage:

1. **Register sweep** — write `0xFFFFFFFF`/`0x00000000`/`0xAAAAAAAA`/`0x55555555`
   to every register, with rotating `awprot`/`arprot`, then read each back.
   Includes partial-strobe (`wstrb`) writes and an unmapped-address access.
2. **Pattern sweep** — 9 patterns × 4 pixel formats × 3 bit depths on a
   256×128 frame.
3. **Moving box bounce** — runs long enough for the box to bounce off all
   four walls, exercising both edge-clamp branches.
4. **Backpressure** — random `tready` toggling at 7/8 duty to stress the
   stall path.
5. **External frame sync** — multiple rising edges on `frame_sync_in`.
6. **Software frame sync** — `CONTROL[1]` held to force-trigger frames.
7. **Status read while busy** — final readback of every register.

Expected output:

```
RESULT: pixels=4609406 lines=17756 frames=147
PASS
Total coverage (622/622) 100.00%
```

A handful of structurally unreachable items are excluded with
`// verilator coverage_off` and a comment explaining why (BT.601
saturation arms that are mathematically unreachable from 12-bit unsigned
RGB; AXI `bresp`/`rresp` always tied to OKAY; padding bits of `tdata`
that are tied zero by the format-packing spec; upper bits of the
frame-rate divider/`y`/`frame_num` that would only toggle in
multi-million-pixel sims; and the per-lane `PIXELS_PER_CLOCK>1` datapath,
which the PPC=1 coverage build does not exercise — that path is covered by
the cocotb/iverilog PPC gates below).

Outputs land in `sim/logs/`:

- `vtpgz_axilite_top.vcd` — full waveform
- `coverage.dat` — raw coverage database
- `coverage_summary.txt` — overall coverage summary
- `annotated/` — line-annotated source (uncovered lines marked `%00`)

## cocotb

Python-authored spec/property tests live under `sim/cocotb/`. There are two
runners, split by simulator because of a tool quirk:

```sh
# Control plane + AXIS handshake (Verilator runner).
python sim/cocotb/run_cocotb.py

# Pixels-per-clock data path (Icarus runner): programs the core over
# AXI-Lite, captures every AXIS beat, and checks it beat-exact against the
# Python reference model across PIXELS_PER_CLOCK 1/2/4/8 × RGB/RAW/YUV,
# sweeping all 8 synthetic patterns per build (12 suites).
python sim/cocotb/run_ppc.py
```

The PPC data-path suite uses Icarus because cocotb 2.0.1 + Verilator returns
a sampled-once value for the packed `m_axis_tdata`; Icarus reads it
correctly. The Verilator-backed cocotb suites are therefore scoped to the
control plane, and the byte-exact C++ gate in `sim/run_sim.py` remains the
Verilator-backed data-path regression.

A standalone iverilog beat-exact PPC gate (RTL ↔ Python model, all patterns
and modes, PPC 1/2/4/8) is also available:

```sh
python sim/check_ppc_vs_model.py
```

## Hardware test on Arty A7-100T

A complete reference design under `hw/arty_a7_100t/` instantiates the VTPGZ
core, the [fpgacapZero](https://github.com/lcapossio/fpgacapZero)
JTAG-to-AXI4 bridge, and a small AXI-Stream → BRAM frame-capture sink.
The host sweeps all 108 (pattern × format × bpp) combinations through the
FPGA over JTAG, captures each frame, and asserts byte-exact equality
against a Python reference model that mirrors the RTL pipeline
register-by-register.

Requirements:
- Vivado 2025.x (`vivado` and `xsdb` on `PATH`)
- Xilinx `hw_server` running (`hw_server -d`)
- Digilent Arty A7-100T connected via USB
- Submodules initialized: `git submodule update --init --recursive`

Build the bitstream:

```sh
python hw/arty_a7_100t/scripts/build.py
```

Run the full sweep (programs the bitstream + 108 captures + byte-exact
compare):

```sh
python hw/arty_a7_100t/python/run_hw_test.py
```

Expected: `Ran 108 combinations, 0 failures` / `HW PASS - byte-exact across all combinations`.

Architecture and address map are documented in
[hw/arty_a7_100t/README.md](../hw/arty_a7_100t/README.md).

### Pixels-per-clock on silicon

The demo builds at `PIXELS_PER_CLOCK=1` by default. To validate packed-pixel
output on hardware, set `VTPGZ_PIXELS_PER_CLOCK` in
[demo_top.v](../hw/arty_a7_100t/rtl/demo_top.v) (2/4/8), rebuild, and re-run —
`frame_capture` serializes each wide beat into `ceil(TDATA_WIDTH/32)`
little-endian words and `run_hw_test.py` reads back the configured PPC and
checks byte-exact. PPC>1 builds run the demo at a lower clock (`clk_gen`'s
`CLKOUT0_DIVIDE`): the per-lane counter-chain patterns (checker/grid) do not
close 130 MHz, and the demo targets correctness rather than throughput.
PPC=4 is verified byte-exact across all patterns on the board.
