// =============================================================================
// cnn_accelerator_top.v  –  Basys-3 (Artix-7 xc7a35tcpg236-1) top level
//
// FPGA-compatible port list:
//   clk         – 100 MHz board clock (W5 / GCLK pin)
//   rst         – active-HIGH reset tied to BTNC (T17)
//   start       – active-HIGH start pulse (BTNL / W19, or SW0)
//   feature_out – 16-bit serialised convolution output
//   valid       – 1 when feature_out holds a new value
//
// Internal architecture is UNCHANGED:
//   image_rom → line_buffer → window_generator →
//   mac_array → accumulator → activation_relu →
//   feature_map_store → FPGA output ports
//
// Weight loading:
//   A hard-wired Laplacian kernel is written during the LOAD state so no
//   external switches are needed.  To use a different kernel at runtime,
//   map weight_wr_en / weight_wr_addr / weight_wr_data to board switches
//   (see commented-out port section below).
// =============================================================================

`include "line_buffer.v"
`include "window_generator.v"
`include "weight_buffer.v"
`include "mac_array.v"
`include "accumulator.v"
`include "activation_relu.v"
`include "controller_fsm.v"
`include "image_rom.v"
`include "feature_map_store.v"

module cnn_accelerator_top #(
    parameter IMAGE_WIDTH  = 8,
    parameter IMAGE_HEIGHT = 8,
    parameter KERNEL_SIZE  = 3,
    parameter DATA_WIDTH   = 8,
    parameter PROD_WIDTH   = 16,
    parameter ACC_WIDTH    = 32,
    parameter OUT_WIDTH    = 8,
    parameter MAC_UNITS    = 9,      // KERNEL_SIZE × KERNEL_SIZE
    parameter TOTAL_OUT    = 36,     // (8-3+1)²
    parameter STORE_WIDTH  = 16
)(
    // ── Basys-3 FPGA ports ────────────────────────────────────────────────
    input  wire                  clk,          // 100 MHz  (W5)
    input  wire                  rst,          // BTNC     (T17)  active-HIGH
    input  wire                  start,        // BTNL / SW0       active-HIGH

    output wire [STORE_WIDTH-1:0] feature_out, // serialised feature map pixel
    output wire                   valid        // feature_out is valid this cycle
);

    // =========================================================================
    // Internal wires
    // =========================================================================

    // Active-low reset used by all sub-modules
    wire rst_n = ~rst;

    // Weight-buffer interface
    wire                                                  weight_wr_en_w;
    wire [$clog2(KERNEL_SIZE*KERNEL_SIZE)-1:0]            weight_wr_addr_w;
    wire signed [DATA_WIDTH-1:0]                          weight_wr_data_w;
    wire                                                  weight_loaded;
    wire signed [DATA_WIDTH*KERNEL_SIZE*KERNEL_SIZE-1:0]  weight_flat;

    // Image ROM → pipeline
    wire signed [DATA_WIDTH-1:0]                          pixel_in;
    wire                                                  pixel_valid;
    wire                                                  frame_done;

    // Line buffer → Window generator
    wire [(KERNEL_SIZE-1)*DATA_WIDTH-1:0]                 row_out_flat;

    // Window generator → MAC array
    wire signed [DATA_WIDTH*KERNEL_SIZE*KERNEL_SIZE-1:0]  window_flat;
    wire                                                  window_valid;

    // MAC array → Accumulator
    wire signed [PROD_WIDTH*MAC_UNITS-1:0]                products;
    wire                                                  mac_valid;

    // Accumulator → ReLU
    wire signed [ACC_WIDTH-1:0]                           acc_result;
    wire                                                  acc_valid;

    // ReLU → feature_map_store
    wire [OUT_WIDTH-1:0]                                  relu_out;
    wire                                                  relu_valid;

    // Controller FSM
    wire                                                  pipe_en_fsm;
    wire                                                  done_fsm;
    wire                                                  ctrl_result_valid;

    // ROM enable – driven by the weight-load sequencer
    wire                                                  rom_en;

    // =========================================================================
    // Hard-wired Laplacian kernel loader
    // =========================================================================
    // Writes all 9 weights in 9 consecutive cycles after reset, then holds
    // weight_wr_en low.  Keeps the design fully self-contained on the FPGA.
    //
    //   -1  -1  -1
    //   -1   8  -1
    //   -1  -1  -1

    localparam NWEIGHTS = KERNEL_SIZE * KERNEL_SIZE;  // 9

    // wload_cnt: 0 = idle (pre-start), 1-9 = writing weight[0..8], 10 = done
    // We use a separate reg for the address presented to weight_buffer so that
    // address and data are always in lock-step.
    reg [3:0]  wload_cnt;   // counts write beats: goes 0→NWEIGHTS then stops
    reg        wload_done;  // latched high after all 9 writes complete
    reg        wload_active;// we are currently writing weights

    // Registered weight signals driven combinatorially from wload_cnt-1
    reg [$clog2(NWEIGHTS)-1:0]   w_addr_r;
    reg signed [DATA_WIDTH-1:0]  w_data_r;
    reg                           w_en_r;

    // Kernel constants (synthesised as LUT constants, not real memory)
    function signed [DATA_WIDTH-1:0] krn_val;
        input integer idx;
        begin
            case (idx)
                0,1,2,3,5,6,7,8: krn_val = -8'sd1;
                4:                krn_val =  8'sd8;
                default:          krn_val =  8'sd0;
            endcase
        end
    endfunction

    always @(posedge clk) begin
        if (rst) begin
            wload_cnt    <= 0;
            wload_done   <= 1'b0;
            wload_active <= 1'b0;
            w_en_r       <= 1'b0;
            w_addr_r     <= 0;
            w_data_r     <= 0;
        end else begin
            w_en_r <= 1'b0;  // default

            if (!wload_done) begin
                if (!wload_active) begin
                    wload_active <= 1'b1;   // start immediately after reset
                end else if (wload_cnt < NWEIGHTS) begin
                    // Present weight[wload_cnt] to the buffer
                    w_en_r   <= 1'b1;
                    w_addr_r <= wload_cnt[$clog2(NWEIGHTS)-1:0];
                    w_data_r <= krn_val(wload_cnt);
                    wload_cnt <= wload_cnt + 1;
                end else begin
                    // All 9 weights written
                    wload_done   <= 1'b1;
                    wload_active <= 1'b0;
                end
            end
        end
    end

    assign weight_wr_en_w   = w_en_r;
    assign weight_wr_addr_w = w_addr_r;
    assign weight_wr_data_w = w_data_r;

    // ── start latch: capture start pulse, used to kick the ROM ───────────────
    // The ROM will begin streaming as soon as both wload_done=1 AND
    // start_latched=1.  start can arrive before or after weight loading.
    reg start_latched;
    always @(posedge clk) begin
        if (rst)        start_latched <= 1'b0;
        else if (start) start_latched <= 1'b1;
    end

    // rom_en is a level; image_rom latches it on the first cycle it sees it
    assign rom_en = wload_done && start_latched;

    // =========================================================================
    // Sub-module instantiation
    // =========================================================================

    // ── 1. Controller FSM ─────────────────────────────────────────────────
    controller_fsm #(
        .IMAGE_WIDTH  (IMAGE_WIDTH),
        .IMAGE_HEIGHT (IMAGE_HEIGHT),
        .KERNEL_SIZE  (KERNEL_SIZE)
    ) u_ctrl (
        .clk            (clk),
        .rst_n          (rst_n),
        .start          (start),
        .weight_loaded  (weight_loaded),
        .pixel_valid_in (pixel_valid),
        .pipe_en        (pipe_en_fsm),
        .done_out       (done_fsm),
        .result_valid   (ctrl_result_valid)
    );

    // ── 2. Weight Buffer ───────────────────────────────────────────────────
    weight_buffer #(
        .DATA_WIDTH  (DATA_WIDTH),
        .KERNEL_SIZE (KERNEL_SIZE)
    ) u_weights (
        .clk           (clk),
        .rst_n         (rst_n),
        .weight_wr_en  (weight_wr_en_w),
        .weight_wr_addr(weight_wr_addr_w),
        .weight_wr_data(weight_wr_data_w),
        .weight_flat   (weight_flat),
        .weight_loaded (weight_loaded)
    );

    // ── 3. Image ROM ───────────────────────────────────────────────────────
    image_rom #(
        .DATA_WIDTH   (DATA_WIDTH),
        .IMAGE_PIXELS (IMAGE_WIDTH * IMAGE_HEIGHT)
    ) u_img_rom (
        .clk        (clk),
        .rst        (rst),
        .en         (rom_en),
        .pixel_out  (pixel_in),
        .pixel_valid(pixel_valid),
        .frame_done (frame_done)
    );

    // ── 4. Line Buffer ─────────────────────────────────────────────────────
    line_buffer #(
        .DATA_WIDTH  (DATA_WIDTH),
        .IMAGE_WIDTH (IMAGE_WIDTH),
        .KERNEL_SIZE (KERNEL_SIZE)
    ) u_line_buf (
        .clk         (clk),
        .rst_n       (rst_n),
        .pixel_in    (pixel_in),
        .pixel_valid (pixel_valid),
        .row_out_flat(row_out_flat)
    );

    // ── 5. Window Generator ────────────────────────────────────────────────
    window_generator #(
        .DATA_WIDTH  (DATA_WIDTH),
        .IMAGE_WIDTH (IMAGE_WIDTH),
        .KERNEL_SIZE (KERNEL_SIZE)
    ) u_win_gen (
        .clk         (clk),
        .rst_n       (rst_n),
        .pixel_in    (pixel_in),
        .pixel_valid (pixel_valid),
        .row_out_flat(row_out_flat),
        .window_flat (window_flat),
        .window_valid(window_valid)
    );

    // ── 6. MAC Array ───────────────────────────────────────────────────────
    mac_array #(
        .DATA_WIDTH (DATA_WIDTH),
        .PROD_WIDTH (PROD_WIDTH),
        .MAC_UNITS  (MAC_UNITS)
    ) u_mac_arr (
        .clk        (clk),
        .rst_n      (rst_n),
        .enable     (window_valid),
        .pixel_flat (window_flat),
        .weight_flat(weight_flat),
        .products   (products),
        .valid_out  (mac_valid)
    );

    // ── 7. Accumulator ─────────────────────────────────────────────────────
    accumulator #(
        .PROD_WIDTH (PROD_WIDTH),
        .ACC_WIDTH  (ACC_WIDTH),
        .MAC_UNITS  (MAC_UNITS)
    ) u_accum (
        .clk      (clk),
        .rst_n    (rst_n),
        .products (products),
        .valid_in (mac_valid),
        .result   (acc_result),
        .valid_out(acc_valid)
    );

    // ── 8. ReLU Activation ─────────────────────────────────────────────────
    activation_relu #(
        .ACC_WIDTH (ACC_WIDTH),
        .OUT_WIDTH (OUT_WIDTH)
    ) u_relu (
        .clk      (clk),
        .rst_n    (rst_n),
        .acc_in   (acc_result),
        .valid_in (acc_valid),
        .feature  (relu_out),
        .valid_out(relu_valid)
    );

    // ── 9. Feature Map Store & Serialiser ──────────────────────────────────
    feature_map_store #(
        .OUT_WIDTH (OUT_WIDTH),
        .STORE_W   (STORE_WIDTH),
        .TOTAL_OUT (TOTAL_OUT)
    ) u_fmap (
        .clk         (clk),
        .rst         (rst),
        .feature_in  (relu_out),
        .valid_in    (relu_valid),
        .feature_out (feature_out),
        .valid_out   (valid),
        .capture_done(/* unused at top level */)
    );

endmodule