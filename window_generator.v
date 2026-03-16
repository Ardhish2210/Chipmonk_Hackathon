// =============================================================================
// Module      : window_generator.v
// Description : Generates a 3x3 INT8 activation window every clock once the
//               pipeline has filled. This is the spatial "unfolder" for the
//               ConvNet core and feeds the fixed-point MAC array.
//               Uses three horizontal shift registers (one per row) fed by:
//                   top    ← row_out_flat[1]
//                   middle ← row_out_flat[0]
//                   bottom ← pixel_in
//
//               Window is VALID (for VALID convolution, no padding) only when
//               both row and column indices are >= 2.
//
// Parameters  :
//   DATA_WIDTH  - pixel bit-width (8 for INT8)
//   IMAGE_WIDTH - pixels per row
//   KERNEL_SIZE - kernel dimension K; tested for K=3
// =============================================================================

module window_generator #(
    parameter DATA_WIDTH  = 8,
    parameter IMAGE_WIDTH = 32,
    parameter KERNEL_SIZE = 3
) (
    input  wire                                                  clk,
    input  wire                                                  rst_n,
    input  wire signed [DATA_WIDTH-1:0]                         pixel_in,
    input  wire                                                 pixel_valid,
    // Flat packed row taps from line_buffer (see line_buffer.v)
    input  wire [(KERNEL_SIZE-1)*DATA_WIDTH-1:0]                row_out_flat,
    // Flattened K*K window output (wire, combinatorially derived from sr)
    output wire signed [DATA_WIDTH*KERNEL_SIZE*KERNEL_SIZE-1:0] window_flat,
    output reg                                                  window_valid
);

    // -------------------------------------------------------------------------
    // Horizontal shift registers: three rows × three columns (for K=3).
    // Implemented as 1-D arrays for tool compatibility.
    // -------------------------------------------------------------------------
    reg signed [DATA_WIDTH-1:0] top_sr   [0:2];
    reg signed [DATA_WIDTH-1:0] mid_sr   [0:2];
    reg signed [DATA_WIDTH-1:0] bot_sr   [0:2];

    // Row/column counters to know when a full 3x3 window is inside the image
    reg [$clog2(IMAGE_WIDTH)-1:0]  col_cnt;
    reg [$clog2(IMAGE_WIDTH)-1:0]  row_cnt;

    wire signed [DATA_WIDTH-1:0] mid_tap;
    wire signed [DATA_WIDTH-1:0] top_tap;

    assign mid_tap = row_out_flat[0*DATA_WIDTH +: DATA_WIDTH];
    assign top_tap = row_out_flat[1*DATA_WIDTH +: DATA_WIDTH];

    integer i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            col_cnt      <= {($clog2(IMAGE_WIDTH)){1'b0}};
            row_cnt      <= {($clog2(IMAGE_WIDTH)){1'b0}};
            window_valid <= 1'b0;
            for (i = 0; i < 3; i = i+1) begin
                top_sr[i] <= {DATA_WIDTH{1'b0}};
                mid_sr[i] <= {DATA_WIDTH{1'b0}};
                bot_sr[i] <= {DATA_WIDTH{1'b0}};
            end
        end else if (pixel_valid) begin
            // Update row/column indices
            if (col_cnt == IMAGE_WIDTH-1) begin
                col_cnt <= {($clog2(IMAGE_WIDTH)){1'b0}};
                row_cnt <= row_cnt + 1'b1;
            end else begin
                col_cnt <= col_cnt + 1'b1;
            end

            // Bottom row shift register (newest pixel on the right)
            bot_sr[0] <= bot_sr[1];
            bot_sr[1] <= bot_sr[2];
            bot_sr[2] <= pixel_in;

            // Middle row shift register fed by mid_tap
            mid_sr[0] <= mid_sr[1];
            mid_sr[1] <= mid_sr[2];
            mid_sr[2] <= mid_tap;

            // Top row shift register fed by top_tap
            top_sr[0] <= top_sr[1];
            top_sr[1] <= top_sr[2];
            top_sr[2] <= top_tap;

            // VALID convolution region: only when row,col >= 2
            if ((row_cnt >= 2) && (col_cnt >= 2))
                window_valid <= 1'b1;
            else
                window_valid <= 1'b0;
        end else begin
            window_valid <= 1'b0;
        end
    end

    // -------------------------------------------------------------------------
    // Pack shift registers into flat window: row-major, left to right.
    // window_flat[(r*3 + c)*DATA_WIDTH +: DATA_WIDTH]
    // -------------------------------------------------------------------------
    assign window_flat[0*DATA_WIDTH +: DATA_WIDTH] = top_sr[0];
    assign window_flat[1*DATA_WIDTH +: DATA_WIDTH] = top_sr[1];
    assign window_flat[2*DATA_WIDTH +: DATA_WIDTH] = top_sr[2];

    assign window_flat[3*DATA_WIDTH +: DATA_WIDTH] = mid_sr[0];
    assign window_flat[4*DATA_WIDTH +: DATA_WIDTH] = mid_sr[1];
    assign window_flat[5*DATA_WIDTH +: DATA_WIDTH] = mid_sr[2];

    assign window_flat[6*DATA_WIDTH +: DATA_WIDTH] = bot_sr[0];
    assign window_flat[7*DATA_WIDTH +: DATA_WIDTH] = bot_sr[1];
    assign window_flat[8*DATA_WIDTH +: DATA_WIDTH] = bot_sr[2];

endmodule
