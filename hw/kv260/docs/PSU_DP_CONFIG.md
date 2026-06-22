# Zynq UltraScale+ PSU DisplayPort Configuration

The KV260 DisplayPort path is implemented by the Zynq UltraScale+ PS
DisplayPort subsystem. The block design in `hw/kv260/vivado/build_bd.tcl`
sets the required PS properties directly so the XSA can be regenerated from
this repository alone.

## Property Namespaces

The DisplayPort settings are split across two PS property namespaces:

| Namespace | Purpose |
|---|---|
| `PSU__DISPLAYPORT__*` | Peripheral enable and GT lane mapping |
| `PSU__DP__*` | Protocol and reference-clock settings |
| `PSU__DPAUX__*` | AUX-channel MIO mapping |

Set the `PSU__DISPLAYPORT__*` gate first. If the DisplayPort peripheral is
not enabled, downstream `PSU__DP__*` and `PSU__DPAUX__*` properties can be
left unset by the IP configuration.

## KV260 Settings Used Here

```tcl
CONFIG.PSU__DISPLAYPORT__PERIPHERAL__ENABLE {1}
CONFIG.PSU__DISPLAYPORT__LANE0__ENABLE      {1}
CONFIG.PSU__DISPLAYPORT__LANE0__IO          {GT Lane1}
CONFIG.PSU__DISPLAYPORT__LANE1__ENABLE      {1}
CONFIG.PSU__DISPLAYPORT__LANE1__IO          {GT Lane0}

CONFIG.PSU__DP__LANE_SEL                    {Dual Lower}
CONFIG.PSU__DP__REF_CLK_SEL                 {Ref Clk0}
CONFIG.PSU__DP__REF_CLK_FREQ                {27}

CONFIG.PSU__DPAUX__PERIPHERAL__ENABLE       {1}
CONFIG.PSU__DPAUX__PERIPHERAL__IO           {MIO 27 .. 30}

CONFIG.PSU__USE__VIDEO                      {1}
CONFIG.PSU__CRF_APB__DP_VIDEO_REF_CTRL__SRCSEL {VPLL}
```

The bare-metal app trains one HBR2 lane. Keeping both lane mappings visible
in the block design makes the PS configuration explicit and reproducible.

## Clocking

`dp_video_in_clk` is exposed when `PSU__USE__VIDEO` is enabled. This design
ties it to `pl_clk0`; pixels for the final DP stream are sourced from the
PS DPDMA graphics path rather than from a live PL video input.

The DP video reference clock is sourced from VPLL so
`XAVBuf_SetPixelClock(74250000)` can retune the pixel clock for 1280x720 at
60 Hz.
