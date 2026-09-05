`include "axi4_if.svh"
`include "axi4_pkg.svh"
`include "addr_next_macro.svh"

import axi4_pkg::*;

`timescale 10ns/1ns
module axi4_slave
#(
    parameter MEM_SIZE = 1024,
    parameter ADDR_WIDTH = 32,
    parameter DATA_WIDTH = 32,
    parameter ID_WIDTH   = 4,
    parameter MIN_ADDR   = 32'h00000000
) (
    axi4_if.slave bus
);

    `ADDR_NEXT_FUNC(ADDR_WIDTH)

    localparam DATA_WIDTH_BYTES = DATA_WIDTH / 8;
    localparam OFFSET_BITS = $clog2(DATA_WIDTH_BYTES);

    // Mem - array of words, not bytes
    // it is done to avoid multiple simultanious writes at different addresses
    localparam WORDS = MEM_SIZE / DATA_WIDTH_BYTES;
    (* ram_style = "block" *) logic [DATA_WIDTH-1:0] mem [MIN_ADDR:MIN_ADDR+WORDS-1];

    logic [ADDR_WIDTH-1:0] raddr;
    logic [7:0] rburst_size;
    logic [7:0] rburst_len;
    logic [7:0] rburst_cnt;
    logic [1:0] rburst_type;
    logic [DATA_WIDTH-1:0] rdata_reg;

    logic [ADDR_WIDTH-1:0] waddr;
    logic [7:0] wburst_size;
    logic [7:0] wburst_len;
    logic [1:0] wburst_type;

    logic [OFFSET_BITS-1:0] roffset, woffset;

    logic [ID_WIDTH-1:0] rid_reg;
    logic [ID_WIDTH-1:0] wid_reg;

    typedef enum logic [1:0] {
        READ_IDLE,
        READ_DATA,
        READ_SEND_RDATA
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
            READ_IDLE:       srstate_next = (bus.ARVALID && bus.ARREADY) ? READ_DATA : READ_IDLE;
            READ_DATA:       srstate_next = READ_SEND_RDATA; // shift 1 cycle to get rdata from mem
            READ_SEND_RDATA: srstate_next = (bus.RREADY && (rburst_cnt == rburst_len)) ?
                                            READ_IDLE : READ_SEND_RDATA;
            default:         srstate_next = READ_IDLE;
        endcase

        case (swstate)
            WRITE_IDLE: swstate_next = (bus.AWVALID && bus.AWREADY) ? WRITE_DATA : WRITE_IDLE;
            WRITE_DATA: swstate_next = (bus.WVALID && bus.WREADY && bus.WLAST) ?
                                        WRITE_RESP : WRITE_DATA;
            WRITE_RESP: swstate_next = (bus.BVALID && bus.BREADY) ? WRITE_IDLE : WRITE_RESP;
            default:    swstate_next = WRITE_IDLE;
        endcase
    end

    //assign roffset = raddr[OFFSET_BITS-1:0];
    assign woffset = waddr[OFFSET_BITS-1:0];
    //assign bus.RLAST = (srstate == READ_SEND_RDATA) && (rburst_cnt == rburst_len);
    assign bus.ARREADY = (srstate == READ_IDLE) ||
                         (srstate == READ_SEND_RDATA && bus.RLAST && bus.RREADY);

    always_ff @(posedge bus.ACLK or negedge bus.ARESETn) begin
        if (!bus.ARESETn) begin
            srstate <= READ_IDLE;
            bus.RVALID <= 1'b0;
            bus.RDATA <= '0;
            bus.RRESP <= OKAY;
            bus.RID <= '0;
            rid_reg <= '0;
            rburst_cnt <= '0;
            raddr <= '0;
            rdata_reg <= '0;
        end else begin
            srstate <= srstate_next;
            bus.RVALID <= (srstate == READ_SEND_RDATA);
            bus.RLAST  <= (srstate == READ_SEND_RDATA) && (rburst_cnt == rburst_len);

            if (bus.ARVALID && bus.ARREADY) begin
                raddr        <= bus.ARADDR;
                rburst_size  <= 1 << bus.ARSIZE;
                rburst_len   <= bus.ARLEN;
                rburst_type  <= bus.ARBURST;
                rburst_cnt   <= '0;
                rid_reg      <= bus.ARID;
            end

            if (srstate == READ_DATA || srstate == READ_SEND_RDATA) begin
                rdata_reg <= mem[raddr >> OFFSET_BITS];
                roffset <= raddr[OFFSET_BITS-1:0] * 8;

                bus.RDATA <= rdata_reg >> roffset;
                // TODO: RVALID check RRESP
                bus.RRESP <= (rburst_size <= DATA_WIDTH_BYTES) ? OKAY : SLVERR;
                bus.RID   <= rid_reg;

                if (bus.RREADY && (srstate == READ_SEND_RDATA)) begin
                    if (rburst_cnt != rburst_len) begin
                        rburst_cnt <= rburst_cnt + 1;
                        raddr <= addr_next(rburst_size, rburst_len, rburst_type, raddr);
                    end
                end
            end
        end
    end

    always_ff @(posedge bus.ACLK or negedge bus.ARESETn) begin
        if (!bus.ARESETn) begin
            swstate <= WRITE_IDLE;
            bus.AWREADY <= 1'b1;
            bus.WREADY  <= 1'b1;
            bus.BVALID  <= 1'b0;
            bus.BRESP   <= OKAY;
            bus.BID     <= '0;
            wid_reg <= '0;
            waddr <= '0;
        end else begin
            swstate <= swstate_next;

            bus.AWREADY <= (swstate == WRITE_IDLE) ||
                           (swstate == WRITE_RESP && bus.BVALID && bus.BREADY);
            bus.WREADY <= 1'b1;

            if (bus.AWVALID && bus.AWREADY) begin
                waddr        <= bus.AWADDR;
                wburst_size  <= 1 << bus.AWSIZE;
                wburst_len   <= bus.AWLEN;
                wburst_type  <= bus.AWBURST;
                wid_reg      <= bus.AWID;
            end

            if (swstate == WRITE_DATA && bus.WVALID && bus.WREADY) begin
                automatic logic [ADDR_WIDTH-1:0] word_addr;
                automatic logic [DATA_WIDTH_BYTES-1:0] wstrb;
                automatic logic [DATA_WIDTH-1:0] wdata;
                word_addr = waddr >> OFFSET_BITS;
                wstrb = bus.WSTRB;
                wdata = bus.WDATA;

                // Check only those bits that are set taking into account woffset.
                if (wstrb[woffset])   mem[word_addr][7:0] <= wdata[7:0];
                if (woffset+1 < DATA_WIDTH_BYTES && wstrb[woffset+1])
                    mem[word_addr][15:8] <= wdata[15:8];
                if (woffset+2 < DATA_WIDTH_BYTES && wstrb[woffset+2])
                    mem[word_addr][23:16] <= wdata[23:16];
                if (woffset+3 < DATA_WIDTH_BYTES && wstrb[woffset+3])
                    mem[word_addr][31:24] <= wdata[31:24];
                // For DATA_WIDTH_BYTES > 4 it is needed to add same for 5..

                if (!bus.WLAST) begin
                    waddr <= addr_next(wburst_size, wburst_len, wburst_type, waddr);
                end
            end

            if (swstate == WRITE_RESP) begin
                bus.BVALID <= 1'b1;
                bus.BRESP  <= (wburst_size <= DATA_WIDTH_BYTES) ? OKAY : SLVERR;
                bus.BID    <= wid_reg;

                if (bus.BVALID && bus.BREADY) begin
                    bus.BVALID <= 1'b0;
                end
            end else begin
                bus.BVALID <= 1'b0;
            end
        end
    end

endmodule
