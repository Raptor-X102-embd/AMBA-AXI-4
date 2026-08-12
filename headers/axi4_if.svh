`ifndef AXI4_IF
`define AXI4_IF

/* verilator lint_off UNUSEDSIGNAL */
interface axi4_if #(
  parameter ADDR_WIDTH = 32,
  parameter DATA_WIDTH = 32,
  parameter ID_WIDTH   = 4,
  parameter USER_WIDTH = 0
) (
  input logic ACLK,
  input logic ARESETn
);
    // Write Address Channel
    logic [ID_WIDTH-1:0]     AWID;
    logic [ADDR_WIDTH-1:0]   AWADDR;
    logic [7:0]              AWLEN;
    logic [2:0]              AWSIZE;
    logic [1:0]              AWBURST;
    logic                    AWLOCK;
    logic [3:0]              AWCACHE;
    logic [2:0]              AWPROT;
    logic [3:0]              AWQOS;
    logic [3:0]              AWREGION;
    logic [USER_WIDTH-1:0]   AWUSER; 
    logic                    AWVALID;
    logic                    AWREADY;

    // Write Data Channel
    logic [DATA_WIDTH-1:0]   WDATA;
    logic [DATA_WIDTH/8-1:0] WSTRB;
    logic                    WLAST;
    logic [USER_WIDTH-1:0]   WUSER;
    logic                    WVALID;
    logic                    WREADY;

    // Write Response Channel
    logic [ID_WIDTH-1:0]     BID;
    logic [1:0]              BRESP;
    logic [USER_WIDTH-1:0]   BUSER;
    logic                    BVALID;
    logic                    BREADY;

    // Read Address Channel
    logic [ID_WIDTH-1:0]     ARID;
    logic [ADDR_WIDTH-1:0]   ARADDR;
    logic [7:0]              ARLEN;
    logic [2:0]              ARSIZE;
    logic [1:0]              ARBURST;
    logic                    ARLOCK;
    logic [3:0]              ARCACHE;
    logic [2:0]              ARPROT;
    logic [3:0]              ARQOS;
    logic [3:0]              ARREGION;
    logic [USER_WIDTH-1:0]   ARUSER;
    logic                    ARVALID;
    logic                    ARREADY;

    // Read Data Channel
    logic [ID_WIDTH-1:0]     RID;
    logic [DATA_WIDTH-1:0]   RDATA;
    logic [1:0]              RRESP;
    logic                    RLAST;
    logic [USER_WIDTH-1:0]   RUSER;
    logic                    RVALID;
    logic                    RREADY;

    modport master (
        input ACLK, ARESETn,
        output AWID, AWADDR, AWLEN, AWSIZE, AWBURST, AWLOCK, AWCACHE, AWPROT,
               AWQOS, AWREGION, AWUSER, AWVALID,
        input  AWREADY,
        output WDATA, WSTRB, WLAST, WUSER, WVALID,
        input  WREADY,
        input  BID, BRESP, BUSER, BVALID,
        output BREADY,
        output ARID, ARADDR, ARLEN, ARSIZE, ARBURST, ARLOCK, ARCACHE, ARPROT,
               ARQOS, ARREGION, ARUSER, ARVALID,
        input  ARREADY,
        input  RID, RDATA, RRESP, RLAST, RUSER, RVALID,
        output RREADY
    );

    modport slave (
        input ACLK, ARESETn,
        input  AWID, AWADDR, AWLEN, AWSIZE, AWBURST, AWLOCK, AWCACHE, AWPROT,
               AWQOS, AWREGION, AWUSER, AWVALID,
        output AWREADY,
        input  WDATA, WSTRB, WLAST, WUSER, WVALID,
        output WREADY,
        output BID, BRESP, BUSER, BVALID,
        input  BREADY,
        input  ARID, ARADDR, ARLEN, ARSIZE, ARBURST, ARLOCK, ARCACHE, ARPROT,
               ARQOS, ARREGION, ARUSER, ARVALID,
        output ARREADY,
        output RID, RDATA, RRESP, RLAST, RUSER, RVALID,
        input  RREADY
    );

endinterface
/* verilator lint_off UNUSEDSIGNAL */

`endif
