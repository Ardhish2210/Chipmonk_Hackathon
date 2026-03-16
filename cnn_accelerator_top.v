// =============================================================================
// Module      : cnn_accelerator_top.v
// Description : Top-level INT8 CNN convolution accelerator.
//               Integrates all sub-modules in a streaming pipeline:
//
//   (1) INT8 activations + INT8 weights  → ConvNet core
//       pixel_in ─► line_buffer ─► window_generator ─► mac_array
//                                                        │
//   (2) INT8 weight buffering
//       weight_buffer ─────────────────────────────────►─┘
//                                                        │
//   (3) Fixed-point MAC accumulation + ReLU
//                                                  accumulator
//                                                        │
//                                               activation_relu
//                                                        │
//                                               feature_out stream
//
//   (4) Simple control FSM (start / done, optional enables)
//       controller_fsm provides a basic control shell around
//       the streaming datapath.
//
// Parameters  :
//   IMAGE_WIDTH   – pixels per row
//   IMAGE_HEIGHT  – rows per image
//   KERNEL_SIZE   – K (convolution kernel is K×K)
//   DATA_WIDTH    – pixel & weight bit-width (8 for INT8 ConvNet core)
//   PROD_WIDTH    – MAC product width (16, fixed-point)
//   ACC_WIDTH     – accumulator width (32, fixed-point)
//   OUT_WIDTH     – feature-map output width (8, post-ReLU)
//   MAC_UNITS     – parallel MAC units (must equal KERNEL_SIZE²)
// =============================================================================

