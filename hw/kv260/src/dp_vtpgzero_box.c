/*
 * dp_vtpgzero_box.c -- Bare-metal KV260: vtpgZero (PL) -> writer -> DDR
 *                     -> DPDMA -> AVBUF -> DP TX -> monitor.
 *
 * Author: Leonardo Capossio - bard0 design - hello@bard0.com
 * Year:   2026
 *
 * What this app does:
 *
 *   1. Brings up the PS DisplayPort path: link training, MSA, AVBUF
 *      graphics layer, and DPDMA graphics channel 3 armed against a DDR
 *      framebuffer at 0x4C000000.
 *
 *   2. Programs the vtpgZero core in PL over AXI-Lite (mapped at
 *      0xA0000000 by the BD) for 1280x720 RGB color bars with the moving
 *      box overlay enabled. The PL writer (axis_to_ddr_writer) continuously
 *      streams the framebuffer into DDR over the HPC0 coherent slave.
 *
 *   3. The bouncing box appears on the monitor. No CPU per-frame work
 *      after the initial setup -- the PL pipeline runs autonomously.
 *
 * The CPU only configures the display path and PL core. It does not paint
 * frames after setup; the PL pipeline owns framebuffer updates.
 *
 * IMPORTANT: this app must run against the vtpgzero_kv260.xsa BSP (built
 * from hw/kv260/vivado/build_pl.tcl). The PL bitstream MUST be loaded before running
 * the app -- the bare-metal flow is:
 *
 *   1. set_jtag_boot
 *   2. PMUFW + FSBL (from vtpgzero_kv260 BSP)
 *   3. PL bitstream program
 *   4. dow + run dp_vtpgzero_box.elf
 */

#include "xdppsu.h"
#include "xdppsu_hw.h"
#include "xavbuf.h"
#include "xavbuf_hw.h"
#include "xavbuf_clk.h"
#include "xdpdma.h"
#include "xvidc.h"
#include "xstatus.h"
#include "xparameters.h"

/* ------------------------------------------------------------------ */
/* Raw UART1                                                           */
/* ------------------------------------------------------------------ */
void u1(char c) {
    volatile unsigned int *sr = (volatile unsigned int *)0xFF01002CUL;
    volatile unsigned int *ff = (volatile unsigned int *)0xFF010030UL;
    int t = 200000;
    while ((*sr & (1u << 4)) && --t > 0) {}
    *ff = (unsigned int)c;
}
/* Nonblocking RX: returns -1 if FIFO empty, else the byte. SR bit 1 =
 * RXEMPTY. */
static int u1_rx(void) {
    volatile unsigned int *sr = (volatile unsigned int *)0xFF01002CUL;
    volatile unsigned int *ff = (volatile unsigned int *)0xFF010030UL;
    if (*sr & (1u << 1)) return -1;
    return (int)(*ff & 0xFFu);
}
void u1s(const char *s) { while (*s) { if (*s == '\n') u1('\r'); u1(*s++); } }
void u1x(unsigned int v) {
    const char h[] = "0123456789ABCDEF";
    for (int i = 28; i >= 0; i -= 4) u1(h[(v >> i) & 0xF]);
}
void u1xl(const char *label, unsigned int v) { u1s(label); u1x(v); u1s("\n"); }

/* Scalar memcpy -- MMU is OFF so DDR is Device memory; libc's memcpy
 * uses unaligned NEON ldp/stp which fault on Device memory. This
 * byte-by-byte version is safe. We also compile with -mgeneral-regs-only
 * so the compiler never emits NEON for struct copies. */
void *memcpy(void *dst, const void *src, unsigned long n) {
    unsigned char *d = (unsigned char *)dst;
    const unsigned char *s = (const unsigned char *)src;
    while (n--) *d++ = *s++;
    return dst;
}

/* Cache stubs -- no MMU, no caches to manage. The BSP's xdpdma/xdppsu
 * drivers call these; without stubs we'd get link errors. */
void Xil_DCacheDisable(void) {}
void Xil_ICacheDisable(void) {}
void Xil_DCacheFlush(void) {}
void Xil_DCacheFlushRange(unsigned long a, unsigned long l) { (void)a; (void)l; }
void Xil_DCacheInvalidateRange(unsigned long a, unsigned long l) { (void)a; (void)l; }

