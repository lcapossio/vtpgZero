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

The sweep also covers the three non-default YUV colorimetry builds
(`YUV_MATRIX` × `YUV_RANGE`, minus the default BT.601/full which is already
in the mode sweep) at 8, 10 and 12 bpc, which are the three palette depths.
It adds six `BAR_LEVEL=75` builds as well: BT.709 limited at 8, 10 and 12
bpc, plus one each of YUV BT.601 full, RGB and RAW.

### YUV range, matrix and bar level

The colour-bar palettes are generated from the colorimetry by
`scripts/gen_yuv_palettes.py`, which writes them into `vtpgz_core.v`. CI
checks that the RTL is up to date with the generator:

```sh
python scripts/gen_yuv_palettes.py --check
```

The colorimetry itself is asserted against the Python model, which takes its
palettes from the same generator rather than copying the RTL constants:

```sh
python hw/arty_a7_100t/python/check_yuv_range.py
python hw/arty_a7_100t/python/check_yuv_range_mutations.py
```

The first checks five properties:

- Every build's colour bars equal the standard codes exactly, at 8, 10 and
  12 bpc. That covers RGB and YUV, both matrices, both ranges, and 100% and
  75% bars. It renders a real frame through the model, so palette selection
  is under test too. The expected values are the published tables where
  one exists: the classic 8-bit and 10-bit limited tables, and SMPTE RP 219
  for 75% BT.709. Otherwise they come from an exact-arithmetic
  implementation of BT.601/BT.709/H.273, written separately from the
  generator.
- A limited build keeps every runtime-valued pattern inside Y 64..940 /
  C 64..960, *and actually reaches both ends* on the gradients.
- Neutral chroma stays exactly `0x800`.
- The shipped RGB and BT.601 full-range 100% palettes are unchanged bit for
  bit.
- `image_to_hex.py --yuv` converts the eight bar colours to the published
  8-bit codes.

The second is the reason to believe the first. It mutates the model and
asserts that the check which *owns* that bug is the one that fires. The
mutations are:

- move a palette constant by one LSB;
- give an 8-bit build the 10-bit codes truncated (the bug the per-depth
  palettes fix);
- give a 75% build the 100% bars;
- drop the limited-range luma map;
- rescale the raw colour registers;
- make the image converter ignore `--matrix`.

A spec test nobody has seen fail is not evidence.

Together with `all_modes`, this is what carries the spec through to RTL: the
model is checked against the standard, and the RTL is checked byte-for-byte
against the model.

One case the model cannot reach is a pattern stripped at build time, since
the model has no `EN_*` flags. A stripped slot is documented to read as
black, and in YUV black is `{Y_black, 0x800, 0x800}` — the all-zero triple is
saturated green. `tb/tb_black.v` builds the core with COLORBAR, SOLID and
IMAGE stripped and checks those slots plus slot 5 are exactly black on every
lane, at PPC 1/2/4/8 in both ranges:

