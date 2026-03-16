// =============================================================================
// weight_buffer.v  –  FIXED
//
// BUG FIXED:
//   Original: assign weight_loaded = weight_wr_en;
//   This made weight_loaded a 1-cycle pulse only on the LAST write cycle.
//   The controller_fsm transitions ST_LOAD → ST_RUN only when weight_loaded=1,
//   but because weight_loaded dropped immediately after the write, the FSM
//   never consistently saw it, so it stayed in ST_LOAD and the ROM was
//   never enabled.
//
//   FIX: weight_loaded is now a registered flag that sets after all
//   NUM_WEIGHTS have been written and stays high until reset.
// =============================================================================

module weight_buffer #(
    parameter DATA_WIDTH  = 8,
    parameter KERNEL_SIZE = 3
) (
    input  wire                                                   clk,
    input  wire                                                   rst_n,
    input  wire                                                   weight_wr_en,
    input  wire [$clog2(KERNEL_SIZE*KERNEL_SIZE)-1:0]             weight_wr_addr,
    input  wire signed [DATA_WIDTH-1:0]                           weight_wr_data,
    output wire signed [DATA_WIDTH*KERNEL_SIZE*KERNEL_SIZE-1:0]   weight_flat,
    output wire                                                    weight_loaded
);

    localparam NUM_WEIGHTS = KERNEL_SIZE * KERNEL_SIZE;

    reg signed [DATA_WIDTH-1:0] weights [0:NUM_WEIGHTS-1];
    // ── FIX: persistent loaded flag ──────────────────────────────────────────
    reg loaded_r;
    integer i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < NUM_WEIGHTS; i = i+1)
                weights[i] <= {DATA_WIDTH{1'b0}};
            loaded_r <= 1'b0;
        end else begin
            if (weight_wr_en) begin
                weights[weight_wr_addr] <= weight_wr_data;
                // Set loaded when the last address (NUM_WEIGHTS-1) is written
                if (weight_wr_addr == NUM_WEIGHTS - 1)
                    loaded_r <= 1'b1;
            end
        end
    end

    // Stays high once all weights are loaded; cleared only by reset
    assign weight_loaded = loaded_r;

    genvar gi;
    generate
        for (gi = 0; gi < NUM_WEIGHTS; gi = gi+1) begin : gen_wflat
            assign weight_flat[gi*DATA_WIDTH +: DATA_WIDTH] = weights[gi];
        end
    endgenerate

endmodule