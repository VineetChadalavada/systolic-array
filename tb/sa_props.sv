// =============================================================================
// sa_props.sv -- properties of sa_core, shared by simulation and formal
//
// Bound to sa_core (see the bind at the bottom of tb_sa_core.sv and the
// formal wrapper), so it sees every internal signal without the design
// having to export anything.
//
// The same five properties are written twice:
//   * concurrent SVA (assert property) for the simulators
//   * clocked immediate assertions with $past for SymbiYosys, because the
//     open-source Yosys front end only understands that subset
//
//   P1  a weight bank is never written while an activation that will use it
//       is still inside the array            (the double-buffering safety rule)
//   P2  C obeys AXI4-Stream: once c_valid is high it stays high, with c_data
//       and c_last stable, until c_ready
//   P3  the result FIFO never overflows or underflows
//   P4  an activation row is only accepted when its weight bank holds the
//       weights of ITS tile (loaded and not yet used by an earlier tile)
//   P5  no accumulator overflow (only reachable if ACC_W is undersized)
// =============================================================================
module sa_props #(
    parameter int ROWS  = 4,
    parameter int COLS  = 4,
    parameter int ACC_W = 32,
    parameter bit EXPECT_NO_OVF = 1
) (
    input logic                  clk,
    input logic                  rst_n,
    input logic                  w_fire,
    input logic                  wr_bank,
    input logic                  a_fire,
    input logic                  rd_bank,
    input logic                  br_consume,
    input logic                  br_bank,
    input logic [1:0]            bank_full,
    input logic [1:0]            bank_fresh,
    input logic                  c_valid,
    input logic                  c_ready,
    input logic [COLS*ACC_W-1:0] c_data,
    input logic                  c_last,
    input logic [1:0]            fifo_cnt,
    input logic                  push,
    input logic                  pop,
    input logic                  ovf_sticky
`ifdef FORMAL
   ,input logic                  rd_ptr
   ,input logic                  wr_ptr
   ,input logic [ROWS-1:0][ROWS-1:0] f_sk_v      // skew lane r, stage t
   ,input logic [ROWS-1:0][ROWS-1:0] f_sk_b
   ,input logic [ROWS-1:0][ROWS-1:0] f_sk_l
   ,input logic [ROWS-1:0][COLS:0]   f_pe_v      // input of PE(r, c)
   ,input logic [ROWS-1:0][COLS:0]   f_pe_b
   ,input logic [ROWS-1:0][COLS:0]   f_pe_l
`endif
);

    // ---- auxiliary state: rows inside the array, per weight bank ------------
    // +1 when a row tagged with bank b is accepted, -1 when the bottom-right PE
    // (the last one to multiply it) consumes it.  At most ROWS+COLS rows can
    // be in flight, so 8 bits is plenty for any configuration we build.
    logic [7:0] inflight [2];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            inflight[0] <= '0;
            inflight[1] <= '0;
        end else begin
            for (int b = 0; b < 2; b++)
                inflight[b] <= inflight[b]
                             + 8'((a_fire && rd_bank == b[0]) ? 1 : 0)
                             - 8'((br_consume && br_bank == b[0]) ? 1 : 0);
        end
    end

`ifdef FORMAL
    // ---- SymbiYosys style -----------------------------------------------------
    logic past_valid = 1'b0;
    always_ff @(posedge clk) past_valid <= 1'b1;

    // Every activation lane is a chain of registers indexed by AGE: how many
    // (enabled) cycles ago the row was accepted.  Lane r holds ages 1..r in
    // its skew stages and ages r..r+COLS-1 at the inputs of PE(r,0..COLS-1).
    // The bottom-right PE, the last user of a row, sees it at age LAST_AGE.
    localparam int LAST_AGE = ROWS + COLS - 2;
    localparam int NAGE     = LAST_AGE + 1;

    // ag_x[r][t] : side-band bit x of the row of age t in lane r (t >= 1)
    logic [ROWS-1:0][NAGE-1:0] ag_v, ag_b, ag_l;
    genvar gr, gt;
    generate
        for (gr = 0; gr < ROWS; gr++) begin : g_lane
            for (gt = 0; gt < NAGE; gt++) begin : g_age
                if (gt == 0 || gt > gr + COLS - 1) begin : g_none
                    assign ag_v[gr][gt] = 1'b0;
                    assign ag_b[gr][gt] = 1'b0;
                    assign ag_l[gr][gt] = 1'b0;
                end else if (gt < gr) begin : g_skew
                    assign ag_v[gr][gt] = f_sk_v[gr][gt-1];
                    assign ag_b[gr][gt] = f_sk_b[gr][gt-1];
                    assign ag_l[gr][gt] = f_sk_l[gr][gt-1];
                end else begin : g_pe
                    assign ag_v[gr][gt] = f_pe_v[gr][gt-gr];
                    assign ag_b[gr][gt] = f_pe_b[gr][gt-gr];
                    assign ag_l[gr][gt] = f_pe_l[gr][gt-gr];
                end
            end
        end
    endgenerate

    // rows of each bank in the longest lane, ages 1..LAST_AGE
    logic [7:0] lane_cnt [2];
    logic       has_last [2];
    always_comb begin
        for (int b = 0; b < 2; b++) begin
            lane_cnt[b] = '0;
            has_last[b] = 1'b0;
            for (int t = 1; t <= LAST_AGE; t++)
                if (ag_v[ROWS-1][t] && ag_b[ROWS-1][t] == b[0]) begin
                    lane_cnt[b] = lane_cnt[b] + 8'd1;
                    if (ag_l[ROWS-1][t]) has_last[b] = 1'b1;
                end
        end
    end

    always_comb begin
        if (rst_n) begin
            // ------------------------- the properties --------------------------
            // P1  no weight write into a bank with rows still to be multiplied
            if (w_fire) assert (inflight[wr_bank] == 0);
            // P3  FIFO bounds
            assert (fifo_cnt <= 2);
            if (push)  assert (fifo_cnt != 2);
            if (pop)   assert (fifo_cnt != 0);
            // P4  rows only use weights loaded for their own tile
            if (a_fire) assert (bank_full[rd_bank] && bank_fresh[rd_bank]);
`ifdef CHECK_OVF
            // P5  (bounded check only: induction would start from arbitrary
            //      partial sums, so this one is not part of the unbounded proof)
            if (EXPECT_NO_OVF) assert (!ovf_sticky);
