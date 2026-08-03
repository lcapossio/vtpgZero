# FPGA resource matrix

Full per-configuration synthesis results. For the headline numbers see the
[FPGA resource usage](../README.md#fpga-resource-usage-and-frequency) section
of the main README.

Standalone `vtpgz_axilite_top` (no demo wrapper, no frame_capture, no JTAG-AXI
bridge, no MMCM), synthesized out-of-context against `xc7a100tcsg324-1`
with Vivado 2025.2's default `synth_design` flow. Reproducible with
`python synth/run_matrix.py`.

## All-patterns build, sweep over output mode and BPC

| Config | LUT | FF | BRAM36 |
|---|---:|---:|---:|
| `full_rgb_8b`     | 1270 | 1212 | 0 |
| `full_rgb_10b`    | 1270 | 1218 | 0 |
| `full_rgb_12b`    | 1270 | 1224 | 0 |
| `full_rgb_14b`    | 1270 | 1224 | 0 |
| `full_rgb_16b`    | 1270 | 1224 | 0 |
| `full_raw_8b`     | 1278 | 1200 | 0 |
| `full_raw_10b`    | 1280 | 1202 | 0 |
| `full_raw_12b`    | 1282 | 1204 | 0 |
| `full_raw_14b`    | 1282 | 1204 | 0 |
| `full_raw_16b`    | 1282 | 1204 | 0 |
| `full_yuv_8b`     | 1232 | 1210 | 0 |
| `full_yuv_10b`    | 1236 | 1216 | 0 |
| `full_yuv_12b`    | 1236 | 1222 | 0 |
| `full_yuv_14b`    | 1236 | 1222 | 0 |
| `full_yuv_16b`    | 1232 | 1222 | 0 |
| `full_yuv422_16b` | 1245 | 1212 | 0 |

The YUV path produces `{Y,Cb,Cr}` directly from the pattern generators
(precomputed BT.601 palette for the colorbar, neutral chroma for
grayscale-style patterns), so the output stage is just bit-shrink +
reorder in every mode. YUV 444 is roughly the same size as RGB at the
same BPC; the old RAW Bayer mux savings are offset by the extra
YUV logic added in recent revisions.

## Pattern deltas (`OUTPUT_MODE=YUV` baseline)

| Config | LUT | FF |
|---|---:|---:|
| `baseline_solid_yuv`  |  526 |  926 |
| `only_colorbar_yuv`   |  549 |  955 |
| `only_hgrad_yuv`      |  548 |  951 |
| `only_vgrad_yuv`      |  558 |  951 |
| `only_checker_yuv`    |  564 |  962 |
| `only_moving_box_yuv` | 1054 | 1059 |
| `only_grid_yuv`       |  569 |  959 |
| `only_ramp_yuv`       |  548 |  951 |
| `only_noise_yuv`      |  531 |  947 |

Per-feature deltas relative to `baseline_solid_yuv` (526 LUT / 926 FF):

| Feature | ΔLUT | ΔFF |
|---|---:|---:|
| `EN_COLORBAR`   |  +23 | +29 |
| `EN_HGRAD`      |  +22 | +25 |
| `EN_VGRAD`      |  +32 | +25 |
| `EN_CHECKER`    |  +38 | +36 |
| `EN_MOVING_BOX` | **+528** | +133 |
| `EN_GRID`       |  +43 | +33 |
| `EN_RAMP`       |  +22 | +25 |
| `EN_NOISE`      |   +5 | +21 |

`EN_MOVING_BOX` is by far the most expensive feature (the bouncing
position arithmetic and per-pixel range comparators for the overlay).
`EN_NOISE` is the cheapest. There are no multiplies anywhere in the design.

## Tiniest possible build

| Config | LUT | FF |
|---|---:|---:|
| `tiny_raw_8b` (only EN_SOLID, OUTPUT_MODE=RAW, BPC=8) | **534** | 914 |

This is the absolute minimum: 1 pattern, RAW Bayer 8 bpc. ~534 LUTs total.
Useful as an image-sensor-emulator for camera/ISP bring-up where you only
need a controllable raw stream.

## Pixels-per-clock sweep

All-patterns RGB-8b build swept over `PIXELS_PER_CLOCK` (the `ppc1` row is
the same build as `full_rgb_8b` above). Mode/BPC/patterns are held fixed so
the numbers isolate the cost of widening the per-lane datapath from 1 to N
pixels per beat. Reproducible with `python synth/run_matrix.py ppc`.

| Config | LUT | FF | beat width | vs `ppc1` |
|---|---:|---:|---:|---|
| `ppc1_full_rgb_8b` | 1270 | 1212 |  24b | — |
| `ppc2_full_rgb_8b` | 1338 | 1288 |  48b | +5% LUT / +6% FF |
| `ppc4_full_rgb_8b` | 1554 | 1406 |  96b | +22% LUT / +16% FF |
| `ppc8_full_rgb_8b` | 1980 | 1644 | 192b | +56% LUT / +36% FF |

Scaling is strongly sub-linear: 8× the per-clock pixel throughput costs only
**+56% LUT / +36% FF**. The per-pixel packers and the single-step
counter/accumulator chains replicate per lane, but the shared timing FSM,
moving-box position arithmetic, and config registers do not.
`PIXELS_PER_CLOCK=1` is the default and its netlist is unchanged from
releases before the feature existed (verified: the pre-feature commit
synthesizes to the identical 1270 LUT / 1212 FF). There is no BRAM or DSP
cost at any PPC in this build; the `EN_IMAGE` patterns would add BRAM that
scales with PPC via replication.

**Test conditions**: Vivado 2025.2, target `xc7a100tcsg324-1` -1 speed grade,
`synth_design` default strategy, out-of-context mode. No timing constraints
applied (so the synth tool is conservative). Place-and-route results are
typically ~5% smaller after phys-opt and packing.
