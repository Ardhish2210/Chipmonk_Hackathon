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
    parameter IMAGE_WIDTH  = 64,
    parameter IMAGE_HEIGHT = 64,
    parameter KERNEL_SIZE  = 3,
    parameter DATA_WIDTH   = 8,
    parameter PROD_WIDTH   = 16,
    parameter ACC_WIDTH    = 32,
    parameter OUT_WIDTH    = 8,
    parameter MAC_UNITS    = 9,
    parameter TOTAL_OUT    = 3844,
    parameter STORE_WIDTH  = 16
)(
    input  wire                  clk,
    input  wire                  rst,
    input  wire                  start,
    output wire [STORE_WIDTH-1:0] feature_out,
    output wire                   valid
);

    wire rst_n = ~rst;

    wire                                                  weight_wr_en_w;
    wire [$clog2(KERNEL_SIZE*KERNEL_SIZE)-1:0]            weight_wr_addr_w;
    wire signed [DATA_WIDTH-1:0]                          weight_wr_data_w;
    wire                                                  weight_loaded;
    wire signed [DATA_WIDTH*KERNEL_SIZE*KERNEL_SIZE-1:0]  weight_flat;

    wire signed [DATA_WIDTH-1:0]                          pixel_in;
    wire                                                  pixel_valid;
    wire                                                  frame_done;

    wire [(KERNEL_SIZE-1)*DATA_WIDTH-1:0]                 row_out_flat;

    wire signed [DATA_WIDTH*KERNEL_SIZE*KERNEL_SIZE-1:0]  window_flat;
    wire                                                  window_valid;

    wire signed [PROD_WIDTH*MAC_UNITS-1:0]                products;
    wire                                                  mac_valid;

    wire signed [ACC_WIDTH-1:0]                           acc_result;
    wire                                                  acc_valid;

    wire [OUT_WIDTH-1:0]                                  relu_out;
    wire                                                  relu_valid;

    wire                                                  pipe_en_fsm;
    wire                                                  done_fsm;
    wire                                                  ctrl_result_valid;

    wire                                                  rom_en;

    // =========================================================================
    // Hard-wired Laplacian kernel loader
    // =========================================================================
    localparam NWEIGHTS = KERNEL_SIZE * KERNEL_SIZE;

    reg [3:0]  wload_cnt;
    reg        wload_done;
    reg        wload_active;

    reg [$clog2(NWEIGHTS)-1:0]   w_addr_r;
    reg signed [DATA_WIDTH-1:0]  w_data_r;
    reg                           w_en_r;

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
            w_en_r <= 1'b0;

            if (!wload_done) begin
                if (!wload_active) begin
                    wload_active <= 1'b1;
                end else if (wload_cnt < NWEIGHTS) begin
                    w_en_r   <= 1'b1;
                    w_addr_r <= wload_cnt[$clog2(NWEIGHTS)-1:0];
                    w_data_r <= krn_val(wload_cnt);
                    wload_cnt <= wload_cnt + 1;
                end else begin
                    wload_done   <= 1'b1;
                    wload_active <= 1'b0;
                end
            end
        end
    end

    assign weight_wr_en_w   = w_en_r;
    assign weight_wr_addr_w = w_addr_r;
    assign weight_wr_data_w = w_data_r;

    reg start_latched;
    always @(posedge clk) begin
        if (rst)        start_latched <= 1'b0;
        else if (start) start_latched <= 1'b1;
    end

    assign rom_en = wload_done && start_latched;

    // =========================================================================
    // Sub-module instantiation
    // =========================================================================

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
        .capture_done(/* unused */)
    );

endmodule