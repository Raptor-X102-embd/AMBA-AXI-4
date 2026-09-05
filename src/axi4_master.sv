`include "axi4_if.svh"
`include "axi4_pkg.svh"
`include "addr_next_macro.svh"

import axi4_pkg::*;

`timescale 10ns/1ns
module axi4_master
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
    output logic                  read_ready,
    output logic [ID_WIDTH-1:0]   write_id_out,
    output logic [1:0]            write_resp_out,
    output logic                  write_done,
    output logic                  write_ready
);

    `ADDR_NEXT_FUNC(ADDR_WIDTH)

    localparam DATA_WIDTH_BYTES = DATA_WIDTH / 8;
    localparam OFFSET_BITS = $clog2(DATA_WIDTH_BYTES);
    localparam QIDX_BITS = $clog2(MAX_OUTSTANDING);

    // Separated arrays 
    // This was done because yosys couldn't synthesise structure array to
    // registers. There is complicated logic with many simultaneous writes, so
    // we cant use BRAM.

    // read_req_q
    (* ram_style = "distributed" *) logic [ID_WIDTH-1:0]   read_req_id   [0:MAX_OUTSTANDING-1];
    (* ram_style = "distributed" *) logic [ADDR_WIDTH-1:0] read_req_addr [0:MAX_OUTSTANDING-1];
    (* ram_style = "distributed" *) logic [7:0]            read_req_len  [0:MAX_OUTSTANDING-1];
    (* ram_style = "distributed" *) logic [7:0]            read_req_size_bytes [0:MAX_OUTSTANDING-1];
    (* ram_style = "distributed" *) logic [2:0]            read_req_size_code [0:MAX_OUTSTANDING-1];
    (* ram_style = "distributed" *) logic [1:0]            read_req_burst[0:MAX_OUTSTANDING-1];

    // read_pending
    (* ram_style = "distributed" *) logic [ID_WIDTH-1:0]   read_pend_id   [0:MAX_OUTSTANDING-1];
    (* ram_style = "distributed" *) logic [ADDR_WIDTH-1:0] read_pend_addr [0:MAX_OUTSTANDING-1];
    (* ram_style = "distributed" *) logic [7:0]            read_pend_len  [0:MAX_OUTSTANDING-1];
    (* ram_style = "distributed" *) logic [7:0]            read_pend_size_bytes [0:MAX_OUTSTANDING-1];
    //(* ram_style = "distributed" *) logic [2:0]            read_pend_size_code [0:MAX_OUTSTANDING-1];
    (* ram_style = "distributed" *) logic [1:0]            read_pend_burst[0:MAX_OUTSTANDING-1];
    //(* ram_style = "distributed" *) logic [7:0]            read_pend_cnt  [0:MAX_OUTSTANDING-1];
    (* ram_style = "distributed" *) logic                  read_pend_active[0:MAX_OUTSTANDING-1];

    logic [QIDX_BITS-1:0] read_q_head, read_q_tail;
    logic [QIDX_BITS:0]   read_q_count;
    logic push_read, pop_read;
    logic has_active_reads;
    logic can_issue_read;

    // write_req_q
    (* ram_style = "distributed" *) logic [ID_WIDTH-1:0]   write_req_id   [0:MAX_OUTSTANDING-1];
    (* ram_style = "distributed" *) logic [ADDR_WIDTH-1:0] write_req_addr [0:MAX_OUTSTANDING-1];
    (* ram_style = "distributed" *) logic [7:0]            write_req_len  [0:MAX_OUTSTANDING-1];
    (* ram_style = "distributed" *) logic [7:0]            write_req_size_bytes [0:MAX_OUTSTANDING-1];
    (* ram_style = "distributed" *) logic [2:0]            write_req_size_code [0:MAX_OUTSTANDING-1];
    (* ram_style = "distributed" *) logic [1:0]            write_req_burst[0:MAX_OUTSTANDING-1];
    (* ram_style = "distributed" *) logic [7:0]            write_req_cnt  [0:MAX_OUTSTANDING-1];
    (* ram_style = "distributed" *) logic                  write_req_active[0:MAX_OUTSTANDING-1];

    (* ram_style = "distributed" *) logic [DATA_WIDTH-1:0] wdata_fifo [0:MAX_OUTSTANDING-1];

    logic [QIDX_BITS-1:0] write_q_tail;
    logic [QIDX_BITS:0]   write_q_count;

    logic [QIDX_BITS-1:0] aw_head; // write_q_head
    logic [QIDX_BITS-1:0] w_ptr;         // index of transaction currently transferring data
    logic [QIDX_BITS-1:0] b_ptr;         // index of transaction awaiting response
    logic [QIDX_BITS:0]   active_count;  // number of outstanding writes (AW issued, B not yet received)

    logic [QIDX_BITS:0]   wdata_count;   // number of slots in wdata_fifo that are occupied
    logic push_write, pop_aw, pop_wdata, pop_b;


    // helper functions
    function automatic int find_free_read_slot();
        automatic logic found;
        found = 1'b0;
        find_free_read_slot = -1;
        for (int i = 0; i < MAX_OUTSTANDING; i++)
            if (!found && !read_pend_active[i]) begin 
                found = 1'b1;
                find_free_read_slot = i;
            end
    endfunction

    function automatic int find_read_by_id(input [ID_WIDTH-1:0] id);
        automatic logic found;
        found = 1'b0;
        find_read_by_id = -1;
        for (int i = 0; i < MAX_OUTSTANDING; i++)
            if (!found && read_pend_active[i] && read_pend_id[i] == id) begin
                found = 1'b1;
                find_read_by_id = i;
            end
    endfunction

    function automatic logic [QIDX_BITS-1:0] find_next_active_write(input logic [QIDX_BITS-1:0] start);
        logic [QIDX_BITS-1:0] idx;
        automatic logic found;
        found = 1'b0;
        idx = start;
        find_next_active_write = start;
        for (int i = 0; i < MAX_OUTSTANDING; i++) begin
            if (!found && write_req_active[idx] && (write_req_cnt[idx] <= write_req_len[idx])) begin
                found = 1'b1;
                find_next_active_write = idx;
            end
            idx = (idx + 1) & QIDX_BITS'(MAX_OUTSTANDING - 1);
        end
    endfunction

    function automatic logic [DATA_WIDTH_BYTES-1:0] gen_wstrb(
        input [OFFSET_BITS-1:0] offset,
        input logic [7:0] size_bytes
    );
        logic [DATA_WIDTH_BYTES-1:0] strb;
        strb = '0;
        case (size_bytes)
            1: strb = 1'b1 << offset;
            2: strb = {2{1'b1}} << offset;
            4: strb = {4{1'b1}} << offset;
            8: strb = {8{1'b1}} << offset;
            16: strb = {16{1'b1}} << offset;
            32: strb = {32{1'b1}} << offset;
            64: strb = {64{1'b1}} << offset;
            128: strb = {128{1'b1}} << offset;
            default: strb = '0; // unsupported sizes or incorrect
        endcase
        gen_wstrb = strb;
    endfunction

    // Read FSM
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
        automatic logic found;
        found = 1'b0;
        has_active_reads = 1'b0;
        for (int i = 0; i < MAX_OUTSTANDING; i++) begin
            if (!found && read_pend_active[i]) begin
                has_active_reads = 1'b1;
                found = 1'b1;
            end
        end
    end

    assign read_ready  = (read_q_count < MAX_OUTSTANDING);
    assign can_issue_read = (read_q_count > 0) && (find_free_read_slot() >= 0);
    assign push_read = start_read && (read_q_count < MAX_OUTSTANDING);
    assign pop_read  = bus.ARREADY && can_issue_read;

    always_ff @(posedge bus.ACLK or negedge bus.ARESETn) begin
        if (!bus.ARESETn) begin
            mrstate <= R_IDLE;
            read_q_head <= 0;
            read_q_tail <= 0;
            read_q_count <= 0;
            for (int i = 0; i < MAX_OUTSTANDING; i++) begin
                read_req_id[i] <= '0;
                read_req_addr[i] <= '0;
                read_req_len[i] <= '0;
                read_req_size_bytes[i] <= '0;
                read_req_size_code[i] <= '0;
                read_req_burst[i] <= '0;
                read_pend_id[i] <= '0;
                read_pend_addr[i] <= '0;
                read_pend_len[i] <= '0;
                read_pend_size_bytes[i] <= '0;
                //read_pend_size_code[i] <= '0;
                read_pend_burst[i] <= '0;
                //read_pend_cnt[i] <= '0;
                read_pend_active[i] <= 1'b0;
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

            // New request add
            if (push_read) begin
                read_req_id  [read_q_tail] <= read_id;
                read_req_addr[read_q_tail] <= read_addr;
                read_req_len [read_q_tail] <= read_len;
                read_req_size_bytes[read_q_tail] <= 1 << read_size;
                read_req_size_code[read_q_tail] <= read_size;
                read_req_burst[read_q_tail] <= read_burst;
                read_q_tail <= (read_q_tail + 1) & QIDX_BITS'(MAX_OUTSTANDING - 1);
            end

            // Move request to active queue
            if (pop_read) begin
                automatic logic [QIDX_BITS-1:0] p_slot;
                automatic logic [QIDX_BITS-1:0] q_idx;
                p_slot = QIDX_BITS'(find_free_read_slot());
                q_idx = read_q_head;
                read_pend_id   [p_slot] <= read_req_id   [q_idx];
                read_pend_addr [p_slot] <= read_req_addr [q_idx];
                read_pend_len  [p_slot] <= read_req_len  [q_idx];
                read_pend_size_bytes[p_slot] <= read_req_size_bytes[q_idx];
                //read_pend_size_code[p_slot] <= read_req_size_code[q_idx];
                read_pend_burst[p_slot] <= read_req_burst[q_idx];
                //read_pend_cnt  [p_slot] <= 0;
                read_pend_active[p_slot] <= 1'b1;
                read_q_head <= (read_q_head + 1) & QIDX_BITS'(MAX_OUTSTANDING - 1);
            end

            read_q_count <= read_q_count + (push_read ? 1 : 0) - (pop_read ? 1 : 0);

            bus.ARVALID <= can_issue_read;
            if (read_q_count > 0) begin
                automatic logic [QIDX_BITS-1:0] idx;
                idx = read_q_head;
                bus.ARADDR  <= read_req_addr[idx];
                bus.ARLEN   <= read_req_len [idx];
                bus.ARSIZE  <= read_req_size_code[idx];
                bus.ARBURST <= read_req_burst[idx];
                bus.ARID    <= read_req_id   [idx];
            end 
            bus.ARLOCK  <= 1'b0;
            bus.ARCACHE <= 4'b0000;
            bus.ARPROT  <= 3'b000;

            if (mrstate == R_DATA && bus.RVALID && bus.RREADY) begin
                automatic logic [ID_WIDTH-1:0] rid;
                automatic int idx;
                rid = bus.RID;
                idx = find_read_by_id(rid);
                if (idx >= 0) begin
                    read_data_out <= bus.RDATA;
                    read_resp_out <= bus.RRESP;
                    read_rid_out  <= rid;
                    if (!bus.RLAST) begin
                        read_pend_addr[idx] <= addr_next(
                            read_pend_size_bytes[idx],
                            read_pend_len[idx],
                            read_pend_burst[idx],
                            read_pend_addr[idx]
                        );
                    end else begin
                        read_done <= 1'b1;
                        read_pend_active[idx] <= 1'b0;
                    end
                end else begin
                    read_resp_out <= DECERR;
                    read_done <= 1'b1;
                end
            end
        end
    end

    typedef enum logic [1:0] {
        W_IDLE,
        W_AW,
        W_DATA,
        W_RESP
    } mwstate_t;

    mwstate_t mwstate, mwstate_next;

    logic [ID_WIDTH-1:0]   cur_id;
    logic [ADDR_WIDTH-1:0] cur_addr;
    logic [7:0]            cur_len;
    logic [7:0]            cur_size_bytes;
    logic [2:0]            cur_size_code;
    logic [1:0]            cur_burst;
    logic [7:0]            cur_cnt;

    logic w_active;

    assign write_ready = (write_q_count < MAX_OUTSTANDING) && (wdata_count < MAX_OUTSTANDING);
    assign push_write  = start_write && write_ready;
    assign pop_aw      = (mwstate == W_IDLE) && (write_q_count > 0);
    assign pop_wdata   = (mwstate == W_DATA) && bus.WREADY && (cur_cnt < cur_len);
    assign pop_b       = (mwstate == W_RESP) && bus.BVALID && bus.BREADY;

    always_comb begin
        w_active = (mwstate == W_DATA) && (cur_cnt <= cur_len);
    end

    always_comb begin
        mwstate_next = mwstate;
        case (mwstate)
            W_IDLE: begin
                if (write_q_count > 0) mwstate_next = W_AW;
            end
            W_AW: begin
                if (bus.AWREADY) mwstate_next = W_DATA;
            end
            W_DATA: begin
                if (bus.WREADY && (cur_cnt == cur_len)) begin
                    mwstate_next = W_RESP;
                end
            end
            W_RESP: begin
                if (bus.BVALID && bus.BREADY) mwstate_next = W_IDLE;
            end
        endcase
    end

    always_ff @(posedge bus.ACLK or negedge bus.ARESETn) begin
        if (!bus.ARESETn) begin
            mwstate <= W_IDLE;
            write_q_tail <= 0;
            write_q_count <= 0;
            aw_head <= 0;
            w_ptr <= 0;
            b_ptr <= 0;
            active_count <= 0;
            wdata_count <= 0;
            for (int i = 0; i < MAX_OUTSTANDING; i++) begin
                write_req_id[i] <= '0;
                write_req_addr[i] <= '0;
                write_req_len[i] <= '0;
                write_req_size_bytes[i] <= '0;
                write_req_size_code[i] <= '0;
                write_req_burst[i] <= '0;
                write_req_cnt[i] <= '0;
                write_req_active[i] <= 1'b0;
                wdata_fifo[i] <= '0;
            end
            write_done <= 1'b0;
            write_id_out <= '0;
            write_resp_out <= OKAY;
            cur_id <= '0;
            cur_addr <= '0;
            cur_len <= '0;
            cur_size_bytes <= '0;
            cur_size_code <= '0;
            cur_burst <= INCR;
            cur_cnt <= '0;

            bus.AWVALID <= 1'b0;
            bus.AWADDR  <= '0;
            bus.AWLEN   <= '0;
            bus.AWSIZE  <= '0;
            bus.AWBURST <= INCR;
            bus.AWID    <= '0;
            bus.AWLOCK  <= 1'b0;
            bus.AWCACHE <= 4'b0000;
            bus.AWPROT  <= 3'b000;

            bus.WVALID  <= 1'b0;
            bus.WDATA   <= '0;
            bus.WSTRB   <= '0;
            bus.WLAST   <= 1'b0;
            bus.BREADY  <= 1'b0;
        end else begin
            mwstate <= mwstate_next;

            if (push_write) begin
                write_req_id  [write_q_tail] <= write_id;
                write_req_addr[write_q_tail] <= write_addr;
                write_req_len [write_q_tail] <= write_len;
                write_req_size_bytes[write_q_tail] <= 1 << write_size;
                write_req_size_code[write_q_tail] <= write_size;
                write_req_burst[write_q_tail] <= write_burst;
                write_req_cnt [write_q_tail] <= 0;
                write_req_active[write_q_tail] <= 1'b0;
                wdata_fifo[write_q_tail] <= write_data;
                write_q_tail <= (write_q_tail + 1) & QIDX_BITS'(MAX_OUTSTANDING - 1);
            end

            if (pop_aw) begin
                cur_id   <= write_req_id  [aw_head];
                cur_addr <= write_req_addr[aw_head];
                cur_len  <= write_req_len [aw_head];
                cur_size_bytes <= write_req_size_bytes[aw_head];
                cur_size_code  <= write_req_size_code[aw_head];
                cur_burst <= write_req_burst[aw_head];
                cur_cnt  <= 0;

                write_req_active[aw_head] <= 1'b1;
                write_req_cnt[aw_head] <= 0;
                w_ptr <= aw_head;
                aw_head <= (aw_head + 1) & QIDX_BITS'(MAX_OUTSTANDING - 1);
            end

            if (pop_wdata) begin
                cur_cnt <= cur_cnt + 1;
                if (cur_cnt < cur_len) begin
                    cur_addr <= addr_next(cur_size_bytes, cur_len, cur_burst, cur_addr);
                end
                write_req_cnt[w_ptr] <= write_req_cnt[w_ptr] + 1;
                if (cur_cnt < cur_len) begin
                    write_req_addr[w_ptr] <= addr_next(
                        write_req_size_bytes[w_ptr],
                        write_req_len[w_ptr],
                        write_req_burst[w_ptr],
                        write_req_addr[w_ptr]
                    );
                end
                if (cur_cnt == cur_len) begin
                    w_ptr <= find_next_active_write((w_ptr + 1) & QIDX_BITS'(MAX_OUTSTANDING - 1));
                end
            end

            if (pop_b) begin
                if (write_req_active[b_ptr]) begin
                    write_id_out   <= write_req_id[b_ptr];
                    write_resp_out <= bus.BRESP;
                    write_done     <= 1'b1;
                    write_req_active[b_ptr] <= 1'b0;
                end else begin
                    write_resp_out <= DECERR;
                    write_done     <= 1'b1;
                end
                b_ptr <= (b_ptr + 1) & QIDX_BITS'(MAX_OUTSTANDING - 1);
            end else begin
                write_done <= 1'b0;
            end

            write_q_count <= write_q_count + (push_write ? 1 : 0) - (pop_aw ? 1 : 0);
            active_count  <= active_count  + (pop_aw ? 1 : 0) - (pop_b ? 1 : 0);
            wdata_count   <= wdata_count   + (push_write ? 1 : 0) - (pop_b ? 1 : 0);

            // AW channel
            bus.AWVALID <= (mwstate == W_AW);
            if (mwstate == W_AW) begin
                bus.AWADDR  <= cur_addr;
                bus.AWLEN   <= cur_len;
                bus.AWSIZE  <= cur_size_code;
                bus.AWBURST <= cur_burst;
                bus.AWID    <= cur_id;
            end else begin
                bus.AWADDR  <= '0;
                bus.AWLEN   <= '0;
                bus.AWSIZE  <= '0;
                bus.AWBURST <= INCR;
                bus.AWID    <= '0;
            end
            bus.AWLOCK  <= 1'b0;
            bus.AWCACHE <= 4'b0000;
            bus.AWPROT  <= 3'b000;

            // W channel
            bus.WVALID <= w_active;
            if (w_active) begin
                bus.WDATA <= wdata_fifo[w_ptr];
                bus.WSTRB <= gen_wstrb(cur_addr[OFFSET_BITS-1:0], cur_size_bytes);
                bus.WLAST <= (cur_cnt == cur_len);
            end else begin
                bus.WDATA <= '0;
                bus.WSTRB <= '0;
                bus.WLAST <= 1'b0;
            end

            bus.BREADY <= (mwstate == W_RESP);
        end
    end

endmodule
