# Image patterns (`EN_IMAGE` and `EN_BOX_IMAGE`)

Both features bake an image into inferred block RAM at synthesis time and
draw it with a hardware nearest-neighbour scaler (no multiplier, no divider —
a per-axis Q16 accumulator whose step is computed at elaboration and added
each pixel). Both are stripped at elaboration when their `EN_*` parameter is
`0`, costing no BRAM.

## Embedded image (`EN_IMAGE`, `PATTERN_SEL=9`)

Bakes a 24-bit RGB888 image into inferred block RAM and draws it **once per
frame, centred in the active region** with black padding around it.
`IMAGE_W` / `IMAGE_H` must be powers of two so the BRAM index field is a
low-bit slice of the source coordinates. `IMAGE_OUT_W` / `IMAGE_OUT_H` can be
any positive integer; when they differ from `IMAGE_W` / `IMAGE_H`, the Q16
accumulator does nearest-neighbour scaling between source and output.

Storage scales as `IMAGE_W × IMAGE_H × 24 bits`: 128×128 ≈ 393 kbit ≈ a
dozen BRAM36 tiles (post-pack); 64×64 fits comfortably in 3–4 tiles. Scaling
adds two ~20-bit accumulators + adders (~80 LUTs / 50 FFs) and no extra
BRAM. The 8-bit-per-component source is upsampled to the 12-bit internal
pipeline by MSB replication (`0xFF → 0xFFF`, `0x00 → 0x000`).

Enable in a build (override `IMAGE_W`/`IMAGE_H`/`IMAGE_HEX_FILE` if not using
the defaults):

```verilog
vtpgz_axilite_top #(
    .EN_IMAGE      (1),
    .IMAGE_W       (128),
    .IMAGE_H       (128),
    .IMAGE_HEX_FILE("tests/images/mandrill_128x128.mem"),
    /* … other params … */
) u_vtpgz ( /* … */ );
```

At runtime, write `PATTERN_SEL = 9` to display it. If `EN_IMAGE=0` the
generator is stripped and selecting pattern 9 produces a black frame (same
convention as every other stripped pattern).

Convert any PNG / JPG into a `$readmemh`-compatible hex file with the bundled
script:

```sh
# Bring in the canonical 512×512 mandrill ("baboon.png"), downscale to
# 128×128, and write the .mem the RTL expects by default.
python scripts/image_to_hex.py --fetch-mandrill --width 128 --height 128 \
    --out tests/images/mandrill_128x128.mem

# Or convert a local image
python scripts/image_to_hex.py myphoto.png --width 64 --height 64 \
    --out tests/images/myphoto_64x64.mem
```

## Image-in-box overlay (`EN_BOX_IMAGE=1`)

A second BRAM holds a small image that's painted inside the bouncing box
instead of `cfg_box_color`. The scaler is the same Q16 nearest-neighbour
accumulator as the IMAGE pattern, but the source rectangle is the box, so the
host has to update two runtime registers (`BOX_IMG_X_STEP`,
`BOX_IMG_Y_STEP`) whenever it changes `BOX_SIZE` — same flow it already uses
for `HG_STEP`, `VG_STEP`, `BAR_WIDTH`:

- `BOX_IMG_X_STEP = (BOX_IMAGE_W << 16) / BOX_SIZE.width`
- `BOX_IMG_Y_STEP = (BOX_IMAGE_H << 16) / BOX_SIZE.height`

Default `BOX_IMAGE_W` / `BOX_IMAGE_H` = 32 picks up ~1 BRAM36 with the
24-bit-in-36-bit-tile packing; bump to 64×32 (~1 BRAM36 still) or 64×64
(~3 BRAM36) if you want more detail. The border ring still draws on top, so a
small `BOX_BORDER` value frames the embedded image. Requires
`EN_MOVING_BOX=1`.

## Pixels-per-clock note

At `PIXELS_PER_CLOCK>1`, IMAGE / BOX_IMAGE replicate their source memory once
per lane and read it combinationally, so keep `IMAGE_W`/`IMAGE_H` (and
`BOX_IMAGE_W/H`) modest at high PPC — total image storage scales with
`PIXELS_PER_CLOCK`.
