`include "axi4_if.svh"
`include "axi4_pkg.svh"
`include "addr_next_macro.svh"

module axi4_master
    import axi4_pkg::*;
#(
    parameter ADDR_WIDTH = 32,
    parameter DATA_WIDTH = 32,
    /* verilator lint_off UNUSEDPARAM */
    parameter ID_WIDTH   = 4
    /* verilator lint_off UNUSEDPARAM */
) (
    axi4_if.master                bus,
    input  logic                  start_read,   // pulse to initiate a read transaction
    input  logic                  start_write,  // pulse to initiate a write transaction
    input  logic [ADDR_WIDTH-1:0] read_addr,
    input  logic [ADDR_WIDTH-1:0] write_addr,
    input  logic [DATA_WIDTH-1:0] write_data,
    output logic [DATA_WIDTH-1:0] read_data,
    output logic                  read_done,
    output logic                  write_done
);

    `ADDR_NEXT_FUNC(ADDR_WIDTH)

    localparam DATA_WIDTH_BYTES = DATA_WIDTH / 8;
    localparam OFFSET_BITS = $clog2(DATA_WIDTH_BYTES);

    typedef enum logic [1:0] { 
        READ_IDLE,
        READ_REQ, 
        READ_DATA
    } rstate_t;

    rstate_t rstate, rstate_next;

    logic [ADDR_WIDTH-1:0] raddr;
    logic [7:0] rburst_size;       // in bytes
    logic [7:0] rburst_len;
    logic [7:0] rburst_cnt;
    logic [1:0] rburst_type;

    typedef enum logic [1:0] {
        WRITE_IDLE, 
        WRITE_ADDR, 
        WRITE_DATA, 
        WRITE_RESP
    } wstate_t;

    wstate_t wstate, wstate_next;

    logic [ADDR_WIDTH-1:0] waddr;
    logic [7:0] wburst_size;
    logic [7:0] wburst_len;
    logic [7:0] wburst_cnt;
    logic [1:0] wburst_type;

    always_comb begin
        case (rstate)
            READ_IDLE: rstate_next = start_read ? READ_REQ : READ_IDLE;
            READ_REQ:  rstate_next = (bus.ARVALID && bus.ARREADY) ? READ_DATA : READ_REQ;
            READ_DATA: begin
                if (bus.RVALID && bus.RREADY && bus.RLAST)
                    rstate_next = READ_IDLE;
                else
                    rstate_next = READ_DATA;
            end
            default: rstate_next = READ_IDLE;
        endcase

        case (wstate)
            WRITE_IDLE: wstate_next = start_write ? WRITE_ADDR : WRITE_IDLE;
            WRITE_ADDR: wstate_next = (bus.AWVALID && bus.AWREADY) ? WRITE_DATA : WRITE_ADDR;
            WRITE_DATA: begin
                if (bus.WVALID && bus.WREADY && bus.WLAST)
                    wstate_next = WRITE_RESP;
                else
                    wstate_next = WRITE_DATA;
            end
            WRITE_RESP: wstate_next = (bus.BVALID && bus.BREADY) ? WRITE_IDLE : WRITE_RESP;
            default: wstate_next = WRITE_IDLE;
        endcase
    end

    /* verilator lint_off WIDTHEXPAND */
    /* verilator lint_off UNUSEDSIGNAL */
    function automatic logic [DATA_WIDTH_BYTES-1:0] gen_wstrb(
        input [ADDR_WIDTH-1:0] addr,
        input logic [7:0] size_bytes
    );
        logic [DATA_WIDTH_BYTES-1:0] strb;
        int offset = addr[OFFSET_BITS-1:0];
        strb = '0;
        for (int i = 0; i < size_bytes; i++) begin
            strb[offset + i] = 1'b1;
        end
        return strb;
    endfunction
    /* verilator lint_off UNUSEDSIGNAL */
    /* verilator lint_off WIDTHEXPAND */

    always_ff @(posedge bus.ACLK or negedge bus.ARESETn) begin
        if (!bus.ARESETn) begin
            rstate <= READ_IDLE;
            bus.ARVALID <= 1'b0;
            bus.ARADDR <= '0;
            bus.ARLEN <= '0;
            bus.ARSIZE <= '0;
            bus.ARBURST <= INCR;
            bus.ARID <= '0;
            bus.ARLOCK <= 1'b0;
            bus.ARCACHE <= 4'b0000;
            bus.ARPROT <= 3'b000;
            bus.RREADY <= 1'b0;
            rburst_cnt <= '0;
            raddr <= '0;
            read_data <= '0;
            read_done <= 1'b0;
        end else begin
            rstate <= rstate_next;
            read_done <= 1'b0; // pulse

            bus.ARVALID <= (rstate == READ_REQ);

            if (rstate == READ_REQ) begin
                bus.ARADDR  <= read_addr;
                bus.ARLEN   <= 8'd0;
                bus.ARSIZE  <= 3'b010;
                bus.ARBURST <= INCR;
                bus.ARID    <= '0;
                bus.ARLOCK  <= 1'b0;
                bus.ARCACHE <= 4'b0000;
                bus.ARPROT  <= 3'b000;
            end

            if (bus.ARVALID && bus.ARREADY) begin
                raddr <= bus.ARADDR;
                rburst_size <= 1 << bus.ARSIZE;
                rburst_len <= bus.ARLEN;
                rburst_type <= bus.ARBURST;
                rburst_cnt <= '0;
            end

            bus.RREADY <= (rstate == READ_DATA);

            if (rstate == READ_DATA) begin
                if (bus.RVALID && bus.RREADY) begin
                    read_data <= bus.RDATA;
                    if (!bus.RLAST) begin
                        rburst_cnt <= rburst_cnt + 1;
                        raddr <= addr_next(rburst_size, rburst_len, rburst_type, raddr);
                    end else begin
                        read_done <= 1'b1;
                    end
                end
            end
        end
    end

    assign bus.WLAST = (wburst_cnt == wburst_len);

    always_ff @(posedge bus.ACLK or negedge bus.ARESETn) begin
        if (!bus.ARESETn) begin
            wstate <= WRITE_IDLE;
            bus.AWVALID <= 1'b0;
            bus.AWADDR <= '0;
            bus.AWLEN <= '0;
            bus.AWSIZE <= '0;
            bus.AWBURST <= INCR;
            bus.AWID <= '0;
            bus.AWLOCK <= 1'b0;
            bus.AWCACHE <= 4'b0000;
            bus.AWPROT <= 3'b000;
            bus.WVALID <= 1'b0;
            bus.WDATA <= '0;
            bus.WSTRB <= '0;
            //bus.WLAST <= 1'b0;
            bus.BREADY <= 1'b0;
            wburst_cnt <= '0;
            waddr <= '0;
            write_done <= 1'b0;
        end else begin
            wstate <= wstate_next;
            write_done <= 1'b0; // pulse

            bus.AWVALID <= (wstate == WRITE_ADDR);

            if (wstate == WRITE_ADDR) begin
                bus.AWADDR  <= write_addr;
                bus.AWLEN   <= 8'd0;
                bus.AWSIZE  <= 3'b010;
                bus.AWBURST <= INCR;
                bus.AWID    <= '0;
                bus.AWLOCK  <= 1'b0;
                bus.AWCACHE <= 4'b0000;
                bus.AWPROT  <= 3'b000;
            end

            if (bus.AWVALID && bus.AWREADY) begin
                waddr <= bus.AWADDR;
                wburst_size <= 1 << bus.AWSIZE;
                wburst_len <= bus.AWLEN;
                wburst_type <= bus.AWBURST;
                wburst_cnt <= '0;
            end

            bus.WVALID <= (wstate == WRITE_DATA);

            if (wstate == WRITE_DATA) begin
                bus.WDATA <= write_data;
                bus.WSTRB <= gen_wstrb(waddr, wburst_size);
            end

            if (wstate == WRITE_DATA) begin
                if (bus.WVALID && bus.WREADY) begin
                    if (!bus.WLAST) begin
                        wburst_cnt <= wburst_cnt + 1;
                        waddr <= addr_next(wburst_size, wburst_len, wburst_type, waddr);
                    end
                end
            end

            bus.BREADY <= (wstate == WRITE_RESP);

            if (wstate == WRITE_RESP) begin
                if (bus.BVALID && bus.BREADY) begin
                    write_done <= 1'b1;
                end
            end
        end
    end

endmodule
