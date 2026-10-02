// =============================================================================
// sa_array.sv -- ROWS x COLS grid of sa_pe
//
//            col 0        col 1             col COLS-1
//   row 0   [PE 0,0] -> [PE 0,1] -> ... -> [PE 0,C-1]       ps enters as 0
//              |            |                  |
//   row 1   [PE 1,0] -> [PE 1,1] -> ... -> [PE 1,C-1]
//              |            |                  |
//    ...       v            v                  v
//   row R-1 [PE R-1,0] ->  ...          -> [PE R-1,C-1]
//              |            |                  |
//            ps_bot[0]   ps_bot[1]  ...    ps_bot[C-1]   (one output per column)
//
// Row k is fed activation element k of each input row (already skewed by k
// cycles by sa_core), column n holds weight column n.  The partial sum that
// leaves the bottom of column n is C[m][n] = sum_k A[m][k] * B[k][n].
//
// Ports are flat packed vectors, so the same source works unchanged in every
// tool of the flow (Yosys, the simulators, Vivado).
// =============================================================================
module sa_array #(
    parameter int ROWS  = 4,
    parameter int COLS  = 4,
    parameter int DW    = 8,
    parameter int ACC_W = 32,
    localparam int RW   = (ROWS > 1) ? $clog2(ROWS) : 1
) (
    input  logic                  clk,
    input  logic                  rst_n,
    input  logic                  en,

    // weight write: one row of B per beat, into one bank
    input  logic                  w_we,
    input  logic                  w_bank,
    input  logic [RW-1:0]         w_row,
    input  logic [COLS*DW-1:0]    w_data,

    // skewed activations entering the left edge, one lane per row
    input  logic [ROWS-1:0]       a_vld,
    input  logic [ROWS-1:0]       a_bank,
    input  logic [ROWS-1:0]       a_last,
    input  logic [ROWS*DW-1:0]    a_data,

    // bottom edge: one partial sum per column, plus the side-band of the
    // activation that produced it (taken from the bottom row)
    output logic [COLS-1:0]       bot_vld,
    output logic [COLS-1:0]       bot_last,
    output logic [COLS*ACC_W-1:0] bot_ps,

    // the bottom-right PE is the LAST one to use a tile's weights; sa_core
    // watches it to know when a weight bank can be reloaded
    output logic                  br_consume,     // fires on the edge it multiplies
    output logic                  br_bank,
    output logic                  br_last,

    output logic                  ovf_any         // some PE overflowed (1 cycle late)
`ifdef FORMAL
    // the activation side-band at every PE input, for the proof invariants
    ,output logic [ROWS-1:0][COLS:0] f_vld
    ,output logic [ROWS-1:0][COLS:0] f_bank
    ,output logic [ROWS-1:0][COLS:0] f_last
`endif
);

    // horizontal (activation) and vertical (partial sum) nets
    // (fully packed arrays: every tool in the flow handles these the same way)
    logic [ROWS-1:0][COLS:0][DW-1:0]    a_h;
    logic [ROWS-1:0][COLS:0]            v_h;
    logic [ROWS-1:0][COLS:0]            b_h;
    logic [ROWS-1:0][COLS:0]            l_h;
    logic [ROWS:0][COLS-1:0][ACC_W-1:0] ps_v;
    logic [ROWS*COLS-1:0]               ovf;

    genvar r, c;
    generate
        for (r = 0; r < ROWS; r++) begin : g_left
            assign a_h[r][0] = a_data[r*DW +: DW];
            assign v_h[r][0] = a_vld[r];
            assign b_h[r][0] = a_bank[r];
            assign l_h[r][0] = a_last[r];
        end
        for (c = 0; c < COLS; c++) begin : g_top
            assign ps_v[0][c] = '0;
        end

        for (r = 0; r < ROWS; r++) begin : g_row
            for (c = 0; c < COLS; c++) begin : g_col
                sa_pe #(.DW(DW), .ACC_W(ACC_W)) u_pe (
                    .clk      (clk),
                    .rst_n    (rst_n),
                    .en       (en),
                    .w_we     (w_we && (w_row == RW'(r))),
                    .w_bank   (w_bank),
                    .w_data   (w_data[c*DW +: DW]),
                    .a_vld_i  (v_h[r][c]),
                    .a_bank_i (b_h[r][c]),
                    .a_last_i (l_h[r][c]),
                    .a_i      (a_h[r][c]),
                    .ps_i     (ps_v[r][c]),
                    .a_vld_o  (v_h[r][c+1]),
                    .a_bank_o (b_h[r][c+1]),
                    .a_last_o (l_h[r][c+1]),
                    .a_o      (a_h[r][c+1]),
                    .ps_o     (ps_v[r+1][c]),
                    .ovf_o    (ovf[r*COLS + c])
                );
            end
        end

        // The bottom row's activation side-band leaves each PE one cycle
        // before the partial sum it belongs to (the MAC has two stages), so it
        // is registered once more here to label that partial sum.
        for (c = 0; c < COLS; c++) begin : g_bot
            logic vld_q, last_q;
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n)  vld_q <= 1'b0;
                else if (en) vld_q <= v_h[ROWS-1][c+1];
            end
            always_ff @(posedge clk) begin
                if (en) last_q <= l_h[ROWS-1][c+1];
            end
            assign bot_vld[c]                = vld_q;
            assign bot_last[c]               = last_q;
            assign bot_ps[c*ACC_W +: ACC_W]  = ps_v[ROWS][c];
        end
    endgenerate

    assign br_consume = en && v_h[ROWS-1][COLS-1];
    assign br_bank    = b_h[ROWS-1][COLS-1];
    assign br_last    = l_h[ROWS-1][COLS-1];
    // Each PE's overflow flag is registered before the array-wide OR.  The
    // first implementation ORed the raw flags straight into ovf_sticky, and
    // that path (multiply -> add -> overflow test -> 16-input OR) was the
    // critical path of the whole design.  A status flag can be a cycle late.
    logic [ROWS*COLS-1:0] ovf_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)  ovf_q <= '0;
        else         ovf_q <= en ? ovf : '0;
    end
    assign ovf_any    = |ovf_q;

`ifdef FORMAL
    assign f_vld  = v_h;
    assign f_bank = b_h;
    assign f_last = l_h;
`endif

endmodule
