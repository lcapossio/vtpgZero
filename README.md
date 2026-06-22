# vtpgZero — Video Test Pattern Generator

A synthesizable Verilog-2001 video test pattern generator IP core. Outputs
pixels over an AXI4-Stream master interface and is configured at runtime via
an AXI4-Lite slave register interface.

## Index

- [What this project does](#what-this-project-does)
- [Features](#features)
- [Register map](#register-map-axi4-lite-32-bit)
- [How to test it](#how-to-test-it)
  - [Icarus Verilog smoke test](#icarus-verilog-smoke-test)
  - [Lint](#lint)
  - [Verilator full simulation + 100% coverage](#verilator-full-simulation--100-coverage)
  - [Hardware test on Arty A7-100T](#hardware-test-on-arty-a7-100t)
- [How to use it](#how-to-use-it)
  - [Build-time parameters](#build-time-parameters)
  - [Using vtpgz_core (port-driven, no AXI slave)](#using-vtpgz_core-port-driven)
  - [Using vtpgz_axilite_top (AXI4-Lite controlled)](#using-vtpgz_axilite_top-axi4-lite-controlled)
  - [Programming sequence](#programming-sequence)
  - [External frame sync](#external-frame-sync)
- [FPGA resource usage and frequency](#fpga-resource-usage-and-frequency)
  - [Resource matrix per build-time configuration](#resource-matrix-per-build-time-configuration)
- [File layout](#file-layout)
- [Author and license](#author-and-license)

## What this project does

`vtpgZero` produces video frames of various test patterns at programmable
resolution, pixel format, and bit depth. It can free-run from an internal
divider or be locked to an external frame-sync signal. The output stream is
standard AXI4-Stream with backpressure (`tready`), `tlast` = end of line, and
`tuser` = start of frame.


[↑ back to top](#index)

## Features

- **8 patterns**: SMPTE color bars, horizontal gradient, vertical gradient,
  checkerboard, solid color, crosshatch/grid, color ramp, LFSR
  pseudo-random noise.
- **Bouncing box overlay**: optional animated box that overlays on top of
  any pattern. The box color is configurable via `BOX_COLOR`, and it
  bounces off the frame edges at a configurable speed. To get "box on
  a solid background", just select the solid-color pattern and set
  `SOLID_COLOR` to your desired background. Stripped at elaboration
  when `EN_MOVING_BOX=0`.
- **3 build-time output modes**: pick exactly one at synthesis time
  - **RGB** — direct RGB888/RGB101010/RGB121212
  - **RAW** — single-component: plain monochrome, or any of the 4
    standard Bayer mosaics (RGGB / BGGR / GRBG / GBRG). Smallest
    configuration, useful as an image-sensor emulator
  - **YUV** — native BT.601-style 4:4:4 or 4:2:2 (patterns produce
    `{Y,Cb,Cr}` directly)
- **5 bit depths** (build-time): 8 / 10 / 12 / 14 / 16 bits per component.
  Patterns render at 12-bit precision; the pack stage truncates LSBs for
  `BPC<12` and zero-extends LSBs for `BPC>12`.
- Auto-derived `tdata` width — the smallest multiple-of-8 that fits the
  active components for the chosen mode/bpc. No manual sizing needed.
- **AXI4-Lite** slave for runtime configuration (18 registers).
- **AXI4-Stream** master output with full backpressure support.
- **Frame sync**: internal (clock divider) or external (rising-edge input)
- Pure **Verilog-2001**, no SystemVerilog, no vendor primitives.
- **Build-time pattern selection**: each pattern is gated by an `EN_*`
  parameter and stripped from the netlist when set to `0`.
- **100% Verilator code coverage** (line + toggle) under the bundled
  testbench.


[↑ back to top](#index)

## Register map (AXI4-Lite, 32-bit)

| Offset | Name           | Description                                          |
|--------|----------------|------------------------------------------------------|
| 0x00   | CORE_ID        | **RO** fixed magic `0x47505456` = ASCII "VTPG" little-endian. Read this first to confirm you're talking to a vtpgZero core. |
| 0x04   | VERSION        | **RO** `{major[8], minor[8], patch[16]}`             |
| 0x08   | CONTROL        | `[0]` enable, `[1]` sw_fsync, `[2]` ext_sync         |
| 0x0C   | STATUS         | **RO** `[0]` busy, `[15:8]` frame_count              |
| 0x10   | IMG_WIDTH      | active pixels per line                                |
| 0x14   | IMG_HEIGHT     | active lines per frame                                |
| 0x18   | PATTERN_SEL    | 0=colorbar 1=hgrad 2=vgrad 3=checker 4=solid 5=(reserved) 6=grid 7=ramp 8=noise |
| 0x1C   | COLOR_FORMAT   | **RO** build-time configuration mirror: `[1:0]`=output_mode (0=RGB 1=RAW 2=YUV), `[2]`=yuv_subsample (0=444 1=422), `[5:3]`=raw_bayer (0=PLAIN 1=RGGB 2=BGGR 3=GRBG 4=GBRG), `[6]`=rgb_order (0=Xilinx 1=legacy), `[15:8]`=BPC (8/10/12/14/16), `[31:16]`=TDATA_WIDTH |
| 0x20   | SOLID_COLOR    | `{8'h0, R[8], G[8], B[8]}`                           |
| 0x24   | BOX_COLOR      | moving box color                                     |
| 0x28   | BOX_SIZE       | `{width[16], height[16]}`                            |
| 0x2C   | BOX_SPEED      | `{dx[16], dy[16]}` pixels per frame                  |
| 0x30   | *(reserved)*   | future use                                           |
| 0x34   | GRID_SPACING   | grid line spacing in pixels                          |
| 0x38   | GRID_COLOR     | grid line color                                      |
| 0x3C   | CHECKER_SIZE   | checkerboard square size in pixels                   |
| 0x40   | FRAME_RATE_DIV | clocks per frame for internal sync mode              |
| 0x44   | BAR_WIDTH      | colorbar width in pixels (host writes `img_width/8`) |
| 0x48   | HG_STEP        | horizontal-gradient step per pixel (`0xFFF/(width-1)`) |
| 0x4C   | VG_STEP        | vertical-gradient step per line (`0xFFF/(height-1)`)   |
| 0x50   | BOX_BORDER     | `{border_width[8], border_color[24]}`. Border is drawn inside the box; `border_width=0` means no border. |

AXI4-Lite writes honor `WSTRB` byte lanes. A write with `WSTRB=0`
acknowledges but leaves the addressed register unchanged, including
`CONTROL`.


[↑ back to top](#index)

## How to test it

### Icarus Verilog (smoke test)

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

### Lint

Lint is the first stage of the regression. Run standalone with:

```sh
python sim/run_sim.py lint
```

### Verilator (full simulation + 100% coverage)

Requires `verilator` and a host C++ toolchain on `PATH`. The orchestration
is a single Python script — there is no Makefile.

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
RESULT: pixels=4609830 lines=17757 frames=146
PASS
Total coverage (579/579) 100.00%
```

A handful of structurally unreachable items are excluded with
`// verilator coverage_off` and a comment explaining why (BT.601
saturation arms that are mathematically unreachable from 12-bit unsigned
RGB; AXI `bresp`/`rresp` always tied to OKAY; padding bits of `tdata`
that are tied zero by the format-packing spec; upper bits of the
frame-rate divider/`y`/`frame_num` that would only toggle in
multi-million-pixel sims).

Outputs land in `sim/logs/`:

- `vtpgz_axilite_top.vcd` — full waveform
- `coverage.dat` — raw coverage database
- `coverage_summary.txt` — overall coverage summary
- `annotated/` — line-annotated source (uncovered lines marked `%00`)

### Hardware test on Arty A7-100T

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
[hw/arty_a7_100t/README.md](hw/arty_a7_100t/README.md).


[↑ back to top](#index)

## How to use it

vtpgZero ships in two flavors. Pick whichever fits how the rest of your
system is wired:

* **`vtpgz_core`** — direct port-driven core. No AXI slave, no register
  file. Drive the cfg_* fields from your own RTL (or tie them to
  constants for a fully static colorbar / sensor-emulator build). This
  is the smallest, most portable form.
* **`vtpgz_axilite_top`** — thin wrapper around `vtpgz_core` that adds
  the `vtpgz_axil_regs` AXI4-Lite slave so a CPU/host can configure the
  core at runtime over AXI. This is what the Arty A7-100T demo uses.

The two flavors have **identical** pattern/output behavior — they only
differ in how the cfg_* fields get into the core.

Everything is portable Verilog-2001 with no vendor primitives:

```
rtl/vtpgz_defs.vh        — `include this header (or add rtl/ to your include dirs)
rtl/vtpgz_core.v         — the substance: timing engine, patterns (native
                           per-mode color space), inline pack stage,
                           AXIS output. Configuration via cfg_* input
                           ports. Instantiate this directly if you want
                           cfg-from-RTL or fully-static builds.
rtl/vtpgz_axil_regs.v    — AXI4-Lite slave + register file (only needed
                           with the AXI-Lite wrapper)
rtl/vtpgz_axilite_top.v  — thin wrapper that adds an AXI4-Lite slave on
                           top of vtpgz_core for runtime control
```

### Build-time parameters

| Parameter | Default | Effect |
|---|---|---|
| `C_S_AXI_ADDR_WIDTH` | 8 | AXI4-Lite address width (8 = 256 B = enough for 18 regs) |
| `C_S_AXI_DATA_WIDTH` | 32 | AXI4-Lite data width (only 32 supported) |
| `EN_COLORBAR`   | 1 | Strip the SMPTE colorbar generator if 0 |
| `EN_HGRAD`      | 1 | Strip horizontal-gradient generator if 0 |
| `EN_VGRAD`      | 1 | Strip vertical-gradient generator if 0 |
| `EN_CHECKER`    | 1 | Strip checkerboard generator if 0 |
| `EN_SOLID`      | 1 | Strip solid-color generator if 0 |
| `EN_MOVING_BOX` | 1 | Strip the bouncing-box overlay if 0. When 1, the box is drawn on top of any active pattern using `BOX_COLOR` |
| `EN_GRID`       | 1 | Strip grid/crosshatch generator if 0 |
| `EN_RAMP`       | 1 | Strip color-ramp generator if 0 |
| `EN_NOISE`      | 1 | Strip LFSR noise generator if 0 |
| `OUTPUT_MODE`   | 0 (RGB) | **0** = RGB; **1** = RAW; **2** = YUV. Patterns produce native components in the chosen color space; the output stage just bit-shrinks/zero-extends and reorders. |
| `YUV_SUBSAMPLE` | 0 (444) | Only meaningful when `OUTPUT_MODE=2`. **0** = 4:4:4; **1** = 4:2:2 |
| `RAW_BAYER`     | 1 (RGGB)| Only meaningful when `OUTPUT_MODE=1`. **0** = plain monochrome (G channel); **1** = RGGB; **2** = BGGR; **3** = GRBG; **4** = GBRG. The four Bayer tiles follow standard naming (row-by-row, left to right, top to bottom) |
| `RGB_ORDER`     | 0 (Xilinx) | Component order in `tdata`. **0** = `{pad, B, G, R}` Xilinx PG044; **1** = `{R, G, B, pad}` legacy MSB-first |
| `BPC`           | 8 | Bits per component. Allowed: 8, 10, 12, 14, 16. Patterns render at 12-bit; pack stage truncates LSBs (`BPC<12`), passes through (`BPC=12`), or zero-extends LSBs (`BPC>12`) |
| `C_AXIS_TDATA_WIDTH` | (auto) | **Derived**: smallest multiple-of-8 that holds the active components. Don't override unless you really know what you're doing |

**Output mode notes**:
- `OUTPUT_MODE=0` (RGB) outputs 3-component RGB packed as
  `{ pad, B, G, R }` (or `{R, G, B, pad}` with `RGB_ORDER=1`).
- `OUTPUT_MODE=1` (RAW) outputs 1 component per pixel:
  - `RAW_BAYER=0` → plain monochrome (G channel from each rendered pixel)
  - `RAW_BAYER=1` → **RGGB** Bayer mosaic — `row0:[R,G] row1:[G,B]`
  - `RAW_BAYER=2` → **BGGR** Bayer mosaic — `row0:[B,G] row1:[G,R]`
  - `RAW_BAYER=3` → **GRBG** Bayer mosaic — `row0:[G,R] row1:[B,G]`
  - `RAW_BAYER=4` → **GBRG** Bayer mosaic — `row0:[G,B] row1:[R,G]`
  - All five RAW variants are useful as image-sensor emulators; pick
    whichever Bayer tile matches the sensor you're emulating. **This
    is the smallest configuration**: ~50 LUT smaller than RGB.
- `OUTPUT_MODE=2` (YUV) emits BT.601-style YCbCr **directly** from the
  pattern generators — no runtime color-space conversion of any kind.
  Each pattern has a native YUV variant: the colorbar uses a
  precomputed BT.601 YUV palette, and grayscale-style patterns
  (gradients/ramp/noise/checker/grid) put their value in the Y component
  and hold Cb=Cr=0x800 (neutral chroma). Solid/box/grid color
  *registers* are interpreted by the host as `{Y,Cb,Cr}` triples in YUV
  builds.
  - `YUV_SUBSAMPLE=0` → 4:4:4 (3 components per beat: `{V, U, Y}`)
  - `YUV_SUBSAMPLE=1` → 4:2:2 (2 components per beat: `{C, Y}`, `C`
    alternates Cb on even-x pixels and Cr on odd-x)

A pattern that is stripped at build time still has its `PATTERN_SEL`
slot in the runtime register, but selecting it at runtime produces a
black frame. **At least one pattern** must remain enabled or the design
has no valid pattern source. The `COLOR_FORMAT` register at offset 0x18
is **read-only** and reflects the build-time configuration so software
can probe it.

### Using `vtpgz_core` (port-driven, no AXI slave)

`vtpgz_core` exposes the configuration fields as plain input ports — one
per AXI-Lite register field. There is no register file inside the
core, so a `vtpgz_core`-only build pulls in `rtl/vtpgz_defs.vh` and
`rtl/vtpgz_core.v` and nothing else.

The 18 cfg_* ports are the same fields that `vtpgz_axil_regs` would
drive: `cfg_enable`, `cfg_sw_fsync`, `cfg_ext_sync`, `cfg_img_width`,
`cfg_img_height`, `cfg_pattern`, `cfg_solid_color`, `cfg_box_color`,
`cfg_box_width`, `cfg_box_height`, `cfg_box_dx`, `cfg_box_dy`,
`cfg_grid_spacing`, `cfg_grid_color`, `cfg_checker_size`,
`cfg_frame_rate_div`, `cfg_bar_width`, `cfg_hg_step`, `cfg_vg_step`.
Status outputs `sts_busy` (1 bit) and `sts_frame_count[7:0]` are also
exposed.

A typical fully-static instantiation — a 1920×1080 SMPTE colorbar
generator with no CPU in sight, free-running at 60 fps from a
130 MHz clock — looks like this:

```verilog
vtpgz_core #(
    // Strip everything but colorbar to keep area minimal
    .EN_COLORBAR   (1),
    .EN_HGRAD      (0), .EN_VGRAD     (0), .EN_CHECKER (0),
    .EN_SOLID      (0), .EN_MOVING_BOX(0), .EN_GRID    (0),
    .EN_RAMP       (0), .EN_NOISE     (0),
    .OUTPUT_MODE   (0),  // 0=RGB 1=RAW 2=YUV
    .RGB_ORDER     (0),  // 0=Xilinx 1=legacy
    .BPC           (8)   // 8/10/12/14/16
) u_vtpgz (
    .aclk          (aclk),
    .aresetn       (aresetn),

    // Static configuration -- tie everything to its compile-time value.
    // The synth tool constant-folds disabled patterns, comparators, and
    // unused color slots out of the netlist.
    .cfg_enable        (1'b1),                  // run forever
    .cfg_sw_fsync      (1'b0),
    .cfg_ext_sync      (1'b0),                  // use internal frame sync
    .cfg_img_width     (16'd1920),
    .cfg_img_height    (16'd1080),
    .cfg_pattern       (4'd0),                  // colorbar
    .cfg_solid_color   (24'h000000),            // unused
    .cfg_box_color     (24'h000000),            // unused
    .cfg_box_width     (16'd0),                 // unused
    .cfg_box_height    (16'd0),                 // unused
    .cfg_box_dx        (16'd0),
    .cfg_box_dy        (16'd0),
    .cfg_grid_spacing  (16'd0),
    .cfg_grid_color    (24'h000000),
    .cfg_checker_size  (16'd0),
    .cfg_frame_rate_div(32'd2_166_666),         // 130 MHz / 60 fps
    .cfg_bar_width     (16'd240),               // 1920 / 8
    .cfg_hg_step       (16'd0),
    .cfg_vg_step       (16'd0),

    // Status -- leave dangling if you don't need them
    .sts_busy          (),
    .sts_frame_count   (),

    // AXI4-Stream master (video out)
    .m_axis_tdata      (vid_tdata),
    .m_axis_tvalid     (vid_tvalid),
    .m_axis_tready     (vid_tready),
    .m_axis_tlast      (vid_tlast),
    .m_axis_tuser      (vid_tsof),

    // External frame sync (only used when cfg_ext_sync=1)
    .frame_sync_in     (1'b0)
);
```

If you'd rather drive cfg_* from your own RTL (e.g., from a small FSM
that swaps patterns once per second, or from a sideband bus that isn't
AXI-Lite), just connect those signals to your own logic instead of
constants. Behavior is identical to a register write to the AXI-Lite
flavor.

For host-precomputed register values that the AXI-Lite flavor
initialises automatically, see the **Programming sequence** section
below — those are the same numbers you tie to the cfg_* ports.

#### Driving `vtpgz_core` (waveform)

The core is **synchronous** to a single clock `aclk`, uses synchronous
reset on `aresetn` (active-low), and emits video on a standard AXI4-
Stream master with `tvalid` / `tready` / `tlast` (end-of-line) /
`tuser` (start-of-frame). Required signal handling:

1. Hold `aresetn` low for **≥ 1 `aclk` cycle**, then release.
2. Drive `cfg_*` to stable values (or wire them to constants for a
   static build). Most importantly `cfg_img_width`, `cfg_img_height`,
   `cfg_pattern`, the host-precomputed step values
   (`cfg_bar_width`, `cfg_hg_step`, `cfg_vg_step` — see the
   **Programming sequence** section below for the formulas), and
   `cfg_frame_rate_div`.
3. Assert `cfg_enable = 1`. Until `cfg_enable` goes high the timing
   engine is idle and the AXI-Stream output stays at `tvalid = 0`.
4. Pick a frame-sync source:
    - **Internal sync** (default): leave `cfg_ext_sync = 0`. The core
      asserts an internal one-cycle pulse every `cfg_frame_rate_div`
      clocks while `cfg_enable` is high; each pulse starts a new
      frame.
    - **External sync**: set `cfg_ext_sync = 1` and drive
      `frame_sync_in` from any vsync-style signal. The core does
      **rising-edge detection** on `frame_sync_in`.
    - **Software one-shot**: pulse `cfg_sw_fsync = 1` for one cycle
      to force a single frame start.
5. Pull `m_axis_tready` high to consume the stream. If your sink is
   not always ready, just toggle `tready` whenever you can accept a
   beat — the core will stall the pipeline cleanly and resume
   without losing or duplicating any pixel.

The handshake is plain AXI-Stream: a beat completes only when
`tvalid && tready` are both high on a rising edge of `aclk`. `tuser`
(SOF) is asserted only on the first beat of each frame; `tlast`
(EOL) is asserted on the last beat of every line.

```text
phase      |reset|---- idle, wait for frame_start ----|---------- frame N, beats stream out ------------|
cycle       0  1  2  3  4  5  6  7  8  9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30
aclk       _╱‾╲_╱‾╲_╱‾╲_╱‾╲_╱‾╲_╱‾╲_╱‾╲_╱‾╲_╱‾╲_╱‾╲_╱‾╲_╱‾╲_╱‾╲_╱‾╲_╱‾╲_╱‾╲_╱‾╲_╱‾╲_╱‾╲_╱‾╲_╱‾╲_╱‾╲_╱‾╲_
aresetn    ____╱‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾
cfg_enable __________╱‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾
frame_start* _________________________╱‾╲_____________________________________________________________
m_axis_tready ___________________╱‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾╲_____╱‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾
m_axis_tvalid ____________________________________╱‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾
m_axis_tuser  ____________________________________╱‾‾‾╲___________________________________________________________
m_axis_tlast  __________________________________________________________________________________╱‾‾‾╲_
m_axis_tdata  -------------------------------|P00|P10|P20|P30|P30|P30|P40|P50|P60|P70|P80|...|PNL|---
                                               ▲          ▲       ▲                          ▲
                                               │          │       │                          │
                                            first beat    │     tready=1 again,           last beat
                                            tuser=1       │     P40 advances                of line
                                            (SOF)         │                                tlast=1 (EOL)
                                                          │
                                                       backpressure window:
                                                       tready=0 for 2 cycles,
                                                       P30 held on the bus,
                                                       no pixel lost
```

Legend: `Pxy` = pixel at column x, row y. `PNL` = last beat of the
line (`tlast=1`). `*frame_start` is an internal node, shown for
illustration only — it's the OR of `cfg_sw_fsync`, the internal-sync
pulse, and the rising-edge of `frame_sync_in` (gated by
`cfg_ext_sync`). You don't need to drive or observe it.

A beat **completes** only on a rising edge of `aclk` where both
`tvalid && tready` are high. In the window above, P00..P30 are
consumed cleanly (cycles 16..19), then the sink drops `tready` for
two clocks while the core holds `tvalid=1` and the same `P30` value
on `tdata`. As soon as `tready` rises again, the next beat (`P40`)
advances on the very next edge.

Notes:

- **Latency from sync to first beat is 2 clocks**: when `frame_start`
  asserts, the timing engine moves to ACTIVE on the next edge, then
  the pre-mux and post-mux pixel pipeline stages advance together
  before the AXI output register presents the first beat. `tuser`,
  `tlast`, and `tdata` are delayed together, so the stream-visible
  frame contents are unchanged.
- **No blanking intervals**: the core streams the active picture only.
  `tuser` is asserted on the first beat of each frame, `tlast` on the
  last beat of each line, and everything in between flows back-to-back.
  Inter-line and inter-frame timing should be handled by a downstream
  video-timing block (or a simple throttle FSM) by holding `tready` low
  for the right number of clocks during HBLANK / VBLANK.
- **Backpressure** is honoured cycle-by-cycle. When `tvalid && !tready`
  on any beat, all internal pipeline stages stall in place; nothing
  is dropped or repeated.
- **Ignored mid-frame syncs**: a `frame_start` pulse that arrives
  while a frame is still in flight (`active = 1`) is **dropped**, not
  queued. This is the right behavior for a free-running vsync — if
  the sink is too slow to consume the current frame, the next vsync
  is skipped instead of frames piling up.
- **Reset clears state**: `aresetn = 0` clears the timing engine,
  the AXI output register, and all pattern state. After release,
  the first frame after `cfg_enable` rises uses fresh
  pattern-counter state (this is the BUG-07 fix in [no_commit/BUGS.md] —
  see the multi-capture sequential gate `python sim/run_sim.py
  check_seq` for how it's tested).

### Using `vtpgz_axilite_top` (AXI4-Lite controlled)

`vtpgz_axilite_top` is a thin wrapper that instantiates
`vtpgz_axil_regs` and a `vtpgz_core` instance back-to-back. Its public
interface is an AXI4-Lite slave for control plus the same AXI4-Stream
master for video out. Drop it in, wire your AXI4-Lite master, and use
the **Programming sequence** below to configure it from software.

```verilog
vtpgz_axilite_top #(
    .C_S_AXI_ADDR_WIDTH (8),
    .C_S_AXI_DATA_WIDTH (32),
    // Strip unused patterns to save area
    .EN_COLORBAR   (1),
    .EN_HGRAD      (1),
    .EN_VGRAD      (1),
    .EN_CHECKER    (1),
    .EN_SOLID      (1),
    .EN_MOVING_BOX (1),
    .EN_GRID       (1),
    .EN_RAMP       (1),
    .EN_NOISE      (1),
    // Output mode (build-time)
    .OUTPUT_MODE   (0),  // 0=RGB 1=RAW 2=YUV
    .YUV_SUBSAMPLE (0),  // 0=444 1=422 (only for OUTPUT_MODE=2)
    .RAW_BAYER     (1),  // 0=PLAIN 1=RGGB 2=BGGR 3=GRBG 4=GBRG (only for OUTPUT_MODE=1)
    .RGB_ORDER     (0),  // 0=Xilinx 1=legacy
    .BPC           (8)   // 8, 10, 12, 14, or 16
    // C_AXIS_TDATA_WIDTH is auto-derived; don't override
) u_vtpgz (
    .aclk          (aclk),
    .aresetn       (aresetn),
    // AXI4-Lite slave (control)
    .s_axil_awaddr (axil_awaddr), .s_axil_awprot (axil_awprot),
    .s_axil_awvalid(axil_awvalid),.s_axil_awready(axil_awready),
    .s_axil_wdata  (axil_wdata),  .s_axil_wstrb (axil_wstrb),
    .s_axil_wvalid (axil_wvalid), .s_axil_wready(axil_wready),
    .s_axil_bresp  (axil_bresp),  .s_axil_bvalid(axil_bvalid),
    .s_axil_bready (axil_bready),
    .s_axil_araddr (axil_araddr), .s_axil_arprot(axil_arprot),
    .s_axil_arvalid(axil_arvalid),.s_axil_arready(axil_arready),
    .s_axil_rdata  (axil_rdata),  .s_axil_rresp (axil_rresp),
    .s_axil_rvalid (axil_rvalid), .s_axil_rready(axil_rready),
    // AXI4-Stream master (video). The width is auto-derived from
    // OUTPUT_MODE/BPC. Use vtpgz_axilite_top's C_AXIS_TDATA_WIDTH parameter to
    // size the connecting net (or read VTPGZ_REG_COLOR_FORMAT[31:16]
    // from software at runtime).
    .m_axis_tdata  (vid_tdata),
    .m_axis_tvalid (vid_tvalid),
    .m_axis_tready (vid_tready),
    .m_axis_tlast  (vid_tlast),    // end-of-line
    .m_axis_tuser  (vid_tsof),     // start-of-frame (1 bit)
    // External frame sync (used when CONTROL[2]=1)
    .frame_sync_in (ext_fsync)
);
```

The core has **one** clock domain (`aclk`). All AXI, all pattern logic
and the video output are clocked by it. If your video sink runs on a
different clock you must put an asynchronous AXI4-Stream FIFO on the
output (any standard CDC FIFO will do).

`m_axis_tuser` is **1 bit wide**: it asserts on the first beat of each
frame. This matches the Xilinx convention used by `axis_subset_converter`,
`v_axi4s_remap`, `v_tc`, etc.

### Programming sequence

1. Hold `aresetn` low for at least one `aclk` cycle and release.
2. Write `IMG_WIDTH`, `IMG_HEIGHT` to the desired resolution.
3. Write the host-precomputed step values (these replace per-pixel dividers
   with cheap accumulators in hardware):
   - `BAR_WIDTH   = IMG_WIDTH / 8`              (colorbar bar width)
   - `HG_STEP     = 0xFFF / (IMG_WIDTH  - 1)`   (horizontal gradient step)
   - `VG_STEP     = 0xFFF / (IMG_HEIGHT - 1)`   (vertical gradient step)
4. Write `PATTERN_SEL` (0=colorbar, 1..4=gradients/checker/solid, 6=grid,
   7=ramp, 8=noise). The bouncing box overlays on top of whatever pattern
   is selected — configure it with `BOX_COLOR`, `BOX_SIZE`, `BOX_SPEED`.
   Write `COLOR_FORMAT`
   (`{bpp[3:0], fmt[3:0]}`).
5. Optional pattern parameters: `SOLID_COLOR`, `BOX_COLOR`/`BOX_SIZE`/
   `BOX_SPEED`, `GRID_SPACING`/`GRID_COLOR`, `CHECKER_SIZE`.
6. For internal sync mode (`CONTROL[2]=0`): write `FRAME_RATE_DIV` to set
   the clock-divider for the frame rate (one frame every N `aclk`s).
7. Write `CONTROL = 0x1` (enable). The core starts streaming.

To change configuration, write `CONTROL = 0` first, wait for the in-flight
frame to drain, then reprogram and re-enable.

### External frame sync

Drive `frame_sync_in` with any pulse-style signal that marks the start of
a frame and set `CONTROL[2] = 1` (`ext_sync` mode). The core does
**rising-edge detection** internally so it accepts:

- 1-clock pulses
- Multi-clock pulses (including signals held high indefinitely — only the
  rising edge counts)
- Free-running periodic vsync at any rate slower than the frame emission
  time

This is **directly compatible with Xilinx VTC's `vsync_out`** (and any
other timing generator that produces a vsync pulse): just wire it in. The
test in `sim/sim_main.cpp` Phase 5 verifies all four cases (1-cycle pulse,
wide pulse, mid-frame pulse correctly ignored, periodic vsync).

If a `frame_sync_in` rising edge arrives **while a frame is still in
flight**, it is **dropped** (not queued). This is the desired behavior for
a free-running vsync — if the downstream sink is too slow to consume the
current frame, the next vsync gets dropped instead of letting frames pile
up. If you need a different behavior (e.g., latched pending), instantiate
your own pending-bit FF before `frame_sync_in`.


[↑ back to top](#index)

## FPGA resource usage and frequency

### Measured on Arty A7-100T

| Metric | Value |
|---|---|
| Target | Digilent Arty A7-100T (XC7A100TCSG324-1, speed grade -1) |
| Tool | Vivado 2025.2, default synth + impl strategies |
| Clock | 130 MHz (sourced from on-board 100 MHz osc via MMCM, mult 13/2 div 5) |
| WNS | +0.333 ns (timing met, 0 failing endpoints) |
| LUTs | 2070 / 63400 = 3.26% |
| FFs | 2457 / 126800 = 1.94% |
| BRAM36 | 6 / 135 = 4.44% (8 KB capture buffer; fcapz async FIFOs in LUTRAM) |
| Hardware test | **108/108 byte-exact** vs Python model (`hw/arty_a7_100t/python/run_hw_test.py`) |

The numbers above include the full demo wrapper: `vtpgz_axilite_top` +
`frame_capture` + the fpgacapZero `fcapz_ejtagaxi_xilinx7` JTAG-to-AXI
bridge + a 32 KB on-chip BRAM frame buffer + clk_gen MMCM. The vtpgZero
core itself (`rtl/vtpgz_core.v` + AXI-Lite wrapper) is roughly half of
the total (see the resource matrix below for the standalone numbers).

### Resource matrix per build-time configuration

Standalone `vtpgz_axilite_top` (no demo wrapper, no frame_capture, no JTAG-AXI
bridge, no MMCM), synthesized out-of-context against `xc7a100tcsg324-1`
with Vivado 2025.2's default `synth_design` flow. Reproducible with
`python synth/run_matrix.py`.

#### All-patterns build, sweep over output mode and BPC

| Config | LUT | FF | BRAM36 |
|---|---:|---:|---:|
| `full_rgb_8b`     | 968 |  908 | 0 |
| `full_rgb_10b`    | 968 |  914 | 0 |
| `full_rgb_12b`    | 968 |  920 | 0 |
| `full_rgb_14b`    | 967 |  920 | 0 |
| `full_rgb_16b`    | 967 |  920 | 0 |
| `full_raw_8b`     | 976 |  894 | 0 |
| `full_raw_10b`    | 978 |  896 | 0 |
| `full_raw_12b`    | 980 |  898 | 0 |
| `full_raw_14b`    | 980 |  898 | 0 |
| `full_raw_16b`    | 980 |  898 | 0 |
| `full_yuv_8b`     | 962 |  908 | 0 |
| `full_yuv_10b`    | 954 |  914 | 0 |
| `full_yuv_12b`    | 961 |  920 | 0 |
| `full_yuv_14b`    | 962 |  920 | 0 |
| `full_yuv_16b`    | 962 |  920 | 0 |
| `full_yuv422_16b` | 972 |  909 | 0 |

The YUV path produces `{Y,Cb,Cr}` directly from the pattern generators
(precomputed BT.601 palette for the colorbar, neutral chroma for
grayscale-style patterns), so the output stage is just bit-shrink +
reorder in every mode. YUV 444 is roughly the same size as RGB at the
same BPC; the old RAW Bayer mux savings are offset by the extra
YUV logic added in recent revisions.

#### Pattern deltas (`OUTPUT_MODE=YUV` baseline)

| Config | LUT | FF |
|---|---:|---:|
| `baseline_solid_yuv`  | 402 |  732 |
| `only_colorbar_yuv`   | 462 |  752 |
| `only_hgrad_yuv`      | 431 |  753 |
| `only_vgrad_yuv`      | 433 |  753 |
| `only_checker_yuv`    | 431 |  767 |
| `only_moving_box_yuv` | 695 |  767 |
| `only_grid_yuv`       | 520 |  765 |
| `only_ramp_yuv`       | 431 |  753 |
| `only_noise_yuv`      | 409 |  749 |

Per-feature deltas relative to `baseline_solid_yuv` (402 LUT / 732 FF):

| Feature | ΔLUT | ΔFF |
|---|---:|---:|
| `EN_COLORBAR`   |  +60 | +20 |
| `EN_HGRAD`      |  +29 | +21 |
| `EN_VGRAD`      |  +31 | +21 |
| `EN_CHECKER`    |  +29 | +35 |
| `EN_MOVING_BOX` | **+293** | +35 |
| `EN_GRID`       | +118 | +33 |
| `EN_RAMP`       |  +29 | +21 |
| `EN_NOISE`      |   +7 | +17 |

`EN_MOVING_BOX` is by far the most expensive feature (the bouncing
position arithmetic and per-pixel range comparators for the overlay). `EN_NOISE` is
the cheapest. There are no multiplies anywhere in the design.

#### Tiniest possible build

| Config | LUT | FF |
|---|---:|---:|
| `tiny_raw_8b` (only EN_SOLID, OUTPUT_MODE=RAW, BPC=8) | **410** | 718 |

This is the absolute minimum: 1 pattern, RAW Bayer 8 bpc.
~410 LUTs total. Useful as an image-sensor-emulator for camera/ISP
bring-up where you only need a controllable raw stream.

**Test conditions for the matrix above**: Vivado 2025.2, target
`xc7a100tcsg324-1` -1 speed grade, `synth_design` default strategy,
out-of-context mode. No timing constraints applied (so the synth tool
is conservative). Place-and-route results are typically ~5% smaller
after phys-opt and packing.


[↑ back to top](#index)

## File layout

```
rtl/
  vtpgz_defs.vh         constants, register addresses, pattern/format codes
  vtpgz_axil_regs.v     AXI4-Lite slave + register file
  vtpgz_core.v          port-driven core: timing engine, pattern generators
                        (native per-mode color space), inline pack stage,
                        AXIS output -- instantiate this directly if you
                        want to drive cfg_* from your own RTL or hold them
                        at constants
  vtpgz_axilite_top.v   thin wrapper that ties vtpgz_axil_regs to
                        vtpgz_core, exposing an AXI4-Lite slave for
                        runtime control
tb/
  tb_vtpgz_axilite_top.v   Icarus Verilog smoke testbench
sim/
  sim_main.cpp       Verilator C++ testbench (7-phase, 100% coverage)
  sim_capture.cpp    sim ↔ Python-model byte-exact gate
  sim_capture_seq.cpp  multi-capture (sequential) sim ↔ model gate
  sim_top.v          tpg + frame_capture wrapper for the seq harness
  run_sim.py         Verilator orchestration (lint/build/run/cov/all_modes)
synth/
  synth_matrix.tcl   Vivado synth-only TCL for one config
  run_matrix.py      driver: synth N parameter configs, build matrix CSV
fcapz/               git submodule: upstream fpgacapZero RTL + host tools
hw/
  arty_a7_100t/      Arty A7-100T reference design (vtpgz_axilite_top + frame_capture
                     + fpgacapZero JTAG-AXI bridge + 130 MHz MMCM + Python host)
  kv260/             KV260 DisplayPort reference design (vtpgZero -> DDR writer
                     -> DPDMA graphics -> PS DisplayPort TX)
LICENSE              Apache-2.0
```


[↑ back to top](#index)

## Author and license

- **Author**: Leonardo Capossio — bard0 design — hello@bard0.com — [bard0](www.bard0.com)
- **License**: Apache License 2.0 — see [LICENSE](LICENSE)

[↑ back to top](#index)