#define RD(a)    (*(volatile unsigned int *)(unsigned long)(a))
#define WR(a, v) (*(volatile unsigned int *)(unsigned long)(a) = (unsigned int)(v))

static void short_delay(volatile unsigned int loops) {
    while (loops--) __asm__ volatile ("nop");
}
static void usleep_busy(unsigned us) {
    volatile unsigned i = us * 200u;
    while (i--) __asm__ volatile ("nop");
}

/* ================================================================== */
/* vtpgZero programming                                                */
/* ================================================================== */
#define VTPG_BASE              0xA0000000UL
#define VTPG_REG_CORE_ID       0x00
#define VTPG_REG_CONTROL       0x08
#define VTPG_REG_IMG_WIDTH     0x10
#define VTPG_REG_IMG_HEIGHT    0x14
#define VTPG_REG_PATTERN_SEL   0x18
#define VTPG_REG_COLOR_FORMAT  0x1C
#define VTPG_REG_SOLID_COLOR   0x20
#define VTPG_REG_BOX_COLOR     0x24
#define VTPG_REG_BOX_SIZE      0x28
#define VTPG_REG_BOX_SPEED     0x2C
#define VTPG_REG_GRID_SPACING  0x34
#define VTPG_REG_GRID_COLOR    0x38
#define VTPG_REG_CHECKER_SIZE  0x3C
#define VTPG_REG_FRAME_RATE    0x40
#define VTPG_REG_BAR_WIDTH     0x44
#define VTPG_REG_HG_STEP       0x48
#define VTPG_REG_VG_STEP       0x4C
#define VTPG_REG_BOX_BORDER    0x50

#define VTPG_PAT_COLORBAR      0
#define VTPG_CORE_ID_MAGIC     0x47505456u  /* "VTPG" little-endian */

static int vtpg_init_moving_box(unsigned w, unsigned h) {
    u1s("vtpg: probe PL @ 0xA0000000...\n");
    unsigned id = RD(VTPG_BASE + VTPG_REG_CORE_ID);
    u1xl("vtpg CORE_ID: ", id);
    if (id != VTPG_CORE_ID_MAGIC) {
        u1s("vtpg: bad magic, PL not responding\n");
        return XST_FAILURE;
    }
    unsigned fmt = RD(VTPG_BASE + VTPG_REG_COLOR_FORMAT);
    u1xl("vtpg COLOR_FORMAT: ", fmt);
    if (((fmt >> 16) != 24u) || (((fmt >> 8) & 0xFFu) != 8u) ||
        ((fmt & 0x3u) != 0u) || (((fmt >> 6) & 0x1u) != 0u)) {
        u1s("vtpg: expected RGB/Xilinx-order/8bpc/24-bit AXIS\n");
        return XST_FAILURE;
    }

    /* Disable while reprogramming */
    WR(VTPG_BASE + VTPG_REG_CONTROL, 0);

    /* Resolution */
    WR(VTPG_BASE + VTPG_REG_IMG_WIDTH,  w);
    WR(VTPG_BASE + VTPG_REG_IMG_HEIGHT, h);

    /* Host-precomputed step values (only used by colorbar / hgrad / vgrad,
     * but harmless to set always). */
    WR(VTPG_BASE + VTPG_REG_BAR_WIDTH, w / 8u);
    if (w > 1) WR(VTPG_BASE + VTPG_REG_HG_STEP, 0xFFFu / (w - 1));
    if (h > 1) WR(VTPG_BASE + VTPG_REG_VG_STEP, 0xFFFu / (h - 1));

    /* Moving-box overlay on colorbar background.
     * The new vtpgz_core draws the box as a POST-MUX overlay on whatever
     * pattern is selected. Selecting PAT_COLORBAR gives colorbars with
     * a bouncing yellow box on top. */
    WR(VTPG_BASE + VTPG_REG_BOX_COLOR, 0x00FFFFFFu);        /* white */
    WR(VTPG_BASE + VTPG_REG_BOX_SIZE,  (96u << 16) | 64u);  /* {w[16],h[16]} */
    WR(VTPG_BASE + VTPG_REG_BOX_SPEED, (4u  << 16) | 3u);   /* {dx[16],dy[16]} */
    WR(VTPG_BASE + VTPG_REG_BOX_BORDER, (2u << 24) | 0x00000000u);  /* 2px black border */

    /* FRAME_RATE_DIV set huge so the internal divider never auto-triggers;
     * frames are started by SW pulsing CONTROL[1] (sw_fsync) on each DP
     * vsync. The writer paints a 1280x720 frame in ~9.2 ms at 100 MHz, so
     * starting at DP vsync (16.67 ms period) lets the writer outpace the
     * DPDMA scanout for every row -- no tear. */
    WR(VTPG_BASE + VTPG_REG_FRAME_RATE, 100000000u);        /* ~1 Hz fallback */

    /* Select colorbar pattern; box overlay is automatic. */
    WR(VTPG_BASE + VTPG_REG_PATTERN_SEL, VTPG_PAT_COLORBAR);

    /* Enable (sw_fsync stays low until the vsync poll pulses it) */
    WR(VTPG_BASE + VTPG_REG_CONTROL, 1);
    u1s("vtpg moving-box programmed and enabled\n");
    return XST_SUCCESS;
}

