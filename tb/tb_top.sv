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
  logic                  write_ready;
  logic                  read_ready;

  // Счётчики для проверки потерь
  int writes_sent    = 0;
  int writes_done    = 0;
  int reads_sent     = 0;
  int reads_done     = 0;

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
    .read_ready(read_ready),
    .write_id_out(write_id_out),
    .write_resp_out(write_resp_out),
    .write_done(write_done),
    .write_ready(write_ready)
  );

  logic test_passed;


  // --------------------------------------------------------------
  // Задача записи – ожидает готовности, выставляет запрос на 1 такт
  // --------------------------------------------------------------
  task do_write(
    input [ID_WIDTH-1:0]   id,
    input [ADDR_WIDTH-1:0] addr,
    input [DATA_WIDTH-1:0] data,
    input [7:0]            len,
    input [2:0]            size,
    input [1:0]            burst
  );
    @(posedge ACLK);
    while (!write_ready) @(posedge ACLK);
    start_write <= 1;
    write_id    <= id;
    write_addr  <= addr;
    write_data  <= data;
    write_len   <= len;
    write_size  <= size;
    write_burst <= burst;
    writes_sent++;
    @(posedge ACLK);
    start_write <= 0;
  endtask

  // --------------------------------------------------------------
  // Задача чтения – аналогично
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
    while (!read_ready) @(posedge ACLK);
    start_read <= 1;
    read_id    <= id;
    read_addr  <= addr;
    read_len   <= len;
    read_size  <= size;
    read_burst <= burst;
    reads_sent++;
    @(posedge ACLK);
    start_read <= 0;
    // Не ждём завершения – оно будет отслеживаться отдельно
  endtask

  // --------------------------------------------------------------
  // Отслеживание завершённых транзакций
  // --------------------------------------------------------------
  always @(posedge ACLK) begin
    if (write_done) writes_done++;
    if (read_done)  reads_done++;
  end

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
    @(posedge ACLK);

    $display("\n=== Test 1: Simple write+read with ID ===\n");
    do_write(5, 32'h00001000, 32'hDEADBEEF, 0, 3'b010, INCR);
    do_read(5, 32'h00001000, 0, 3'b010, INCR, read_data_out);
    // Ожидаем завершения этих двух транзакций
    while (writes_done < 1 || reads_done < 1) @(posedge ACLK);
    if (read_data_out != 32'hDEADBEEF) begin
      $display("ERROR: Data mismatch: expected DEADBEEF, got %h", read_data_out);
      test_passed = 0;
    end

    $display("\n=== Test 2: Two writes with different IDs ===\n");
    do_write(1, 32'h00001010, 32'h12345678, 0, 3'b010, INCR);
    do_write(2, 32'h00001020, 32'h9ABCDEF0, 0, 3'b010, INCR);
    do_read(1, 32'h00001010, 0, 3'b010, INCR, read_data_out);
    do_read(2, 32'h00001020, 0, 3'b010, INCR, read_data_out);
    while (writes_done < 3 || reads_done < 3) @(posedge ACLK);

    $display("\n=== Test 3: Burst write and read (4 beats) ===\n");
    do_write(3, 32'h00001000, 32'hA5A5A5A5, 3, 3'b010, INCR);
    do_read(3, 32'h00001000, 3, 3'b010, INCR, read_data_out);
    while (writes_done < 4 || reads_done < 4) @(posedge ACLK);

    // --------------------------------------------------------------
    // Test 5: Buffer overflow / переполнение очередей
    // --------------------------------------------------------------
    $display("\n=== Test 5: Buffer overflow (MAX_OUTSTANDING=8) ===\n");

    // Отправляем 20 записей с ожиданием готовности (без ожидания завершения)
    for (int i = 0; i < 20; i++) begin
      do_write(i[ID_WIDTH-1:0], 32'h00002000 + i*4, 32'hA0000000 + i, 0, 3'b010, INCR);
    end

    // Отправляем 20 чтений
    for (int i = 0; i < 20; i++) begin
      do_read(i[ID_WIDTH-1:0], 32'h00002000 + i*4, 0, 3'b010, INCR, read_data_out);
    end

    // Ждём завершения всех транзакций с тайм-аутом
    $display("Waiting for all writes and reads to finish...");
    begin
      automatic int timeout = 100000;
      while ((writes_done < writes_sent || reads_done < reads_sent) && timeout > 0) begin
        @(posedge ACLK);
        timeout--;
        if (timeout == 0) begin
          $display("ERROR: Timeout! writes_done=%0d/%0d, reads_done=%0d/%0d",
                   writes_done, writes_sent, reads_done, reads_sent);
          test_passed = 0;
          $finish;
        end
      end
    end
    $display("All transactions completed.");

    // Проверяем, что все отправленные транзакции завершились
    if (writes_done != writes_sent) begin
      $display("ERROR: Lost %0d write transactions!", writes_sent - writes_done);
      test_passed = 0;
    end
    if (reads_done != reads_sent) begin
      $display("ERROR: Lost %0d read transactions!", reads_sent - reads_done);
      test_passed = 0;
    end

    // Проверяем данные для первых 8 записей (они гарантированно должны быть записаны)
    for (int i = 0; i < 8; i++) begin
      automatic logic [DATA_WIDTH-1:0] rddata;
      // Используем do_read, которая будет ждать готовности и завершения, 
      // но сейчас все транзакции уже завершены, можно просто прочитать.
      // Для простоты используем отдельный цикл чтения.
      start_read <= 1;
      read_id    <= i[ID_WIDTH-1:0];
      read_addr  <= 32'h00002000 + i*4;
      read_len   <= 0;
      read_size  <= 3'b010;
      read_burst <= INCR;
      @(posedge ACLK);
      start_read <= 0;
      while (!read_done) @(posedge ACLK);
      rddata = read_data_out;
      if (rddata !== 32'hA0000000 + i) begin
        $display("ERROR: Data mismatch for i=%0d, expected %h, got %h",
                 i, 32'hA0000000 + i, rddata);
        test_passed = 0;
      end
    end

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
