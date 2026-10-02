// =============================================================================
// sa_pe.sv -- one processing element of the weight-stationary systolic array
//
//                 ps_i (partial sum from above)
//                   |
//        a_i  ->  [ w0 | w1 ]  ->  a_o        activation keeps moving right
//                 [  MAC     ]
//                   |
//                 ps_o = ps_i + a_i * w[a_bank_i]   (2-stage: multiply, then add)
//
// Two weight registers (bank 0 / bank 1) make the PE double-buffered: the
// next tile's weight is written into one bank while activations tagged with
// the other bank are still being multiplied.  The bank tag travels WITH the
// activation, so each PE switches banks exactly when the first activation of
// the new tile reaches it -- no global "swap" cycle and no pipeline bubble.
//
// Everything that moves through the array advances only when en = 1 (global
// stall for backpressure).  Weight writes are independent of en.
//
// Control (valid) is reset; datapath registers are not, which is the usual
// ASIC practice: it saves area and the valid bit says when data is real.
// =============================================================================
// Vivado only: map the multiply-add into a DSP48 slice (syn/vivado_impl.tcl
// defines USE_DSP).  Other tools ignore the attribute.
`ifdef USE_DSP
(* use_dsp = "yes" *)
`endif
module sa_pe #(
    parameter int DW    = 8,      // activation / weight width (signed)
    parameter int ACC_W = 32      // partial-sum width (signed)
) (
    input  logic             clk,
    input  logic             rst_n,
    input  logic             en,

    // weight write port
    input  logic             w_we,
    input  logic             w_bank,
    input  logic [DW-1:0]    w_data,

    // activation in from the left neighbour (or the skew buffer)
    input  logic             a_vld_i,
    input  logic             a_bank_i,
    input  logic             a_last_i,
    input  logic [DW-1:0]    a_i,

    // partial sum in from the PE above (0 for the top row)
    input  logic [ACC_W-1:0] ps_i,

    // activation out to the right neighbour
    output logic             a_vld_o,
    output logic             a_bank_o,
    output logic             a_last_o,
    output logic [DW-1:0]    a_o,

    // partial sum out to the PE below
    output logic [ACC_W-1:0] ps_o,

    // this cycle's accumulate overflowed (only meaningful when en && a_vld_i)
    output logic             ovf_o
);

    // ---- double-buffered stationary weight --------------------------------
    logic [DW-1:0] w0_q, w1_q;

    always_ff @(posedge clk) begin
        if (w_we && !w_bank) w0_q <= w_data;
        if (w_we &&  w_bank) w1_q <= w_data;
    end

    // ---- two-stage multiply-accumulate ---------------------------------------
    //
    //   stage 1 (cycle T, when the activation arrives):  prod_q <= a * w
    //   stage 2 (cycle T+1):                             ps_o   <= ps_i + prod_q
    //
    // The partial sum for the same row leaves the PE above at the end of
    // ITS stage 2, which is exactly cycle T, so it is waiting in ps_i when
    // this PE runs stage 2.  The vertical chain therefore still moves one row
    // per cycle and the skew/deskew are unchanged; results just appear one
    // cycle later.  The first version did multiply AND add in one cycle,
    // which capped the design at ~90 MHz on Artix-7 (see README, timing).
    //
    // The weight is read in stage 1, so the last use of a weight bank is
    // still the cycle the activation arrives -- bank retirement is unchanged.
    logic signed [DW-1:0]    w_sel;
    logic signed [2*DW-1:0]  mult, prod, prod_q;
    logic signed [ACC_W-1:0] prod_ext, sum;

    assign w_sel    = a_bank_i ? w1_q : w0_q;
    // The multiply gets its own statement on purpose.  Inside "c ? x*y : '0"
    // the unsigned '0 makes the WHOLE expression unsigned (SystemVerilog
    // expression typing), and the multiply silently becomes unsigned too.
    assign mult     = $signed(a_i) * w_sel;
    // An empty slot contributes 0, so a partial sum simply passes through.
    // (Zeroing the activation before the multiply instead was tried: it was
    // slower on Artix-7, 156 vs 176 MHz, and did not save a DSP.)
    assign prod     = a_vld_i ? mult : '0;

    assign prod_ext = ACC_W'(prod_q);                   // sign-extends
    assign sum      = $signed(ps_i) + prod_ext;

    // signed overflow: both addends have the same sign, the result does not.
    // a_vld_o is a_vld_i one cycle later, i.e. "prod_q is real".
    assign ovf_o = a_vld_o && (ps_i[ACC_W-1] == prod_ext[ACC_W-1])
                           && (sum[ACC_W-1]  != ps_i[ACC_W-1]);

    // ---- pipeline registers ------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)  a_vld_o <= 1'b0;
        else if (en) a_vld_o <= a_vld_i;
    end

    always_ff @(posedge clk) begin
        if (en) begin
            a_o      <= a_i;
            a_bank_o <= a_bank_i;
            a_last_o <= a_last_i;
            prod_q   <= prod;          // stage 1
            ps_o     <= sum;           // stage 2
        end
    end

endmodule
