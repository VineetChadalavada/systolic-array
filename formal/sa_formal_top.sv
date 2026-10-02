// =============================================================================
// sa_formal_top.sv -- formal harness for sa_core
//
// Every input is left free (the solver picks any value on every cycle), so
// the properties in tb/sa_props.sv must hold for ANY traffic, including
// traffic that breaks the AXI4-Stream rules.  The only assumption is a reset
// in the first cycle.
//
// A small array is used because the properties are about control, which is
// identical at every size; 2 rows x 3 columns keeps it asymmetric.
// =============================================================================
module sa_formal_top #(
    parameter int ROWS  = 2,
    parameter int COLS  = 3,
    parameter int DW    = 8,
    parameter int ACC_W = 32,
    localparam int RW   = (ROWS > 1) ? $clog2(ROWS) : 1
) (
    input  logic                  clk,
    input  logic                  rst_n,
    input  logic                  w_valid,
    input  logic [RW-1:0]         w_row,
    input  logic [COLS*DW-1:0]    w_data,
    input  logic                  w_last,
    input  logic                  a_valid,
    input  logic [ROWS*DW-1:0]    a_data,
    input  logic                  a_last,
    input  logic                  c_ready
);
    logic                  w_ready, a_ready, c_valid, c_last, ovf_sticky;
    logic [COLS*ACC_W-1:0] c_data;
    logic [1:0]            bank_full;

    sa_core #(.ROWS(ROWS), .COLS(COLS), .DW(DW), .ACC_W(ACC_W)) dut (.*);

    // reset in the first cycle, then run
    logic init = 1'b1;
    always_ff @(posedge clk) init <= 1'b0;
    always_comb if (init) assume (!rst_n);
    always_comb if (!init) assume (rst_n);

    // reachability: show that the interesting situations can happen at all
    always_ff @(posedge clk) begin
        if (rst_n) begin
            cover (bank_full == 2'b11);                 // both banks loaded
            cover (w_valid && w_ready && a_valid && a_ready);   // load during compute
            cover (c_valid && c_last);                  // a whole tile came out
            cover (c_valid && !c_ready && !a_ready);    // backpressure reached the input
        end
    end
endmodule
