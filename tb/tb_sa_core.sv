// =============================================================================
// tb_sa_core.sv -- self-checking testbench for sa_core
//
// Runs unchanged on Verilator (--timing) and on Vivado xsim.
//
//   generator    builds tiles: a random ROWS x COLS weight tile B and M random
//                activation rows A, and computes the expected C = A x B
//                (the golden model is plain integer arithmetic, below)
//   W driver     sends B row by row      \   valid/ready, random idle gaps,
//   A driver     sends A row by row       >  AXI4-Stream rules (valid held
//   C sink       random c_ready          /   until accepted)
//   scoreboard   compares every C beat with the expected row, in order
//
// Phases
//   1 directed      identity weights, then all-ones
//   2 corners       -128 x -128 (largest product), 127 x -128, mixed signs
//   3 random        many tiles, random M, random gaps and backpressure
//   4 throughput    back-to-back tiles, no gaps, c_ready=1: measures how busy
//                   the array is, for long and for short tiles
//   (OVF_TEST build) a deliberately undersized accumulator must raise ovf
//
// Exit: prints PASS / FAIL; $fatal on failure so scripts see a non-zero code.
// =============================================================================
`timescale 1ns/1ps

`ifndef ROWS
  `define ROWS 4
`endif
`ifndef COLS
  `define COLS 4
`endif
`ifndef SEED
  `define SEED 1
`endif

module tb_sa_core;

    localparam int ROWS  = `ROWS;
    localparam int COLS  = `COLS;
    localparam int DW    = 8;
`ifdef OVF_TEST
    localparam int ACC_W = 16;          // too small on purpose
`else
    localparam int ACC_W = 32;
`endif
    localparam int RW    = (ROWS > 1) ? $clog2(ROWS) : 1;

    // ------------------------------------------------------------------
    // clock, reset, DUT
    // ------------------------------------------------------------------
    logic clk = 1'b0;
    logic rst_n;
    always #5 clk = ~clk;                // 100 MHz in simulation time

    logic                  w_valid = 0, w_ready, w_last = 0;
    logic [RW-1:0]         w_row = '0;
    logic [COLS*DW-1:0]    w_data = '0;
    logic                  a_valid = 0, a_ready, a_last = 0;
    logic [ROWS*DW-1:0]    a_data = '0;
    logic                  c_valid, c_ready = 0, c_last;
    logic [COLS*ACC_W-1:0] c_data;
    logic                  ovf_sticky;
    logic [1:0]            bank_full;

    sa_core #(.ROWS(ROWS), .COLS(COLS), .DW(DW), .ACC_W(ACC_W)
`ifdef OVF_TEST
              , .CHECK_ACC_W(0)
