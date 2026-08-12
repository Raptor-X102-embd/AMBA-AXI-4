`ifndef ADDR_NEXT_MACRO
`define ADDR_NEXT_MACRO 

`define ADDR_NEXT_FUNC(WIDTH) \
function automatic logic [WIDTH-1:0] addr_next( \
    input logic [7:0]  burst_size, \
    input logic [7:0]  burst_len, \
    input logic [1:0]  burst_type, \
    input logic [WIDTH-1:0] addr \
); \
    logic [WIDTH-1:0] next_addr; \
    int num_beats = int'(burst_len) + 1; \
    int block_size = int'(burst_size) * num_beats; \
    case (burst_type) \
        FIXED: next_addr = addr; \
        INCR:  next_addr = addr + (WIDTH'(burst_size)); \
        WRAP: begin \
            logic [WIDTH-1:0] lower = addr & ~(block_size - 1); \
            logic [WIDTH-1:0] upper = lower + block_size; \
            next_addr = addr + (WIDTH'(burst_size)); \
            if (next_addr == upper) next_addr = lower; \
        end \
        default: next_addr = addr; \
    endcase \
    return next_addr; \
endfunction

`endif
