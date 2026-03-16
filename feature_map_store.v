// =============================================================================
// feature_map_store.v
// Captures the 6x6 (36-entry) convolution feature map from the pipeline,
// then re-serializes it for output over a single 16-bit bus.
//
// Capture phase : stores each feature_in word as it arrives (valid_in = 1).
// Readout phase : after all 36 values are captured, outputs them one per
//                 clock cycle with valid asserted.
// =============================================================================

module feature_map_store #(
    parameter OUT_WIDTH  = 8,     // width coming from ReLU (saturated 8-bit)
    parameter STORE_W    = 16,    // storage / output width
    parameter TOTAL_OUT  = 36     // OUT_W * OUT_H = 6 * 6
)(
    input  wire                  clk,
    input  wire                  rst,

    // ── Capture interface (from activation_relu) ──────────────────────────
    input  wire [OUT_WIDTH-1:0]  feature_in,
    input  wire                  valid_in,

    // ── Serialised readout interface ──────────────────────────────────────
    output reg  [STORE_W-1:0]    feature_out,
    output reg                   valid_out,
    output reg                   capture_done   // one-cycle pulse when all 36 stored
);

    // -------------------------------------------------------------------------
    // Storage
    // -------------------------------------------------------------------------
    reg [STORE_W-1:0] feature_map [0:TOTAL_OUT-1];

    // -------------------------------------------------------------------------
    // State machine: IDLE → CAPTURE → READOUT → DONE
    // All state in one always block to avoid inter-block race conditions.
    // -------------------------------------------------------------------------
    localparam ST_CAPTURE = 2'd0;
    localparam ST_READOUT = 2'd1;
    localparam ST_DONE    = 2'd2;

    reg [1:0]                   state;
    reg [$clog2(TOTAL_OUT):0]   cnt;   // shared counter (capture & readout)

    always @(posedge clk) begin
        if (rst) begin
            state        <= ST_CAPTURE;
            cnt          <= 0;
            capture_done <= 1'b0;
            valid_out    <= 1'b0;
            feature_out  <= 0;
        end else begin
            capture_done <= 1'b0;   // default
            valid_out    <= 1'b0;   // default

            case (state)

                // ── Capture incoming pixels ───────────────────────────────
                ST_CAPTURE: begin
                    if (valid_in) begin
                        feature_map[cnt] <= {{(STORE_W-OUT_WIDTH){1'b0}}, feature_in};
                        if (cnt == TOTAL_OUT - 1) begin
                            // All 36 pixels stored
                            capture_done <= 1'b1;
                            cnt          <= 0;
                            state        <= ST_READOUT;
                        end else begin
                            cnt <= cnt + 1;
                        end
                    end
                end

                // ── Serialise stored pixels onto feature_out / valid_out ──
                ST_READOUT: begin
                    feature_out <= feature_map[cnt];
                    valid_out   <= 1'b1;
                    if (cnt == TOTAL_OUT - 1) begin
                        cnt   <= 0;
                        state <= ST_DONE;
                    end else begin
                        cnt <= cnt + 1;
                    end
                end

                // ── All done – hold outputs low ───────────────────────────
                ST_DONE: begin
                    valid_out   <= 1'b0;
                    feature_out <= 0;
                end

                default: state <= ST_CAPTURE;
            endcase
        end
    end

endmodule