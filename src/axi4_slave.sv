`include "axi4_if.svh"
`include "axi4_pkg.svh"
`include "addr_next_macro.svh"


`timescale 10ns/1ns
module axi4_slave
    import axi4_pkg::*;
#(
    parameter MEM_SIZE = 1024,
    parameter ADDR_WIDTH = 32,
    parameter DATA_WIDTH = 32,
    parameter ID_WIDTH   = 4
) (
    axi4_if.slave bus
);

    `ADDR_NEXT_FUNC(ADDR_WIDTH)

    localparam DATA_WIDTH_BYTES = DATA_WIDTH / 8;
    localparam OFFSET_BITS = $clog2(DATA_WIDTH_BYTES);

    logic [7:0] mem [0:MEM_SIZE-1];

    logic [ADDR_WIDTH-1:0] raddr;
    logic [7:0] rburst_size;
    logic [7:0] rburst_len;
    logic [7:0] rburst_cnt;
    logic [1:0] rburst_type;

    logic [ADDR_WIDTH-1:0] waddr;
    logic [7:0] wburst_size;
    logic [7:0] wburst_len;
    logic [1:0] wburst_type;

    logic [OFFSET_BITS-1:0] roffset, woffset;

    logic [ID_WIDTH-1:0] rid_reg;
    logic [ID_WIDTH-1:0] wid_reg;

    typedef enum logic {
        READ_IDLE,
        READ_DATA
    } srstate_t;

    typedef enum logic [1:0] {
        WRITE_IDLE,
        WRITE_REQ,
        WRITE_DATA,
        WRITE_RESP
    } swstate_t;

    srstate_t srstate, srstate_next;
    swstate_t swstate, swstate_next;

    always_comb begin
        case (srstate)
            READ_IDLE: srstate_next = (bus.ARVALID && bus.ARREADY) ? READ_DATA : READ_IDLE;
            READ_DATA: srstate_next = (bus.RVALID && bus.RREADY && bus.RLAST) ? READ_IDLE : READ_DATA;
            default:   srstate_next = READ_IDLE;
        endcase

        case (swstate)
            WRITE_IDLE: swstate_next = (bus.AWVALID && bus.AWREADY) ? WRITE_DATA : WRITE_IDLE;
            WRITE_DATA: swstate_next = (bus.WVALID && bus.WREADY && bus.WLAST) ? 
                                        WRITE_RESP : WRITE_DATA;
            WRITE_RESP: swstate_next = (bus.BVALID && bus.BREADY) ? WRITE_IDLE : WRITE_RESP;
            default:    swstate_next = WRITE_IDLE;
        endcase
    end

    assign roffset = raddr[OFFSET_BITS-1:0];
    assign woffset = waddr[OFFSET_BITS-1:0];
    assign bus.RLAST = (srstate == READ_DATA) && (rburst_cnt == rburst_len);


    assign bus.ARREADY = (srstate == READ_IDLE) || 
                         (srstate == READ_DATA && bus.RLAST && bus.RREADY);

    always_ff @(posedge bus.ACLK or negedge bus.ARESETn) begin
        if (!bus.ARESETn) begin
            srstate <= READ_IDLE;
            //bus.ARREADY <= 1'b1;
            bus.RVALID <= 1'b0;
            bus.RDATA <= '0;
            bus.RRESP <= OKAY;
            bus.RID <= '0;
            rid_reg <= '0;
            rburst_cnt <= '0;
            raddr <= '0;
        end else begin
            srstate <= srstate_next;

            bus.RVALID <= (srstate == READ_DATA);

            if (bus.ARVALID && bus.ARREADY) begin
                raddr <= bus.ARADDR;
                rburst_size <= 1 << bus.ARSIZE;
                rburst_len <= bus.ARLEN;
                rburst_type <= bus.ARBURST;
                rburst_cnt <= '0;
                rid_reg <= bus.ARID;
            end

            if (srstate == READ_DATA) begin
                //bus.RVALID <= 1'b1;
                bus.RDATA <= '0;
                if (bus.RREADY) begin
                    for (int i = 0; i < rburst_size; i++) begin
                        automatic int rline = int'(roffset) + i;
                        bus.RDATA[rline*8 +: 8] <= mem[(raddr + i) & (MEM_SIZE-1)];
                    end
                end
                bus.RRESP <= (rburst_size <= DATA_WIDTH_BYTES) ? OKAY : SLVERR;
                bus.RID <= rid_reg;

                if (bus.RVALID && bus.RREADY) begin
                    if (rburst_cnt != rburst_len) begin
                        rburst_cnt <= rburst_cnt + 1;
                        raddr <= addr_next(rburst_size, rburst_len, rburst_type, raddr);
                    end
                end
            end else begin
                //bus.RVALID <= 1'b0;
            end
        end
    end

    always_ff @(posedge bus.ACLK or negedge bus.ARESETn) begin
        if (!bus.ARESETn) begin
            swstate <= WRITE_IDLE;
            bus.AWREADY <= 1'b1;
            bus.WREADY  <= 1'b1;
            bus.BVALID  <= 1'b0;
            bus.BRESP       <= OKAY;
            bus.BID         <= '0;
            wid_reg <= '0;
            waddr <= '0;
        end else begin
            swstate <= swstate_next;

            bus.AWREADY <= (swstate == WRITE_IDLE) || 
                           (swstate == WRITE_RESP && bus.BVALID && bus.BREADY);
            bus.WREADY <= 1'b1;

            if (bus.AWVALID && bus.AWREADY) begin
                waddr <= bus.AWADDR;
                wburst_size <= 1 << bus.AWSIZE;
                wburst_len <= bus.AWLEN;
                wburst_type <= bus.AWBURST;
                wid_reg <= bus.AWID;
            end

            if (swstate == WRITE_DATA) begin
                if (bus.WVALID && bus.WREADY) begin
                    for (int i = 0; i < wburst_size; i++) begin
                        automatic int wline = int'(woffset) + i;
                        if (bus.WSTRB[wline])
                            mem[(waddr + i) & (MEM_SIZE-1)] <= bus.WDATA[wline*8 +: 8];
                    end
                    if (!bus.WLAST) begin
                        waddr <= addr_next(wburst_size, wburst_len, wburst_type, waddr);
                    end
                end
            end

            if (swstate == WRITE_RESP) begin
                bus.BVALID <= 1'b1;
                bus.BRESP <= (wburst_size <= DATA_WIDTH_BYTES) ? OKAY : SLVERR;
                bus.BID <= wid_reg;

                if (bus.BVALID && bus.BREADY) begin
                    bus.BVALID <= 1'b0;
                end
            end else begin
                bus.BVALID <= 1'b0;
            end
        end
    end

endmodule
