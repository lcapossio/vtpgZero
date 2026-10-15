# KV260 DisplayPort Demo

This reference design drives the KV260 DisplayPort output from vtpgZero.
The path is:

```text
vtpgZero AXI4-Stream RGB888 -> axis_to_ddr_writer -> PS DDR framebuffer
    -> DPDMA graphics channel -> AVBUF -> PS DisplayPort TX
```

The PL does not feed live pixels directly into the DisplayPort subsystem.
Instead, vtpgZero continuously rewrites a 1280x720 ABGR8888 framebuffer at
`0x4C000000`, and the PS DPDMA graphics channel scans that buffer to the
monitor.

A second design on the same board, the
[8K throughput bench](#8k-throughput-bench), runs vtpgZero at 7680x4320,
60 fps and checks every frame against the model.

## Build

From the repository root:

```powershell
python hw\kv260\scripts\build_pl.py
python hw\kv260\scripts\build_bsp.py hw\kv260\build\pl\vtpgzero_kv260.xsa
$env:KV260_BSP_DIR = "hw\kv260\build\bsp_vtpgzero_kv260\hw_platform"
python hw\kv260\scripts\build.py --target box
```

The PL build creates:

```text
hw/kv260/build/pl/vtpgzero_kv260.bit
hw/kv260/build/pl/vtpgzero_kv260.xsa
```

## Run

Cold boot and load the app over JTAG:

```powershell
python hw\kv260\scripts\load.py --cold --target box
```

The loader programs the bitstream, removes PS-PL isolation, toggles
`pl_resetn0`, downloads the bare-metal A53 app, and starts it. UART output is
on the KV260 USB-UART at 115200 baud.

## Interactive control (UART)

The bare-metal app opens a single-key command interpreter on the KV260
USB-UART (FT4232H **channel B**, 115200 8N1). Send `?` to print the
help banner. Available keys:

| Key | Effect |
|-----|--------|
| `0`..`9` | switch `PATTERN_SEL` (0=bars, 1=hgrad, 2=vgrad, 3=checker, 4=solid, 5=SMPTE RP 219, 6=grid, 7=ramp, 8=noise, 9=image) |
| `+` / `-` | grow / shrink the box in 16-px steps (image-in-box auto-rescales) |
| `f` / `s` | faster / slower box motion |
| `b` | cycle box color through an 8-entry palette (visible only when image-in-box is off) |
| `c` | cycle solid color (visible when `PATTERN_SEL = 4`) |
| `g` / `G` | shrink / grow grid spacing (pattern 6) |
| `k` / `K` | shrink / grow checker size (pattern 3) |
| `e` / `d` | enable / disable the core (`d` truly stops motion; the vsync handler only pulses `sw_fsync` while enabled) |
| `v` | toggle vsync lock (see below) |
| `i` | toggle image-in-box (writes `BOX_IMG_*_STEP = 0` as the runtime sentinel that falls back to solid `cfg_box_color`) |

Each keystroke is a single AXI-Lite write to vtpgZero at `0xA0000000`;
the change takes effect on the next emitted frame, no reconfig needed.

## Vsync-locked frame production

The PL writer and DPDMA scanout are clocked by independent PLLs (~100
MHz PL aclk vs 74.25 MHz DP pixel clock) and drift relative to each
other. With both processes pointed at a single DDR framebuffer, the
drift produces a slow-moving tear-line.

The app eliminates the tear by **disabling vtpgZero's internal frame
divider and pulsing `CONTROL[1]` (sw_fsync) on every DPDMA vsync
interrupt**. The writer paints a 1280x720 frame in ~9.2 ms at 100 MHz,
which is well inside DPDMA's 16.67 ms frame period, so the writer
outpaces the scanout for every row and no tearing line exists. The
pulse is the first thing executed on vsync detection so the BSP
interrupt handler's latency doesn't eat into vblank.

Press `v` over UART to toggle vsync-lock off (restores the original
free-run behavior, tearing reappears).

## Design Notes

- The vtpgZero AXI-Lite control aperture is pinned to `0xA0000000`; the app
  verifies `CORE_ID` before touching the rest of the registers.
- The vtpgZero register file honors AXI4-Lite `WSTRB`. The KV260 app uses
  normal 32-bit MMIO writes, but any alternate host/debug master must drive
  nonzero strobes or writes, including `CONTROL`, will acknowledge without
  changing the register.
- The vtpgZero instance is built as RGB, Xilinx byte order, 8 bpc, 24-bit
  AXI4-Stream. The app verifies `COLOR_FORMAT` before enabling the core.
- `axis_to_ddr_writer` converts vtpgZero RGB888 stream beats into the
  ABGR8888 layout consumed by the DPDMA graphics path. It is bounded to the
  configured framebuffer size and drops surplus malformed-frame beats until
  the next start-of-frame marker.
- The DisplayPort link is configured for 1280x720 at 60 Hz, one HBR2 lane.
- Keep the DP property ordering in `vivado/build_bd.tcl`: the PS DisplayPort
  gate properties and DPAUX MIO mapping must be set before relying on the
  lower-level `PSU__DP__*` protocol properties.
- The KV260 BD ships with both `EN_IMAGE=1` (128×128 mandrill scaled to
  fill the 1280×720 active region as `PATTERN_SEL=9`) and `EN_BOX_IMAGE=1`
  (32×32 mandrill scaled to whatever the box is currently sized to). The
  app pre-computes `BOX_IMG_X/Y_STEP` at init and on every UART `+/-`
  size change. To disable image-in-box at runtime, write `0` to either
  step register (the `i` UART key does this); the box reverts to solid
  `cfg_box_color`.
- The BD also sets `EN_SMPTE=1`, so `PATTERN_SEL=5` is the SMPTE RP 219
  chart. Its geometry registers reset to 1920x1080 values, so the app writes
  the 1280x720 geometry at init (bar 137, side panel 160, PLUGE step 46, row
  unit 60, ramp step 1533). The bouncing box draws over it like any other
  pattern.

## 8K throughput bench

A second KV260 design checks that vtpgZero sustains 7680x4320 at 60 fps.
There is no picture: the KV260 DisplayPort cannot carry 8K, and the DDR
could not take 8 pixels x 4 bytes per clock at this rate. Instead,
vtpgZero streams into `rtl/axis_frame_monitor.v`, which holds `TREADY`
high and measures every frame in the fabric.

```text
pl_clk0 (99.999 MHz) -> MMCM -> 249.9975 MHz
    vtpgZero (PIXELS_PER_CLOCK=8, RGB 8 bpc) -> axis_frame_monitor
PS M_AXI_HPM0_FPD -> AXI interconnect (clock crossing) -> both AXI-Lite slaves
```

At 8 pixels per clock a 7680x4320 frame is 960 x 4320 beats plus one idle
clock between lines: 4,151,519 clocks. 60 fps therefore needs 249.1 MHz.
The bench runs at 249.9975 MHz (the MMCM's 250 MHz from a PS clock that
is really 99.999 MHz) with `FRAME_RATE_DIV` = 4,166,625, so one frame
starts every 1/60 s.

For each pattern, the monitor records:
- the beat and `TLAST` counts;
- the active time (SOF beat to last `TLAST`);
- the SOF-to-SOF period;
- mid-line bubbles;
- a CRC-32 of every frame.

It keeps the minimum and maximum of each count and time since the last
clear, so one bad frame cannot hide behind the good ones after it.

The host drives everything over JTAG through the PS (xsdb memory access)
and checks:

- 4,147,200 beats in 4320 lines in every frame (minimum == maximum), and
  no bubble;
- frames still arriving: between two snapshots taken seconds apart, the
  frame count advances by the elapsed fabric clocks / `FRAME_RATE_DIV`;
- every frame period equal to `FRAME_RATE_DIV`, so minimum == maximum and
  the rate is 60.0000 fps. Host-timed, the clock agrees with 249.9975 MHz to
  within the JTAG latency jitter;
- the CRC of the first frame after enable equal to the CRC of the same
  frame from the bit-exact Python model (`vtpgz_model.py`, all 33 Mpixels).

It also finds the core's free-running ceiling: the smallest
`FRAME_RATE_DIV` at which no frame start is dropped.

```powershell
python hw\kv260\scripts\bench8k.py build     # ~25 min
python hw\kv260\scripts\bench8k.py run       # cold boot + ~2 min
```

`run` borrows the DisplayPort demo's PMUFW and FSBL from
`build/bsp_vtpgzero_kv260` (build them with `build_bsp.py` first). The PS
configuration is the same, so they bring this design up too. The board is
selected by JTAG cable serial, so other boards on the same `hw_server` are
left alone. The default is the author's board: set `$KV260_JTAG_SERIAL` to
yours (xsdb's `targets -target-properties` lists each target's
`jtag_cable_serial`).

Measured on a KV260 (Vivado 2025.2, `Performance_ExplorePostRoutePhysOpt`;
WNS +0.109 ns at 250 MHz; vtpgZero 3875 LUT / 2551 FF, monitor
1021 LUT / 1103 FF):

```text
7680x4320, 8 px/clk, clock 249.9975 MHz, FRAME_RATE_DIV=4166625, active frame = 4151519 clocks
pattern          fps  host fps  host MHz frames    beats lines    period min/max bubbles first CRC     model  result
colorbar     60.0000    60.063   249.980    272  4147200  4320  4166625/4166625        0  dff0d416  dff0d416  OK
hgrad        60.0000    60.087   249.967    271  4147200  4320  4166625/4166625        0  66d4c2a4  66d4c2a4  OK
vgrad        60.0000    59.963   249.981    272  4147200  4320  4166625/4166625        0  0cb20e3b  0cb20e3b  OK
checker      60.0000    59.903   249.994    272  4147200  4320  4166625/4166625        0  e8cd7539  e8cd7539  OK
solid        60.0000    60.066   249.950    271  4147200  4320  4166625/4166625        0  ada2b0d1  ada2b0d1  OK
smpte*       60.0000    59.923   249.975    272  4147200  4320  4166625/4166625        0  0e52299b  0e52299b  OK
grid         60.0000    59.983   249.953    271  4147200  4320  4166625/4166625        0  8c52c702  8c52c702  OK
ramp         60.0000    60.022   250.065    272  4147200  4320  4166625/4166625        0  66d4c2a4  66d4c2a4  OK
noise        60.0000    60.057   250.032    272  4147200  4320  4166625/4166625        0  c51529a1  c51529a1  OK

Free-running: FRAME_RATE_DIV=4151521 (active + 2) holds every frame, 60.218 fps at 249.998 MHz
* SMPTE RP 219 is not in this build (EN_SMPTE=0): pattern 5 renders black, as the model does.

PASS: 9/9 patterns at 8Kp60
```

The bouncing box (480x270, moving 8 by 4 pixels per frame) is on in every
pattern. HGRAD and RAMP share a CRC because in RGB both are the same gray
sweep driven by `HG_STEP`.

Notes:

- The KV260's -2LV part (0.72 V) is the slow end of this family. Out of
  context, at default strategies, the core alone sits right at 250 MHz
  (see [docs/resources.md](../../docs/resources.md#frequency-on-ultrascale-8k-throughput)).
  The in-system build closes with margin only because of the
  `Performance_*` strategies set in `vivado/build_pl_8k.tcl`. The limit
  is the colour-bar wrap counter's feedback loop.
- Connection automation gives the fast clock its own `proc_sys_reset` but
  leaves its `ext_reset_in` open, which Vivado ties to 0: an active-low
  reset held forever, and the first AXI-Lite read hangs. The PS `DAP`
  then reports an AXI-AP transaction error. `build_bd_8k.tcl` wires
  `pl_resetn0` in, and `bench8k.py run` clears a stuck DAP with `rst -dap`
  before booting.
