# vtpgZero: YUV output is full-range BT.601, which HD/UHD video links do not carry

<!-- Author: Leonardo Capossio - bard0 design (www.bard0.com) - hello@bard0.com | Year: 2026 | License: MIT -->

## Summary

In `OUTPUT_MODE=2` (YUV), every pattern comes out **full range** (codes 0 to
full scale), and the colour bars use the **BT.601** matrix. HDMI, SDI and most
video IP treat YCbCr as **limited range** (Y 64–940, C 64–960 at 10 bits). At
HD and UHD they also decode it with **BT.709**. So the bars come out wrong on
real equipment:
- black and white are clipped;
- every primary and secondary is clipped;
- the bar hues are shifted.

Nothing in the stream says it is wrong. The picture merely looks almost right.

Proposal: two build-time parameters, `YUV_RANGE` and `YUV_MATRIX`. Their
defaults keep today's output bit for bit, so no existing user is affected.

## Evidence

Found on a ZCU106 cross-converter (PixDocDemo), which builds vtpgZero at
`OUTPUT_MODE=2, YUV_SUBSAMPLE=1, BPC=10`. That is 4:2:2 10-bit into an AMD
frame buffer, then HDMI TX and SDI TX. The frame buffer was read over JTAG,
lines 0 and 500:

- Luma bar levels: `0, 116, 306, 422, 601, 717, 907, 1023`
- Chroma: `0 … 1023`
- **480 of 1920 samples per line are code 0 or 1023**, which are SDI's
  reserved TRS codes.

They come from `bar_palette()` in `rtl/vtpgz_core.v`: 100% bars, BT.601,
full range. White is `12'hFFF`, black is `12'h000`, and Cb/Cr swing the full
`000…FFF`.

What an HD YCbCr sink shows from them. The sink applies BT.709 limited-range
decode to the current palette at 10 bits (12-bit >> 2). Values are in %
RGB; anything outside 0–100 is clipped on screen:

| bar     | Y / Cb / Cr sent | decoded R, G, B %  |
|---------|------------------|--------------------|
| white   | 1023 / 512 / 512 | 109, 109, 109      |
| yellow  | 907 / 0 / 595    | 111, 103, **−10**  |
| cyan    | 717 / 684 / 0    | **−15**, 98, 110   |
| green   | 601 / 173 / 83   | **−14**, 91, **−9**|
| magenta | 422 / 851 / 940  | 116, 11, 111       |
| red     | 306 / 339 / 1023 | 117, 5, **−8**     |
| blue    | 116 / 1023 / 428 | **−9**, 0, 112     |
| black   | 0 / 512 / 512    | −7, −7, −7         |

Every bar is out of gamut. None of them matches the colour a reference bar
signal produces.

Consequences seen downstream:
- **HDMI:** the AVI InfoFrame defaults YCbCr to limited range, so a sink
  clips 0–63 and 941–1023. Signalling full range needs the YQ bit, and it
  is legal only if the sink's EDID advertises QY. Most CE sinks do not.
- **SDI:** codes 0–3 and 1020–1023 are reserved for TRS. AMD's SDI TX
  bridge happens to clamp to 4–1019, in `v_vid_sdi_tx_bridge_v2_0_12g_clamp.v`
  and in the 3G formatter. Without such a clamp, sending this stream on SDI
  would corrupt sync. Even clamped, the bars are super-black and super-white,
  which an SDI analyser flags as gamut errors.
- **Test value:** colour bars exist so an engineer can check a chain against
  known values. Bars at non-standard levels cannot serve as that reference.

## Proposal

### 1. `YUV_RANGE` (build-time, YUV mode only)

- `0` = FULL. The default, and exactly today's behaviour.
- `1` = LIMITED. Y 16–235, C 16–240 at 8 bits (64–940 and 64–960 at 10
  bits).

**Colour bars:** a second precomputed palette, constants only. The 12-bit
values should be exactly 4 × the standard 10-bit values. The pack stage
truncates LSBs, so every BPC then lands on the standard code: `3760>>2 = 940`,
`3760>>4 = 235`, `256>>4 = 16`.

**Runtime-valued patterns** (HGRAD, VGRAD, CHECKER, RAMP, NOISE, the GRID
background, the IMAGE padding): compress luma once, in the pattern-mux output,
before the pack stage. Chroma on these patterns is already neutral `0x800` and
stays so. Suggested luma, in the 12-bit domain, exact at both ends at every
BPC:

    Y_lim = 256 + ((Y * 3505) >> 12)     // 0 -> 256 (64 @10b), 4095 -> 3760 (940 @10b)

3505 is `0xDB1`. It can be written as shifts and adds, so the YUV build stays
DSP-free, or it can use one DSP. If a future pattern produces non-neutral
chroma at run time, the matching chroma map is:

    C_lim = 2048 + (((C - 2048) * 7 + 4) >>> 3)   // 0 -> 256 (64 @10b), 0x800 -> 0x800 exact

Its top lands at 959 rather than 960. That is legal, and the one-code
asymmetry comes from full-range chroma having no +2048.

**Colour registers** (`SOLID_COLOR`, `BOX_COLOR`, `GRID_COLOR`) should **not**
be scaled. They are already documented as raw `{Y,Cb,Cr}` code values in YUV
builds, and a host that writes an exact code expects to get that code.
Document that in a LIMITED build the host is responsible for writing legal
values.

