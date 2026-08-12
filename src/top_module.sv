`include "axi4_if.svh"

module top_module #(
    parameter MEM_SIZE = 1024,
    parameter ADDR_WIDTH = 32,
    parameter DATA_WIDTH = 32,
    parameter ID_WIDTH   = 4,
    parameter USER_WIDTH = 0
)(
    input  logic                  ACLK,
    input  logic                  ARESETn,
    input  logic                  start_read,   // pulse to initiate a read transaction
    input  logic                  start_write,  // pulse to initiate a write transaction
    input  logic [ADDR_WIDTH-1:0] read_addr,
    input  logic [ADDR_WIDTH-1:0] write_addr,
    input  logic [DATA_WIDTH-1:0] write_data,
    output logic [DATA_WIDTH-1:0] read_data,
    output logic                  read_done,
    output logic                  write_done
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
        .ID_WIDTH(ID_WIDTH)
    ) u_master (
        .bus(bus),
        .start_read(start_read),
        .start_write(start_write),
        .read_addr(read_addr),
        .write_addr(write_addr),
        .write_data(write_data),
        .read_data(read_data),
        .read_done(read_done),
        .write_done(write_done) 
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
