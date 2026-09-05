`include "axi4_if.svh"

`timescale 10ns/1ns
module top_module #(
    parameter MEM_SIZE = 1024,
    parameter ADDR_WIDTH = 32,
    parameter DATA_WIDTH = 32,
    parameter ID_WIDTH   = 4,
    parameter USER_WIDTH = 0,
    parameter MAX_OUTSTANDING = 16
)(
    input  logic ACLK,
    input  logic ARESETn,
    input  logic                  start_read,
    input  logic [ID_WIDTH-1:0]   read_id,
    input  logic [ADDR_WIDTH-1:0] read_addr,
    input  logic [7:0]            read_len,
    input  logic [2:0]            read_size,
    input  logic [1:0]            read_burst,
    input  logic                  start_write,
    input  logic [ID_WIDTH-1:0]   write_id,
    input  logic [ADDR_WIDTH-1:0] write_addr,
    input  logic [7:0]            write_len,
    input  logic [2:0]            write_size,
    input  logic [1:0]            write_burst,
    input  logic [DATA_WIDTH-1:0] write_data,
    output logic [ID_WIDTH-1:0]   read_rid_out,
    output logic [1:0]            read_resp_out,
    output logic [DATA_WIDTH-1:0] read_data_out,
    output logic                  read_done,
    output logic                  read_ready,
    output logic [ID_WIDTH-1:0]   write_id_out,
    output logic [1:0]            write_resp_out,
    output logic                  write_done,
    output logic                  write_ready
);

  axi4_if #(
    .ADDR_WIDTH(ADDR_WIDTH),
    .DATA_WIDTH(DATA_WIDTH),
    .ID_WIDTH(ID_WIDTH),
    .USER_WIDTH(USER_WIDTH)
  ) bus (
    .ACLK(ACLK),
    .ARESETn(ARESETn)
  );

  axi4_master #(
    .ADDR_WIDTH(ADDR_WIDTH),
    .DATA_WIDTH(DATA_WIDTH),
    .ID_WIDTH(ID_WIDTH),
    .MAX_OUTSTANDING(MAX_OUTSTANDING)
  ) u_master (
    .bus(bus),
    .start_read(start_read),
    .read_id(read_id),
    .read_addr(read_addr),
    .read_len(read_len),
    .read_size(read_size),
    .read_burst(read_burst),
    .start_write(start_write),
    .write_id(write_id),
    .write_addr(write_addr),
    .write_len(write_len),
    .write_size(write_size),
    .write_burst(write_burst),
    .write_data(write_data),
    .read_rid_out(read_rid_out),
    .read_resp_out(read_resp_out),
    .read_data_out(read_data_out),
    .read_done(read_done),
    .read_ready(read_ready),
    .write_id_out(write_id_out),
    .write_resp_out(write_resp_out),
    .write_done(write_done),
    .write_ready(write_ready)
  );

  axi4_slave #(
    .MEM_SIZE(MEM_SIZE),
    .ADDR_WIDTH(ADDR_WIDTH),
    .DATA_WIDTH(DATA_WIDTH),
    .ID_WIDTH(ID_WIDTH)
  ) u_slave (
    .bus(bus)
  );

endmodule
