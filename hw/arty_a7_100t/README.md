# vtpgZero — Arty A7-100T reference design

End-to-end FPGA demo and hardware integration test for the vtpgZero video
test pattern generator on the Digilent Arty A7-100T.

## What it does

- Instantiates `vtpgz_top` (the VTPGZ core)
- Wires its AXI4-Stream output to a `frame_capture` block that sinks one
  frame into an on-chip 32 KB BRAM buffer
- Adds the [fpgacapZero](https://github.com/lcapossio/fpgacapZero)
  `fcapz_ejtagaxi_xilinx7` JTAG-to-AXI4 bridge so the host can drive the
  VTPGZ configuration registers and read back the captured frame over the
  same USB cable used for programming
- An MMCM-derived clock domain runs everything: 100 MHz in the default
  4-pixels-per-clock build, 130 MHz at 1 pixel per clock

## Architecture

```
                  USB / FT2232H
                       |
                    BSCANE2 (USER4)
                       |
              fcapz_ejtagaxi_xilinx7
                       |
                  AXI4 master  (32-bit)
                       |
                  inline addr[16] decode
                  /            \
              addr[16]=0    addr[16]=1
                  |            |
            axi4_to_axil      frame_capture
                  |          (AXIS sink + BRAM + AXI4 slave)
              vtpgz_top
              (DUT)
                  |
              AXI-Stream (48-bit tdata)
                       |
                    frame_capture
```

## Address map (32-bit byte addresses)

| Range | Target |
|---|---|
| `0x0000_0000`–`0x0000_00FF` | VTPGZ AXI4-Lite registers (see top-level README) |
| `0x0001_0000` | `CAPTURE_CTRL`  W: `[0]`=arm `[1]`=clear |
| `0x0001_0004` | `CAPTURE_STATUS` R: `[0]`=done, `[1]`=field_id of the captured frame (vtpgZero `fid`, latched at its SOF beat; only meaningful when `CONTROL[3]` interlace is set), `[29:16]`=word_count |
| `0x0001_0008` | `FID_HIST` R: field ID of the last 32 SOF beats seen on the stream, bit 0 = most recent |
| `0x0001_000C` | `SOF_COUNT` R: `[7:0]` number of SOF beats shifted into `FID_HIST` |
| `0x0001_0010` | `FLV_MODE` RW: `[0]`=parallel mode (the FVAL/LVAL/DVAL adapter owns `tready`), `[1]`=clear the monitor statistics (self-clearing) |
| `0x0001_0014` | `FLV_STATUS` R: `[0]`=adapter `TIMING_ERR`, `[1]`=DVAL ever differed from LVAL, `[15:8]`=frames seen, `[31:16]`=LVAL pulses in the last complete frame |
| `0x0001_0018` | `FLV_LVAL` R: `{max[31:16], min[15:0]}` LVAL pulse width in cycles |
| `0x0001_001C` | `FLV_VBLANK` R: `{max[31:16], min[15:0]}` vertical blanking in cycles |
| `0x0001_0020` | `FLV_FID` R: `[7:0]` `FIELD_ID` sampled at the last 8 FVAL rising edges, bit 0 = most recent |
| `0x0001_8000`–`0x0001_FFFF` | `FRAME_BRAM` (read-only window, 32 KB) |

`CAPTURE_CTRL[2]` clears `FID_HIST`/`SOF_COUNT`; it is independent of
`CAPTURE_CTRL[1]`, so the history survives a normal clear+arm sequence.

### Why `FID_HIST` exists

`frame_capture` drives `s_axis_tready` low unless it is actively capturing,
and its FSM terminates on the **second** `tuser` (that SOF beat is accepted
but not stored). Two consequences, both measured on the board:

- Between captures the VTPGZ stalls mid-field with `STATUS[0]` (busy) high
  and `STATUS[15:8]` (frame_count) frozen.
- Each arm→done cycle consumes exactly **two** field starts (frame_count
  advances by 2 per capture), so consecutive captures always land on the
  **same** field parity. `CAPTURE_STATUS[1]` alone therefore cannot show
  `fid` alternating, even though the core alternates correctly.

`FID_HIST` records every field start instead, so adjacent bits are
consecutive fields and must differ for an interlaced source. That is what
`run_hw_interlace.py` checks.

## Parallel video out on the board

The demo also instantiates `vtpgz_axis_to_flvdval` on the same stream the
capture sink sees, so the FVAL/LVAL/DVAL adapter is exercised on silicon and
not only in simulation.

The pixel bus does **not** leave the device. This build runs the core at
`PIXELS_PER_CLOCK=4`, which makes `PIX_DATA` 96 bits wide -- far more than the
Arty's headers can carry. What is verified on hardware is therefore the raster
*timing*, measured in fabric by `flv_monitor` and read back through the CSRs
above.

Only one consumer may drive `tready`. `frame_capture` normally holds it low
between captures, which the adapter cannot tolerate: a parallel interface has
no way to express a stall, so the source must free-run gap-free. Setting
`FLV_MODE[0]` hands `tready` to the adapter and ties it high. Capture results
are meaningless while that bit is set, and `run_hw_flvdval.py` clears it again
when it finishes.

```sh
python hw/arty_a7_100t/python/run_hw_flvdval.py
```

For each geometry it asserts, from the geometry alone, the same properties
`tb_gapfree` asserts in simulation:

- LVAL pulse `min == max == IMG_WIDTH / PIXELS_PER_CLOCK` -- one short or long
  line anywhere in the run moves `min` or `max` and cannot average away;
- lines per frame `== IMG_HEIGHT`;
- vertical blanking `min == max == PERIOD - ACTIVE`, with `ACTIVE` and the
  dropped-sync-tick `PERIOD` as defined in the top-level README;
- `TIMING_ERR` never latches and DVAL never differs from LVAL;
- `FIELD_ID` at the FVAL rising edge alternates for an interlaced source and
  stays 0 for a progressive one.

## Build

```sh
python hw/arty_a7_100t/scripts/build.py
```

This calls Vivado in batch mode (locating it via `PATH`), runs synth +
impl + write_bitstream, and writes outputs to:

- `hw/arty_a7_100t/build/demo_top.bit` — bitstream
- `hw/arty_a7_100t/build/reports/{synth,impl}_{utilization,timing}.rpt`
- `hw/arty_a7_100t/build/post_route.dcp` — routed checkpoint

Build time: ~6 minutes on a typical workstation.

## Run

Start `hw_server` in the background once:

```sh
hw_server -d
```

Then run the integration test:

```sh
python hw/arty_a7_100t/python/run_hw_test.py
```

In a fresh checkout, initialize submodules first so the shared
`fpgacapZero` dependency is present:

```sh
git submodule update --init --recursive
```

The host:
1. Programs the bitstream over JTAG
2. Probes the EJTAG-AXI bridge identity
3. For each of the 9 patterns × 4 formats × 3 bit depths:
   - Configures the VTPGZ registers
   - Clears + arms the capture sink
   - Enables the VTPGZ
   - Polls `CAPTURE_STATUS` until `done`
   - Burst-reads the frame from BRAM (auto-increment `read_block`)
   - Renders the same combo with the bit-exact Python model
     (`vtpgz_model.py`) and asserts equality

The VTPGZ AXI4-Lite register file honors `WSTRB`; writes with
`WSTRB=0` acknowledge but do not modify registers, including
`CONTROL`.

Expected output:

```
Bridge: id=0x454A4158 v0.1 addr_w=32 data_w=32
VTPGZ CORE_ID = 0x47505456 ("VTPG")
VTPGZ VERSION = 0x00070000
Build cfg: mode=0 sub=0 bayer=1 order=0 bpc=8 tdata_width=96 ppc=4
  OK    pat=0
  ...
  OK    pat=8
Ran 9 patterns, 0 failures
HW PASS — byte-exact across all patterns
```

Most of the wall-clock is JTAG round-trip overhead, not FPGA work — each
capture itself completes in microseconds.

### Test conditions

- Test geometry: 64 × 32 pixels per frame (= 2048 pixels = 8 KB at RGB888)
- Pattern slots swept: all 9 (`colorbar`, `hgrad`, `vgrad`, `checker`,
  `solid`, slot 5 -- black, since the moving box is an overlay rather than
  a pattern -- `grid`, `ramp`, `noise`)
- Output format, bit depth and pixels per clock are build-time: the script
  reads them back from the loaded bitstream, and another format means
  another bitstream. Pass `VTPGZ_<NAME>=<int>` to `build.py`, e.g.
  `VTPGZ_OUTPUT_MODE=2 VTPGZ_BPC=10 VTPGZ_YUV_RANGE=1 VTPGZ_YUV_MATRIX=1
  VTPGZ_BAR_LEVEL=75`, and give `run_hw_test.py` the matching
  `--yuv-range`/`--yuv-matrix`/`--bar-level` (those three are not in the
  read-back).
- Pass criterion: byte-exact equality between FPGA capture and the
  cycle-accurate Python model

## Resource utilization

| Resource | Used | Available | % |
|---|---|---|---|
| Slice LUTs | 3494 | 63400 | 5.51% |
| Slice Registers | 3229 | 126800 | 2.55% |
| BRAM36 | 8 | 135 | 5.93% |
| DSP48E1 | 0 | 240 | 0.00% |
| MMCM | 1 | 6 | 16.7% |
| BUFG | 3 | 32 | 9.38% |

Default build (RGB, 8 bpc, 4 pixels per clock), including the parallel-video
adapter and the `flv_monitor` instrument.

Tool: Vivado 2025.2, default synth + impl strategies,
device `xc7a100tcsg324-1` (speed grade -1).

## Achieved frequency

The default build (4 pixels per clock) runs at **100 MHz** -- 400 Mpixel/s
-- with WNS = +0.768 ns (timing met, 0 failing endpoints) on the internal
`clk_out_unbuf` domain. The FPGA clock is generated by an MMCM that takes
the on-board 100 MHz oscillator to a 650 MHz VCO (`CLKFBOUT_MULT_F=13`,
`DIVCLK_DIVIDE=2`) and divides it by `CLKOUT0_DIVIDE_F`: 6.5 for PPC>1
(100 MHz), 5 for PPC=1 (130 MHz). `VTPGZ_CLK_MHZ=<n>` overrides it for any
`n` that divides 5200 (e.g. 50, 65, 100, 130); `build.tcl` prints the clock
each build was constrained at.

| Build | Clock | WNS | Hardware test |
|---|---|---:|---|
| RGB-8b, 4 pixels/clock (default) | 100 MHz | +0.768 ns | 9/9 |
| RGB-8b, 2 pixels/clock | 100 MHz | +1.152 ns | 9/9 |
| YUV-10b BT.709 limited, 4 pixels/clock | 100 MHz | +0.727 ns | 9/9 |

## File layout

The `fpgacapZero` dependency now lives in the repo-root `fcapz/`
submodule. The Arty build consumes `fcapz/rtl`, and
`run_hw_test.py` imports the host bridge package from
`fcapz/host/fcapz`.

```
hw/arty_a7_100t/
├── README.md                    this file
├── constraints/
│   └── arty_a7_100t.xdc         pin constraints, MMCM clock, BSCAN false-path
├── scripts/
│   ├── build.tcl                Vivado batch script
│   └── build.py                 Python wrapper that locates vivado in PATH
├── rtl/
│   ├── demo_top.v               board wrapper
│   ├── clk_gen.v                MMCM 100 → 130 / 100 MHz + reset sync
│   ├── axi4_to_axil.v           AXI4-to-AXI4-Lite shim for the VTPGZ region
│   ├── frame_capture.v          AXIS sink + BRAM + AXI4 slave
│   ├── bram_sdp.v               canonical SDP BRAM wrapper
│   └── vendor/fpgacapzero/      copies of the fpgacapZero JTAG-AXI bridge
│       ├── fcapz_ejtagaxi.v
│       ├── fcapz_ejtagaxi_xilinx7.v
│       ├── fcapz_async_fifo.v
│       └── jtag_tap/jtag_tap_xilinx7.v
└── python/
    ├── vtpgz_model.py           cycle-accurate Python model of the VTPGZ
    ├── run_hw_test.py           9-pattern byte-exact HW test driver
    ├── check_sim_vs_model.py    sim ↔ model gate (no HW required)
    ├── check_seq.py             multi-capture sim verification
    └── fcapz/                   fpgacapZero Python bridge controller
        ├── transport.py
        └── ejtagaxi.py
```

## Author and license

- **Author**: Leonardo Capossio — bard0 design — hello@bard0.com
- **License**: Apache-2.0