### 2. `YUV_MATRIX` (build-time, YUV mode only; affects the colour-bar palette only)

- `0` = BT.601. The default, today's behaviour, and correct for SD.
- `1` = BT.709. Correct for HD and UHD. HDMI and SDI assume it at those
  resolutions unless told otherwise.

Four constant palettes in all: {601, 709} × {full, limited}. Each is eight
triples, so the cost is a few LUTs of constant mux and nothing at run time.

### 3. Optional: 75% bars

SMPTE RP 219 75% bars are what broadcast equipment expects to see. They could
be a `BAR_LEVEL` parameter, or a palette choice alongside 100%. This is
lower priority than 1 and 2.

## Reference values (10-bit, `{Y, Cb, Cr}`; 12-bit constant = value × 4)

BT.709, limited, 100% (the most useful single palette for HD/UHD HDMI and SDI):

| bar     | Y   | Cb  | Cr  | 12-bit                |
|---------|-----|-----|-----|-----------------------|
| white   | 940 | 512 | 512 | `EB0 800 800`         |
| yellow  | 877 |  64 | 553 | `DB4 100 8A4`         |
| cyan    | 754 | 615 |  64 | `BC8 99C 100`         |
| green   | 691 | 167 | 105 | `ACC 29C 1A4`         |
| magenta | 313 | 857 | 919 | `4E4 D64 E5C`         |
| red     | 250 | 409 | 960 | `3E8 664 F00`         |
| blue    | 127 | 960 | 471 | `1FC F00 75C`         |
| black   |  64 | 512 | 512 | `100 800 800`         |

BT.709, limited, 75% (matches SMPTE RP 219):

| bar     | Y   | Cb  | Cr  |
|---------|-----|-----|-----|
| white   | 721 | 512 | 512 |
| yellow  | 674 | 176 | 543 |
| cyan    | 581 | 589 | 176 |
| green   | 534 | 253 | 207 |
| magenta | 251 | 771 | 817 |
| red     | 204 | 435 | 848 |
| blue    | 111 | 848 | 481 |
| black   |  64 | 512 | 512 |

BT.601, limited, 100%:

| bar     | Y   | Cb  | Cr  |
|---------|-----|-----|-----|
| white   | 940 | 512 | 512 |
| yellow  | 840 |  64 | 585 |
| cyan    | 678 | 663 |  64 |
| green   | 578 | 215 | 137 |
| magenta | 426 | 809 | 887 |
| red     | 326 | 361 | 960 |
| blue    | 164 | 960 | 439 |
| black   |  64 | 512 | 512 |

Computed as Y = Kr·R + Kg·G + Kb·B, Cb = (B−Y)/(2(1−Kb)), Cr = (R−Y)/(2(1−Kr)),
then Y' = 64 + 876·Y and C' = 512 + 896·C, rounded.
BT.709: Kr = 0.2126, Kb = 0.0722. BT.601: Kr = 0.299, Kb = 0.114.

## Tests it needs

- **Palette exactness:** for each {matrix, range}, the bars at `BPC` 8, 10 and
  12 equal the tables above exactly, with no tolerance. The byte-exact model
  gate (`sim/run_sim.py all_modes`) covers this once the Python model has the
  same palettes. The model must get them from the formula above, not a copy of
  the RTL constants, or the check proves nothing.
- **Range bounds:** in a LIMITED build, over a full frame of every
  runtime-valued pattern, Y is within 64–940 and C within 64–960 at 10 bits,
  and the extremes are actually reached: Y = 64 and 940 on the gradients. A
  bound check that passes on an all-grey frame proves nothing.
- **Neutral chroma is exact:** `0x800` in, `0x800` out, in both ranges.
- **Default is unchanged:** a FULL/601 build is byte-identical to the current
  release across the existing regression.
- **Prove the checks bite:** swap one palette constant, or drop the luma map,
  and confirm the palette and bounds tests fail.

## Related issues found while reading the code

- **IMAGE in a YUV build sends RGB as YCbCr.** `image_r/g/b_bus` go straight
  into `pat_c0..2` (`vtpgz_core.v` ~1092 and the pattern mux ~1272) with no
  conversion. The image comes out as the wrong colours. Its black padding
  (`12'h000` on all three components) becomes Y=0, Cb=0, Cr=0, which is
  **saturated green**. Either convert (that needs a matrix, and so DSPs), or
  reject `EN_IMAGE=1` with `OUTPUT_MODE=2` at elaboration, the way the PPC
  guard does. At the least, pad with `{black Y, 0x800, 0x800}`.
- **Documentation:** the parameter comment (`vtpgz_core.v:66`, "full BT.601
  matrix … uses DSPs") and the README ("BT.601-style") should say which
  range and matrix the output uses. I found no multiplier in the YUV path, so
  "uses DSPs" looks stale.

## Downstream use once released (PixDocDemo)

Set `YUV_RANGE=1, YUV_MATRIX=1` on the `tpg` cell in `tcl/build_bd.tcl`, bump
the submodule, and rebuild. Its BUG-193 is then fixed on both outputs, with no
AVI change needed, since limited range is the default the InfoFrame already
implies.
