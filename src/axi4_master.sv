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
        logic [2:0]            size_code;          // FIX: храним исходный код размера
        logic [1:0]            burst;
        logic [7:0]            cnt;
        logic                  active;
    } pending_t;

    pending_t read_req_q [0:MAX_OUTSTANDING-1];
    pending_t read_pending [0:MAX_OUTSTANDING-1];
    logic [QIDX_BITS-1:0] read_q_head, read_q_tail;
    logic [QIDX_BITS:0]   read_q_count;
    logic push_read, pop_read;
    logic has_active_reads;
    logic can_issue_read;

    pending_t write_req_q [0:MAX_OUTSTANDING-1];   // holds all requests (waiting, active, or finished)
    logic [DATA_WIDTH-1:0] wdata_fifo [0:MAX_OUTSTANDING-1]; // data associated with each request

    logic [QIDX_BITS-1:0] write_q_tail;
    logic [QIDX_BITS:0]   write_q_count;

    logic [QIDX_BITS-1:0] aw_head; // write_q_head
    logic [QIDX_BITS-1:0] w_ptr;         // index of transaction currently transferring data
    logic [QIDX_BITS-1:0] b_ptr;         // index of transaction awaiting response
    logic [QIDX_BITS:0]   active_count;  // number of outstanding writes (AW issued, B not yet received)

    logic [QIDX_BITS:0]   wdata_count;   // number of slots in wdata_fifo that are occupied
    logic push_write, pop_aw, pop_wdata, pop_b;

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
            if (write_req_q[i].active && write_req_q[i].id == id)
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
            bus.ARLEN   <= '0;
            bus.ARSIZE  <= '0;
            bus.ARBURST <= INCR;
            bus.ARID    <= '0;
            bus.ARLOCK  <= 1'b0;
            bus.ARCACHE <= 4'b0000;
            bus.ARPROT  <= 3'b000;
            bus.RREADY  <= 1'b0;
        end else begin
            mrstate <= mrstate_next;
            read_done <= 1'b0;
            bus.RREADY <= (read_q_count > 0) || has_active_reads;

            if (push_read) begin
                read_req_q[read_q_tail].id         <= read_id;
                read_req_q[read_q_tail].addr       <= read_addr;
                read_req_q[read_q_tail].len        <= read_len;
                read_req_q[read_q_tail].size_bytes <= 1 << read_size;
                read_req_q[read_q_tail].size_code  <= read_size;          // FIX: сохраняем код
                read_req_q[read_q_tail].burst      <= read_burst;
                read_req_q[read_q_tail].active     <= 1'b0;
                read_q_tail <= (read_q_tail + 1) & QIDX_BITS'(MAX_OUTSTANDING - 1);
            end

            if (pop_read) begin
                automatic logic [QIDX_BITS-1:0] p_slot = QIDX_BITS'(find_free_slot(read_pending));
                automatic logic [QIDX_BITS-1:0] q_idx = read_q_head;
                read_pending[p_slot] <= read_req_q[q_idx];
                read_pending[p_slot].active <= 1'b1;
                read_q_head <= (read_q_head + 1) & QIDX_BITS'(MAX_OUTSTANDING - 1);
            end

            read_q_count <= read_q_count + (push_read ? 1 : 0) - (pop_read ? 1 : 0);

            bus.ARVALID <= can_issue_read;

            if (read_q_count > 0) begin
                automatic logic [QIDX_BITS-1:0] idx = read_q_head;
                bus.ARADDR  <= read_req_q[idx].addr;
                bus.ARLEN   <= read_req_q[idx].len;
                bus.ARSIZE  <= read_req_q[idx].size_code;                // FIX: используем код
                bus.ARBURST <= read_req_q[idx].burst;
                bus.ARID    <= read_req_q[idx].id;
            end 
            bus.ARLOCK  <= 1'b0;
            bus.ARCACHE <= 4'b0000;
            bus.ARPROT  <= 3'b000;

            if (mrstate == R_DATA && bus.RVALID && bus.RREADY) begin
                automatic int idx = find_read_by_id(bus.RID);
                if (idx >= 0) begin
                    read_data_out <= bus.RDATA;
                    read_resp_out <= bus.RRESP;
                    read_rid_out  <= bus.RID;

                    if (!bus.RLAST) begin
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

    assign push_write = start_write &&
                        (write_q_count < MAX_OUTSTANDING) &&
                        (wdata_count < MAX_OUTSTANDING);

    assign pop_aw = (write_q_count > 0) && (active_count < MAX_OUTSTANDING) && bus.AWREADY;

    logic w_active;
    assign w_active = (w_ptr != aw_head) && write_req_q[w_ptr].active;

    assign bus.WVALID = w_active && (write_req_q[w_ptr].cnt <= write_req_q[w_ptr].len);
    assign bus.WLAST  = w_active && (write_req_q[w_ptr].cnt == write_req_q[w_ptr].len); 

    assign bus.BREADY = (b_ptr != aw_head) && write_req_q[b_ptr].active;
    assign pop_wdata = bus.WVALID && bus.WREADY;
    assign pop_b = bus.BVALID && bus.BREADY;

    assign bus.AWVALID = (write_q_count > 0) && (active_count < MAX_OUTSTANDING);

    always_comb begin
        bus.AWADDR  = '0;
        bus.AWLEN   = '0;
        bus.AWSIZE  = '0;
        bus.AWBURST = INCR;
        bus.AWID    = '0;
        if (write_q_count > 0) begin
            bus.AWADDR  = write_req_q[aw_head].addr;
            bus.AWLEN   = write_req_q[aw_head].len;
            bus.AWSIZE  = write_req_q[aw_head].size_code;               // FIX: используем код
            bus.AWBURST = write_req_q[aw_head].burst;
            bus.AWID    = write_req_q[aw_head].id;
        end
        bus.AWLOCK  = 1'b0;
        bus.AWCACHE = 4'b0000;
        bus.AWPROT  = 3'b000;
    end

    always_comb begin
        bus.WDATA = '0;
        bus.WSTRB = '0;
        if (w_active) begin
            bus.WDATA = wdata_fifo[w_ptr];
            bus.WSTRB = gen_wstrb(
                write_req_q[w_ptr].addr[OFFSET_BITS-1:0],
                write_req_q[w_ptr].size_bytes
            );
        end
    end

    always_ff @(posedge bus.ACLK or negedge bus.ARESETn) begin
        if (!bus.ARESETn) begin
            write_q_tail <= 0;
            write_q_count <= 0;
            aw_head <= 0;
            w_ptr <= 0;
            b_ptr <= 0;
            active_count <= 0;
            wdata_count <= 0;
            for (int i = 0; i < MAX_OUTSTANDING; i++) begin
                write_req_q[i] <= '0;
                wdata_fifo[i] <= '0;
            end
            write_done <= 1'b0;
            write_id_out <= '0;
            write_resp_out <= OKAY;
        end else begin
            write_done <= 1'b0;

            if (push_write) begin
                write_req_q[write_q_tail].id         <= write_id;
                write_req_q[write_q_tail].addr       <= write_addr;
                write_req_q[write_q_tail].len        <= write_len;
                write_req_q[write_q_tail].size_bytes <= 1 << write_size;
                write_req_q[write_q_tail].size_code  <= write_size;      // FIX: сохраняем код
                write_req_q[write_q_tail].burst      <= write_burst;
                write_req_q[write_q_tail].cnt        <= 0;
                write_req_q[write_q_tail].active     <= 1'b0;
                wdata_fifo[write_q_tail]             <= write_data;
                write_q_tail <= (write_q_tail + 1) & QIDX_BITS'(MAX_OUTSTANDING - 1);
            end

            if (pop_aw) begin
                write_req_q[aw_head].active <= 1'b1;
                write_req_q[aw_head].cnt    <= 0;
                aw_head <= (aw_head + 1) & QIDX_BITS'(MAX_OUTSTANDING - 1);
            end

            if (pop_wdata) begin
                if (w_active) begin
                    if (!bus.WLAST) begin
                        write_req_q[w_ptr].cnt <= write_req_q[w_ptr].cnt + 1;
                        write_req_q[w_ptr].addr <= addr_next(
                            write_req_q[w_ptr].size_bytes,
                            write_req_q[w_ptr].len,
                            write_req_q[w_ptr].burst,
                            write_req_q[w_ptr].addr
                        );
                    end else begin
                        w_ptr <= (w_ptr + 1) & QIDX_BITS'(MAX_OUTSTANDING - 1);
                    end
                end
            end

            write_q_count <= write_q_count
                           + (push_write ? 1 : 0)
                           - (pop_aw    ? 1 : 0);

            active_count  <= active_count
                           + (pop_aw    ? 1 : 0)
                           - (pop_b     ? 1 : 0);

            wdata_count   <= wdata_count
                           + (push_write ? 1 : 0)
                           - (pop_b     ? 1 : 0);

            if (pop_b) begin
                if (write_req_q[b_ptr].active) begin
                    write_id_out   <= write_req_q[b_ptr].id;
                    write_resp_out <= bus.BRESP;
                    write_done     <= 1'b1;
                    write_req_q[b_ptr].active <= 1'b0;
                    b_ptr <= (b_ptr + 1) & QIDX_BITS'(MAX_OUTSTANDING - 1);
                end else begin
                    write_resp_out <= DECERR;
                    write_done     <= 1'b1;
                    b_ptr <= (b_ptr + 1) & QIDX_BITS'(MAX_OUTSTANDING - 1);
                end
            end
        end
    end

endmodule
