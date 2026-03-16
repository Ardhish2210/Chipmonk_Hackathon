// =============================================================================
// Module      : mac_array.v
// Description : Array of MAC_UNITS parallel MAC units forming the
//               fixed-point MAC array for the ConvNet core.
//               Each unit receives one INT8 activation and one INT8
//               weight from the K×K window and weight buffer, and
//               produces one fixed-point product per cycle.
//
//   MAC_UNITS must equal KERNEL_SIZE × KERNEL_SIZE for full parallelism.
//   If MAC_UNITS < K², the controller must time-multiplex (not covered here;
//   full parallel mode is the default for small kernels).
//
// Parameters  :
//   DATA_WIDTH  – operand width (8)
//   PROD_WIDTH  – product width (16)
//   MAC_UNITS   – number of parallel MACs (= K²)
//
// Ports       :
//   pixel_flat  – flattened K² pixels  (MAC_UNITS × DATA_WIDTH bits)
//   weight_flat – flattened K² weights (MAC_UNITS × DATA_WIDTH bits)
//   products    – flattened products   (MAC_UNITS × PROD_WIDTH bits)
//   valid_out   – products valid (delayed by 1 cycle due to MAC register)
// =============================================================================

`include "mac_unit.v"

module mac_array #(
    parameter DATA_WIDTH = 8,
    parameter PROD_WIDTH = 16,
    parameter MAC_UNITS  = 9    // = KERNEL_SIZE²
) (
    input  wire                                    clk,
    input  wire                                    rst_n,
    input  wire                                    enable,
    input  wire signed [DATA_WIDTH*MAC_UNITS-1:0]  pixel_flat,
    input  wire signed [DATA_WIDTH*MAC_UNITS-1:0]  weight_flat,
    output wire signed [PROD_WIDTH*MAC_UNITS-1:0]  products,
    output reg                                     valid_out
);

    // Pipeline the valid signal by 1 cycle to align with MAC outputs
    always @(posedge clk) begin
        if (!rst_n)
            valid_out <= 1'b0;
        else
            valid_out <= enable;
    end

    // -------------------------------------------------------------------------
    // Instantiate MAC_UNITS mac_unit instances
    // -------------------------------------------------------------------------
    genvar gi;
    generate
        for (gi = 0; gi < MAC_UNITS; gi = gi+1) begin : gen_mac
            mac_unit #(
                .DATA_WIDTH  (DATA_WIDTH),
                .OUT_WIDTH   (PROD_WIDTH),
                .PIPELINE_REG(1)
            ) u_mac (
                .clk        (clk),
                .rst_n      (rst_n),
                .enable     (enable),
                .data_in    (pixel_flat  [gi*DATA_WIDTH  +: DATA_WIDTH]),
                .weight_in  (weight_flat [gi*DATA_WIDTH  +: DATA_WIDTH]),
                .product_out(products    [gi*PROD_WIDTH  +: PROD_WIDTH])
            );
        end
    endgenerate

endmodule
