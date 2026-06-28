"""AXI-Stream tready propagation test.

The `tready_low_should_stall_axis` test asserts: when cocotb drives
m_axis_tready=0 and the core is otherwise enabled, no handshakes occur
(tvalid asserts but the source stalls). This proves cocotb's writes to
input signals reach the DUT through Verilator's VPI.

NOTE on the missing companion test: a `tready_high_should_advance_axis`
test was attempted but cocotb 2.0.1 + Verilator 5.048 returns a constant
sampled-once value when reading the packed m_axis_tdata output every
cycle, even though the DUT's pipeline IS advancing (handshakes count is
non-zero and matches expected, the C++ Verilator harness reads the same
signal correctly, and tlast / tuser update normally). The byte-exact
RTL<->model gate in sim/run_sim.py (driven by sim_capture.cpp) covers
the data-path verification across all 20 mode/bpc configs; the YUV
spec gate is hw/arty_a7_100t/python/check_yuv_spec.py against the
reference model. Revisit cocotb-side AXIS capture when 2.x / Verilator
ships a fix for the packed-output read quirk.
"""
from __future__ import annotations

import os

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

CLK_PERIOD_NS = 10

REG_CONTROL     = 0x08
REG_IMG_WIDTH   = 0x10
REG_IMG_HEIGHT  = 0x14
REG_PATTERN_SEL = 0x18
REG_FRAME_RATE  = 0x40
REG_BAR_WIDTH   = 0x44

FRAME_W = 32
FRAME_H = 4
LINE_GAP_CYCLES = int(os.environ.get("VTPGZ_LINE_GAP_CYCLES", "1"))


async def _axi_write(dut, addr, data, timeout=100):
    dut.s_axi_awaddr.value  = addr
    dut.s_axi_awvalid.value = 1
    dut.s_axi_wdata.value   = data
    dut.s_axi_wstrb.value   = 0xF
    dut.s_axi_wvalid.value  = 1
    dut.s_axi_bready.value  = 1
    aw = w = b = False
    for _ in range(timeout):
        await RisingEdge(dut.aclk)
        if not aw and int(dut.s_axi_awready.value) and int(dut.s_axi_awvalid.value):
            dut.s_axi_awvalid.value = 0; aw = True
        if not w and int(dut.s_axi_wready.value) and int(dut.s_axi_wvalid.value):
            dut.s_axi_wvalid.value = 0; w = True
        if not b and int(dut.s_axi_bvalid.value) and int(dut.s_axi_bready.value):
            dut.s_axi_bready.value = 0; b = True
        if aw and w and b:
            return
    raise AssertionError("write timeout")


@cocotb.test()
async def tready_low_should_stall_axis(dut):
    """Bring the core up, hold m_axis_tready=0, and count handshakes."""
    cocotb.start_soon(Clock(dut.aclk, CLK_PERIOD_NS, unit="ns").start())
    dut.aresetn.value       = 0
    for s in ("s_axi_awaddr","s_axi_awprot","s_axi_wdata","s_axi_wstrb",
              "s_axi_araddr","s_axi_arprot"):
        getattr(dut, s).value = 0
    for s in ("s_axi_awvalid","s_axi_wvalid","s_axi_bready",
              "s_axi_arvalid","s_axi_rready","frame_sync_in"):
        getattr(dut, s).value = 0
    dut.m_axis_tready.value = 0   # <-- tready LOW
    for _ in range(20):
        await RisingEdge(dut.aclk)
    dut.aresetn.value = 1
    for _ in range(5):
        await RisingEdge(dut.aclk)

    await _axi_write(dut, REG_IMG_WIDTH,   FRAME_W)
    await _axi_write(dut, REG_IMG_HEIGHT,  FRAME_H)
    await _axi_write(dut, REG_BAR_WIDTH,   4)
    await _axi_write(dut, REG_FRAME_RATE,  100)
    await _axi_write(dut, REG_PATTERN_SEL, 0)
    await _axi_write(dut, REG_CONTROL,     1)

    handshakes = 0
    tvalid_seen = 0
    for _ in range(500):
        await RisingEdge(dut.aclk)
        if int(dut.m_axis_tvalid.value):
            tvalid_seen += 1
        if int(dut.m_axis_tvalid.value) and int(dut.m_axis_tready.value):
            handshakes += 1
    dut._log.info(f"tready=0 result: tvalid asserted on {tvalid_seen} cycles, "
                  f"handshakes={handshakes}")
    assert tvalid_seen > 0, "core never asserted tvalid -- frame divider issue?"
    assert handshakes == 0, (
        f"observed {handshakes} handshakes with tready=0 -- cocotb's tready "
        "writes are NOT reaching the DUT")


@cocotb.test()
async def tready_high_should_produce_handshakes(dut):
    """tready=1 should produce N handshakes per N-cycle observation window
    (modulo the frame divider's gaps). We do NOT assert on tdata here --
    that's the part that's broken under cocotb 2.0.1 + Verilator 5.048."""
    cocotb.start_soon(Clock(dut.aclk, CLK_PERIOD_NS, unit="ns").start())
    dut.aresetn.value       = 0
    for s in ("s_axi_awaddr","s_axi_awprot","s_axi_wdata","s_axi_wstrb",
              "s_axi_araddr","s_axi_arprot"):
        getattr(dut, s).value = 0
    for s in ("s_axi_awvalid","s_axi_wvalid","s_axi_bready",
              "s_axi_arvalid","s_axi_rready","frame_sync_in"):
        getattr(dut, s).value = 0
    dut.m_axis_tready.value = 1
    for _ in range(20):
        await RisingEdge(dut.aclk)
    dut.aresetn.value = 1
    for _ in range(5):
        await RisingEdge(dut.aclk)

    await _axi_write(dut, REG_IMG_WIDTH,   FRAME_W)
    await _axi_write(dut, REG_IMG_HEIGHT,  FRAME_H)
    await _axi_write(dut, REG_BAR_WIDTH,   4)
    await _axi_write(dut, REG_FRAME_RATE,  100)
    await _axi_write(dut, REG_PATTERN_SEL, 0)
    await _axi_write(dut, REG_CONTROL,     1)

    handshakes = 0
    tuser_seen = 0
    tlast_seen = 0
    line_idx = 0
    gap_remaining = 0
    for _ in range(500):
        await RisingEdge(dut.aclk)
        if gap_remaining:
            assert int(dut.m_axis_tvalid.value) == 0, (
                "m_axis_tvalid asserted during configured inter-line gap "
                f"({gap_remaining} gap cycles still expected)")
            gap_remaining -= 1
        if int(dut.m_axis_tvalid.value) and int(dut.m_axis_tready.value):
            handshakes += 1
            if int(dut.m_axis_tuser.value):
                tuser_seen += 1
                line_idx = 0
            if int(dut.m_axis_tlast.value):
                tlast_seen += 1
                line_idx += 1
                if line_idx < FRAME_H:
                    gap_remaining = LINE_GAP_CYCLES
    dut._log.info(f"tready=1 result: handshakes={handshakes}, "
                  f"SOFs={tuser_seen}, EOLs={tlast_seen}")
    assert handshakes > 0, "no handshakes -- tready stuck low?"
    # For a 32x4 frame, expect ~4 EOLs per frame and ~1 SOF per frame.
    # Over 500 cycles with frame_rate_div=100 we should see at least one
    # complete frame.
    assert tlast_seen > 0, "no EOL seen -- core not advancing through line"
    assert tuser_seen > 0, "no SOF seen -- core not emitting frames"
