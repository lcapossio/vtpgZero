//-----------------------------------------------------------------------------
// vtpgz_defs.vh - vtpgZero Video Test Pattern Generator definitions
//
// SPDX-FileCopyrightText: 2026 Leonardo Capossio - bard0 design - hello@bard0.com
// SPDX-License-Identifier: Apache-2.0
//-----------------------------------------------------------------------------
`ifndef VTPGZ_DEFS_VH
`define VTPGZ_DEFS_VH

// IP version
//   0.1.2 = current: configurable inter-line TVALID gap
//   0.1.1: colorbar state/AXIS alignment fix + regression
//   0.1.0: box overlay + configurable border, no CSC, BPC 8-16,
//           4 Bayer tiles, CORE_ID at 0x00, vtpgz_core split
`define VTPGZ_VERSION_MAJOR  8'd0
`define VTPGZ_VERSION_MINOR  8'd1
`define VTPGZ_VERSION_PATCH 16'd2

// Register byte offsets (AXI4-Lite, 32-bit data)
// 0x00 is a fixed core-identifier ASCII tag "VTPG" (in little-endian
// bytes: 'V'=0x56, 'T'=0x54, 'P'=0x50, 'G'=0x47 -> 0x47505456). Software
// can read it to confirm it's talking to a vtpgZero core.
`define VTPGZ_REG_CORE_ID       8'h00
`define VTPGZ_REG_VERSION       8'h04
`define VTPGZ_REG_CONTROL       8'h08
`define VTPGZ_REG_STATUS        8'h0C
`define VTPGZ_REG_IMG_WIDTH     8'h10
`define VTPGZ_REG_IMG_HEIGHT    8'h14
`define VTPGZ_REG_PATTERN_SEL   8'h18
`define VTPGZ_REG_COLOR_FORMAT  8'h1C  // RO: reflects build-time output mode
`define VTPGZ_REG_SOLID_COLOR   8'h20
`define VTPGZ_REG_BOX_COLOR     8'h24
`define VTPGZ_REG_BOX_SIZE      8'h28
`define VTPGZ_REG_BOX_SPEED     8'h2C
`define VTPGZ_REG_RSVD_30       8'h30  // reserved — future use
`define VTPGZ_REG_GRID_SPACING  8'h34
`define VTPGZ_REG_GRID_COLOR    8'h38
`define VTPGZ_REG_CHECKER_SIZE  8'h3C
`define VTPGZ_REG_FRAME_RATE    8'h40
`define VTPGZ_REG_BAR_WIDTH     8'h44
`define VTPGZ_REG_HG_STEP       8'h48
`define VTPGZ_REG_VG_STEP       8'h4C
`define VTPGZ_REG_BOX_BORDER   8'h50  // {border_width[8], border_color[24]}
// Host-pre-computed nearest-neighbour step values for the BOX_IMAGE
// overlay (only meaningful with EN_BOX_IMAGE=1). Host writes
//   BOX_IMG_X_STEP = (BOX_IMAGE_W << 16) / BOX_SIZE.width
//   BOX_IMG_Y_STEP = (BOX_IMAGE_H << 16) / BOX_SIZE.height
// whenever BOX_SIZE changes; mirrors the host-precompute pattern used by
// HG_STEP / VG_STEP / BAR_WIDTH.
`define VTPGZ_REG_BOX_IMG_X_STEP 8'h54
`define VTPGZ_REG_BOX_IMG_Y_STEP 8'h58

// Magic value returned by VTPGZ_REG_CORE_ID. Little-endian "VTPG":
//   byte 0 = 'V' (0x56)
//   byte 1 = 'T' (0x54)
//   byte 2 = 'P' (0x50)
//   byte 3 = 'G' (0x47)
`define VTPGZ_CORE_ID_MAGIC 32'h47505456

// Pattern IDs
`define VTPGZ_PAT_COLORBAR    4'd0
`define VTPGZ_PAT_HGRAD       4'd1
`define VTPGZ_PAT_VGRAD       4'd2
`define VTPGZ_PAT_CHECKER     4'd3
`define VTPGZ_PAT_SOLID       4'd4
`define VTPGZ_PAT_RSVD_5      4'd5  // reserved — future use (was PAT_MOVING_BOX)
`define VTPGZ_PAT_GRID        4'd6
`define VTPGZ_PAT_RAMP        4'd7
`define VTPGZ_PAT_NOISE       4'd8
`define VTPGZ_PAT_IMAGE       4'd9  // BRAM-baked image, baked at synth time

// ----- Build-time output-mode parameter values (OUTPUT_MODE) -----
`define VTPGZ_MODE_RGB    0
`define VTPGZ_MODE_RAW    1
`define VTPGZ_MODE_YUV    2

// ----- YUV_SUBSAMPLE parameter values (only meaningful for MODE_YUV) -----
`define VTPGZ_YUV_444     0
`define VTPGZ_YUV_422     1

// ----- RAW_BAYER parameter values (only meaningful for MODE_RAW) -----
// Tile names follow the standard convention: row-by-row, left to right,
// top to bottom. RGGB = row0:[R,G] / row1:[G,B], etc.
`define VTPGZ_RAW_PLAIN   0
`define VTPGZ_RAW_RGGB    1
`define VTPGZ_RAW_BGGR    2
`define VTPGZ_RAW_GRBG    3
`define VTPGZ_RAW_GBRG    4

// ----- RGB_ORDER parameter values -----
// 0 = Xilinx convention: { pad, B, G, R }     (R in LSBs)
// 1 = legacy             : { R, G, B, pad }   (R in MSBs)
`define VTPGZ_RGB_ORDER_XILINX 0
`define VTPGZ_RGB_ORDER_LEGACY 1

// Internal pixel width (per component) — patterns always render at 12-bit
// precision and the output stage shrinks down to BPC at the end.
`define VTPGZ_INT_BPP 12

// COLOR_FORMAT register read-back encoding
//   [1:0]  = OUTPUT_MODE         (0=RGB, 1=RAW, 2=YUV)
//   [2]    = YUV_SUBSAMPLE       (0=444, 1=422; meaningful only when MODE_YUV)
//   [5:3]  = RAW_BAYER           (0=plain, 1=RGGB, 2=BGGR, 3=GRBG, 4=GBRG;
//                                 meaningful only when MODE_RAW)
//   [6]    = RGB_ORDER           (0=Xilinx, 1=legacy)
//   [7]    = reserved
//   [15:8] = BPC                 (8/10/12/14/16)
//   [31:16]= TDATA_WIDTH         (auto-derived AXIS data width)

`endif
