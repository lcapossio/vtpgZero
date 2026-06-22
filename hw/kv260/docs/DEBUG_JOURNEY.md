# KV260 Bare-Metal DisplayPort Notes

This note records the design constraints behind the `hw/kv260` reference
design. It is self-contained: the scripts, RTL, application source, and docs
needed by this port live in this repository.

## 1. PSU DisplayPort Properties

The Zynq UltraScale+ PS DisplayPort configuration uses two property
namespaces:

- `PSU__DISPLAYPORT__*`: peripheral gate and GT lane mapping
- `PSU__DP__*`: protocol and clocking fields

The peripheral gate must be enabled first. If
`PSU__DISPLAYPORT__PERIPHERAL__ENABLE` is left at zero, the `PSU__DP__*`
fields can appear to be accepted by Tcl while remaining unset in the IP.

See [PSU_DP_CONFIG.md](PSU_DP_CONFIG.md).

## 2. PS-PL Isolation

In the JTAG bare-metal flow, the FSBL does not load the bitstream itself.
That means it also does not remove PS-PL isolation or toggle `pl_resetn0`
for the fabric after programming.

The loader handles this after `fpga -f` and before downloading the A53 app:

- request PL power-up through the PMU global registers
- toggle `pl_resetn0` through EMIO GPIO bank 5 bit 31
- let the block design `proc_sys_reset` release the generated AXI fabric

Without that sequence, reads to the vtpgZero AXI-Lite aperture can hang
because the PS master never reaches the PL slave.

See [PS_PL_ISOLATION.md](PS_PL_ISOLATION.md).

## 3. Block Design Wiring

The PS AXI ports carry sideband signals that are easy to wire incorrectly by
hand. This design uses Vivado connection automation for both AXI paths:

- PS `M_AXI_HPM0_FPD` to vtpgZero AXI-Lite control
- writer `m_axi` to PS `S_AXI_HPC0_FPD` DDR write path

The block design then pins the vtpgZero control aperture to `0xA0000000` so
the firmware and generated address map cannot drift apart silently.

## 4. DisplayPort Bring-Up Ordering

The bare-metal app uses this ordering for the PS DisplayPort path:

1. Hard-reset stale DPDMA state.
2. Initialize DPPsu, AVBUF, and DPDMA driver structs.
3. Disable the main link.
4. Wake the sink using DPCD `SET_POWER` over AUX.
5. Read receiver capabilities and train one HBR2 lane.
6. Program 1280x720@60 MSA fields.
7. Retune the DP pixel clock through VPLL.
8. Configure AVBUF graphics and DPDMA graphics channel 3.
9. Pulse DP register `0xB124`.
10. Enable the main link.

Small ordering changes in this sequence can produce a trained link with no
visible monitor output, so the sequence is kept explicit in
`src/dp_vtpgzero_box.c`.

## 5. DDR Writer Throughput

Single-beat AXI4 writes are too slow for a 1280x720 framebuffer at 60 Hz.
The writer buffers 16 pixels and issues 16-beat bursts, flushing partial
bursts at end-of-line or when a new SOF arrives with pending data.

The framebuffer format is ABGR8888 at `0x4C000000`; vtpgZero emits RGB888 in
Xilinx AXI4-Stream byte order, and `axis_to_ddr_writer` performs the packing.
The writer is parameterized for the expected frame size and consumes/drops
surplus beats after `IMG_W*IMG_H` pixels until the next SOF, so a malformed
stream cannot continue writing beyond the framebuffer.

## 6. BSP Clock Property

The PS configuration sets `CONFIG.PSU__PSS_REF_CLK__FREQMHZ {33.333}`. The
standalone BSP generator needs that clock information to produce the driver
headers and `libxil.a` used by the bare-metal app.
