`include "axi4_if.svh"
`include "axi4_pkg.svh"
`include "addr_next_macro.svh"

`timescale 10ns/1ns
module axi4_master
    import axi4_pkg::*;
#(
    parameter ADDR_WIDTH      = 32,
    parameter DATA_WIDTH      = 32,
    parameter ID_WIDTH        = 4,
    parameter MAX_OUTSTANDING = 16 // must be power of 2 for correct % operation 
)(
    axi4_if.master                bus,
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
    output logic [ID_WIDTH-1:0]   write_id_out,
    output logic [1:0]            write_resp_out,
    output logic                  write_done
);

    `ADDR_NEXT_FUNC(ADDR_WIDTH)

    localparam DATA_WIDTH_BYTES = DATA_WIDTH / 8;
    localparam OFFSET_BITS = $clog2(DATA_WIDTH_BYTES);
    localparam QIDX_BITS = $clog2(MAX_OUTSTANDING);

    typedef struct packed {
        logic [ID_WIDTH-1:0]   id;
        logic [ADDR_WIDTH-1:0] addr;
        logic [7:0]            len;
        logic [7:0]            size_bytes;
        logic [1:0]            burst;
        logic [7:0]            cnt;
        logic                  active;
    } pending_t;

    pending_t read_req_q [0:MAX_OUTSTANDING-1];
    pending_t read_pending [0:MAX_OUTSTANDING-1];
    logic [QIDX_BITS-1:0] read_q_head, read_q_tail;
    logic [QIDX_BITS:0]   read_q_count;
    logic push_read, pop_read;

    pending_t write_req_q [0:MAX_OUTSTANDING-1];
    pending_t write_pending [0:MAX_OUTSTANDING-1];
    logic [QIDX_BITS-1:0] write_q_head, write_q_tail;
    logic [QIDX_BITS:0]   write_q_count;
    logic push_write, pop_write, pop_wdata;

    logic [DATA_WIDTH-1:0] wdata_fifo [0:MAX_OUTSTANDING-1];
    logic [QIDX_BITS-1:0]  wdata_head, wdata_tail;
    logic [QIDX_BITS:0]    wdata_count;

    logic has_active_reads;
    //logic has_active_writes;
    int active_idx;

    logic can_issue_read;
    //logic can_issue_write;

    function automatic int find_free_slot(ref pending_t arr[0:MAX_OUTSTANDING-1]);
        for (int i = 0; i < MAX_OUTSTANDING; i++)
            if (!arr[i].active) return i;
        return -1;
    endfunction

    function automatic int find_read_by_id(input [ID_WIDTH-1:0] id);
        for (int i = 0; i < MAX_OUTSTANDING; i++)
            if (read_pending[i].active && read_pending[i].id == id)
                return i;
        return -1;
    endfunction

    function automatic int find_write_by_id(input [ID_WIDTH-1:0] id);
        for (int i = 0; i < MAX_OUTSTANDING; i++)
            if (write_pending[i].active && write_pending[i].id == id)
                return i;
        return -1;
    endfunction

    function automatic logic [DATA_WIDTH_BYTES-1:0] gen_wstrb(
        input [OFFSET_BITS-1:0] offset,
        input logic [7:0] size_bytes
    );
        logic [DATA_WIDTH_BYTES-1:0] strb;
        strb = '0;
        for (int i = 0; i < size_bytes; i++)
            if (int'(offset) + i < DATA_WIDTH_BYTES)
                strb[int'(offset) + i] = 1'b1;
        return strb;
    endfunction

    typedef enum logic { R_IDLE, R_DATA } mrstate_t;
    mrstate_t mrstate, mrstate_next;

    always_comb begin
        case (mrstate)
            R_IDLE:  mrstate_next = (read_q_count > 0 || has_active_reads) ? R_DATA : R_IDLE;
            R_DATA:  mrstate_next = (read_q_count == 0 && !has_active_reads) ? R_IDLE : R_DATA;
            default: mrstate_next = R_IDLE;
        endcase
    end

    typedef enum logic [1:0] { W_IDLE, W_ADDR, W_DATA, W_RESP } mwstate_t;
    mwstate_t mwstate, mwstate_next;

    always_comb begin
        case (mwstate)
            W_IDLE:  mwstate_next = (write_q_count > 0) ? W_ADDR : W_IDLE;
            W_ADDR:  mwstate_next = (bus.AWVALID && bus.AWREADY) ? W_DATA : W_ADDR;
            W_DATA:  mwstate_next = (bus.WVALID && bus.WREADY && bus.WLAST) ? W_RESP : W_DATA;
            W_RESP:  mwstate_next = (bus.BVALID && bus.BREADY) ? W_IDLE : W_RESP;
            default: mwstate_next = W_IDLE;
        endcase
    end

    always_comb begin
        has_active_reads = 1'b0;
        for (int i = 0; i < MAX_OUTSTANDING; i++) begin
            if (read_pending[i].active) begin
                has_active_reads = 1'b1;
                break;
            end
        end
    end

    assign can_issue_read = (read_q_count > 0) && (find_free_slot(read_pending) >= 0);
    assign push_read = start_read && (read_q_count < MAX_OUTSTANDING);
    assign pop_read  = bus.ARREADY && can_issue_read;

    always_ff @(posedge bus.ACLK or negedge bus.ARESETn) begin
        if (!bus.ARESETn) begin
            mrstate <= R_IDLE;
            read_q_head <= 0;
            read_q_tail <= 0;
            read_q_count <= 0;
            for (int i = 0; i < MAX_OUTSTANDING; i++) begin
                read_req_q[i] <= '0;
                read_pending[i].active <= 1'b0;
            end
            read_done <= 1'b0;
            read_data_out <= '0;
            read_resp_out <= OKAY;
            read_rid_out <= '0;
            bus.ARVALID <= 1'b0;
            bus.ARADDR  <= '0;
            bus.ARLEN       <= '0;
            bus.ARSIZE  <= '0;
            bus.ARBURST <= INCR;
            bus.ARID        <= '0;
            bus.ARLOCK  <= 1'b0;
            bus.ARCACHE <= 4'b0000;
            bus.ARPROT  <= 3'b000;
            bus.RREADY  <= 1'b0;
        end else begin
            mrstate <= mrstate_next;
            read_done <= 1'b0;
            bus.RREADY <= (read_q_count > 0) || has_active_reads;

            if (push_read) begin
                read_req_q[read_q_tail].id               <= read_id;
                read_req_q[read_q_tail].addr             <= read_addr;
                read_req_q[read_q_tail].len              <= read_len;
                read_req_q[read_q_tail].size_bytes <= 1 << read_size;
                read_req_q[read_q_tail].burst            <= read_burst;
                //read_req_q[read_q_tail].cnt              <= '0;
                read_req_q[read_q_tail].active       <= 1'b0;
                read_q_tail <= (read_q_tail + 1) & QIDX_BITS'(MAX_OUTSTANDING - 1);;
            end

            if (pop_read) begin
                automatic logic [QIDX_BITS-1:0] p_slot = find_free_slot(read_pending);
                automatic logic [QIDX_BITS-1:0] q_idx = read_q_head;
                read_pending[p_slot] <= read_req_q[q_idx];
                //read_pending[p_slot].cnt <= '0;
                read_pending[p_slot].active <= 1'b1;
                read_q_head <= (read_q_head + 1) & QIDX_BITS'(MAX_OUTSTANDING - 1);;
            end

            read_q_count <= read_q_count + (push_read ? 1 : 0) - (pop_read ? 1 : 0);

            bus.ARVALID <= can_issue_read;

            if (read_q_count > 0) begin
                automatic logic [QIDX_BITS-1:0] idx = read_q_head;
                //bus.ARVALID <= 1'b1;
                bus.ARADDR  <= read_req_q[idx].addr;
                bus.ARLEN   <= read_req_q[idx].len;
                bus.ARSIZE  <= 3'($clog2(read_req_q[idx].size_bytes));
                bus.ARBURST <= read_req_q[idx].burst;
                bus.ARID    <= read_req_q[idx].id;
            end else begin
                //bus.ARVALID <= 1'b0;
            end
            bus.ARLOCK  <= 1'b0;
            bus.ARCACHE <= 4'b0000;
            bus.ARPROT  <= 3'b000;

            //bus.RREADY <= (mrstate == R_DATA);

            if (mrstate == R_DATA && bus.RVALID && bus.RREADY) begin
                automatic int idx = find_read_by_id(bus.RID);
                if (idx >= 0) begin
                    read_data_out <= bus.RDATA;
                    read_resp_out <= bus.RRESP;
                    read_rid_out    <= bus.RID;

                    if (!bus.RLAST) begin
                        //read_pending[idx].cnt <= read_pending[idx].cnt + 1;
                        read_pending[idx].addr <= addr_next(
                            read_pending[idx].size_bytes,
                            read_pending[idx].len,
                            read_pending[idx].burst,
                            read_pending[idx].addr
                        );
                    end else begin
                        read_done <= 1'b1;
                        read_pending[idx].active <= 1'b0;
                    end
                end else begin
                    read_resp_out <= DECERR;
                    read_done <= 1'b1;
                end
            end
        end
    end

   // always_comb begin
   //     has_active_writes = 1'b0;
   //     for (int i = 0; i < MAX_OUTSTANDING; i++)
   //         if (write_pending[i].active) has_active_writes = 1'b1;
   // end

   // assign can_issue_write = (write_q_count > 0) && (find_free_slot(write_pending) >= 0);
    assign bus.WLAST = (mwstate == W_DATA && active_idx >= 0) &&
                       (write_pending[active_idx].cnt == write_pending[active_idx].len);
    assign push_write = start_write &&
                        (write_q_count < MAX_OUTSTANDING) &&
                        (wdata_count < MAX_OUTSTANDING);

    assign pop_write = (mwstate == W_ADDR) && bus.AWREADY &&
                        (write_q_count > 0);

    assign pop_wdata = (mwstate == W_DATA) && bus.WVALID && bus.WREADY;

    always_comb begin
        active_idx = -1;
        for (int i = 0; i < MAX_OUTSTANDING; i++) begin
            if (write_pending[i].active) begin
                active_idx = i;
                break;
            end
        end
    end

    always_ff @(posedge bus.ACLK or negedge bus.ARESETn) begin
        if (!bus.ARESETn) begin
            mwstate <= W_IDLE;
            write_q_head <= '0;
            write_q_tail <= '0;
            write_q_count <= '0;
            wdata_head <= '0;
            wdata_tail <= '0;
            wdata_count <= '0;
            for (int i = 0; i < MAX_OUTSTANDING; i++) begin
                write_req_q[i] <= '0;
                write_pending[i].active <= 1'b0;
                wdata_fifo[i] <= '0;
            end
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
            bus.WDATA  <= '0;
            bus.WSTRB  <= '0;
            bus.BREADY <= 1'b0;
            write_done <= 1'b0;
            write_id_out <= '0;
            write_resp_out <= OKAY;
        end else begin
            mwstate <= mwstate_next;
            write_done <= 1'b0;

            if (push_write) begin
                write_req_q[write_q_tail].id         <= write_id;
                write_req_q[write_q_tail].addr       <= write_addr;
                write_req_q[write_q_tail].len        <= write_len;
                write_req_q[write_q_tail].size_bytes <= 1 << write_size;
                write_req_q[write_q_tail].burst      <= write_burst;
                write_req_q[write_q_tail].cnt        <= '0;
                write_req_q[write_q_tail].active     <= 1'b0;
                wdata_fifo[wdata_tail]               <= write_data;
                write_q_tail <= (write_q_tail + 1) & QIDX_BITS'(MAX_OUTSTANDING - 1);;
                wdata_tail   <= (wdata_tail + 1) & QIDX_BITS'(MAX_OUTSTANDING - 1);;
            end

            if (pop_write) begin
                automatic logic [QIDX_BITS-1:0] p_slot = find_free_slot(write_pending);
                automatic logic [QIDX_BITS-1:0] q_idx = write_q_head;
                write_pending[p_slot] <= write_req_q[q_idx];
                write_pending[p_slot].active <= 1'b1;
                write_pending[p_slot].cnt <= '0; 
                write_q_head <= (write_q_head + 1) & QIDX_BITS'(MAX_OUTSTANDING - 1);;
            end

            if (pop_wdata) begin
                wdata_head <= (wdata_head + 1) & QIDX_BITS'(MAX_OUTSTANDING - 1);;
            end

            write_q_count <= write_q_count + (push_write ? 1 : 0) - (pop_write ? 1 : 0);
            wdata_count   <= wdata_count   + (push_write ? 1 : 0) - (pop_wdata ? 1 : 0);

            if (write_q_count > 0) begin
                automatic logic [QIDX_BITS-1:0] idx = write_q_head;
                bus.AWVALID <= 1'b1;
                bus.AWADDR  <= write_req_q[idx].addr;
                bus.AWLEN   <= write_req_q[idx].len;
                bus.AWSIZE  <= 3'($clog2(write_req_q[idx].size_bytes));
                bus.AWBURST <= write_req_q[idx].burst;
                bus.AWID    <= write_req_q[idx].id;
            end else begin
                bus.AWVALID <= 1'b0;
            end
            bus.AWLOCK  <= 1'b0;
            bus.AWCACHE <= 4'b0000;
            bus.AWPROT  <= 3'b000;

            bus.WVALID <= (mwstate == W_DATA && active_idx >= 0);
            if (mwstate == W_DATA && active_idx >= 0) begin
                bus.WDATA <= wdata_fifo[wdata_head];
                bus.WSTRB <= gen_wstrb(
                                 write_req_q[active_idx].addr[OFFSET_BITS-1:0],
                                 write_req_q[active_idx].size_bytes
                             );
            end else begin
                bus.WDATA <= '0;
                bus.WSTRB <= '0;
            end

            if (mwstate == W_DATA && bus.WVALID && bus.WREADY) begin
                if (!bus.WLAST) begin
                    write_pending[active_idx].cnt <= write_pending[active_idx].cnt + 1;
                    write_pending[active_idx].addr <= addr_next(
                        write_pending[active_idx].size_bytes,
                        write_pending[active_idx].len,
                        write_pending[active_idx].burst,
                        write_pending[active_idx].addr
                    );
                end
            end

            bus.BREADY <= (mwstate == W_RESP);

            if (mwstate == W_RESP && bus.BVALID && bus.BREADY) begin
                automatic int wr_idx = find_write_by_id(bus.BID);
                if (wr_idx >= 0) begin
                    write_id_out    <= write_pending[wr_idx].id;
                    write_resp_out  <= bus.BRESP;
                    write_pending[wr_idx].active <= 1'b0;
                    write_done      <= 1'b1;
                end else begin
                    write_resp_out  <= DECERR;
                    write_done      <= 1'b1;
                end
            end
        end
    end

endmodule
