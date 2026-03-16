// =============================================================================
// Module      : weight_buffer.v
// Description : INT8 weight buffering for the ConvNet core.
//               Stores KERNEL_SIZE × KERNEL_SIZE signed 8-bit weights for
//               one convolution filter and presents them in parallel to
//               the fixed-point MAC array via 'weight_flat'.
// =============================================================================

module weight_buffer #(
    parameter DATA_WIDTH  = 8,
    parameter KERNEL_SIZE = 3
) (
    input  wire                                              clk,
    input  wire                                              rst_n,
    input  wire                                              weight_wr_en,
    input  wire [$clog2(KERNEL_SIZE*KERNEL_SIZE)-1:0]       weight_wr_addr,
    input  wire signed [DATA_WIDTH-1:0]                     weight_wr_data,
    output wire signed [DATA_WIDTH*KERNEL_SIZE*KERNEL_SIZE-1:0] weight_flat,
    output wire                                              weight_loaded
);

    localparam NUM_WEIGHTS = KERNEL_SIZE * KERNEL_SIZE;

    reg signed [DATA_WIDTH-1:0] weights [0:NUM_WEIGHTS-1];
    integer i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < NUM_WEIGHTS; i = i+1)
                weights[i] <= {DATA_WIDTH{1'b0}};
        end else if (weight_wr_en) begin
            weights[weight_wr_addr] <= weight_wr_data;
        end
    end

    assign weight_loaded = weight_wr_en;

    genvar gi;
    generate
        for (gi = 0; gi < NUM_WEIGHTS; gi = gi+1) begin : gen_wflat
            assign weight_flat[gi*DATA_WIDTH +: DATA_WIDTH] = weights[gi];
        end
    endgenerate

endmodule