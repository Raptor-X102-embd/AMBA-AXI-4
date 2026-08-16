`ifndef AXI4_PKG
`define AXI4_PKG

`timescale 10ns/1ns

package axi4_pkg;
    typedef enum logic [1:0] { OKAY, EXOKAY, SLVERR, DECERR } resp_t;
    typedef enum logic [1:0] { FIXED, INCR, WRAP } burst_t;
endpackage

`endif
