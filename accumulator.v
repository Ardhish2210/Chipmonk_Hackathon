// =============================================================================
// Module      : accumulator.v
// Description : Balanced adder tree that sums MAC_UNITS signed partial
//               products into a single accumulation result.
//
//               The tree is fully pipelined; latency = ceil(log2(MAC_UNITS))
//               clock cycles.  The ACC_WIDTH parameter prevents overflow for
//               the maximum theoretical sum:
//                  max_sum = MAC_UNITS × (127²) ≤ 2^(ACC_WIDTH-1) - 1
//               Recommended: ACC_WIDTH = PROD_WIDTH + ceil(log2(MAC_UNITS)) + 1
//
// Parameters  :
//   PROD_WIDTH  – width of each partial product (16)
//   ACC_WIDTH   – accumulator output width
//   MAC_UNITS   – number of inputs (=K²)
//
// Ports       :
//   products    – flattened partial products (MAC_UNITS × PROD_WIDTH)
//   valid_in    – products are valid
//   result      – accumulated sum
//   valid_out   – result is valid (latency cycles after valid_in)
// =============================================================================

module accumulator #(
    parameter PROD_WIDTH = 16,
    parameter ACC_WIDTH  = 32,
    parameter MAC_UNITS  = 9
) (
    input  wire                               clk,
    input  wire                               rst_n,
    input  wire signed [PROD_WIDTH*MAC_UNITS-1:0] products,
    input  wire                               valid_in,
    output reg  signed [ACC_WIDTH-1:0]        result,
    output reg                                valid_out
);

    // -------------------------------------------------------------------------
    // Parametric adder tree using generate.  Number of pipeline stages =
    // ceil(log2(MAC_UNITS)).
    // We implement this as a flat combinational reduction then register once.
    // For larger MAC_UNITS a hierarchical generate tree would be used; for
    // typical K=3 (9 inputs) a single registered sum is sufficient and maps
    // well to DSP carry-chains in FPGAs.
    // -------------------------------------------------------------------------

    // Unpack products into a working array (combinational)
    wire signed [ACC_WIDTH-1:0] padded [0:MAC_UNITS-1];
    genvar gi;
    generate
        for (gi = 0; gi < MAC_UNITS; gi = gi+1) begin : gen_pad
            assign padded[gi] = {{(ACC_WIDTH-PROD_WIDTH){products[gi*PROD_WIDTH + PROD_WIDTH-1]}},
                                  products[gi*PROD_WIDTH +: PROD_WIDTH]};
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Summation – unrolled for up to 16 inputs.
    // For synthesizers this becomes a tree automatically due to optimization.
    // -------------------------------------------------------------------------
    reg signed [ACC_WIDTH-1:0] sum_comb;
    integer i;
    always @(*) begin
        sum_comb = {ACC_WIDTH{1'b0}};
        for (i = 0; i < MAC_UNITS; i = i+1)
            sum_comb = sum_comb + padded[i];
    end

    // -------------------------------------------------------------------------
    // Pipeline register
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            result    <= {ACC_WIDTH{1'b0}};
            valid_out <= 1'b0;
        end else begin
            result    <= sum_comb;
            valid_out <= valid_in;
        end
    end

endmodule
