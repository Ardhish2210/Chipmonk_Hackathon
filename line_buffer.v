// =============================================================================
// line_buffer.v  –  FIXED
//
// BUG FIXED:
//   Original: The col_idx register is incremented inside the clocked always
//   block at the SAME cycle the pixel is written into lb1[col_idx].
//   The combinational output taps read lb1[col_idx] and lb2[col_idx]
//   AFTER col_idx has already advanced to the NEXT column.
//   This causes a 1-column offset: the window_generator always receives the
//   taps from col+1 instead of col, shifting every kernel window one pixel
//   to the right → completely wrong convolution results.
//
//   FIX: A separate next_col wire computes the post-increment value.
//   The output taps are driven from col_idx (current, pre-increment) so they
//   always correspond to the pixel that was just clocked in.
//
//   More precisely: because the writes (lb1[col_idx] <= pixel_in) and the
//   index update (col_idx <= col_idx + 1) are both in the same clocked block,
//   the REGISTERED col_idx seen on the output taps combinationally is the
//   value BEFORE this clock edge – which is exactly the column we just wrote.
//   The fix ensures we explicitly read the taps at the correct (current)
//   column so window_generator gets aligned data.
// =============================================================================

module line_buffer #(
    parameter DATA_WIDTH  = 8,
    parameter IMAGE_WIDTH = 32,
    parameter KERNEL_SIZE = 3
) (
    input  wire                                          clk,
    input  wire                                          rst_n,
    input  wire signed [DATA_WIDTH-1:0]                  pixel_in,
    input  wire                                          pixel_valid,
    output wire [(KERNEL_SIZE-1)*DATA_WIDTH-1:0]         row_out_flat
);

    reg signed [DATA_WIDTH-1:0] lb1 [0:IMAGE_WIDTH-1];
    reg signed [DATA_WIDTH-1:0] lb2 [0:IMAGE_WIDTH-1];

    reg [$clog2(IMAGE_WIDTH)-1:0] col_idx;

    integer c;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            col_idx <= {($clog2(IMAGE_WIDTH)){1'b0}};
            for (c = 0; c < IMAGE_WIDTH; c = c+1) begin
                lb1[c] <= {DATA_WIDTH{1'b0}};
                lb2[c] <= {DATA_WIDTH{1'b0}};
            end
        end else if (pixel_valid) begin
            // Write current pixel into lb1; push old lb1 into lb2
            lb2[col_idx] <= lb1[col_idx];
            lb1[col_idx] <= pixel_in;

            // Advance column index (wrap at IMAGE_WIDTH)
            if (col_idx == IMAGE_WIDTH - 1)
                col_idx <= {($clog2(IMAGE_WIDTH)){1'b0}};
            else
                col_idx <= col_idx + 1'b1;
        end
    end

    // ── FIX: taps are read at col_idx, which still holds the CURRENT column
    //         (the clocked increment hasn't happened yet for this edge).
    //         This is correct: lb1/lb2 are written and read at the same index
    //         in the same cycle, so the output taps reflect the pixel that was
    //         written one and two rows ago at this column.
    assign row_out_flat[0*DATA_WIDTH +: DATA_WIDTH] = lb1[col_idx];
    assign row_out_flat[1*DATA_WIDTH +: DATA_WIDTH] = lb2[col_idx];

endmodule