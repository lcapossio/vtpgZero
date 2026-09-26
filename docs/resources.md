# FPGA resource matrix

Full per-configuration synthesis results. For the headline numbers see the
[FPGA resource usage](../README.md#fpga-resource-usage-and-frequency) section
of the main README.

Standalone `vtpgz_axilite_top` (no demo wrapper, no frame_capture, no JTAG-AXI
bridge, no MMCM), synthesized out-of-context against `xc7a100tcsg324-1`
with Vivado 2025.2's default `synth_design` flow. Reproducible with
`python synth/run_matrix.py`, which passes every top-level parameter
explicitly and records the full parameter set of each row in
`synth/results/matrix.csv`. Parameters a table does not mention are at their
defaults: `EN_IMAGE=0`, `EN_BOX_IMAGE=0`, `EN_INTERLACE=0`, `YUV_RANGE=0`
(full), `YUV_MATRIX=0` (BT.601), `BAR_LEVEL=100`, `TID_WIDTH=0`,
`TDEST_WIDTH=0`, `PIXELS_PER_CLOCK=1`.

No configuration below uses a BRAM or a DSP.

## All-patterns build, sweep over output mode and BPC

| Config | LUT | FF |
|---|---:|---:|
| `full_rgb_8b`     | 1380 | 1244 |
| `full_rgb_10b`    | 1380 | 1250 |
| `full_rgb_12b`    | 1380 | 1256 |
| `full_rgb_14b`    | 1380 | 1256 |
| `full_rgb_16b`    | 1380 | 1256 |
| `full_raw_8b`     | 1388 | 1232 |
| `full_raw_10b`    | 1390 | 1234 |
| `full_raw_12b`    | 1392 | 1236 |
| `full_raw_14b`    | 1392 | 1236 |
| `full_raw_16b`    | 1392 | 1236 |
| `full_yuv_8b`     | 1320 | 1242 |
| `full_yuv_10b`    | 1318 | 1248 |
| `full_yuv_12b`    | 1318 | 1254 |
| `full_yuv_14b`    | 1318 | 1254 |
| `full_yuv_16b`    | 1320 | 1254 |
| `full_yuv422_16b` | 1330 | 1244 |

The YUV path produces `{Y,Cb,Cr}` directly from the pattern generators (a
per-build colour-bar palette, neutral chroma for the grayscale-style
patterns), so the output stage is just bit-shrink + reorder in every mode.
The internal datapath is 12 bits wide whatever the BPC, which is why BPC
barely moves the numbers.

## Pattern deltas (`OUTPUT_MODE=YUV` baseline)

| Config | LUT | FF |
|---|---:|---:|
| `baseline_solid_yuv`  |  538 |  958 |
| `only_colorbar_yuv`   |  636 |  987 |
| `only_hgrad_yuv`      |  560 |  983 |
| `only_vgrad_yuv`      |  570 |  983 |
| `only_checker_yuv`    |  601 |  994 |
| `only_moving_box_yuv` | 1066 | 1091 |
| `only_grid_yuv`       |  582 |  991 |
| `only_ramp_yuv`       |  560 |  983 |
| `only_noise_yuv`      |  543 |  979 |

Per-feature deltas relative to `baseline_solid_yuv` (538 LUT / 958 FF):

| Feature | ΔLUT | ΔFF |
|---|---:|---:|
| `EN_COLORBAR`   |  +98 | +29 |
| `EN_HGRAD`      |  +22 | +25 |
| `EN_VGRAD`      |  +32 | +25 |
| `EN_CHECKER`    |  +63 | +36 |
| `EN_MOVING_BOX` | **+528** | +133 |
| `EN_GRID`       |  +44 | +33 |
| `EN_RAMP`       |  +22 | +25 |
| `EN_NOISE`      |   +5 | +21 |

`EN_MOVING_BOX` is by far the most expensive feature (the bouncing
position arithmetic and per-pixel range comparators for the overlay).
`EN_NOISE` is the cheapest. There are no multiplies anywhere in the design.

## Tiniest possible build

| Config | LUT | FF |
|---|---:|---:|
| `tiny_raw_8b` (only EN_SOLID, OUTPUT_MODE=RAW, BPC=8) | **546** | 946 |

This is the absolute minimum: 1 pattern, RAW Bayer 8 bpc. ~546 LUTs total.
Useful as an image-sensor-emulator for camera/ISP bring-up where you only
need a controllable raw stream.

## Pixels-per-clock sweep

All-patterns RGB-8b build swept over `PIXELS_PER_CLOCK` (the `ppc1` row is
the same build as `full_rgb_8b` above). Mode/BPC/patterns are held fixed so
the numbers isolate the cost of widening the per-lane datapath from 1 to N
pixels per beat. Reproducible on its own with `python synth/run_matrix.py ppc`.

| Config | LUT | FF | beat width | vs `ppc1` |
|---|---:|---:|---:|---|
| `ppc1_full_rgb_8b` | 1380 | 1244 |  24b | — |
| `ppc2_full_rgb_8b` | 1627 | 1463 |  48b | +18% LUT / +18% FF |
| `ppc4_full_rgb_8b` | 2398 | 1786 |  96b | +74% LUT / +44% FF |
| `ppc8_full_rgb_8b` | 3835 | 2444 | 192b | +178% LUT / +96% FF |

8× the per-clock pixel throughput costs about 2.8× the LUTs. The pattern
generators, colour-bar compares and packers replicate per lane; the shared
timing FSM, moving-box position arithmetic and config registers do not.
At PPC>1 the per-lane multiples of the bar width, checker size, grid spacing
and gradient step are registered rather than computed each beat, and so
is each wrap-counter's per-beat step (m × size − PPC), so that the counter
chains close 100 MHz at up to 8 pixels per clock; that is most of the FF
growth.

Versions of this table before September 2026 reported +56% LUT at PPC=8.
Those numbers came from RTL where several lanes drove the same pipeline
registers and Vivado silently kept only one driver, pruning the other lanes'
logic. With that fixed, and with the later per-lane colour-bar pipeline that
lets PPC>1 builds close timing, the table above is the real cost.

## Interlace

| Config | LUT | FF |
|---|---:|---:|
| `ppc1_full_rgb_8b_interlace` | 1369 | 1248 |
| `ppc4_full_rgb_8b_interlace` | 2316 | 1790 |

`EN_INTERLACE=1` costs 4 FF. The LUT counts land a little below the
progressive builds (−11 at PPC=1, −82 at PPC=4), which is synthesis
variation rather than a saving. `ppc4_full_rgb_8b_interlace` is the core
build of the Arty A7 demo.

## YUV colorimetry

All patterns, YUV 4:4:4.

| Config | PPC | LUT | FF |
|---|---:|---:|---:|
| `yuv_10b_601full`   | 1 | 1318 | 1248 |
| `yuv_10b_709full`   | 1 | 1310 | 1246 |
| `yuv_10b_709lim`    | 1 | 1395 | 1247 |
| `yuv_10b_709lim_75` | 1 | 1393 | 1247 |
| `yuv_8b_709lim`     | 1 | 1381 | 1237 |
| `yuv_10b_601full`   | 4 | 2317 | 1802 |
| `yuv_10b_709full`   | 4 | 2285 | 1794 |
| `yuv_10b_709lim`    | 4 | 2513 | 1796 |
| `yuv_10b_709lim_75` | 4 | 2518 | 1796 |
| `yuv_8b_709lim`     | 4 | 2580 | 1756 |

The matrix (`YUV_MATRIX`) and the bar level (`BAR_LEVEL`) only change the
colour-bar palette constants, so they cost nothing. Limited range
(`YUV_RANGE=1`) adds the luma map for the gradients, checker, ramp and noise:
a shift-and-add constant multiply, no DSP, applied once per lane after the
stage-1 register to whichever of those patterns is selected. That is +85 LUT
at PPC=1 and +228 LUT at PPC=4 over the full-range BT.709 build.

**Test conditions**: Vivado 2025.2, target `xc7a100tcsg324-1` -1 speed grade,
`synth_design` default strategy, out-of-context mode. No timing constraints
applied (so the synth tool is conservative). Place-and-route results are
typically a few percent smaller after phys-opt and packing.
