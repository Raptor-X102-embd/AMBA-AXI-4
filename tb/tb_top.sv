`include "axi4_if.svh"
`include "axi4_pkg.svh"
`timescale 10ns/1ns

module tb_top;
  import axi4_pkg::*;
  parameter MEM_SIZE   = 1024;
  parameter USER_WIDTH = 4;
  parameter ADDR_WIDTH = 32;
  parameter DATA_WIDTH = 32;
  parameter ID_WIDTH   = 4;

  logic ACLK;
  logic ARESETn;

  logic                  start_read;
  logic [ID_WIDTH-1:0]   read_id;
  logic [ADDR_WIDTH-1:0] read_addr;
  logic [7:0]            read_len;
  logic [2:0]            read_size;
  logic [1:0]            read_burst;
  logic [ID_WIDTH-1:0]   read_rid_out;
  logic [1:0]            read_resp_out;
  logic [DATA_WIDTH-1:0] read_data_out;
  logic                  read_done;
  logic [DATA_WIDTH-1:0] rdata1, rdata2, rdata3;
  logic [ID_WIDTH-1:0]   rid1, rid2, rid3;

  logic                  start_write;
  logic [ID_WIDTH-1:0]   write_id;
  logic [ADDR_WIDTH-1:0] write_addr;
  logic [7:0]            write_len;
  logic [2:0]            write_size;
  logic [1:0]            write_burst;
  logic [DATA_WIDTH-1:0] write_data;
  logic [ID_WIDTH-1:0]   write_id_out;
  logic [1:0]            write_resp_out;
  logic                  write_done;

  always #5 ACLK = ~ACLK;

  top_module #(
    .MEM_SIZE(MEM_SIZE),
    .ADDR_WIDTH(ADDR_WIDTH),
    .DATA_WIDTH(DATA_WIDTH),
    .ID_WIDTH(ID_WIDTH),
    .USER_WIDTH(USER_WIDTH),
    .MAX_OUTSTANDING(8)
  ) u_top (
    .ACLK(ACLK),
    .ARESETn(ARESETn),
    .start_read(start_read),
    .read_id(read_id),
    .read_addr(read_addr),
    .read_len(read_len),
    .read_size(read_size),
    .read_burst(read_burst),
    .start_write(start_write),
    .write_id(write_id),
    .write_addr(write_addr),
    .write_len(write_len),
    .write_size(write_size),
    .write_burst(write_burst),
    .write_data(write_data),
    .read_rid_out(read_rid_out),
    .read_resp_out(read_resp_out),
    .read_data_out(read_data_out),
    .read_done(read_done),
    .write_id_out(write_id_out),
    .write_resp_out(write_resp_out),
    .write_done(write_done)
  );

  logic test_passed;

  // --------------------------------------------------------------
  // Задача записи – безопасная синхронизация
  // --------------------------------------------------------------
  task do_write(
    input [ID_WIDTH-1:0]   id,
    input [ADDR_WIDTH-1:0] addr,
    input [DATA_WIDTH-1:0] data,
    input [7:0]            len,
    input [2:0]            size,
    input [1:0]            burst
  );
    // Устанавливаем start_write сразу после положительного фронта,
    // чтобы он был виден на следующем такте.
    @(posedge ACLK);
    start_write <= 1;
    write_id    <= id;
    write_addr  <= addr;
    write_data  <= data;
    write_len   <= len;
    write_size  <= size;
    write_burst <= burst;

    // Держим активным ровно один такт
    @(posedge ACLK);
    start_write <= 0;

    // Ожидаем завершения записи
    while (!write_done) @(posedge ACLK);

    if (write_id_out !== id) begin
      $display("ERROR: Write ID mismatch: sent %0d, got %0d", id, write_id_out);
      test_passed = 0;
    end
    if (write_resp_out != OKAY) begin
      $display("ERROR: Write response not OKAY: %0d", write_resp_out);
      test_passed = 0;
    end
    $display("Write done: ID=%0d, addr=0x%8h, data=0x%8h", id, addr, data);
  endtask

  // --------------------------------------------------------------
  // Задача чтения – аналогичная синхронизация
  // --------------------------------------------------------------
  task do_read(
    input [ID_WIDTH-1:0]   id,
    input [ADDR_WIDTH-1:0] addr,
    input [7:0]            len,
    input [2:0]            size,
    input [1:0]            burst,
    output [DATA_WIDTH-1:0] data
  );
    @(posedge ACLK);
    start_read <= 1;
    read_id    <= id;
    read_addr  <= addr;
    read_len   <= len;
    read_size  <= size;
    read_burst <= burst;

    @(posedge ACLK);
    start_read <= 0;

    while (!read_done) @(posedge ACLK);

    if (read_rid_out !== id) begin
      $display("ERROR: Read ID mismatch: sent %0d, got %0d", id, read_rid_out);
      test_passed = 0;
    end
    if (read_resp_out != OKAY) begin
      $display("ERROR: Read response not OKAY: %0d", read_resp_out);
      test_passed = 0;
    end
    data = read_data_out;
    $display("Read done: ID=%0d, addr=0x%8h, data=0x%8h", id, addr, data);
  endtask

  // --------------------------------------------------------------
  // Основной тест
  // --------------------------------------------------------------
  initial begin
    ACLK = 0;
    ARESETn = 0;
    start_read = 0;
    start_write = 0;
    test_passed = 1;

    #20 ARESETn = 1;
    @(posedge ACLK); // даём время на выход из сброса

    $display("\n=== Test 1: Simple write+read with ID ===\n");
    do_write(5, 32'h00001000, 32'hDEADBEEF, 0, 3'b010, INCR);
    do_read(5, 32'h00001000, 0, 3'b010, INCR, read_data_out);
    if (read_data_out != 32'hDEADBEEF) begin
      $display("ERROR: Data mismatch: expected DEADBEEF, got %h", read_data_out);
      test_passed = 0;
    end

    $display("\n=== Test 2: Two writes with different IDs ===\n");
    do_write(1, 32'h00001010, 32'h12345678, 0, 3'b010, INCR);
    do_write(2, 32'h00001020, 32'h9ABCDEF0, 0, 3'b010, INCR);
    do_read(1, 32'h00001010, 0, 3'b010, INCR, read_data_out);
    do_read(2, 32'h00001020, 0, 3'b010, INCR, read_data_out);

    $display("\n=== Test 3: Burst write and read (4 beats) ===\n");
    do_write(3, 32'h00001000, 32'hA5A5A5A5, 3, 3'b010, INCR);
    do_read(3, 32'h00001000, 3, 3'b010, INCR, read_data_out);

   // $display("\n=== Test 4: 3 outstanding reads ===\n");
   // do_write(10, 32'h00001000, 32'hAAAAAAAA, 0, 3'b010, INCR);
   // do_write(11, 32'h00001010, 32'hBBBBBBBB, 0, 3'b010, INCR);
   // do_write(12, 32'h00001020, 32'hCCCCCCCC, 0, 3'b010, INCR);

    // Запускаем три чтения подряд с разными ID
   // fork
   //   begin
   //     @(posedge ACLK);
   //     start_read <= 1;
   //     read_id    <= 4;
   //     read_addr  <= 32'h00001000;
   //     read_len   <= 0;
   //     read_size  <= 3'b010;
   //     read_burst <= INCR;
   //     @(posedge ACLK);
   //     start_read <= 0;
   //   end
   //   begin
   //     @(posedge ACLK);
   //     start_read <= 1;
   //     read_id    <= 5;
   //     read_addr  <= 32'h00001010;
   //     read_len   <= 0;
   //     read_size  <= 3'b010;
   //     read_burst <= INCR;
   //     @(posedge ACLK);
   //     start_read <= 0;
   //   end
   //   begin
   //     @(posedge ACLK);
   //     start_read <= 1;
   //     read_id    <= 6;
   //     read_addr  <= 32'h00001020;
   //     read_len   <= 0;
   //     read_size  <= 3'b010;
   //     read_burst <= INCR;
   //     @(posedge ACLK);
   //     start_read <= 0;
   //   end
   // join

   // // Собираем результаты трёх чтений
   // begin
   //   automatic int cnt = 0;
   //   while (cnt < 3) begin
   //     @(posedge ACLK);
   //     if (read_done) begin
   //       cnt++;
   //       $display("Read done: ID=%0d, data=0x%8h", read_rid_out, read_data_out);
   //       case (read_rid_out)
   //         4: begin rdata1 = read_data_out; rid1 = read_rid_out; end
   //         5: begin rdata2 = read_data_out; rid2 = read_rid_out; end
   //         6: begin rdata3 = read_data_out; rid3 = read_rid_out; end
   //       endcase
   //     end
   //   end
   // end

   // if (rid1 == 4 && rdata1 != 32'hAAAAAAAA) begin
   //   $display("ERROR: Read1 data mismatch, expected AAAAAAAA, got %h", rdata1);
   //   test_passed = 0;
   // end
   // if (rid2 == 5 && rdata2 != 32'hBBBBBBBB) begin
   //   $display("ERROR: Read2 data mismatch, expected BBBBBBBB, got %h", rdata2);
   //   test_passed = 0;
   // end
   // if (rid3 == 6 && rdata3 != 32'hCCCCCCCC) begin
   //   $display("ERROR: Read3 data mismatch, expected CCCCCCCC, got %h", rdata3);
   //   test_passed = 0;
   // end

    // Итог
    if (test_passed) begin
      $display("\n=========================================");
      $display(" ALL TESTS PASSED ");
      $display("=========================================");
    end else begin
      $display("\n=========================================");
      $display(" SOME TESTS FAILED ");
      $display("=========================================");
    end

    #20 $finish;
  end

  // Включение VCD-дампов
  initial begin
    $dumpfile("sim.vcd");
    $dumpvars(0, tb_top);
  end

endmodule
