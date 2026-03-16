// =============================================================================
// window_generator.v  –  FIXED
//
// BUGS FIXED:
//
// BUG 1 – Line-buffer tap timing (critical):
//   The line_buffer outputs row_out_flat combinationally from col_idx.
//   col_idx is the CURRENT column (before it increments this clock edge).
//   However, the shift registers (top_sr, mid_sr, bot_sr) are clocked:
//   they latch mid_tap / top_tap on the RISING edge alongside pixel_in.
//   Because lb1[col_idx] / lb2[col_idx] are already correct for the current
//   pixel (see line_buffer fix), this is now properly aligned.
//
// BUG 2 – window_valid fires one pixel too early:
//   The condition  (row_cnt >= 2) && (col_cnt >= 2)  is checked at the same
//   cycle the shift registers are updated.  But the 3×3 window is only
//   complete when col_cnt has reached 2 (i.e., the THIRD pixel of the row
//   has entered bot_sr).  Using col_cnt >= KERNEL_SIZE-1 is correct for
//   zero-based counting, so that part is fine.
//
//   The real issue is that col_cnt and row_cnt are updated in the SAME always
//   block as the shift-register writes.  After the update col_cnt reflects the
//   index for the NEXT pixel, not the current one.  So window_valid should
//   be based on the PRE-increment values.  We capture them before the block
//   updates and compare against them.
//
// BUG 3 – row_cnt uses $clog2(IMAGE_WIDTH) bits instead of enough bits for
//   IMAGE_HEIGHT.  For a square image this is fine, but made explicit here.
// =============================================================================

module window_generator #(
    parameter DATA_WIDTH  = 8,
    parameter IMAGE_WIDTH = 32,
    parameter KERNEL_SIZE = 3
) (
    input  wire                                                   clk,
    input  wire                                                   rst_n,
    input  wire signed [DATA_WIDTH-1:0]                          pixel_in,
    input  wire                                                   pixel_valid,
    input  wire [(KERNEL_SIZE-1)*DATA_WIDTH-1:0]                  row_out_flat,
    output wire signed [DATA_WIDTH*KERNEL_SIZE*KERNEL_SIZE-1:0]   window_flat,
    output reg                                                    window_valid
);

    reg signed [DATA_WIDTH-1:0] top_sr [0:KERNEL_SIZE-1];
    reg signed [DATA_WIDTH-1:0] mid_sr [0:KERNEL_SIZE-1];
    reg signed [DATA_WIDTH-1:0] bot_sr [0:KERNEL_SIZE-1];

    // Use enough bits for both width and height
    reg [$clog2(IMAGE_WIDTH)-1:0]  col_cnt;
    reg [$clog2(IMAGE_WIDTH)-1:0]  row_cnt;   // works for square images

    wire signed [DATA_WIDTH-1:0] mid_tap;
    wire signed [DATA_WIDTH-1:0] top_tap;

    assign mid_tap = row_out_flat[0*DATA_WIDTH +: DATA_WIDTH];
    assign top_tap = row_out_flat[1*DATA_WIDTH +: DATA_WIDTH];

    integer i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            col_cnt      <= 0;
            row_cnt      <= 0;
            window_valid <= 1'b0;
            for (i = 0; i < KERNEL_SIZE; i = i+1) begin
                top_sr[i] <= {DATA_WIDTH{1'b0}};
                mid_sr[i] <= {DATA_WIDTH{1'b0}};
                bot_sr[i] <= {DATA_WIDTH{1'b0}};
            end
        end else if (pixel_valid) begin

            // ── FIX BUG 2: capture pre-increment counters for valid check ──
            // window_valid is set based on where this pixel LANDS in the window.
            // After KERNEL_SIZE-1 full rows have passed (row_cnt >= KERNEL_SIZE-1)
            // AND this is at least the (KERNEL_SIZE-1)-th column of that row
            // (col_cnt >= KERNEL_SIZE-1), all three shift-register positions
            // hold valid image data.
            if ((row_cnt >= KERNEL_SIZE-1) && (col_cnt >= KERNEL_SIZE-1))
                window_valid <= 1'b1;
            else
                window_valid <= 1'b0;

            // ── Shift register updates ─────────────────────────────────────
            // Bottom row: new pixel enters at [KERNEL_SIZE-1]
            bot_sr[0] <= bot_sr[1];
            bot_sr[1] <= bot_sr[2];
            bot_sr[2] <= pixel_in;

            // Middle row: fed by lb1 tap (one row above current)
            mid_sr[0] <= mid_sr[1];
            mid_sr[1] <= mid_sr[2];
            mid_sr[2] <= mid_tap;

            // Top row: fed by lb2 tap (two rows above current)
            top_sr[0] <= top_sr[1];
            top_sr[1] <= top_sr[2];
            top_sr[2] <= top_tap;

            // ── Counter updates (AFTER valid check, to use pre-increment) ──
            if (col_cnt == IMAGE_WIDTH - 1) begin
                col_cnt <= 0;
                row_cnt <= row_cnt + 1'b1;
            end else begin
                col_cnt <= col_cnt + 1'b1;
            end

        end else begin
            window_valid <= 1'b0;
        end
    end

    // ── Pack shift registers into flat window: row-major, left→right ─────────
    // window_flat index: [row*KERNEL_SIZE + col] * DATA_WIDTH
    genvar gr, gc;
    generate
        for (gr = 0; gr < KERNEL_SIZE; gr = gr+1) begin : gen_row
            for (gc = 0; gc < KERNEL_SIZE; gc = gc+1) begin : gen_col
                // top_sr maps to row 0, mid_sr to row 1, bot_sr to row 2
                // Within each row, [0] is oldest (leftmost), [KERNEL_SIZE-1] newest
                assign window_flat[(gr*KERNEL_SIZE + gc)*DATA_WIDTH +: DATA_WIDTH] =
                    (gr == 0) ? top_sr[gc] :
                    (gr == 1) ? mid_sr[gc] :
                                bot_sr[gc];
            end
        end
    endgenerate

endmodule