`endif
    ) dut (.*);

    // ------------------------------------------------------------------
    // transaction queues
    // ------------------------------------------------------------------
    typedef struct packed { logic [RW-1:0] row; logic [COLS*DW-1:0] data; logic last; } w_beat_t;
    typedef struct packed { logic [ROWS*DW-1:0] data; logic last; }                     a_beat_t;
    typedef struct packed { logic [COLS*ACC_W-1:0] data; logic last; }                  c_beat_t;

    w_beat_t wq[$];
    a_beat_t aq[$];
    c_beat_t cq[$];

    // knobs the phases turn
    int w_gap_pct = 0, a_gap_pct = 0, c_ready_pct = 100;

    // statistics
    int  n_tiles = 0, n_rows = 0, n_checked = 0, n_errors = 0;
    longint cyc = 0;

    // ------------------------------------------------------------------
    // golden model + generator
    // ------------------------------------------------------------------
    int b_mat [ROWS][COLS];

    function automatic logic signed [DW-1:0] rnd8();
        return DW'($urandom_range(255));
    endfunction

    // queue one tile: weights from b_mat, M activation rows; mode picks values
    //   0 random  1 all -128  2 a=127 w=-128  3 a=-128 w=127
    task automatic add_tile(int m_rows, int mode);
        w_beat_t wb;
        a_beat_t ab;
        c_beat_t cb;
        int      a_row [ROWS];
        longint  acc;

        for (int k = 0; k < ROWS; k++) begin
            wb.row  = RW'(k);
            wb.last = (k == ROWS - 1);
            for (int n = 0; n < COLS; n++) begin
                wb.data[n*DW +: DW] = DW'(b_mat[k][n]);
            end
            wq.push_back(wb);
        end
        for (int m = 0; m < m_rows; m++) begin
            for (int k = 0; k < ROWS; k++) begin
                case (mode)
                    1:       a_row[k] = -128;
                    2:       a_row[k] = 127;
                    3:       a_row[k] = -128;
                    default: a_row[k] = int'(rnd8());
                endcase
                ab.data[k*DW +: DW] = DW'(a_row[k]);
            end
            ab.last = (m == m_rows - 1);
            aq.push_back(ab);
            for (int n = 0; n < COLS; n++) begin
                acc = 0;
                for (int k = 0; k < ROWS; k++)
                    acc += longint'(a_row[k]) * longint'(b_mat[k][n]);
                cb.data[n*ACC_W +: ACC_W] = ACC_W'(acc);
            end
            cb.last = ab.last;
            cq.push_back(cb);
        end
        n_tiles++;
        n_rows += m_rows;
    endtask

    function automatic void set_weights(int mode);
        for (int k = 0; k < ROWS; k++)
            for (int n = 0; n < COLS; n++)
                case (mode)
                    0: b_mat[k][n] = int'(rnd8());
                    1: b_mat[k][n] = -128;
                    2: b_mat[k][n] = -128;
                    3: b_mat[k][n] = 127;
                    4: b_mat[k][n] = (k == n) ? 1 : 0;      // identity
                    5: b_mat[k][n] = 1;
                    default: b_mat[k][n] = 0;
                endcase
    endfunction

    // ------------------------------------------------------------------
    // drivers (synchronous, race-free: everything updates on the clock)
    // ------------------------------------------------------------------
    // NOTE: the beat variables are declared here and assigned below.  Writing
    // "w_beat_t b = wq.pop_front();" inside the always block would declare a
    // STATIC variable whose initialiser runs once, at time zero -- the driver
    // would resend the first beat forever.  (Found that the hard way.)
    w_beat_t w_nxt;
    a_beat_t a_nxt;

    always @(posedge clk) begin
        cyc <= cyc + 1;
        if (rst_n) begin
            // W: a beat may change only after it was accepted (or if idle)
            if (!w_valid || w_ready) begin
                if (wq.size() > 0 && $urandom_range(99) >= w_gap_pct) begin
                    w_nxt    = wq.pop_front();
                    w_valid <= 1'b1;
                    w_row   <= w_nxt.row;
                    w_data  <= w_nxt.data;
                    w_last  <= w_nxt.last;
                end else begin
                    w_valid <= 1'b0;
                end
            end
            // A
            if (!a_valid || a_ready) begin
                if (aq.size() > 0 && $urandom_range(99) >= a_gap_pct) begin
                    a_nxt    = aq.pop_front();
                    a_valid <= 1'b1;
                    a_data  <= a_nxt.data;
                    a_last  <= a_nxt.last;
                end else begin
                    a_valid <= 1'b0;
                end
            end
            // C: random backpressure
            c_ready <= ($urandom_range(99) < c_ready_pct);
        end
    end

    // ------------------------------------------------------------------
    // scoreboard
    // ------------------------------------------------------------------
    c_beat_t exp;
    always @(posedge clk) begin
        if (rst_n && c_valid && c_ready) begin
            if (cq.size() == 0) begin
                $error("unexpected C beat %h", c_data);
                n_errors++;
            end else begin
                exp = cq.pop_front();
                n_checked++;
                if (exp.data !== c_data || exp.last !== c_last) begin
                    n_errors++;
                    if (n_errors <= 10) begin
                        $display("MISMATCH at cycle %0d, result row %0d", cyc, n_checked);
                        for (int n = 0; n < COLS; n++)
                            $display("   C[%0d]  got %0d  expected %0d", n,
                                     $signed(c_data[n*ACC_W +: ACC_W]),
                                     $signed(exp.data[n*ACC_W +: ACC_W]));
                        $display("   last got %0b expected %0b", c_last, exp.last);
                    end
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // functional coverage (plain counters: portable across simulators)
    // ------------------------------------------------------------------
    int cov_backpressure = 0;   // C valid but not ready
    int cov_overlap      = 0;   // weights loading while activations stream
    int cov_bank_both    = 0;   // both banks loaded at once
    int cov_stall        = 0;   // array frozen by a full FIFO
    int cov_last_bank[2] = '{0, 0};
    int cov_w_wait       = 0;   // weight writer blocked: both banks busy

    always @(posedge clk) begin
        if (rst_n) begin
            if (c_valid && !c_ready)      cov_backpressure++;
            if (w_valid && w_ready && a_valid && a_ready) cov_overlap++;
            if (bank_full == 2'b11)       cov_bank_both++;
            if (!dut.en)                  cov_stall++;
            if (w_valid && !w_ready)      cov_w_wait++;
            if (a_valid && a_ready && a_last) cov_last_bank[dut.rd_bank]++;
        end
    end

`ifdef TB_DEBUG
    always @(posedge clk)
        if (rst_n && cyc < 80)
            $display("%4d  W v%0b r%0b row%0d last%0b | A v%0b r%0b last%0b | C v%0b r%0b | en%0b full%b wr%0b rd%0b sk_vld%b bot_vld%b",
                     cyc, w_valid, w_ready, w_row, w_last, a_valid, a_ready, a_last,
                     c_valid, c_ready, dut.en, bank_full, dut.wr_bank, dut.rd_bank,
                     dut.sk_vld, dut.bot_vld);
    always @(posedge clk)
        if (rst_n && cyc < 80 && (dut.w_fire || (dut.br_consume)))
            $display("%4d  EVENT w_fire%0b wbank%0b wlast%0b | br_consume%0b br_bank%0b br_last%0b | inflight %0d %0d",
                     cyc, dut.w_fire, dut.wr_bank, w_last, dut.br_consume, dut.br_bank, dut.br_last,
                     dut.u_props.inflight[0], dut.u_props.inflight[1]);
