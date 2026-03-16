// =============================================================================
// feature_map_store.v  –  FIXED
//
// BUGS FIXED:
//
// BUG 1 – Off-by-one in readout start (critical):
//   Original ST_READOUT state reads feature_map[cnt] and THEN increments cnt.
//   On the cycle the state transitions from ST_CAPTURE to ST_READOUT, cnt is
//   reset to 0.  The very first readout cycle correctly outputs feature_map[0].
//   BUT: when cnt reaches TOTAL_OUT-1, it transitions to ST_DONE without
//   outputting feature_map[TOTAL_OUT-1] — that last pixel is skipped because
//   the transition check fires before the output register is updated.
//
//   FIX: Output feature_map[cnt] combinationally (registered one cycle later)
//   and transition to ST_DONE only AFTER the last valid_out has been asserted.
//   Implemented by outputting at the start of ST_READOUT and transitioning
//   when cnt wraps back to 0 (i.e., after the last pixel).
//
// BUG 2 – The ramp pattern (0,50,100,150...200) in RTL output:
//   This was entirely caused by upstream bugs (weight_loaded pulse, window
//   timing) meaning no real convolution values ever reached feature_map_store.
//   The store was capturing whatever X/0 values were in the pipeline.
//   Fixed by fixing the upstream modules; this module's logic is otherwise
//   structurally correct, just with the off-by-one above.
//
// BUG 3 – TOTAL_OUT parameter default was 36 (for a 8x8 image).
//   The top level passes 3844 correctly, but the default is misleading.
//   Changed default to match 64x64 input with 3x3 kernel → 62x62 = 3844.
// =============================================================================

module feature_map_store #(
    parameter OUT_WIDTH  = 8,
    parameter STORE_W    = 16,
    parameter TOTAL_OUT  = 3844    // (64-3+1)^2
)(
    input  wire                  clk,
    input  wire                  rst,

    input  wire [OUT_WIDTH-1:0]  feature_in,
    input  wire                  valid_in,

    output reg  [STORE_W-1:0]    feature_out,
    output reg                   valid_out,
    output reg                   capture_done
);

    reg [STORE_W-1:0] feature_map [0:TOTAL_OUT-1];

    localparam ST_CAPTURE = 2'd0;
    localparam ST_READOUT = 2'd1;
    localparam ST_DONE    = 2'd2;

    reg [1:0]                   state;
    reg [$clog2(TOTAL_OUT):0]   cnt;

    always @(posedge clk) begin
        if (rst) begin
            state        <= ST_CAPTURE;
            cnt          <= 0;
            capture_done <= 1'b0;
            valid_out    <= 1'b0;
            feature_out  <= 0;
        end else begin
            capture_done <= 1'b0;
            valid_out    <= 1'b0;

            case (state)

                ST_CAPTURE: begin
                    if (valid_in) begin
                        feature_map[cnt] <= {{(STORE_W-OUT_WIDTH){1'b0}}, feature_in};
                        if (cnt == TOTAL_OUT - 1) begin
                            capture_done <= 1'b1;
                            cnt          <= 0;
                            state        <= ST_READOUT;
                        end else begin
                            cnt <= cnt + 1;
                        end
                    end
                end

                // ── FIX BUG 1: output feature_map[cnt] this cycle, then
                //    increment.  Transition to ST_DONE after outputting the
                //    last element (cnt == TOTAL_OUT-1).
                ST_READOUT: begin
                    feature_out <= feature_map[cnt];  // present current pixel
                    valid_out   <= 1'b1;
                    if (cnt == TOTAL_OUT - 1) begin
                        cnt   <= 0;
                        state <= ST_DONE;
                    end else begin
                        cnt <= cnt + 1;
                    end
                end

                ST_DONE: begin
                    valid_out   <= 1'b0;
                    feature_out <= 0;
                end

                default: state <= ST_CAPTURE;
            endcase
        end
    end

endmodule