`endif

            // ------------- invariants that make the proof inductive -------------
            // I1  all lanes carry the same row at the same age
            for (int r = 0; r < ROWS - 1; r++)
                for (int t = 1; t <= r + COLS - 1; t++) begin
                    assert (ag_v[r][t] == ag_v[ROWS-1][t]);
                    if (ag_v[r][t]) begin
                        assert (ag_b[r][t] == ag_b[ROWS-1][t]);
                        assert (ag_l[r][t] == ag_l[ROWS-1][t]);
                    end
                end
            for (int b = 0; b < 2; b++) begin
                // I2  the in-flight counter is exact
                assert (inflight[b] == lane_cnt[b]);
                // I3  an empty bank has nothing in flight and is not fresh
                if (!bank_full[b]) assert (inflight[b] == 0 && !bank_fresh[b]);
                // I4  only the bank being streamed can be fresh with rows in flight
                if (bank_fresh[b] && rd_bank != b[0]) assert (inflight[b] == 0);
                // I5  a fresh bank has not seen its last row yet ...
                if (bank_fresh[b]) assert (!has_last[b]);
                // I6  ... and a full, no-longer-fresh bank still has it in flight
                if (bank_full[b] && !bank_fresh[b]) assert (has_last[b]);
            end
            // I7  the last row of a bank is its youngest row in flight
            for (int t = 1; t <= LAST_AGE; t++)
                if (ag_v[ROWS-1][t] && ag_l[ROWS-1][t])
                    for (int u = 1; u < t; u++)
                        if (ag_v[ROWS-1][u])
                            assert (ag_b[ROWS-1][u] != ag_b[ROWS-1][t]);
            // I8  FIFO pointers agree with the count
            if (fifo_cnt == 1) assert (wr_ptr != rd_ptr);
            else               assert (wr_ptr == rd_ptr);
        end
    end

    always_ff @(posedge clk) begin
        if (past_valid && rst_n && $past(rst_n)) begin
            // P2  C holds still while stalled
            if ($past(c_valid && !c_ready)) begin
                assert (c_valid);
                assert (c_data == $past(c_data));
                assert (c_last == $past(c_last));
            end
        end
    end
`else
    // ---- simulator style ------------------------------------------------------
    p1_no_bank_overwrite: assert property (@(posedge clk) disable iff (!rst_n)
        w_fire |-> inflight[wr_bank] == 0)
        else $error("P1: weight bank %0d overwritten with %0d rows in flight",
                    wr_bank, inflight[wr_bank]);

    p2_c_stable: assert property (@(posedge clk) disable iff (!rst_n)
        c_valid && !c_ready |=> c_valid && $stable(c_data) && $stable(c_last))
        else $error("P2: C changed or dropped valid while stalled");

    p3_fifo_bounds: assert property (@(posedge clk) disable iff (!rst_n)
        (fifo_cnt <= 2) && !(push && fifo_cnt == 2) && !(pop && fifo_cnt == 0))
        else $error("P3: result FIFO overflow / underflow");

    p4_bank_loaded: assert property (@(posedge clk) disable iff (!rst_n)
        a_fire |-> bank_full[rd_bank] && bank_fresh[rd_bank])
        else $error("P4: activation accepted with no weights loaded");

    p5_no_ovf: assert property (@(posedge clk) disable iff (!rst_n)
        EXPECT_NO_OVF |-> !ovf_sticky)
        else $error("P5: accumulator overflow");
`endif

endmodule
