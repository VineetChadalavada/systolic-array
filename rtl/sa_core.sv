// =============================================================================
// sa_core.sv -- weight-stationary INT8 systolic array, top level
//
// Computes, tile by tile,       C[m][n] = sum_k A[m][k] * B[k][n]
//     B : ROWS x COLS weight tile   (loaded, then held stationary)
//     A : M x ROWS activations      (streamed, any number of rows M per tile)
//     C : M x COLS results          (streamed out, one row per beat)
//
// Three valid/ready interfaces (AXI4-Stream semantics):
//
//   W  weights      w_row, w_data = row w_row of B (COLS bytes), w_last on
//                   the final row of a tile.  ROWS beats per tile.
//   A  activations  a_data = one row of A (ROWS bytes), a_last on the last
//                   row of the tile.  Uses the most recently completed B.
//   C  results      c_data = one row of C (COLS x ACC_W bits), c_last marks
//                   the row produced by a_last.
//
// Microarchitecture
//
//   W --> [bank control] --w_we/bank/row--> PE weight registers (2 banks)
//
//   A --> [skew: row k delayed k] --> [ ROWS x COLS PE array ] -->
//         [deskew: col n delayed COLS-1-n] --> [2-entry FIFO] --> C
//
//   * Double buffering.  Tile t+1's weights load into the idle bank while tile
//     t streams.  A 1-bit bank tag rides along with every activation, so the
//     array never stops to "swap"; for M >= ROWS the array stays 100% busy
//     across tile boundaries.
//   * Bank release.  A bank is marked free (reloadable) on the clock edge
//     where the bottom-right PE -- the last PE to see any row of the tile --
//     multiplies the tile's last row.  Overwriting a bank that is still in use
//     is therefore impossible; formal/ proves it.
//   * Backpressure.  The whole array advances on a single enable,
//     en = (output FIFO not full).  The FIFO count is a register, so there is
//     NO combinational path from c_ready to a_ready.  Two entries are enough
//     for full throughput.
// =============================================================================
module sa_core #(
    parameter int ROWS        = 4,
    parameter int COLS        = 4,
    parameter int DW          = 8,
    parameter int ACC_W       = 32,
    parameter bit CHECK_ACC_W = 1,      // 0 only to test the overflow flag
    localparam int RW         = (ROWS > 1) ? $clog2(ROWS) : 1
) (
    input  logic                  clk,
    input  logic                  rst_n,

    // W: weight rows
    input  logic                  w_valid,
    output logic                  w_ready,
    input  logic [RW-1:0]         w_row,
    input  logic [COLS*DW-1:0]    w_data,
    input  logic                  w_last,

    // A: activation rows
    input  logic                  a_valid,
    output logic                  a_ready,
    input  logic [ROWS*DW-1:0]    a_data,
    input  logic                  a_last,

    // C: result rows
    output logic                  c_valid,
    input  logic                  c_ready,
    output logic [COLS*ACC_W-1:0] c_data,
    output logic                  c_last,

    // status
    output logic                  ovf_sticky,   // an accumulator ever overflowed
    output logic [1:0]            bank_full     // per-bank "loaded, not yet retired"
);

    // ------------------------------------------------------------------
    // Elaboration-time guarantee: worst case |sum| = ROWS * 128 * 128 must fit
    // in a signed ACC_W.  Instantiating a module that does not exist is the
    // portable way to stop every tool (Yosys, Verilator, Vivado) with an error.
    // ------------------------------------------------------------------
    generate
        if (CHECK_ACC_W && (ACC_W < 2*DW + $clog2(ROWS))) begin : g_acc_check
            ERROR_ACC_W_too_small_for_ROWS u_error ();
        end
    endgenerate

    // ------------------------------------------------------------------
    // global enable: advance the array only if the result FIFO has room
    // ------------------------------------------------------------------
    logic [1:0] fifo_cnt;
    logic       en;
    assign en = (fifo_cnt != 2'd2);

    // ------------------------------------------------------------------
    // weight bank control
    // ------------------------------------------------------------------
    // Two flags per bank -- one is not enough (an earlier version had only
    // bank_full, and assertion P1 caught activations of the NEXT tile being
    // accepted against a bank still holding the PREVIOUS tile's weights):
    //   bank_full  : weights loaded and not yet retired  -> blocks W writes
    //   bank_fresh : loaded, and its activation tile not yet fully accepted
    //                                                    -> allows A rows
    logic [1:0] bank_fresh;
    logic wr_bank;        // bank the W port is filling
    logic rd_bank;        // bank new activation rows are tagged with
    logic w_fire, a_fire;
    logic br_consume, br_bank, br_last;

    assign w_ready = !bank_full[wr_bank];
    assign a_ready = en && bank_fresh[rd_bank];
    assign w_fire  = w_valid && w_ready;
    assign a_fire  = a_valid && a_ready;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bank_full  <= 2'b00;
            bank_fresh <= 2'b00;
            wr_bank    <= 1'b0;
            rd_bank   <= 1'b0;
        end else begin
            // retire: the last row of the tile has just been used by the
            // bottom-right PE, so nothing will read this bank again
            if (br_consume && br_last)
                bank_full[br_bank] <= 1'b0;
            // load complete (cannot be the bank being retired: w_ready
            // requires it to be free already)
            if (w_fire && w_last) begin
                bank_full[wr_bank]  <= 1'b1;
                bank_fresh[wr_bank] <= 1'b1;
                wr_bank             <= ~wr_bank;
            end
            // the tile's last row is in: no more rows may use this bank
            if (a_fire && a_last) begin
                bank_fresh[rd_bank] <= 1'b0;
                rd_bank             <= ~rd_bank;
            end
        end
    end

    // ------------------------------------------------------------------
    // input skew: lane k is delayed by k cycles so that row m meets the
    // partial sum for row m in every PE
    // ------------------------------------------------------------------
    logic [ROWS-1:0]       sk_vld, sk_bank, sk_last;
    logic [ROWS*DW-1:0]    sk_data;
`ifdef FORMAL
    // skew register contents, lane r stage t, for the proof invariants
    logic [ROWS-1:0][ROWS-1:0] f_sk_v, f_sk_b, f_sk_l;
`endif

    genvar r, c;
    generate
        for (r = 0; r < ROWS; r++) begin : g_skew
            if (r == 0) begin : g_direct
`ifdef FORMAL
                assign f_sk_v[0] = '0;
                assign f_sk_b[0] = '0;
                assign f_sk_l[0] = '0;
`endif
                assign sk_vld[0]       = a_fire;
                assign sk_bank[0]      = rd_bank;
                assign sk_last[0]      = a_last;
                assign sk_data[0 +: DW] = a_data[0 +: DW];
            end else begin : g_delay
                // flat vectors + "+:" part-selects: every tool in the flow
                // (Yosys included) accepts these inside a generate block
                logic [r-1:0]    v_q, b_q, l_q;
                logic [r*DW-1:0] d_q;
                always_ff @(posedge clk or negedge rst_n) begin
                    if (!rst_n) begin
                        v_q <= '0;
                    end else if (en) begin
                        v_q[0] <= a_fire;
                        for (int i = 1; i < r; i++)
                            v_q[i] <= v_q[i-1];
                    end
                end
                always_ff @(posedge clk) begin
                    if (en) begin
                        b_q[0] <= rd_bank;
                        l_q[0] <= a_last;
                        d_q[0 +: DW] <= a_data[r*DW +: DW];
                        for (int i = 1; i < r; i++) begin
                            b_q[i]         <= b_q[i-1];
                            l_q[i]         <= l_q[i-1];
                            d_q[i*DW +: DW] <= d_q[(i-1)*DW +: DW];
                        end
                    end
                end
`ifdef FORMAL
                assign f_sk_v[r] = ROWS'(v_q);
                assign f_sk_b[r] = ROWS'(b_q);
                assign f_sk_l[r] = ROWS'(l_q);
`endif
                assign sk_vld[r]          = v_q[r-1];
                assign sk_bank[r]         = b_q[r-1];
                assign sk_last[r]         = l_q[r-1];
                assign sk_data[r*DW +: DW] = d_q[(r-1)*DW +: DW];
            end
        end
    endgenerate

    // ------------------------------------------------------------------
    // the array
    // ------------------------------------------------------------------
    logic [COLS-1:0]       bot_vld, bot_last;
    logic [COLS*ACC_W-1:0] bot_ps;
    logic                  ovf_any;
`ifdef FORMAL
    logic [ROWS-1:0][COLS:0] f_pe_v, f_pe_b, f_pe_l;
`endif

    sa_array #(.ROWS(ROWS), .COLS(COLS), .DW(DW), .ACC_W(ACC_W)) u_array (
        .clk        (clk),
        .rst_n      (rst_n),
        .en         (en),
        .w_we       (w_fire),
        .w_bank     (wr_bank),
        .w_row      (w_row),
        .w_data     (w_data),
        .a_vld      (sk_vld),
        .a_bank     (sk_bank),
        .a_last     (sk_last),
        .a_data     (sk_data),
        .bot_vld    (bot_vld),
        .bot_last   (bot_last),
        .bot_ps     (bot_ps),
        .br_consume (br_consume),
        .br_bank    (br_bank),
        .br_last    (br_last),
        .ovf_any    (ovf_any)
`ifdef FORMAL
       ,.f_vld      (f_pe_v)
       ,.f_bank     (f_pe_b)
       ,.f_last     (f_pe_l)
`endif
    );

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)       ovf_sticky <= 1'b0;
        else if (ovf_any) ovf_sticky <= 1'b1;
    end

    // ------------------------------------------------------------------
    // output deskew: column n is delayed COLS-1-n cycles, so all COLS
    // results of one row line up with column COLS-1's
    // ------------------------------------------------------------------
    logic [COLS*ACC_W-1:0] row_data;
    logic                  row_vld, row_last;

    generate
        for (c = 0; c < COLS; c++) begin : g_deskew
            localparam int D = COLS - 1 - c;
            if (D == 0) begin : g_direct
                assign row_data[c*ACC_W +: ACC_W] = bot_ps[c*ACC_W +: ACC_W];
            end else begin : g_delay
                logic [D*ACC_W-1:0] d_q;
                always_ff @(posedge clk) begin
                    if (en) begin
                        d_q[0 +: ACC_W] <= bot_ps[c*ACC_W +: ACC_W];
                        for (int i = 1; i < D; i++)
                            d_q[i*ACC_W +: ACC_W] <= d_q[(i-1)*ACC_W +: ACC_W];
                    end
                end
                assign row_data[c*ACC_W +: ACC_W] = d_q[(D-1)*ACC_W +: ACC_W];
            end
        end
    endgenerate

    // column COLS-1 has no deskew delay, so its side-band labels the row
    assign row_vld  = bot_vld[COLS-1];
    assign row_last = bot_last[COLS-1];

    // ------------------------------------------------------------------
    // 2-entry result FIFO (doubles as the skid buffer)
    // ------------------------------------------------------------------
    logic [COLS*ACC_W:0]      fifo_q0, fifo_q1;   // {last, data}
    logic                     rd_ptr, wr_ptr;
    logic                     push, pop;

    assign push    = en && row_vld;
    assign pop     = c_valid && c_ready;
    assign c_valid = (fifo_cnt != 2'd0);
    assign {c_last, c_data} = rd_ptr ? fifo_q1 : fifo_q0;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fifo_cnt <= 2'd0;
            rd_ptr   <= 1'b0;
            wr_ptr   <= 1'b0;
        end else begin
            if (push) wr_ptr <= ~wr_ptr;
            if (pop)  rd_ptr <= ~rd_ptr;
            case ({push, pop})
                2'b10:   fifo_cnt <= fifo_cnt + 2'd1;
                2'b01:   fifo_cnt <= fifo_cnt - 2'd1;
                default: fifo_cnt <= fifo_cnt;
            endcase
        end
    end

    always_ff @(posedge clk) begin
        if (push && !wr_ptr) fifo_q0 <= {row_last, row_data};
        if (push &&  wr_ptr) fifo_q1 <= {row_last, row_data};
    end

`ifdef FORMAL
    // Formal: the checker is instantiated here (simulation binds it instead),
    // because the open-source Yosys front end has no hierarchical references.
    sa_props #(.ROWS(ROWS), .COLS(COLS), .ACC_W(ACC_W), .EXPECT_NO_OVF(CHECK_ACC_W)) u_props (
        .clk(clk), .rst_n(rst_n), .w_fire(w_fire), .wr_bank(wr_bank), .a_fire(a_fire),
        .rd_bank(rd_bank), .br_consume(br_consume), .br_bank(br_bank),
        .bank_full(bank_full), .bank_fresh(bank_fresh),
        .c_valid(c_valid), .c_ready(c_ready), .c_data(c_data), .c_last(c_last),
        .fifo_cnt(fifo_cnt), .push(push), .pop(pop), .ovf_sticky(ovf_sticky),
        .rd_ptr(rd_ptr), .wr_ptr(wr_ptr),
        .f_sk_v(f_sk_v), .f_sk_b(f_sk_b), .f_sk_l(f_sk_l),
        .f_pe_v(f_pe_v), .f_pe_b(f_pe_b), .f_pe_l(f_pe_l));
`endif

endmodule