/* ================================================================== */
/* DPSUB bring-up. Pixels come from the PL pipeline, not a CPU paint loop. */
/* ================================================================== */
#define CRF_APB_DP_VIDEO_REF_CTRL  0xFD1A0070UL
#define CRF_APB_DP_AUDIO_REF_CTRL  0xFD1A0074UL
#define CRF_APB_DP_STC_REF_CTRL    0xFD1A007CUL
#define DP_BASE                    0xFD4A0000UL
#define DP_SOFT_RESET              0x001CUL
#define FB_BASE        0x4C000000UL
#define FB_W           1280U
#define FB_H           720U
#define FB_STRIDE_PIX  1280U
#define FB_STRIDE_B    (FB_STRIDE_PIX * 4U)
#define FB_LINE_B      (FB_W * 4U)
#define FB_BYTES       (FB_STRIDE_B * FB_H)

static XDpPsu Dp;
static XAVBuf Av;
static XDpDma Dma;
static XDpDma_FrameBuffer FrameBuffer;

static void force_dp_video_src_to_vpll(void) {
    unsigned int v = RD(CRF_APB_DP_VIDEO_REF_CTRL);
    v &= ~0x7u;
    v |= (1u << 24);
    WR(CRF_APB_DP_VIDEO_REF_CTRL, v);
    WR(CRF_APB_DP_AUDIO_REF_CTRL, RD(CRF_APB_DP_AUDIO_REF_CTRL) | (1u << 24));
    WR(CRF_APB_DP_STC_REF_CTRL,   RD(CRF_APB_DP_STC_REF_CTRL)   | (1u << 24));
}

