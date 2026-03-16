// =============================================================================
// feature_map_store.v
// Captures TOTAL_OUT convolution pixels, serialises them for the output bus,
// and – in simulation – dumps the feature map to both a .mem file (hex) and
// a .txt file (decimal) as soon as all pixels are captured.
//
// File outputs (simulation only, ignored by synthesis):
//   feature_map_out.mem  – one hex value per line, loadable with $readmemh
//   feature_map_out.txt  – one decimal value per line, easy to read in Python
//
// Both files contain TOTAL_OUT lines, one pixel per line, row-major order.
// =============================================================================

module feature_map_store #(
    parameter OUT_WIDTH  = 8,
    parameter STORE_W    = 16,
    parameter TOTAL_OUT  = 3844    // (64-3+1)^2  for 64x64 input, K=3
)(
    input  wire                  clk,
    input  wire                  rst,

    // ── Capture interface (from activation_relu) ──────────────────────────
    input  wire [OUT_WIDTH-1:0]  feature_in,
    input  wire                  valid_in,

    // ── Serialised readout interface ──────────────────────────────────────
    output reg  [STORE_W-1:0]    feature_out,
    output reg                   valid_out,
    output reg                   capture_done   // one-cycle pulse when all pixels stored
);

    // -------------------------------------------------------------------------
    // Storage array
    // -------------------------------------------------------------------------
    reg [STORE_W-1:0] feature_map [0:TOTAL_OUT-1];

    // -------------------------------------------------------------------------
    // State machine: CAPTURE → READOUT → DONE
    // -------------------------------------------------------------------------
    localparam ST_CAPTURE = 2'd0;
    localparam ST_READOUT = 2'd1;
    localparam ST_DONE    = 2'd2;

    reg [1:0]                   state;
    reg [$clog2(TOTAL_OUT):0]   cnt;

    // -------------------------------------------------------------------------
    // File-dump task (simulation only)
    // Writes feature_map_out.mem  (hex, one value per line)
    //        feature_map_out.txt  (decimal, one value per line)
    // -------------------------------------------------------------------------
    integer fd_mem, fd_txt, fi;
    task dump_files;
        begin
            // ── .mem file (hex) ──────────────────────────────────────────
            fd_mem = $fopen("feature_map_out.mem", "w");
            if (fd_mem == 0)
                $display("[feature_map_store] ERROR: cannot open feature_map_out.mem");
            else begin
                for (fi = 0; fi < TOTAL_OUT; fi = fi + 1)
                    $fdisplay(fd_mem, "%02h", feature_map[fi][OUT_WIDTH-1:0]);
                $fclose(fd_mem);
                $display("[feature_map_store] Wrote feature_map_out.mem (%0d pixels, hex)", TOTAL_OUT);
            end

            // ── .txt file (decimal) ──────────────────────────────────────
            fd_txt = $fopen("feature_map_out.txt", "w");
            if (fd_txt == 0)
                $display("[feature_map_store] ERROR: cannot open feature_map_out.txt");
            else begin
                for (fi = 0; fi < TOTAL_OUT; fi = fi + 1)
                    $fdisplay(fd_txt, "%0d", feature_map[fi][OUT_WIDTH-1:0]);
                $fclose(fd_txt);
                $display("[feature_map_store] Wrote feature_map_out.txt (%0d pixels, decimal)", TOTAL_OUT);
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // Main sequential logic
    // -------------------------------------------------------------------------
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
                            capture_done <= 1'b1;
                            cnt          <= 0;
                            state        <= ST_READOUT;
                            // Dump files as soon as all pixels are captured
                            dump_files;
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