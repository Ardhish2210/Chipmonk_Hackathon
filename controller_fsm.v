// =============================================================================
// Module      : controller_fsm.v
// Description : Simple control FSM for the CNN accelerator.
//               Provides a basic start/done control shell around the
//               streaming ConvNet core, and optional pipeline enables.
//               State machine:
//                 1. IDLE    – wait for start signal
//                 2. LOAD    – accept weight writes; when weight_loaded assert
//                              go to RUN
//                 3. RUN     – stream pixels, enable pipeline stages, count
//                              output pixels; when done go to DONE
//                 4. DONE    – pulse done_out for one cycle, return to IDLE
//
//  The FSM tracks:
//    • How many pixels have been input (pixel_cnt)
//    • How many valid output pixels have been produced (out_cnt)
//    • Pipeline enable  (pipe_en)  – used by line_buffer, window_gen, MACs
//    • Output valid gating (out_en) – suppress outputs during border pixels
//
// Parameters  :
//   IMAGE_WIDTH  – pixels per row
//   IMAGE_HEIGHT – rows per image
//   KERNEL_SIZE  – K (used to compute output feature-map size)
//
// Output feature-map size (no padding, stride=1):
//   OUT_W = IMAGE_WIDTH  - KERNEL_SIZE + 1
//   OUT_H = IMAGE_HEIGHT - KERNEL_SIZE + 1
// =============================================================================

module controller_fsm #(
    parameter IMAGE_WIDTH  = 32,
    parameter IMAGE_HEIGHT = 32,
    parameter KERNEL_SIZE  = 3
) (
    input  wire clk,
    input  wire rst_n,
    // Control handshake
    input  wire start,           // pulse to begin
    input  wire weight_loaded,   // from weight_buffer
    // Pixel stream
    input  wire pixel_valid_in,  // raw pixel valid from upstream
    // Pipeline enables & status
    output reg  pipe_en,         // clock-enable for all pipeline stages
    output reg  done_out,        // one-cycle pulse when image complete
    // Output gating: suppress border outputs
    output reg  result_valid     // qualified output valid (after border skip)
);

    // -------------------------------------------------------------------------
    // Derived constants
    // -------------------------------------------------------------------------
    localparam OUT_W   = IMAGE_WIDTH  - KERNEL_SIZE + 1;
    localparam OUT_H   = IMAGE_HEIGHT - KERNEL_SIZE + 1;
    localparam TOTAL_IN  = IMAGE_WIDTH * IMAGE_HEIGHT;
    localparam TOTAL_OUT = OUT_W * OUT_H;

    localparam CNT_W  = $clog2(TOTAL_IN  + 1);
    localparam OCNT_W = $clog2(TOTAL_OUT + 1);

    // -------------------------------------------------------------------------
    // FSM state encoding
    // -------------------------------------------------------------------------
    localparam [1:0]
        ST_IDLE = 2'b00,
        ST_LOAD = 2'b01,
        ST_RUN  = 2'b10,
        ST_DONE = 2'b11;

    reg [1:0]      state, next_state;

    // -------------------------------------------------------------------------
    // Pixel and output counters
    // -------------------------------------------------------------------------
    reg [CNT_W-1:0]  pixel_cnt;   // counts incoming pixels during RUN
    reg [OCNT_W-1:0] out_cnt;     // counts valid outputs produced

    // Pipeline latency: window warmup + MAC stage + accumulator = ~3+ cycles
    // Window warm-up alone is (K-1)*W + K-1.  We track at the pixel level.
    localparam WARMUP_PIXELS = (KERNEL_SIZE-1)*IMAGE_WIDTH + (KERNEL_SIZE-1);
    // Additional pipeline stages after window (MAC=1, ACC=1, ReLU=1 = 3)
    localparam PIPE_STAGES = 3;

    // col/row tracking to know if the current output is a border column
    reg [$clog2(IMAGE_WIDTH)-1:0]  col_cnt;  // column of pixel_cnt in current row
    reg [$clog2(IMAGE_HEIGHT)-1:0] row_cnt;  // row of pixel_cnt

    // After warmup, suppress first (K-1)/2 rows and last (K-1)/2 rows,
    // and similarly for columns.  For VALID convolution with stride=1:
    //   valid row range: K-1 .. IMAGE_HEIGHT-1
    //   valid col range: K-1 .. IMAGE_WIDTH-1
    // (because we use a causal line buffer – no zero-padding)
    wire in_valid_region;
    assign in_valid_region = (row_cnt >= KERNEL_SIZE-1) &&
                             (col_cnt >= KERNEL_SIZE-1);

    // -------------------------------------------------------------------------
    // State register
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) state <= ST_IDLE;
        else        state <= next_state;
    end

    // -------------------------------------------------------------------------
    // Next-state logic
    // -------------------------------------------------------------------------
    always @(*) begin
        next_state = state;
        case (state)
            ST_IDLE: if (start)         next_state = ST_LOAD;
            ST_LOAD: if (weight_loaded) next_state = ST_RUN;
            ST_RUN:  if (pixel_cnt == TOTAL_IN[CNT_W-1:0]) next_state = ST_DONE;
            ST_DONE:                    next_state = ST_IDLE;
        endcase
    end

    // -------------------------------------------------------------------------
    // Counters & outputs
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            pixel_cnt    <= {CNT_W{1'b0}};
            out_cnt      <= {OCNT_W{1'b0}};
            col_cnt      <= {$clog2(IMAGE_WIDTH){1'b0}};
            row_cnt      <= {$clog2(IMAGE_HEIGHT){1'b0}};
            pipe_en      <= 1'b0;
            done_out     <= 1'b0;
            result_valid <= 1'b0;
        end else begin
            done_out     <= 1'b0;   // default
            result_valid <= 1'b0;   // default

            case (state)
                ST_IDLE: begin
                    pixel_cnt <= {CNT_W{1'b0}};
                    out_cnt   <= {OCNT_W{1'b0}};
                    col_cnt   <= {$clog2(IMAGE_WIDTH){1'b0}};
                    row_cnt   <= {$clog2(IMAGE_HEIGHT){1'b0}};
                    pipe_en   <= 1'b0;
                end

                ST_LOAD: begin
                    pipe_en <= 1'b0;
                end

                ST_RUN: begin
                    pipe_en <= 1'b1;
                    if (pixel_valid_in) begin
                        // Increment pixel counter
                        if (pixel_cnt < TOTAL_IN[CNT_W-1:0])
                            pixel_cnt <= pixel_cnt + 1'b1;

                        // Track column & row
                        if (col_cnt == IMAGE_WIDTH - 1) begin
                            col_cnt <= {$clog2(IMAGE_WIDTH){1'b0}};
                            if (row_cnt < IMAGE_HEIGHT - 1)
                                row_cnt <= row_cnt + 1'b1;
                        end else begin
                            col_cnt <= col_cnt + 1'b1;
                        end

                        // Qualify output
                        // (result appears PIPE_STAGES cycles after window_valid,
                        //  but for simplicity we gate with in_valid_region here;
                        //  exact pipeline alignment is handled in the top level)
                        result_valid <= in_valid_region;
                    end
                end

                ST_DONE: begin
                    pipe_en  <= 1'b0;
                    done_out <= 1'b1;
                end
            endcase
        end
    end

endmodule