static void program_msa_720p60(XDpPsu *dp) {
    XDpPsu_MainStreamAttributes *m = &dp->MsaConfig;
    for (unsigned i = 0; i < sizeof(*m); ++i) ((unsigned char *)m)[i] = 0;
    m->PixelClockHz         = 74250000U;
    m->BitsPerColor         = 8;
    m->ComponentFormat      = XDPPSU_MAIN_STREAM_MISC0_COMPONENT_FORMAT_RGB;
    m->DynamicRange         = 0;
    m->YCbCrColorimetry     = 0;
    m->SynchronousClockMode = 1;
    m->Misc1                = 0;
    m->Vtm.Timing.HActive       = 1280;
    m->Vtm.Timing.HFrontPorch   = 110;
    m->Vtm.Timing.HSyncWidth    = 40;
    m->Vtm.Timing.HBackPorch    = 220;
    m->Vtm.Timing.HTotal        = 1650;
    m->Vtm.Timing.HSyncPolarity = 1;
    m->Vtm.Timing.VActive        = 720;
    m->Vtm.Timing.F0PVFrontPorch = 5;
    m->Vtm.Timing.F0PVSyncWidth  = 5;
    m->Vtm.Timing.F0PVBackPorch  = 20;
    m->Vtm.Timing.F0PVTotal      = 750;
    m->Vtm.Timing.VSyncPolarity  = 1;
    m->UserPixelWidth = 1;
    m->NVid   = 27U * 1000U * dp->LinkConfig.LinkRate;
    m->HStart = m->Vtm.Timing.HSyncWidth + m->Vtm.Timing.HBackPorch;
    m->VStart = m->Vtm.Timing.F0PVSyncWidth + m->Vtm.Timing.F0PVBackPorch;

    m->Misc0 = (XDPPSU_MAIN_STREAM_MISC0_BDC_8BPC << XDPPSU_MAIN_STREAM_MISC0_BDC_SHIFT)
             | (m->ComponentFormat << XDPPSU_MAIN_STREAM_MISC0_COMPONENT_FORMAT_SHIFT)
             | (m->DynamicRange    << XDPPSU_MAIN_STREAM_MISC0_DYNAMIC_RANGE_SHIFT)
             | (m->YCbCrColorimetry<< XDPPSU_MAIN_STREAM_MISC0_YCBCR_COLORIMETRY_SHIFT)
             | m->SynchronousClockMode;
    unsigned bpp = m->BitsPerColor * 3U;
    unsigned wpl = m->Vtm.Timing.HActive * bpp;
    if (wpl % 16U) wpl += 16U;
    wpl /= 16U;
    m->DataPerLane = wpl - dp->LinkConfig.LaneCount;
    if (wpl % dp->LinkConfig.LaneCount)
        m->DataPerLane += (wpl % dp->LinkConfig.LaneCount);
    m->TransferUnitSize = 64;
    unsigned vbw = ((m->PixelClockHz / 1000U) * bpp) / 8U;
    unsigned lbw = dp->LinkConfig.LaneCount * dp->LinkConfig.LinkRate * 27U;
    m->AvgBytesPerTU = ((10U * ((vbw * m->TransferUnitSize) / lbw)) + 5U) / 10U;
    m->InitWait = ((m->AvgBytesPerTU / 1000U) <= 4U)
                ? 64U : (m->TransferUnitSize - (m->AvgBytesPerTU / 1000U));
}

/* _start: SP_EL3=0 after rst -clear-registers; set SP before any C runs.
 * We do NOT enable FP/SIMD here: without MMU all memory is Device-nGnRnE,
 * and libc's NEON memcpy uses unaligned ldp/stp which fault on Device
 * memory. Instead we compile with -mgeneral-regs-only and provide a
 * scalar memcpy override above. */
void dp_run(void);
__asm__ (
    ".section .text\n"
    ".global _start\n"
    "_start:\n"
    "ldr x0, =0x10100000\n"
    "mov sp, x0\n"
    "b dp_run\n"
);