`endif

    // ------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------
    task automatic drain(int timeout);
        int t = 0;
        while ((wq.size() || aq.size() || cq.size() || w_valid || a_valid) && t < timeout) begin
            @(posedge clk);
            t++;
        end
        repeat (ROWS + COLS + 4) @(posedge clk);
        if (cq.size() != 0) begin
            $display("TIMEOUT: %0d result rows never came out", cq.size());
            n_errors++;
            cq.delete();
        end
    endtask

    // busy-ness: fraction of cycles in a window where a new row entered
    task automatic measure(string label, int tiles, int m_rows);
        longint first, last_c;
        int     beats;
        w_gap_pct = 0; a_gap_pct = 0; c_ready_pct = 100;
        for (int t = 0; t < tiles; t++) begin
            set_weights(0);
            add_tile(m_rows, 0);
        end
        beats = tiles * m_rows;
        first = -1;
        last_c = 0;
        fork
            begin
                int seen = 0;
                while (seen < beats) begin
                    @(posedge clk);
                    if (a_valid && a_ready) begin
                        if (first < 0) first = cyc;
                        last_c = cyc;
                        seen++;
                    end
                end
            end
        join
        drain(100000);
        $display("  %-34s %5d rows in %5d cycles  ->  array busy %5.1f %%",
                 label, beats, last_c - first + 1,
                 100.0 * beats / real'(last_c - first + 1));
    endtask

    // ------------------------------------------------------------------
    // the test
    // ------------------------------------------------------------------
    int seed_dummy;
    initial begin
        seed_dummy = $urandom(`SEED);
        rst_n = 1'b0;
        repeat (5) @(posedge clk);
        rst_n <= 1'b1;
        @(posedge clk);

        $display("== sa_core %0dx%0d  INT8 x INT8 -> INT%0d   seed %0d", ROWS, COLS, ACC_W, `SEED);

`ifdef OVF_TEST
        set_weights(1);  add_tile(4, 1);        // ROWS * 16384 > 2^15 - 1
        drain(10000);
        if (!ovf_sticky) begin
            $display("FAIL: overflow not flagged");
            $fatal(1);
        end
        $display("PASS: undersized accumulator overflow was detected (ovf_sticky = 1)");
        $finish;
`else
        // ---- 1 directed --------------------------------------------------
        set_weights(4);  add_tile(6, 0);
        set_weights(5);  add_tile(3, 0);
        drain(10000);
        $display("  phase 1 directed       %0d rows checked, %0d errors", n_checked, n_errors);

        // ---- 2 corner values ---------------------------------------------
        set_weights(1);  add_tile(5, 1);         // -128 * -128 everywhere
        set_weights(2);  add_tile(5, 2);         // 127 * -128
        set_weights(3);  add_tile(5, 3);         // -128 * 127
        set_weights(0);  add_tile(1, 0);         // single-row tile
        drain(10000);
        $display("  phase 2 corners        %0d rows checked, %0d errors", n_checked, n_errors);

        // ---- 3 random, with gaps and backpressure ------------------------
        for (int round = 0; round < 4; round++) begin
            w_gap_pct   = (round == 0) ? 0 : 30;
            a_gap_pct   = (round == 1) ? 0 : 25;
            c_ready_pct = (round == 2) ? 100 : (round == 3 ? 20 : 60);
            for (int t = 0; t < 60; t++) begin
                set_weights(0);
                add_tile($urandom_range(1, 3 * ROWS), 0);
            end
            drain(200000);
        end
        $display("  phase 3 random         %0d rows checked, %0d errors", n_checked, n_errors);

        // ---- 4 latency + throughput ---------------------------------------
        begin : latency
            longint t_in, t_out;
            w_gap_pct = 0; a_gap_pct = 0; c_ready_pct = 100;
            set_weights(0); add_tile(1, 0);
            t_in = -1; t_out = -1;
            while (t_out < 0) begin
                @(posedge clk);
                if (a_valid && a_ready && t_in < 0) t_in = cyc;
                if (c_valid && c_ready)             t_out = cyc;
            end
            drain(1000);
            $display("  phase 4 latency: row accepted -> result handed over = %0d cycles", t_out - t_in);
        end
        $display("  phase 4 throughput (no gaps, c_ready = 1):");
        measure("tiles of M = 1 row",          20, 1);
        measure("tiles of M = ROWS rows",      20, ROWS);
        measure("tiles of M = 2*ROWS rows",    20, 2 * ROWS);
        measure("tiles of M = 2*ROWS+COLS",    20, 2 * ROWS + COLS);
        measure("tiles of M = 4*ROWS rows",    20, 4 * ROWS);

        // ---- report ------------------------------------------------------
        $display("");
        $display("  coverage  backpressure cycles %0d   weight-load/compute overlap %0d",
                 cov_backpressure, cov_overlap);
        $display("            both banks loaded %0d   array stalled %0d   W blocked %0d",
                 cov_bank_both, cov_stall, cov_w_wait);
        $display("            tiles ended on bank0 %0d / bank1 %0d",
                 cov_last_bank[0], cov_last_bank[1]);
        if (cov_backpressure == 0 || cov_overlap == 0 || cov_bank_both == 0
            || cov_stall == 0 || cov_w_wait == 0 || cov_last_bank[0] == 0 || cov_last_bank[1] == 0) begin
            $display("  coverage hole: a scenario above was never exercised");
            n_errors++;
        end
        $display("");
        if (n_errors == 0)
            $display("PASS: %0d tiles, %0d result rows checked, 0 errors", n_tiles, n_checked);
        else begin
            $display("FAIL: %0d errors", n_errors);
            $fatal(1);
        end
        $finish;
`endif
    end

    // watchdog
    initial begin
        #50ms;
        $display("FAIL: watchdog timeout");
        $fatal(1);
    end

endmodule

// properties, bound into the DUT
bind sa_core sa_props #(.ROWS(ROWS), .COLS(COLS), .ACC_W(ACC_W), .EXPECT_NO_OVF(CHECK_ACC_W)) u_props (
    .clk(clk), .rst_n(rst_n), .w_fire(w_fire), .wr_bank(wr_bank), .a_fire(a_fire),
    .rd_bank(rd_bank), .br_consume(br_consume), .br_bank(br_bank), .bank_full(bank_full), .bank_fresh(bank_fresh),
    .c_valid(c_valid), .c_ready(c_ready), .c_data(c_data), .c_last(c_last),
    .fifo_cnt(fifo_cnt), .push(push), .pop(pop), .ovf_sticky(ovf_sticky));
