// =============================================================================
// Module      : activation_relu.v
// Description : Registered ReLU activation function.
//               ReLU(x) = max(0, x)
//               For a signed accumulator value, this clamps negative results
//               to zero and passes positive values unchanged.
//               Also performs optional output saturation to OUT_WIDTH bits.
//
// Parameters  :
//   ACC_WIDTH – width of incoming accumulator result (signed)
//   OUT_WIDTH – output feature-map pixel width (clipped/saturated)
//
// Ports       :
//   acc_in    – signed accumulator input
//   valid_in  – input is valid
//   feature   – output feature-map pixel
//   valid_out – output is valid (1-cycle latency)
// =============================================================================

module activation_relu #(
    parameter ACC_WIDTH = 32,
    parameter OUT_WIDTH = 8
) (
    input  wire                          clk,
    input  wire                          rst_n,
    input  wire signed [ACC_WIDTH-1:0]   acc_in,
    input  wire                          valid_in,
    output reg  [OUT_WIDTH-1:0]          feature,   // unsigned after ReLU
    output reg                           valid_out
);

    // -------------------------------------------------------------------------
    // Saturation limits for OUT_WIDTH unsigned output
    // Max positive value that fits: (2^OUT_WIDTH) - 1
    // -------------------------------------------------------------------------
    localparam [ACC_WIDTH-1:0] SAT_MAX = {{(ACC_WIDTH-OUT_WIDTH){1'b0}},
                                          {OUT_WIDTH{1'b1}}};  // 255 for 8-bit

    wire signed [ACC_WIDTH-1:0] relu_val;
    assign relu_val = acc_in[ACC_WIDTH-1] ? {ACC_WIDTH{1'b0}} : acc_in; // clamp neg

    // Saturate to OUT_WIDTH
    wire [OUT_WIDTH-1:0] sat_val;
    assign sat_val = (relu_val > SAT_MAX) ? {OUT_WIDTH{1'b1}} : relu_val[OUT_WIDTH-1:0];

    always @(posedge clk) begin
        if (!rst_n) begin
            feature   <= {OUT_WIDTH{1'b0}};
            valid_out <= 1'b0;
        end else begin
            feature   <= sat_val;
            valid_out <= valid_in;
        end
    end

endmodule
