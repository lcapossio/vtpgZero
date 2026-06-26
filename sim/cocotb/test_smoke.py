"""Minimal cocotb smoke test for vtpgz_axilite_top.

Goal: prove cocotb can drive inputs and read outputs through Verilator's
VPI before we trust any higher-level driver. Three stages, each isolated:

  1. observe_reset   -- clock, reset, watch m_axis_tvalid stay 0 while
                        CONTROL is at its 0 reset value. Verifies the
                        sim is alive and signals propagate from DUT.
  2. read_core_id    -- AXI-Lite read of CORE_ID (offset 0x00). Verifies
                        we can drive inputs and observe handshakes.
  3. write_then_read -- write PATTERN_SEL=5, read back, expect 5.
                        Verifies the full AXI-Lite write path lands.
"""
from __future__ import annotations

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

CLK_PERIOD_NS = 10

REG_CORE_ID     = 0x00
REG_CONTROL     = 0x08
REG_PATTERN_SEL = 0x18


async def _bringup(dut, reset_cycles: int = 20):
    cocotb.start_soon(Clock(dut.aclk, CLK_PERIOD_NS, unit="ns").start())
    dut.aresetn.value       = 0
    dut.s_axi_awaddr.value  = 0
    dut.s_axi_awprot.value  = 0
    dut.s_axi_awvalid.value = 0
    dut.s_axi_wdata.value   = 0
    dut.s_axi_wstrb.value   = 0
    dut.s_axi_wvalid.value  = 0
    dut.s_axi_bready.value  = 0
    dut.s_axi_araddr.value  = 0
    dut.s_axi_arprot.value  = 0
    dut.s_axi_arvalid.value = 0
    dut.s_axi_rready.value  = 0
    dut.m_axis_tready.value = 1
    dut.frame_sync_in.value = 0
    for _ in range(reset_cycles):
        await RisingEdge(dut.aclk)
    dut.aresetn.value = 1
    for _ in range(5):
        await RisingEdge(dut.aclk)


async def _axi_read(dut, addr: int, timeout: int = 100) -> int:
    """Drive an AR/R handshake. The slave (see rtl/vtpgz_axil_regs.v read
    FSM) raises arready and rvalid on the SAME clock edge, so AR and R
    must be sampled in a single combined loop -- splitting them into two
    phases misses the R handshake by exactly one cycle."""
    dut.s_axi_araddr.value  = addr
    dut.s_axi_arprot.value  = 0
    dut.s_axi_arvalid.value = 1
    dut.s_axi_rready.value  = 1
    ar_done = False
    data: int | None = None
    for _ in range(timeout):
        await RisingEdge(dut.aclk)
        if (not ar_done and int(dut.s_axi_arready.value)
                and int(dut.s_axi_arvalid.value)):
            dut.s_axi_arvalid.value = 0
            ar_done = True
        if (data is None and int(dut.s_axi_rvalid.value)
                and int(dut.s_axi_rready.value)):
            data = int(dut.s_axi_rdata.value)
            dut.s_axi_rready.value = 0
        if ar_done and data is not None:
            return data
    raise AssertionError(
        f"read 0x{addr:02X} timeout: ar_done={ar_done} "
        f"data_seen={data is not None}")


async def _axi_write(dut, addr: int, data: int, timeout: int = 100):
    """Drive AW/W/B handshakes. AW and W are launched concurrently; the
    valids drop the cycle their respective readies are observed."""
    dut.s_axi_awaddr.value  = addr
    dut.s_axi_awprot.value  = 0
    dut.s_axi_awvalid.value = 1
    dut.s_axi_wdata.value   = data
    dut.s_axi_wstrb.value   = 0xF
    dut.s_axi_wvalid.value  = 1
    dut.s_axi_bready.value  = 1
    aw_done = False
    w_done = False
    for _ in range(timeout):
        await RisingEdge(dut.aclk)
        if not aw_done and int(dut.s_axi_awready.value) and int(dut.s_axi_awvalid.value):
            dut.s_axi_awvalid.value = 0
            aw_done = True
        if not w_done and int(dut.s_axi_wready.value) and int(dut.s_axi_wvalid.value):
            dut.s_axi_wvalid.value = 0
            w_done = True
        if aw_done and w_done:
            break
    else:
        raise AssertionError(f"AW/W timeout writing 0x{addr:02X} = 0x{data:08X}")
    for _ in range(timeout):
        await RisingEdge(dut.aclk)
        if int(dut.s_axi_bvalid.value) and int(dut.s_axi_bready.value):
            dut.s_axi_bready.value = 0
            return
    raise AssertionError(f"B timeout writing 0x{addr:02X} = 0x{data:08X}")


@cocotb.test()
async def observe_reset(dut):
    """After reset, CONTROL=0 -> core is disabled -> AXIS should be idle."""
    await _bringup(dut)
    bad = []
    for cycle in range(50):
        await RisingEdge(dut.aclk)
        if int(dut.m_axis_tvalid.value):
            bad.append(cycle)
    assert not bad, (
        f"m_axis_tvalid asserted on cycles {bad[:8]} while CONTROL=0 -- "
        "core appears to be running before being enabled")


@cocotb.test()
async def read_core_id(dut):
    """AR/R handshake against offset 0x00; expect 'VTPG' magic."""
    await _bringup(dut)
    data = await _axi_read(dut, REG_CORE_ID)
    dut._log.info(f"CORE_ID = 0x{data:08X}")
    assert data == 0x47505456, (
        f"CORE_ID readback wrong: got 0x{data:08X}, expected 0x47505456")


@cocotb.test()
async def write_then_read(dut):
    """Round-trip a register write: PATTERN_SEL <- 5, then read back."""
    await _bringup(dut)
    await _axi_write(dut, REG_PATTERN_SEL, 5)
    data = await _axi_read(dut, REG_PATTERN_SEL)
    dut._log.info(f"PATTERN_SEL readback = 0x{data:08X}")
    assert data == 5, f"PATTERN_SEL = 0x{data:08X}, expected 5"
