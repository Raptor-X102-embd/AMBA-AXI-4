`include "axi4_if.svh"
`include "axi4_pkg.svh"
`include "addr_next_macro.svh"

module axi4_slave 
    import axi4_pkg::*;
#(
    parameter MEM_SIZE = 1024,
    parameter ADDR_WIDTH = 32,
    parameter DATA_WIDTH = 32,
    /* verilator lint_off UNUSEDPARAM */
    parameter ID_WIDTH   = 4
    /* verilator lint_off UNUSEDPARAM */
) (
    axi4_if.slave bus
);

    `ADDR_NEXT_FUNC(ADDR_WIDTH)
    localparam DATA_WIDTH_BYTES = DATA_WIDTH / 8;
    localparam OFFSET_BITS = $clog2(DATA_WIDTH_BYTES);
    logic [7:0] mem [0:MEM_SIZE-1];

    logic [ADDR_WIDTH-1:0] raddr;
    logic [7:0] rburst_size;       // in bytes
    logic [7:0] rburst_len;
    logic [7:0] rburst_cnt;
    logic [1:0] rburst_type;

    logic [ADDR_WIDTH-1:0] waddr;
    logic [7:0] wburst_size;
    logic [7:0] wburst_len;
    //logic [7:0] wburst_cnt;
    logic [1:0] wburst_type;

    logic [OFFSET_BITS-1:0] roffset, woffset;
    //logic [OFFSET_BITS-1:0] rline, wline;

    typedef enum logic [1:0] { 
        READ_IDLE, 
        READ_REQ, 
        READ_DATA 
    } rstate_t;
    
    typedef enum logic [1:0] { 
        WRITE_IDLE, 
        WRITE_REQ, 
        WRITE_DATA, 
        WRITE_RESP 
    } wstate_t;

    rstate_t rstate, rstate_next;
    wstate_t wstate, wstate_next;

    always_comb begin
        case (rstate)
            READ_IDLE:     rstate_next = (bus.ARVALID && bus.ARREADY) ? READ_DATA : READ_IDLE;
            READ_DATA: begin
                if (bus.RVALID && bus.RREADY && bus.RLAST)
                    rstate_next = READ_IDLE;
                else
                    rstate_next = READ_DATA;
            end
            default: rstate_next = READ_IDLE;
        endcase

        case (wstate)
            WRITE_IDLE:        wstate_next = (bus.AWVALID && bus.AWREADY) ? WRITE_DATA : WRITE_IDLE;
            WRITE_DATA:  wstate_next = (bus.WVALID && bus.WREADY && bus.WLAST) ? WRITE_RESP : WRITE_DATA;
            WRITE_RESP:  wstate_next = (bus.BVALID && bus.BREADY) ? WRITE_IDLE : WRITE_RESP;
            default: wstate_next = WRITE_IDLE;
        endcase
    end

    assign roffset = raddr[OFFSET_BITS-1:0];
    assign woffset = waddr[OFFSET_BITS-1:0];

    assign bus.RLAST = (rstate == READ_DATA) && (rburst_cnt == rburst_len);

    always_ff @(posedge bus.ACLK or negedge bus.ARESETn) begin
        if (!bus.ARESETn) begin
            rstate <= READ_IDLE;
            bus.ARREADY <= 1'b1;
            bus.RVALID <= 1'b0;
            bus.RDATA <= '0;
            bus.RRESP <= OKAY;
            bus.RID <= '0;
            rburst_cnt <= '0;
            raddr <= '0;
        end else begin
            rstate <= rstate_next;

            bus.ARREADY <= (rstate == READ_IDLE) || (rstate == READ_DATA && bus.RLAST && bus.RREADY);

            if (bus.ARVALID && bus.ARREADY) begin
                raddr <= bus.ARADDR;
                rburst_size <= 1 << bus.ARSIZE;
                rburst_len <= bus.ARLEN;
                rburst_type <= bus.ARBURST;
                rburst_cnt <= '0;
            end

            if (rstate == READ_DATA) begin
                bus.RVALID <= 1'b1;
                bus.RDATA <= '0;
                for (int i = 0; i < rburst_size; i++) begin
                    automatic int rline = int'(roffset) + i;
                    bus.RDATA[rline*8 +: 8] <= mem[(raddr + i) & (MEM_SIZE-1)];
                end
                bus.RRESP <= (rburst_size <= DATA_WIDTH_BYTES) ? OKAY : SLVERR;
                bus.RID <= '0;

                if (bus.RVALID && bus.RREADY) begin
                    if (rburst_cnt != rburst_len) begin
                        rburst_cnt <= rburst_cnt + 1;
                        raddr <= addr_next(rburst_size, rburst_len, rburst_type, raddr);
                    end
                end
            end else begin
                bus.RVALID <= 1'b0;
            end
        end
    end

    always_ff @(posedge bus.ACLK or negedge bus.ARESETn) begin
        if (!bus.ARESETn) begin
            wstate <= WRITE_IDLE;
            bus.AWREADY <= 1'b1;
            bus.WREADY  <= 1'b1;
            bus.BVALID  <= 1'b0;
            bus.BRESP   <= OKAY;
            bus.BID     <= '0;
            //wburst_cnt <= '0;
            waddr <= '0;
        end else begin
            wstate <= wstate_next;

            bus.AWREADY <= (wstate == WRITE_IDLE) || (wstate == WRITE_RESP && bus.BVALID && bus.BREADY);
            bus.WREADY <= 1'b1;

            if (bus.AWVALID && bus.AWREADY) begin
                waddr <= bus.AWADDR;
                wburst_size <= 1 << bus.AWSIZE;
                wburst_len <= bus.AWLEN;
                wburst_type <= bus.AWBURST;
                //wburst_cnt <= '0;
            end

            if (wstate == WRITE_DATA) begin
                if (bus.WVALID && bus.WREADY) begin
                    for (int i = 0; i < wburst_size; i++) begin
                        automatic int wline = int'(woffset) + i;
                        if (bus.WSTRB[wline])
                            mem[(waddr + i) & (MEM_SIZE-1)] <= bus.WDATA[wline*8 +: 8];
                    end
                    if (bus.WLAST) begin
                    end else begin
                        //wburst_cnt <= wburst_cnt + 1;
                        waddr <= addr_next(wburst_size, wburst_len, wburst_type, waddr);
                    end
                end
            end

            if (wstate == WRITE_RESP) begin
                bus.BVALID <= 1'b1;
                bus.BRESP <= (wburst_size <= DATA_WIDTH_BYTES) ? OKAY : SLVERR;
                //bus.BID <= '0;

                if (bus.BVALID && bus.BREADY) begin
                    bus.BVALID <= 1'b0;
                end
            end else begin
                bus.BVALID <= 1'b0;
            end
        end
    end

endmodule
