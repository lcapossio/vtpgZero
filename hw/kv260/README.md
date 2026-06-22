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
| `0`..`8` (skip `5`) | switch `PATTERN_SEL` (0=bars, 1=hgrad, 2=vgrad, 3=checker, 4=solid, 6=grid, 7=ramp, 8=noise) |
| `+` / `-` | grow / shrink the box in 16-px steps |
| `f` / `s` | faster / slower box motion |
| `b` | cycle box color through an 8-entry palette |
| `c` | cycle solid color (visible when `PATTERN_SEL = 4`) |
| `g` / `G` | shrink / grow grid spacing (pattern 6) |
| `k` / `K` | shrink / grow checker size (pattern 3) |
| `e` / `d` | enable / disable the core |
| `v` | toggle vsync lock (see below) |

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
