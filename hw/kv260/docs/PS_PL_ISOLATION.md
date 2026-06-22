# ZynqMP PS-PL Isolation and Fabric Reset

In this JTAG bare-metal flow, the FSBL is loaded before the PL bitstream.
Because the FSBL does not program the bitstream itself, it also does not run
the PL handoff path that removes PS-PL isolation and toggles the fabric reset.

`hw/kv260/scripts/load.py --cold` performs that handoff after `fpga -f` and
before downloading the A53 application.

## Why It Matters

Without the handoff:

- PS AXI masters can be blocked from reaching PL slaves.
- `proc_sys_reset` in the generated block design may keep
  `peripheral_aresetn` asserted.
- A read from the vtpgZero AXI-Lite aperture at `0xA0000000` can hang instead
  of returning `CORE_ID`.

## Sequence Used by the Loader

The loader writes the PMU global registers that request PL power-up:

```tcl
mwr -force 0xFFD80118 [expr {[mrd -force -value 0xFFD80118] | 0x00800000}]
mwr -force 0xFFD80120 [expr {[mrd -force -value 0xFFD80120] | 0x00800000}]
```

Then it toggles `pl_resetn0` via EMIO GPIO bank 5 bit 31:

```tcl
mwr -force 0xFF0A002C 0x80000000
mwr -force 0xFF0A0344 0x80000000
mwr -force 0xFF0A0348 0x80000000
mwr -force 0xFF0A0054 0x80000000
after 50
mwr -force 0xFF0A0054 0x00000000
after 50
mwr -force 0xFF0A0054 0x80000000
after 200
```

After this, AXI transactions from PS `M_AXI_HPM0_FPD` can reach the vtpgZero
AXI-Lite slave and the PL writer can use PS `S_AXI_HPC0_FPD` for DDR writes.