void dp_run(void) {
    u1s("\n\n=== KV260 DP + tpgZero moving box ===\n");

    /* PS-PL isolation removal + fabric reset toggle is done by the XSCT
     * cold-boot script (load.py) BEFORE this app starts. This ensures PL
     * AXI paths are live without disrupting DP state. See docs/PS_PL_ISOLATION.md. */

    /* DPDMA hard reset (clears stale state across JTAG loads). */
    {
        unsigned int r = RD(0xFD1A0100UL);
        WR(0xFD1A0100UL, r | (1u << 17));
        usleep_busy(10);
        WR(0xFD1A0100UL, r & ~(1u << 17));
        usleep_busy(100);
    }

    /* ---- DP/AVBUF/DPDMA init ---- */
    {
    XDpPsu_Config *cfg = XDpPsu_LookupConfig(XPAR_PSU_DP_DEVICE_ID);
    if (!cfg) { u1s("LookupConfig NULL\n"); goto hang; }
    for (unsigned i = 0; i < sizeof(Dp); ++i) ((unsigned char *)&Dp)[i] = 0;
    Dp.Config.DeviceId = cfg->DeviceId;
    Dp.Config.BaseAddr = cfg->BaseAddr;
    Dp.SAxiClkHz       = XDPPSU_0_S_AXI_ACLK;
    Dp.IsReady         = XIL_COMPONENT_IS_READY;

    for (unsigned i = 0; i < sizeof(Av); ++i) ((unsigned char *)&Av)[i] = 0;
    Av.Config.BaseAddr = cfg->BaseAddr;

    XDpDma_Config *dcfg = XDpDma_LookupConfig(XPAR_XDPDMA_0_DEVICE_ID);
    if (!dcfg) { u1s("DPDMA cfg NULL\n"); goto hang; }
    for (unsigned i = 0; i < sizeof(Dma); ++i) ((unsigned char *)&Dma)[i] = 0;
    XDpDma_CfgInitialize(&Dma, dcfg);

    u32 s = XDpPsu_InitializeTx(&Dp);
    u1xl("InitializeTx: ", s);
    if (s != XST_SUCCESS) goto hang;

    s = XDpDma_SetGraphicsFormat(&Dma, ABGR8888);
    u1xl("DpDma SetGfxFmt: ", s);
    s = XAVBuf_SetInputNonLiveGraphicsFormat(&Av, ABGR8888);
    u1xl("AVBuf SetInGfxFmt: ", s);
    XDpDma_SetQOS(&Dma, 11);

    /* 1. Disable main link, wake sink, train before any clock retune. */
    XDpPsu_EnableMainLink(&Dp, 0);

    if (!XDpPsu_IsConnected(&Dp)) { u1s("HPD low\n"); goto hang; }
    u1s("HPD high\n");

    /* DPCD SET_POWER wakeup via AUX channel. */
    { u8 d = 0x1;
      XDpPsu_AuxWrite(&Dp, XDPPSU_DPCD_SET_POWER_DP_PWR_VOLTAGE, 1, &d);
      usleep_busy(500);
      XDpPsu_AuxWrite(&Dp, XDPPSU_DPCD_SET_POWER_DP_PWR_VOLTAGE, 1, &d);
      usleep_busy(500);
    }

    /* Link training. */
    s = XDpPsu_GetRxCapabilities(&Dp);
    u1xl("GetRxCapabilities: ", s);
    if (s != XST_SUCCESS) goto hang;

    XDpPsu_SetEnhancedFrameMode(&Dp,
        Dp.LinkConfig.SupportEnhancedFramingMode ? 1 : 0);
    XDpPsu_SetLaneCount(&Dp, 1);
    XDpPsu_SetLinkRate(&Dp, XDPPSU_LINK_BW_SET_540GBPS);
    XDpPsu_SetDownspread(&Dp, Dp.LinkConfig.SupportDownspreadControl);

    s = XDpPsu_EstablishLink(&Dp);
    u1xl("EstablishLink: ", s);
    if (s != XST_SUCCESS) goto hang;

    /* 2. Clock + MSA + AVBUF + DPDMA + 0xB124 + EnableMainLink.
     * All back-to-back so clock retune doesn't clobber AVBUF state. */
    program_msa_720p60(&Dp);
    force_dp_video_src_to_vpll();
    s = XAVBuf_SetPixelClock(Dp.MsaConfig.PixelClockHz);
    u1xl("SetPixelClock: ", s);

    XDpPsu_WriteReg(Dp.Config.BaseAddr, XDPPSU_SOFT_RESET, 0x1);
    usleep_busy(10);
    XDpPsu_WriteReg(Dp.Config.BaseAddr, XDPPSU_SOFT_RESET, 0x0);

    XDpPsu_SetVideoMode(&Dp);

    XAVBuf_EnableGraphicsBuffers(&Av, 1);
    XAVBuf_InputVideoSelect(&Av, XAVBUF_VIDSTREAM1_NONLIVE,
                            XAVBUF_VIDSTREAM2_NONLIVE_GFX);
    s = XAVBuf_SetOutputVideoFormat(&Av, RGB_8BPC);
    u1xl("AVBuf SetOutFmt: ", s);
    XAVBuf_ConfigureGraphicsPipeline(&Av);
    XAVBuf_ConfigureOutputVideo(&Av);
    XAVBuf_SetBlenderAlpha(&Av, 0, 0);
    XAVBuf_SetAudioVideoClkSrc(&Av, XAVBUF_PS_CLK, XAVBUF_PS_CLK);
    XAVBuf_SoftReset(&Av);

    FrameBuffer.Address  = FB_BASE;
    FrameBuffer.Stride   = FB_STRIDE_B;
    FrameBuffer.LineSize = FB_LINE_B;
    FrameBuffer.Size     = FB_BYTES;

    XDpDma_DisplayGfxFrameBuffer(&Dma, &FrameBuffer);
    XDpDma_SetChannelState(&Dma, GraphicsChan, XDPDMA_ENABLE);
    XDpDma_SetupChannel(&Dma, GraphicsChan);
    XDpDma_Trigger(&Dma, GraphicsChan);

    /* 0xB124 pulse AFTER AVBUF+DPDMA, BEFORE EnableMainLink */
    XDpPsu_WriteReg(Dp.Config.BaseAddr, 0xB124, 0x3);
    usleep_busy(10);
    XDpPsu_WriteReg(Dp.Config.BaseAddr, 0xB124, 0x0);

    XDpPsu_EnableMainLink(&Dp, 1);
    u1s("Main link enabled\n");
    }

    if (vtpg_init_moving_box(FB_W, FB_H) != XST_SUCCESS) {
        u1s("vtpg init failed -- check that PL bitstream is loaded\n");
        goto hang;
    }

    static const unsigned PALETTE[8] = {
        0x00FFFF00, 0x0000FFFF, 0x00FF00FF, 0x0000FF00,
        0x000000FF, 0x00FF0000, 0x00FFFFFF, 0x00808080
    };

    unsigned box_w = 96, box_h = 64;
    unsigned box_dx = 4, box_dy = 3;
    unsigned box_color_idx = 6;  /* PALETTE[6] = white (matches init) */
    unsigned solid_color_idx = 6;
    unsigned grid_spacing = 32;
    unsigned checker_size = 32;
    unsigned vsync_lock = 1;  /* sw_fsync pulse on every DP vsync = no tear */

    u1s("=== Running. UART commands (115200 8N1):\n");
    u1s("  0..9  pattern (0=bars 1=hgrad 2=vgrad 3=checker 4=solid\n");
    u1s("        6=grid 7=ramp 8=noise 9=image; 5 reserved)\n");
    u1s("  +/-   box bigger/smaller     f/s  box faster/slower\n");
    u1s("  b     cycle box color        c    solid color (PATTERN=4)\n");
    u1s("  g/G   grid spacing -/+       k/K  checker size -/+\n");
    u1s("  e/d   enable / disable core  v    toggle vsync lock\n");
    u1s("  ?     help\n===\n");
    u1s("vsync_lock=on\n");

    const unsigned long DPDMA_ISR_REG = 0xFD4C0004UL;
    const unsigned long DPDMA_IEN_REG = 0xFD4C000CUL;
    const u32 VSYNC_INT_MASK          = 0x08000000U;

    WR(DPDMA_IEN_REG, VSYNC_INT_MASK);
    WR(DPDMA_ISR_REG, VSYNC_INT_MASK);

    unsigned tick = 0;
    while (1) {
        u32 isr = RD(DPDMA_ISR_REG);
        if (isr & VSYNC_INT_MASK) {
            /* Kick the writer FIRST, before anything else runs. DPDMA's
             * vsync interrupt fires at start-of-vblank, giving us ~500 us
             * before active scanout of row 0 begins. Anything we do here
             * (BSP handler, prints) eats into that budget and reintroduces
             * tear at the top rows. */
            if (vsync_lock) {
                WR(VTPG_BASE + VTPG_REG_CONTROL, 0x3);  /* sw_fsync rising edge */
                WR(VTPG_BASE + VTPG_REG_CONTROL, 0x1);  /* release */
            }
            /* Clear the latched ISR bit (write-1-to-clear) so we don't
             * re-trigger every loop iteration. */
            WR(DPDMA_ISR_REG, VSYNC_INT_MASK);
            XDpDma_InterruptHandler(&Dma);
            if ((tick++ & 0xFF) == 0) u1xl("[vsync] ", tick);
        }

        int ch = u1_rx();
        if (ch >= 0) {
            if (ch >= '0' && ch <= '9' && ch != '5') {
                WR(VTPG_BASE + VTPG_REG_PATTERN_SEL, (unsigned)(ch - '0'));
                u1s("pattern="); u1((char)ch); u1s("\n");
            } else if (ch == '+') {
                if (box_w < 600) box_w += 16;
                if (box_h < 400) box_h += 16;
                WR(VTPG_BASE + VTPG_REG_BOX_SIZE, (box_w << 16) | box_h);
                u1xl("box_size=", (box_w << 16) | box_h);
            } else if (ch == '-') {
                if (box_w > 32) box_w -= 16;
                if (box_h > 32) box_h -= 16;
                WR(VTPG_BASE + VTPG_REG_BOX_SIZE, (box_w << 16) | box_h);
                u1xl("box_size=", (box_w << 16) | box_h);
            } else if (ch == 'f') {
                if (box_dx < 16) box_dx++;
                if (box_dy < 16) box_dy++;
                WR(VTPG_BASE + VTPG_REG_BOX_SPEED, (box_dx << 16) | box_dy);
                u1xl("box_speed=", (box_dx << 16) | box_dy);
            } else if (ch == 's') {
                if (box_dx > 1) box_dx--;
                if (box_dy > 1) box_dy--;
                WR(VTPG_BASE + VTPG_REG_BOX_SPEED, (box_dx << 16) | box_dy);
                u1xl("box_speed=", (box_dx << 16) | box_dy);
            } else if (ch == 'b') {
                box_color_idx = (box_color_idx + 1) & 7;
                WR(VTPG_BASE + VTPG_REG_BOX_COLOR, PALETTE[box_color_idx]);
                u1xl("box_color=", PALETTE[box_color_idx]);
            } else if (ch == 'c') {
                solid_color_idx = (solid_color_idx + 1) & 7;
                WR(VTPG_BASE + VTPG_REG_SOLID_COLOR, PALETTE[solid_color_idx]);
                u1xl("solid_color=", PALETTE[solid_color_idx]);
            } else if (ch == 'g') {
                if (grid_spacing > 8) grid_spacing -= 8;
                WR(VTPG_BASE + VTPG_REG_GRID_SPACING, grid_spacing);
                u1xl("grid=", grid_spacing);
            } else if (ch == 'G') {
                if (grid_spacing < 256) grid_spacing += 8;
                WR(VTPG_BASE + VTPG_REG_GRID_SPACING, grid_spacing);
                u1xl("grid=", grid_spacing);
            } else if (ch == 'k') {
                if (checker_size > 4) checker_size -= 4;
                WR(VTPG_BASE + VTPG_REG_CHECKER_SIZE, checker_size);
                u1xl("checker=", checker_size);
            } else if (ch == 'K') {
                if (checker_size < 256) checker_size += 4;
                WR(VTPG_BASE + VTPG_REG_CHECKER_SIZE, checker_size);
                u1xl("checker=", checker_size);
            } else if (ch == 'e') {
                WR(VTPG_BASE + VTPG_REG_CONTROL, 1);
                u1s("enable=1\n");
            } else if (ch == 'd') {
                WR(VTPG_BASE + VTPG_REG_CONTROL, 0);
                u1s("enable=0\n");
            } else if (ch == 'v') {
                vsync_lock = !vsync_lock;
                /* When locked, kill the internal divider so only the
                 * vsync-driven sw_fsync pulse triggers frames. When
                 * unlocked, restore ~60 Hz free-run. */
                WR(VTPG_BASE + VTPG_REG_FRAME_RATE,
                   vsync_lock ? 100000000u : 1666666u);
                u1s(vsync_lock ? "vsync_lock=on\n" : "vsync_lock=off\n");
            } else if (ch == '?' || ch == 'h') {
                u1s("keys: 0..9 pattern | +/- size | f/s speed | b box color |\n"
                    "      c solid color | g/G grid | k/K checker | e/d enable\n");
            }
        }

        short_delay(100);
    }

hang:
    while (1) __asm__ volatile ("wfi");
}
