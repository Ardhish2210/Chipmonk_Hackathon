// =============================================================================
// Module      : line_buffer.v
// Description : Two-line INT8 activation buffer for 3x3 convolution windows.
//               For each incoming INT8 pixel at column 'col', provides the
//               corresponding pixels from the same column in the two previous
//               rows. This is the classic 2-line-buffer structure used for
//               streaming ConvNet cores.
//
// Interface   (for KERNEL_SIZE = 3):
//   - On each cycle with pixel_valid=1:
//       * pixel_in is the current-row pixel at column 'col'
//       * row_out_flat[0*DATA_WIDTH +: DATA_WIDTH] = pixel from row-1, same col
//       * row_out_flat[1*DATA_WIDTH +: DATA_WIDTH] = pixel from row-2, same col
//
// Parameters  :
//   DATA_WIDTH  - pixel bit-width (default 8 for INT8)
//   IMAGE_WIDTH - number of pixels per image row
//   KERNEL_SIZE - convolution kernel dimension (K); tested for K=3
// =============================================================================

module line_buffer #(
    parameter DATA_WIDTH  = 8,
    parameter IMAGE_WIDTH = 32,
    parameter KERNEL_SIZE = 3
) (
    input  wire                                              clk,
    input  wire                                              rst_n,
    input  wire signed [DATA_WIDTH-1:0]                     pixel_in,
    input  wire                                             pixel_valid,
    // Flat packed output: (KERNEL_SIZE-1) row taps.
    // For K=3:
    //   row_out_flat[0] = previous-row pixel at this column
    //   row_out_flat[1] = pixel two rows above at this column
    output wire [(KERNEL_SIZE-1)*DATA_WIDTH-1:0]            row_out_flat
);

    // -------------------------------------------------------------------------
    // Internal: two true line buffers (for K=3) implemented as 1-D arrays.
    //           lb1[c] holds the pixel from the previous row at column c.
    //           lb2[c] holds the pixel from two rows above at column c.
    // -------------------------------------------------------------------------

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
            // Cascade current pixel down through the line buffers at this column.
            lb2[col_idx] <= lb1[col_idx];
            lb1[col_idx] <= pixel_in;

            // Advance column index (wrap at IMAGE_WIDTH)
            if (col_idx == IMAGE_WIDTH-1)
                col_idx <= {($clog2(IMAGE_WIDTH)){1'b0}};
            else
                col_idx <= col_idx + 1'b1;
        end
    end

    // -------------------------------------------------------------------------
    // Output taps: previous-row and row-2 pixels at the *current* column index.
    // -------------------------------------------------------------------------
    assign row_out_flat[0*DATA_WIDTH +: DATA_WIDTH] = lb1[col_idx];
    assign row_out_flat[1*DATA_WIDTH +: DATA_WIDTH] = lb2[col_idx];

endmodule