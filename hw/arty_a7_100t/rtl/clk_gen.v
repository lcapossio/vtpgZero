// SPDX-FileCopyrightText: 2026 Leonardo Capossio - bard0 design - hello@bard0.com
// SPDX-License-Identifier: Apache-2.0
//
// clk_gen.v - 100 MHz -> 130 MHz MMCM + reset synchronizer
// for the vtpgZero Arty A7-100T demo.
//
// Uses MMCME2_BASE: VCO = 100 * 13 / 2 = 650 MHz (within 600-1200 MHz
// range for Artix-7 -1 speed grade), CLKOUT0 = 650 / 5 = 130 MHz.
//
// rst_n is asserted low until MMCM is locked AND a 4-stage shift
// register has propagated through. Released synchronously to clk_out.

`timescale 1ns/1ps

module clk_gen (
    input  wire clk_in,         // 100 MHz oscillator
    input  wire reset_btn,      // active-high external reset (BTN0)
    output wire clk_out,        // 130 MHz
    output wire rst_n           // active low, sync to clk_out
);

    wire clk_fb_unbuf, clk_fb;
    wire clk_out_unbuf;
    wire mmcm_locked;

    MMCME2_BASE #(
        .BANDWIDTH         ("OPTIMIZED"),
        .CLKFBOUT_MULT_F   (13.000),   // VCO = 100 * 13 / 2 = 650 MHz
        .CLKFBOUT_PHASE    (0.000),
        .CLKIN1_PERIOD     (10.000),   // 100 MHz
        .CLKOUT0_DIVIDE_F  (5.000),    // 650 / 5 = 130 MHz
        .CLKOUT0_DUTY_CYCLE(0.500),
        .CLKOUT0_PHASE     (0.000),
        .DIVCLK_DIVIDE     (2),
        .REF_JITTER1       (0.010),
        .STARTUP_WAIT      ("FALSE")
    ) u_mmcm (
        .CLKOUT0    (clk_out_unbuf),
        .CLKOUT0B   (),
        .CLKOUT1    (), .CLKOUT1B (),
        .CLKOUT2    (), .CLKOUT2B (),
        .CLKOUT3    (), .CLKOUT3B (),
        .CLKOUT4    (),
        .CLKOUT5    (),
        .CLKOUT6    (),
        .CLKFBOUT   (clk_fb_unbuf),
        .CLKFBOUTB  (),
        .LOCKED     (mmcm_locked),
        .CLKIN1     (clk_in),
        .PWRDWN     (1'b0),
        .RST        (reset_btn),
        .CLKFBIN    (clk_fb)
    );

    BUFG u_bufg_fb  (.I(clk_fb_unbuf),  .O(clk_fb));
    BUFG u_bufg_out (.I(clk_out_unbuf), .O(clk_out));

    // Reset sync (active-low) - released some cycles after MMCM locks
    reg [3:0] rst_sr;
    always @(posedge clk_out or posedge reset_btn) begin
        if (reset_btn || !mmcm_locked) rst_sr <= 4'b0000;
        else                            rst_sr <= {rst_sr[2:0], 1'b1};
    end
    assign rst_n = rst_sr[3];

endmodule
