// =============================================================================
// Module      : mac_unit.v
// Description : Single Multiply-Accumulate unit.
//               Computes signed INT8 × INT8 → INT16 product.
//               The product is registered for one pipeline stage.
//
// This module is purely combinational in the multiply stage and has one
// optional output pipeline register (enabled by PIPELINE_REG parameter).
//
// Parameters  :
//   DATA_WIDTH – input operand width (8 for INT8)
//   OUT_WIDTH  – output product width (=2*DATA_WIDTH for lossless multiply)
//   PIPELINE_REG – 1 = register product output, 0 = combinational
// =============================================================================

module mac_unit #(
    parameter DATA_WIDTH  = 8,
    parameter OUT_WIDTH   = 16,   // must be >= 2*DATA_WIDTH
    parameter PIPELINE_REG = 1
) (
    input  wire                        clk,
    input  wire                        rst_n,
    input  wire                        enable,
    input  wire signed [DATA_WIDTH-1:0] data_in,    // pixel
    input  wire signed [DATA_WIDTH-1:0] weight_in,  // kernel weight
    output reg  signed [OUT_WIDTH-1:0]  product_out  // signed product
);

    wire signed [OUT_WIDTH-1:0] product_wire;
    assign product_wire = {{(OUT_WIDTH - 2*DATA_WIDTH){data_in[DATA_WIDTH-1] ^ weight_in[DATA_WIDTH-1]}},
                           (data_in * weight_in)};

    // Use explicit sign-extended multiplication
    wire signed [2*DATA_WIDTH-1:0] raw_product;
    assign raw_product = data_in * weight_in;  // signed × signed = signed

    generate
        if (PIPELINE_REG) begin : gen_reg
            always @(posedge clk) begin
                if (!rst_n)
                    product_out <= {OUT_WIDTH{1'b0}};
                else if (enable)
                    product_out <= {{(OUT_WIDTH - 2*DATA_WIDTH){raw_product[2*DATA_WIDTH-1]}},
                                    raw_product};
            end
        end else begin : gen_comb
            always @(*) begin
                product_out = {{(OUT_WIDTH - 2*DATA_WIDTH){raw_product[2*DATA_WIDTH-1]}},
                               raw_product};
            end
        end
    endgenerate

endmodule
