// SPDX-FileCopyrightText: 2026 Leonardo Capossio - bard0 design - hello@bard0.com
// SPDX-License-Identifier: Apache-2.0
//
// bram_sdp.v - Simple dual-port block RAM (canonical Xilinx inference form).
//
// Single always block with write port + read port. Vivado infers RAMB36SDP
// with the global BRAM enable always asserted, so the very first write
// after a long idle isn't dropped (which we observed with the dpram wrapper
// that left dout_a unconnected).

`timescale 1ns/1ps

module bram_sdp #(
    parameter WIDTH = 32,
    parameter DEPTH = 8192
)(
    input  wire                          clk,
    // Write port
    input  wire                          we,
    input  wire [$clog2(DEPTH)-1:0]      wr_addr,
    input  wire [WIDTH-1:0]              wr_data,
    // Read port (1-cycle synchronous)
    input  wire [$clog2(DEPTH)-1:0]      rd_addr,
    output reg  [WIDTH-1:0]              rd_data
);

    (* ram_style = "block" *)
    reg [WIDTH-1:0] mem [0:DEPTH-1];

    always @(posedge clk) begin
        if (we) mem[wr_addr] <= wr_data;
        rd_data <= mem[rd_addr];
    end

endmodule