`include "line_buffer.v"
`include "window_generator.v"
`include "weight_buffer.v"
`include "mac_array.v"
`include "accumulator.v"
`include "activation_relu.v"
`include "controller_fsm.v"

module cnn_accelerator_top #(
    parameter IMAGE_WIDTH  = 8,
    parameter IMAGE_HEIGHT = 8,
    parameter KERNEL_SIZE  = 3,
    parameter DATA_WIDTH   = 8,
    parameter PROD_WIDTH   = 16,
    parameter ACC_WIDTH    = 32,
    parameter OUT_WIDTH    = 8,
    parameter MAC_UNITS    = 9    // = KERNEL_SIZE × KERNEL_SIZE
) (
    input  wire                                     clk,
    input  wire                                     rst_n,
    // Control
    input  wire                                     start,      // pulse to begin
    output wire                                     done,       // one-cycle pulse
    // Weight loading
    input  wire                                     weight_wr_en,
    input  wire [$clog2(KERNEL_SIZE*KERNEL_SIZE)-1:0] weight_wr_addr,
    input  wire signed [DATA_WIDTH-1:0]             weight_wr_data,
    // Pixel input stream
    input  wire signed [DATA_WIDTH-1:0]             pixel_in,
    input  wire                                     pixel_valid,
    // Feature map output stream
    output wire [OUT_WIDTH-1:0]                     feature_out,
    output wire                                     feature_valid
);

    // =========================================================================
    // Internal wires
    // =========================================================================

    // Line buffer → Window generator (flat packed bus)
    wire [(KERNEL_SIZE-1)*DATA_WIDTH-1:0] row_out_flat;

    // Weight buffer → MAC array
    wire signed [DATA_WIDTH*KERNEL_SIZE*KERNEL_SIZE-1:0] weight_flat;
    wire                                                  weight_loaded;

    // Window generator → MAC array
    wire signed [DATA_WIDTH*KERNEL_SIZE*KERNEL_SIZE-1:0] window_flat;
    wire                                                  window_valid;

    // MAC array → Accumulator
    wire signed [PROD_WIDTH*MAC_UNITS-1:0]               products;
    wire                                                  mac_valid;

    // Accumulator → ReLU
    wire signed [ACC_WIDTH-1:0]                          acc_result;
    wire                                                 acc_valid;

    // Simple global pipeline enable. Currently we keep the
    // datapath always enabled once out of reset; a lightweight
    // controller FSM is instantiated below to provide a valid
    // 'done' indication without tightly gating the pipeline.
    wire                                                 pipe_en;
    wire                                                 pipe_en_fsm;
    wire                                                 ctrl_result_valid;

    // =========================================================================
    // Sub-module instantiation
    // =========================================================================

    // ── 1. Simple Control FSM ─────────────────────────────────────────────
    // Provides a basic start/done handshake and optional pipeline gating.
    // The datapath's 'pipe_en' is still forced high so that existing
    // streaming behaviour and timing remain unchanged, but 'done' is now
    // driven by the FSM to indicate end-of-frame.
    controller_fsm #(
        .IMAGE_WIDTH  (IMAGE_WIDTH),
        .IMAGE_HEIGHT (IMAGE_HEIGHT),
        .KERNEL_SIZE  (KERNEL_SIZE)
    ) u_ctrl (
        .clk           (clk),
        .rst_n         (rst_n),
        .start         (start),
        .weight_loaded (weight_loaded),
        .pixel_valid_in(pixel_valid),
        .pipe_en       (pipe_en_fsm),
        .done_out      (done),
        .result_valid  (ctrl_result_valid)
    );

    // Keep datapath permanently enabled; FSM can be wired in later if
    // tighter clock-gating is desired.
    assign pipe_en = 1'b1;

    // ── 2. Weight Buffer ───────────────────────────────────────────────────
    weight_buffer #(
        .DATA_WIDTH  (DATA_WIDTH),
        .KERNEL_SIZE (KERNEL_SIZE)
    ) u_weights (
        .clk          (clk),
        .rst_n        (rst_n),
        .weight_wr_en  (weight_wr_en),
        .weight_wr_addr(weight_wr_addr),
        .weight_wr_data(weight_wr_data),
        .weight_flat   (weight_flat),
        .weight_loaded (weight_loaded)
    );

    // ── 3. Line Buffer ─────────────────────────────────────────────────────
    line_buffer #(
        .DATA_WIDTH  (DATA_WIDTH),
        .IMAGE_WIDTH (IMAGE_WIDTH),
        .KERNEL_SIZE (KERNEL_SIZE)
    ) u_line_buf (
        .clk         (clk),
        .rst_n       (rst_n),
        .pixel_in    (pixel_in),
        .pixel_valid (pixel_valid & pipe_en),
        .row_out_flat(row_out_flat)
    );

    // ── 4. Window Generator ────────────────────────────────────────────────
    window_generator #(
        .DATA_WIDTH  (DATA_WIDTH),
        .IMAGE_WIDTH (IMAGE_WIDTH),
        .KERNEL_SIZE (KERNEL_SIZE)
    ) u_win_gen (
        .clk          (clk),
        .rst_n        (rst_n),
        .pixel_in     (pixel_in),
        .pixel_valid  (pixel_valid & pipe_en),
        .row_out_flat (row_out_flat),
        .window_flat  (window_flat),
        .window_valid (window_valid)
    );

    // ── 5. MAC Array ───────────────────────────────────────────────────────
    mac_array #(
        .DATA_WIDTH (DATA_WIDTH),
        .PROD_WIDTH (PROD_WIDTH),
        .MAC_UNITS  (MAC_UNITS)
    ) u_mac_arr (
        .clk        (clk),
        .rst_n      (rst_n),
        // Enable MACs whenever a valid K×K window is available.
        .enable     (window_valid),
        .pixel_flat (window_flat),
        .weight_flat(weight_flat),
        .products   (products),
        .valid_out  (mac_valid)
    );

    // ── 6. Accumulator (Adder Tree) ────────────────────────────────────────
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

    // ── 7. ReLU Activation ─────────────────────────────────────────────────
    activation_relu #(
        .ACC_WIDTH (ACC_WIDTH),
        .OUT_WIDTH (OUT_WIDTH)
    ) u_relu (
        .clk      (clk),
        .rst_n    (rst_n),
        .acc_in   (acc_result),
        .valid_in (acc_valid),
        .feature  (feature_out),
        .valid_out(feature_valid)
    );

endmodule