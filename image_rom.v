// =============================================================================
// image_rom.v  –  Streaming image ROM for CNN accelerator
//
// Streams pixels from a pre-loaded memory file one per clock cycle when
// enabled.  After all IMAGE_PIXELS have been sent, asserts frame_done for
// one cycle and stops.
//
// Notes on the 'en' signal:
//   en is a LEVEL signal.  The ROM starts streaming on the first posedge
//   where en=1, and continues until the frame is complete.
//   Asserting rst (active-HIGH) resets the read pointer.
// =============================================================================

module image_rom #(
    parameter DATA_WIDTH   = 8,
    parameter IMAGE_PIXELS = 4096   // 64×64
) (
    input  wire                      clk,
    input  wire                      rst,         // active-HIGH
    input  wire                      en,          // level: start/continue streaming
    output reg  signed [DATA_WIDTH-1:0] pixel_out,
    output reg                       pixel_valid,
    output reg                       frame_done
);

    // ── ROM storage ──────────────────────────────────────────────────────────
    reg [DATA_WIDTH-1:0] mem [0:IMAGE_PIXELS-1];

    initial begin
        $readmemh("image2.mem", mem);
    end

    // ── Read pointer ─────────────────────────────────────────────────────────
    reg [$clog2(IMAGE_PIXELS)-1:0] rd_ptr;
    reg                             running;

    always @(posedge clk) begin
        if (rst) begin
            rd_ptr      <= 0;
            running     <= 1'b0;
            pixel_valid <= 1'b0;
            frame_done  <= 1'b0;
            pixel_out   <= 0;
        end else begin
            frame_done  <= 1'b0;   // default
            pixel_valid <= 1'b0;   // default

            if (en && !running) begin
                running <= 1'b1;   // latch start
            end

            if (running) begin
                // Output current pixel with valid=1 for ALL pixels incl. last
                pixel_out   <= $signed(mem[rd_ptr]);
                pixel_valid <= 1'b1;

                if (rd_ptr == IMAGE_PIXELS - 1) begin
                    // Last pixel output this cycle with valid=1 (do NOT override)
                    rd_ptr     <= 0;
                    running    <= 1'b0;
                    frame_done <= 1'b1;
                    // pixel_valid stays 1'b1 (set above) for the last pixel
                end else begin
                    rd_ptr <= rd_ptr + 1;
                end
            end
        end
    end

endmodule