```sh
python sim/run_iverilog_black.py
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

## Parallel video adapter (FVAL/LVAL/DVAL)

`tb/tb_flvdval.v` drives `vtpgz_axis_to_flvdval` from a real core instance and
checks the raster properties a parallel sink depends on, all derived from the
geometry rather than from the adapter's own outputs:

- `LVAL` high for exactly `IMG_WIDTH` cycles per line, `IMG_HEIGHT` lines
  inside every `FVAL`;
- horizontal blanking exactly `LINE_GAP_CYCLES`;
- vertical blanking exactly `FRAME_RATE_DIV - ACTIVE`, where
  `ACTIVE = W*H + LINE_GAP_CYCLES*(H-1)`;
- `DVAL` never outside `LVAL`, `LVAL` never outside `FVAL`, and the `DVAL`
  count equal to the number of AXIS beats (nothing dropped or invented);
- `PIX_DATA` equal to the AXIS beat on every `DVAL`;
- `FIELD_ID` alternating across fields for an interlaced source.

A second adapter instance on the same stream uses `FVAL_LEAD=4`,
`FVAL_TRAIL=6` and measures both porches, plus a testbench-side copy of the
delay line proving the pixel path really is delayed by `FVAL_LEAD`.

`FIELD_ID` is sampled at the **FVAL rising edge**, not just at its fall: FVAL
rises combinationally on SOF, so a receiver latching the field ID on that edge
must not see the previous field's parity.

A third instance is fed a hand-built stream so the failure case is deliberate:
`TIMING_ERR` must stay clear on a gap-free stream, must latch when a mid-line
bubble is injected, and must clear on `timing_err_clr`. A fourth, with
`FVAL_LEAD=4`, checks the porch-envelope violation: clean with blanking wider
than the porch, `TIMING_ERR` latched when the next SOF arrives while the
previous frame is still draining the delay line.

`tb/tb_gapfree.v` pins down the assumption the adapter has no FIFO to survive
without. The runner sweeps 11 configurations — `PIXELS_PER_CLOCK` 1/2/4/8,
NOISE (leap-ahead LFSR), the BRAM-backed IMAGE build at PPC 1 and 4, a width
that is not a multiple of PPC, a single-line frame, minimum (1-cycle) vertical
blanking, and a frame rate below the active time — and each run asserts that
every `LVAL` pulse is exactly `IMG_WIDTH/PPC` cycles (min == max), that
`TIMING_ERR` never latches, and that vertical blanking equals the documented
arithmetic.

```sh
python sim/run_iverilog_flvdval.py
```

`tb/tb_flvmon.v` covers `flv_monitor`, the fabric instrument the board test
reads its numbers from. That matters because `run_hw_flvdval.py` asserts
nothing directly -- it compares the monitor's counters against the geometry,
so a wrong monitor either invents a hardware failure or hides a real one.
`tb_gapfree` checks the same raster properties but measures them with its own
testbench-side counters and never instantiates the monitor, which is how an
off-by-one in it reached the board once already (see below). The runner sweeps
5 configurations including 1-cycle blanking, a dropped-tick frame rate, and an
interlaced source.

The `min == max` comparisons are the load-bearing ones: a monitor that
mismeasures a single interval out of many still moves `min` or `max` and
cannot average the error away. Reintroducing the first-blanking-interval bug
makes `tb_flvmon` fail while `tb_flvdval` and all 11 `tb_gapfree` configs
still pass -- that mutation is what establishes the bench is doing work.

```sh
python sim/run_iverilog_flvdval.py
```

Expected: `PASS: tb_flvdval FVAL/LVAL/DVAL adapter`.

### On hardware

The Arty demo instantiates the adapter on the same stream the capture sink
sees, plus `flv_monitor`, which measures the emitted raster in fabric and
reports it through the capture CSR window (`0x0001_0010`-`0x0001_0020`, see
`hw/arty_a7_100t/README.md`). The pixel bus stays on-chip -- at
`PIXELS_PER_CLOCK=4` it is 96 bits wide, so no board can bring it out -- and
what is proven on silicon is the timing.

```sh
python hw/arty_a7_100t/python/run_hw_flvdval.py
```

The script asserts the same properties `tb_gapfree` asserts in simulation:
LVAL pulse min == max == `IMG_WIDTH/PPC`, lines per frame == `IMG_HEIGHT`,
vertical blanking min == max == `PERIOD - ACTIVE`, `TIMING_ERR` clear, DVAL
identical to LVAL throughout, and `FIELD_ID` alternating at the FVAL rising
edge for an interlaced source. Every expected value is computed from the
geometry, not read back from the adapter.

It sets `FLV_MODE[0]` first, which hands `tready` from `frame_capture` to the
adapter and ties it high; the source must free-run gap-free because a parallel
interface cannot express a stall. Capture is meaningless while that bit is
set, and the script clears it on the way out.

Two counter widths bound what can be asked of it. The monitor counts blanking
in 16 bits, so the script checks each case's expected blanking against that
before trusting the comparison rather than silently measuring a wrapped value;
pick a faster `FRAME_RATE_DIV` if a geometry trips the assertion. The frame
count saturates at 255 instead of wrapping, because a single JTAG round trip
is long enough for thousands of frames to pass.

## Interlaced field ID (fid)

`tb/tb_interlace.v` drives an `EN_INTERLACE=1` build alongside a stripped
(`EN_INTERLACE=0`) instance and checks the AMD/Xilinx field convention:
one field per sync pulse with SOF on its first beat, `fid` stable for every
beat of a field, alternating 0/1 under internal sync, following `fid_in`
under external sync, and constant 0 for a progressive stream or a stripped
build.

```sh
python sim/run_iverilog_interlace.py
```

Expected: `PASS: tb_interlace field ID (fid)`.

### On hardware

```sh
python hw/arty_a7_100t/python/run_hw_interlace.py
```

This requires the Arty A7-100T demo bitstream (built with `EN_INTERLACE=1`).
It checks that consecutive field starts alternate and that every captured
field is byte-exact against the Python model at the field height.

Alternation is read from the demo sink's `FID_HIST` register, not from the
per-capture `CAPTURE_STATUS[1]`. `frame_capture` holds `s_axis_tready` low
unless it is capturing, and its FSM stops on the second `tuser`, so each
capture consumes exactly two field starts (confirmed on the board: the
core's `frame_count` advances by 2 per capture) and every capture lands on
the same parity. That is a property of the demo sink, not of the core — see
[hw/arty_a7_100t/README.md](../hw/arty_a7_100t/README.md).

## Hardware test on Arty A7-100T

A complete reference design under `hw/arty_a7_100t/` instantiates the VTPGZ
core, the [fpgacapZero](https://github.com/lcapossio/fpgacapZero)
JTAG-to-AXI4 bridge, and a small AXI-Stream → BRAM frame-capture sink.
The host runs all 9 patterns through the FPGA over JTAG, captures each
frame, and asserts byte-exact equality against a Python reference model that
mirrors the RTL pipeline register-by-register. Output format, bit depth and
pixels per clock are build-time, so the host reads them back from the loaded
bitstream; covering another format means building another bitstream (see
[Other output formats on silicon](#other-output-formats-on-silicon)).

Requirements:
- Vivado 2025.x (`vivado` and `xsdb` on `PATH`)
- Xilinx `hw_server` running (`hw_server -d`)
- Digilent Arty A7-100T connected via USB
- Submodules initialized: `git submodule update --init --recursive`

Build the bitstream:

```sh
python hw/arty_a7_100t/scripts/build.py
```

Run the test (programs the bitstream, captures each of the 9 patterns,
byte-exact compare):

```sh
python hw/arty_a7_100t/python/run_hw_test.py
```

Expected: `Ran 9 patterns, 0 failures` / `HW PASS — byte-exact across all patterns`.

Architecture and address map are documented in
[hw/arty_a7_100t/README.md](../hw/arty_a7_100t/README.md).

### Other output formats on silicon

The demo's core build configuration is a set of `demo_top` parameters, so a
RAW or YUV bitstream needs no source edit. Pass them to `build.py`:

```sh
python hw/arty_a7_100t/scripts/build.py VTPGZ_OUTPUT_MODE=2 VTPGZ_BPC=10     VTPGZ_YUV_RANGE=1 VTPGZ_YUV_MATRIX=1
python hw/arty_a7_100t/python/run_hw_test.py --yuv-range limited --yuv-matrix 709
```

`run_hw_test.py` reads mode, BPC, subsampling, Bayer order and PPC back from
the bitstream, but YUV range, matrix and bar level are not in
`COLOR_FORMAT`, so they must be given on the command line to match the build.
Getting them wrong cannot pass quietly: against the wrong colorimetry the
colorbar, gradients, checker and grid background all mismatch, and against
the wrong bar level the colorbar does.

YUV 4:4:4, 10 bpc, limited range, BT.709 is verified byte-exact across all
patterns on the board (0 DSPs, timing met). As a negative control, the same
bitstream checked against full-range BT.601 fails 8 of 9 patterns, with the
board showing gradient white at 940 and black at 64: the limited-range map is
active on silicon, not just matching by coincidence. Only SOLID matches both
ways, because colour registers are raw code values by design.

Two more colorimetry builds are verified byte-exact across all patterns on
the board, each with a negative control:

- BT.709 limited, **75% bars** (`VTPGZ_BAR_LEVEL=75`), 10 bpc: SMPTE RP 219.
  Checked against 100% bars instead, the colour bars fail and nothing else
  does.
- BT.709 limited, 100% bars, **8 bpc**: the classic 8-bit table. Checked
  against the 10-bit codes truncated (what the core emitted before each
  bit depth got its own palette), the colour bars fail: the board sends cyan
  Cb 154, the published code, where truncation gives 615 >> 2 = 153.

```sh
python hw/arty_a7_100t/scripts/build.py VTPGZ_OUTPUT_MODE=2 VTPGZ_BPC=10     VTPGZ_YUV_RANGE=1 VTPGZ_YUV_MATRIX=1 VTPGZ_BAR_LEVEL=75
python hw/arty_a7_100t/python/run_hw_test.py --yuv-range limited     --yuv-matrix 709 --bar-level 75
```

### Pixels-per-clock on silicon

The demo builds at `PIXELS_PER_CLOCK=4` by default. For another width, pass
it to the build, e.g. `build.py VTPGZ_PIXELS_PER_CLOCK=1` (1/2/4/8), and
re-run — `frame_capture` serializes each wide beat into
`ceil(TDATA_WIDTH/32)` little-endian words and `run_hw_test.py` reads back
the configured PPC and checks byte-exact. PPC>1 builds run the demo at
50 MHz instead of 130 MHz (`clk_gen`'s `CLKOUT0_DIVIDE`): the per-lane
counter-chain patterns (checker/grid) do not close 130 MHz, and the demo
targets correctness rather than throughput. `build.tcl` prints the clock the
build was actually constrained at. PPC=4 is verified byte-exact across all
patterns on the board.
