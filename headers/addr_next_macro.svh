`ifndef ADDR_NEXT_MACRO
`define ADDR_NEXT_MACRO 

`define ADDR_NEXT_FUNC(WIDTH) \
function automatic logic [WIDTH-1:0] addr_next( \
    input logic [7:0]  burst_size, \
    input logic [7:0]  burst_len, \
    input logic [1:0]  burst_type, \
    input logic [WIDTH-1:0] addr \
); \
    logic [WIDTH-1:0] addr_next; \
    int num_beats; \
    int block_size; \
    num_beats = int'(burst_len) + 1; \
    block_size = int'(burst_size) * num_beats; \
    case (burst_type) \
        FIXED: addr_next = addr; \
        INCR:  addr_next = addr + (WIDTH'(burst_size)); \
        WRAP: begin \
            logic [WIDTH-1:0] lower; \
            logic [WIDTH-1:0] upper; \
            lower = addr & ~(block_size - 1); \
            upper = lower + block_size; \
            addr_next = addr + (WIDTH'(burst_size)); \
            if (addr_next == upper) addr_next = lower; \
        end \
        default: addr_next = addr; \
    endcase \
endfunction

`endif
