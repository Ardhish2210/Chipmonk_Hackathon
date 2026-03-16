// =============================================================================
// image_rom.v  (fixed)
// 8×8 grayscale image ROM.  Streams IMAGE_PIXELS pixels (one per clock)
// starting the cycle after 'en' is sampled high.
//
// Timing: pixel_valid and pixel_out are registered together.
// pixel[0] appears on the first valid cycle, pixel[IMAGE_PIXELS-1] on
// the last.  Exactly IMAGE_PIXELS valid cycles are produced.
// =============================================================================

module image_rom #(
    parameter DATA_WIDTH   = 8,
    parameter IMAGE_PIXELS = 4096
)(
    input  wire                         clk,
    input  wire                         rst,
    input  wire                         en,           // pulse or level to start
    output reg  signed [DATA_WIDTH-1:0] pixel_out,    // registered pixel
    output reg                          pixel_valid,   // high for IMAGE_PIXELS cycles
    output reg                          frame_done     // one-cycle pulse after last pixel
);

    // ── ROM ──────────────────────────────────────────────────────────────────
    reg [DATA_WIDTH-1:0] mem [0:IMAGE_PIXELS-1];
    initial $readmemh("image.mem", mem);

    // ── Counter / FSM ────────────────────────────────────────────────────────
    reg [$clog2(IMAGE_PIXELS)-1:0] addr;
    reg                             running;

    always @(posedge clk) begin
        if (rst) begin
            addr        <= 0;
            running     <= 1'b0;
            pixel_valid <= 1'b0;
            pixel_out   <= 0;
            frame_done  <= 1'b0;
        end else begin
            frame_done <= 1'b0;   // default

            if (!running && en) begin
                // Latch pixel[0] and begin streaming
                running     <= 1'b1;
                addr        <= 0;
                pixel_out   <= $signed(mem[0]);
                pixel_valid <= 1'b1;

            end else if (running) begin
                if (addr == IMAGE_PIXELS - 1) begin
                    // pixel[IMAGE_PIXELS-1] was on the bus this cycle → stop
                    running     <= 1'b0;
                    pixel_valid <= 1'b0;
                    frame_done  <= 1'b1;
                    addr        <= 0;
                end else begin
                    addr        <= addr + 1;
                    pixel_out   <= $signed(mem[addr + 1]);
                    pixel_valid <= 1'b1;
                end
            end else begin
                pixel_valid <= 1'b0;
            end
        end
    end

endmodule