`include "axi4_if.svh"
`include "axi4_pkg.svh"

module tb_top;
  parameter MEM_SIZE   = 1024;
  parameter USER_WIDTH = 4;
  parameter ADDR_WIDTH = 32;
  parameter DATA_WIDTH = 32;
  parameter ID_WIDTH   = 4;

  logic ACLK;
  logic ARESETn;
  logic start_read;
  logic start_write;
  logic [ADDR_WIDTH-1:0] read_addr;
  logic [ADDR_WIDTH-1:0] write_addr;
  logic [DATA_WIDTH-1:0] write_data;
  logic [DATA_WIDTH-1:0] read_data;
  logic read_done;
  logic write_done;

  // Clock generation
  always #5 ACLK = ~ACLK;  // 100 MHz

  // DUT instantiation (top_module includes master and slave)
  top_module #(
      .MEM_SIZE(MEM_SIZE),
      .ADDR_WIDTH(ADDR_WIDTH),
      .DATA_WIDTH(DATA_WIDTH),
      .ID_WIDTH(ID_WIDTH),
      .USER_WIDTH(USER_WIDTH)
  ) u_top (
      .ACLK(ACLK),
      .ARESETn(ARESETn),
      .start_read(start_read),
      .start_write(start_write),
      .read_addr(read_addr),
      .write_addr(write_addr),
      .write_data(write_data),
      .read_data(read_data),
      .read_done(read_done),
      .write_done(write_done)
  );

  // Test variables
  logic [DATA_WIDTH-1:0] expected_data;
  logic test_passed;

  // Timeout tasks
  task wait_read_done;
    int timeout = 200;
    while (!read_done && timeout > 0) begin
      @(posedge ACLK);
      timeout--;
    end
    if (timeout == 0) $error("Read timeout");
  endtask

  task wait_write_done;
    int timeout = 200;
    while (!write_done && timeout > 0) begin
      @(posedge ACLK);
      timeout--;
    end
    if (timeout == 0) $error("Write timeout");
  endtask

  // Test sequence
  initial begin
    // Initialisation
    ACLK = 0;
    ARESETn = 0;
    start_read = 0;
    start_write = 0;
    read_addr = '0;
    write_addr = '0;
    write_data = '0;
    test_passed = 1'b1;

    // Reset release
    #10 ARESETn = 1;
    #10;

    // ----------------------------------------------------------
    // Test 1: Write then Read (aligned)
    // ----------------------------------------------------------
    $display("=== Starting Write-Read Test ===");

    // Write value 0xDEADBEEF at address 0x1000
    write_addr = 32'h00001000;
    write_data = 32'hDEADBEEF;
    expected_data = write_data;
    start_write = 1;
    #10 start_write = 0;

    wait_write_done();
    $display("Write done at %t", $time);

    // Read from the same address
    read_addr = 32'h00001000;
    start_read = 1;
    #10 start_read = 0;

    wait_read_done();
    $display("Read done at %t, read_data = 0x%8h", $time, read_data);

    // Check
    if (read_data === expected_data) begin
      $display("PASS: read_data matches expected 0x%8h", expected_data);
    end else begin
      $display("FAIL: read_data = 0x%8h, expected = 0x%8h", read_data, expected_data);
      test_passed = 1'b0;
    end

    // ----------------------------------------------------------
    // Test 2: Unaligned Write then Read
    // ----------------------------------------------------------
    $display("=== Starting Unaligned Write-Read Test ===");
    write_addr = 32'h00001002;
    write_data = 32'hA5A5A5A5;
    expected_data = write_data;
    start_write = 1;
    #10 start_write = 0;

    wait_write_done();

    read_addr = 32'h00001002;
    start_read = 1;
    #10 start_read = 0;

    wait_read_done();

    if (read_data === expected_data) begin
      $display("PASS: unaligned read_data matches expected 0x%8h", expected_data);
    end else begin
      $display("FAIL: unaligned read_data = 0x%8h, expected = 0x%8h", read_data, expected_data);
      test_passed = 1'b0;
    end

    // ----------------------------------------------------------
    // Test 3: Partial write (WSTRB not all ones) – skipped for now
    // (Master currently always writes full word)
    // ----------------------------------------------------------

    // ----------------------------------------------------------
    // Summary
    // ----------------------------------------------------------
    if (test_passed) begin
      $display("=========================================");
      $display(" ALL TESTS PASSED ");
      $display("=========================================");
    end else begin
      $display("=========================================");
      $display(" SOME TESTS FAILED ");
      $display("=========================================");
    end

    #20 $finish;
  end

  // VCD dump
  initial begin
    $dumpfile("sim.vcd");
    $dumpvars(0, tb_top);
  end

endmodule
