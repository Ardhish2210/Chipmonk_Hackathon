// =============================================================================
// Module      : tb_cnn_accelerator.v
// Description : Self-checking testbench for the CNN accelerator.
//               Loads a real 8x8 grayscale image from "image.mem" (hex, one
//               byte per line), applies a 3x3 Laplacian kernel, captures the
//               6x6 output feature map, and verifies it against a software
//               reference (ReLU + saturate to 0..255).
//
// image.mem format : plain hex, one byte per line, exactly 64 lines.
//                    Example:
//                      3F
//                      A0
//                      ...
//                    Loaded with $readmemh.
//
// Pipeline latency (sized for DRAIN_CYCLES):
//   window_generator : +1 cycle (registered window_flat / window_valid)
//   mac_array        : +1 cycle (PIPELINE_REG=1 -- registered products)
//   accumulator      : +1 cycle (adder-tree result registered)
//   activation_relu  : +1 cycle (registered feature_out)
//   Window warm-up   : (K-1)*W + (K-1) = 2*8+2 = 18 pixels
//   Safety margin    : +10 cycles
//   Total drain      : 18 + 4 + 10 = 32 cycles after last pixel
//
// Compatible with Icarus Verilog 0.9.x (Verilog-2001 only -- no SV features).
// Key restrictions respected:
//   * No array task ports (arrays cannot be passed to/from tasks in V-2001)
//   * No underscore separators in numeric literals
//   * ASCII-only comments
// =============================================================================

`timescale 1ns / 1ps
`include "cnn_accelerator_top.v"

module tb_cnn_accelerator;

    // -------------------------------------------------------------------------
    // Parameters
    // -------------------------------------------------------------------------
    parameter IMAGE_WIDTH  = 8;
    parameter IMAGE_HEIGHT = 8;
    parameter KERNEL_SIZE  = 3;
    parameter DATA_WIDTH   = 8;
    parameter PROD_WIDTH   = 16;
    parameter ACC_WIDTH    = 32;
    parameter OUT_WIDTH    = 8;
    parameter MAC_UNITS    = 9;

    localparam OUT_W      = IMAGE_WIDTH  - KERNEL_SIZE + 1;  // 6
    localparam OUT_H      = IMAGE_HEIGHT - KERNEL_SIZE + 1;  // 6
    localparam TOTAL_IN   = IMAGE_WIDTH  * IMAGE_HEIGHT;     // 64
    localparam TOTAL_OUT  = OUT_W * OUT_H;                   // 36

    // Drain after last pixel:
    //   warm-up (18) + pipe stages (4) + safety (10) = 32
    localparam DRAIN_CYCLES = (KERNEL_SIZE-1)*IMAGE_WIDTH
                              + (KERNEL_SIZE-1) + 4 + 10;

    // -------------------------------------------------------------------------
    // Clock -- 100 MHz / 10 ns period
    // -------------------------------------------------------------------------
    reg clk = 1'b0;
    always #5 clk = ~clk;

    // -------------------------------------------------------------------------
    // DUT ports
    // -------------------------------------------------------------------------
    reg                   rst_n          = 1'b0;
    reg                   start          = 1'b0;
    wire                  done;
    reg                   weight_wr_en   = 1'b0;
    reg  [3:0]            weight_wr_addr = 4'd0;
    reg  signed [7:0]     weight_wr_data = 8'd0;
    reg  signed [7:0]     pixel_in       = 8'd0;
    reg                   pixel_valid    = 1'b0;
    wire [OUT_WIDTH-1:0]  feature_out;
    wire                  feature_valid;

    // -------------------------------------------------------------------------
    // DUT instantiation
    // -------------------------------------------------------------------------
    cnn_accelerator_top #(
        .IMAGE_WIDTH  (IMAGE_WIDTH),
        .IMAGE_HEIGHT (IMAGE_HEIGHT),
        .KERNEL_SIZE  (KERNEL_SIZE),
        .DATA_WIDTH   (DATA_WIDTH),
        .PROD_WIDTH   (PROD_WIDTH),
        .ACC_WIDTH    (ACC_WIDTH),
        .OUT_WIDTH    (OUT_WIDTH),
        .MAC_UNITS    (MAC_UNITS)
    ) dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .start          (start),
        .done           (done),
        .weight_wr_en   (weight_wr_en),
        .weight_wr_addr (weight_wr_addr),
        .weight_wr_data (weight_wr_data),
        .pixel_in       (pixel_in),
        .pixel_valid    (pixel_valid),
        .feature_out    (feature_out),
        .feature_valid  (feature_valid)
    );

    // -------------------------------------------------------------------------
    // Data arrays
    //   img_raw  -- unsigned bytes as read from image.mem
    //   img      -- same values reinterpreted as signed (for SW model)
    //   krn      -- 3x3 Laplacian weights (signed)
    //   expected -- SW golden-model 6x6 output
    //   captured -- RTL 6x6 output captured from feature_out
    // -------------------------------------------------------------------------
    reg [7:0]        img_raw  [0:TOTAL_IN-1];
    reg signed [7:0] img      [0:TOTAL_IN-1];
    reg signed [7:0] krn      [0:8];
    reg [7:0]        expected [0:TOTAL_OUT-1];
    reg [7:0]        captured [0:TOTAL_OUT-1];

    // -------------------------------------------------------------------------
    // Output capture -- fires on every feature_valid pulse
    // -------------------------------------------------------------------------
    integer cap_idx;
    always @(posedge clk) begin
        if (feature_valid && cap_idx < TOTAL_OUT) begin
            captured[cap_idx] <= feature_out;
            cap_idx           <= cap_idx + 1;
        end
    end

    // -------------------------------------------------------------------------
    // Shared variables (module scope -- avoids Icarus 0.9.x task-local issues)
    // -------------------------------------------------------------------------
    integer i, r, c;
    integer acc_sw;
    integer pass_cnt, fail_cnt, mismatch;
    integer wi;

    // =========================================================================
    // Task : full synchronous reset
    // =========================================================================
    task do_reset;
        begin
            rst_n        = 0;
            start        = 0;
            pixel_valid  = 0;
            weight_wr_en = 0;
            pixel_in     = 0;
            cap_idx      = 0;
            repeat(6) @(posedge clk);
            rst_n = 1;
            @(posedge clk);
        end
    endtask

    // =========================================================================
    // Task : write all 9 Laplacian weights into the DUT weight buffer.
    //        Reads from module-level 'krn' array.
    //        After the 9th write the FSM sees weight_loaded and moves
    //        LOAD -> RUN; 4 extra cycles covers that transition.
    // =========================================================================
    task do_load_weights;
        begin
            for (wi = 0; wi < 9; wi = wi + 1) begin
                weight_wr_en   = 1;
                weight_wr_addr = wi[3:0];
                weight_wr_data = krn[wi];
                @(posedge clk);
            end
            weight_wr_en = 0;
            repeat(4) @(posedge clk);
        end
    endtask

    // =========================================================================
    // Task : stream all 64 pixels then drain the pipeline.
    //        Reads from module-level 'img' array.
    // =========================================================================
    task do_stream;
        begin
            for (i = 0; i < TOTAL_IN; i = i + 1) begin
                pixel_in    = img[i];
                pixel_valid = 1;
                @(posedge clk);
            end
            pixel_valid = 0;
            pixel_in    = 0;
            repeat(DRAIN_CYCLES) @(posedge clk);
        end
    endtask

    // =========================================================================
    // Task : software golden-model convolution
    //   out[r][c] = ReLU( sum_{kr,kc} img[r+kr][c+kc] * krn[kr*K+kc] )
    //   clipped to 0..255, VALID convolution (no padding, stride=1).
    //   Reads 'img' and 'krn'; writes 'expected'.
    // =========================================================================
    task do_compute_expected;
        integer rr, cc, kr, kc;
        begin
            for (rr = 0; rr < OUT_H; rr = rr + 1) begin
                for (cc = 0; cc < OUT_W; cc = cc + 1) begin
                    acc_sw = 0;
                    for (kr = 0; kr < KERNEL_SIZE; kr = kr + 1) begin
                        for (kc = 0; kc < KERNEL_SIZE; kc = kc + 1) begin
                            acc_sw = acc_sw
                                   + img[(rr+kr)*IMAGE_WIDTH + (cc+kc)]
                                   * krn[kr*KERNEL_SIZE + kc];
                        end
                    end
                    if (acc_sw < 0)   acc_sw = 0;    // ReLU
                    if (acc_sw > 255) acc_sw = 255;  // saturate
                    expected[rr*OUT_W + cc] = acc_sw[7:0];
                end
            end
        end
    endtask

    // =========================================================================
    // Task : print the 8x8 raw input image
    //        Uses module-level 'img_raw' directly (no array task port).
    // =========================================================================
    task print_image;
        integer pr, pc;
        begin
            $display("  Input image (8x8, unsigned pixel values):");
            $display("      C0   C1   C2   C3   C4   C5   C6   C7");
            $display("    +----+----+----+----+----+----+----+----+");
            for (pr = 0; pr < IMAGE_HEIGHT; pr = pr + 1) begin
                $write(" R%0d |", pr);
                for (pc = 0; pc < IMAGE_WIDTH; pc = pc + 1)
                    $write(" %3d |", img_raw[pr*IMAGE_WIDTH + pc]);
                $display("");
            end
            $display("    +----+----+----+----+----+----+----+----+");
        end
    endtask

    // =========================================================================
    // Task : print the 6x6 RTL captured output
    //        Uses module-level 'captured' directly (no array task port).
    // =========================================================================
    task print_captured;
        integer pr, pc;
        begin
            $display("  RTL output -- DUT captured (6x6):");
            $display("      C0   C1   C2   C3   C4   C5");
            $display("    +----+----+----+----+----+----+");
            for (pr = 0; pr < OUT_H; pr = pr + 1) begin
                $write(" R%0d |", pr);
                for (pc = 0; pc < OUT_W; pc = pc + 1)
                    $write(" %3d |", captured[pr*OUT_W + pc]);
                $display("");
            end
            $display("    +----+----+----+----+----+----+");
        end
    endtask

    // =========================================================================
    // Task : print the 6x6 SW golden-model reference output
    //        Uses module-level 'expected' directly (no array task port).
    // =========================================================================
    task print_expected;
        integer pr, pc;
        begin
            $display("  SW golden-model reference output (6x6):");
            $display("      C0   C1   C2   C3   C4   C5");
            $display("    +----+----+----+----+----+----+");
            for (pr = 0; pr < OUT_H; pr = pr + 1) begin
                $write(" R%0d |", pr);
                for (pc = 0; pc < OUT_W; pc = pc + 1)
                    $write(" %3d |", expected[pr*OUT_W + pc]);
                $display("");
            end
            $display("    +----+----+----+----+----+----+");
        end
    endtask

    // =========================================================================
    // Task : pixel-by-pixel self-check, captured vs expected.
    //        Prints row/col coordinates on any mismatch.
    // =========================================================================
    task do_check;
        integer ci;
        begin
            mismatch = 0;
            for (ci = 0; ci < TOTAL_OUT; ci = ci + 1) begin
                if (captured[ci] !== expected[ci]) begin
                    if (mismatch == 0)
                        $display("  *** PIXEL MISMATCHES DETECTED ***");
                    $display("    pixel[%0d] (R%0d,C%0d)  RTL=%0d  REF=%0d",
                              ci, ci/OUT_W, ci%OUT_W,
                              captured[ci], expected[ci]);
                    mismatch = mismatch + 1;
                end
            end

            if (mismatch == 0) begin
                $display("  [PASS]  All %0d output pixels match the reference.",
                          TOTAL_OUT);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("  [FAIL]  %0d / %0d pixels differ.",
                          mismatch, TOTAL_OUT);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    // =========================================================================
    // Main stimulus
    // =========================================================================
    initial begin
        $dumpfile("tb_cnn_accelerator.vcd");
        $dumpvars(0, tb_cnn_accelerator);

        pass_cnt = 0;
        fail_cnt = 0;

        // ---------------------------------------------------------------------
        // Step 1 : Load image from file
        //   image.mem must contain exactly 64 hex byte values, one per line.
        //   Example content:
        //     00
        //     1F
        //     A3   <- pixel index 2
        //     ...
        // ---------------------------------------------------------------------
        $readmemh("image1.mem", img_raw);

        // Reinterpret each unsigned byte as a signed INT8 for the SW model.
        // This matches how the DUT treats pixel_in (signed [7:0]).
        for (i = 0; i < TOTAL_IN; i = i + 1)
            img[i] = $signed(img_raw[i]);

        $display("====================================================");
        $display(" CNN Accelerator -- Real Image Laplacian Test");
        $display(" Image : %0dx%0d px   Kernel : %0dx%0d Laplacian",
                  IMAGE_WIDTH, IMAGE_HEIGHT, KERNEL_SIZE, KERNEL_SIZE);
        $display("====================================================");
        $display("");
        print_image;

        // ---------------------------------------------------------------------
        // Step 2 : Set up Laplacian kernel
        //
        //   -1  -1  -1
        //   -1   8  -1
        //   -1  -1  -1
        //
        // Flat regions produce 0 (after ReLU).
        // Edges/corners produce positive values proportional to contrast.
        // ---------------------------------------------------------------------
        krn[0] = -8'd1;  krn[1] = -8'd1;  krn[2] = -8'd1;
        krn[3] = -8'd1;  krn[4] =  8'd8;  krn[5] = -8'd1;
        krn[6] = -8'd1;  krn[7] = -8'd1;  krn[8] = -8'd1;

        $display("");
        $display("  Laplacian kernel (row-major, 3x3):");
        $display("    [ %3d  %3d  %3d ]", krn[0], krn[1], krn[2]);
        $display("    [ %3d  %3d  %3d ]", krn[3], krn[4], krn[5]);
        $display("    [ %3d  %3d  %3d ]", krn[6], krn[7], krn[8]);
        $display("");

        // ---------------------------------------------------------------------
        // Step 3 : Compute SW golden-model reference output
        // ---------------------------------------------------------------------
        do_compute_expected;

        // ---------------------------------------------------------------------
        // Step 4 : Reset DUT, load weights, stream pixels, drain pipeline
        // ---------------------------------------------------------------------
        do_reset;
        start = 1; @(posedge clk); start = 0;

        do_load_weights;
        do_stream;

        // ---------------------------------------------------------------------
        // Step 5 : Display both output matrices
        // ---------------------------------------------------------------------
        $display("====================================================");
        $display(" Output Feature Maps (6x6, VALID convolution)");
        $display("====================================================");
        $display("");
        print_captured;
        $display("");
        print_expected;

        // ---------------------------------------------------------------------
        // Step 6 : Self-check and summary
        // ---------------------------------------------------------------------
        $display("");
        $display("----------------------------------------------------");
        $display(" Verification result:");
        do_check;
        $display("----------------------------------------------------");
        $display("");
        $display("====================================================");
        $display(" Summary : %0d PASSED  |  %0d FAILED", pass_cnt, fail_cnt);
        if (fail_cnt == 0)
            $display(" REAL IMAGE LAPLACIAN VERIFIED SUCCESSFULLY!");
        else
            $display(" MISMATCH -- check pipeline drain or DUT logic.");
        $display("====================================================");
        $display("");

        repeat(20) @(posedge clk);
        $finish;
    end

    // -------------------------------------------------------------------------
    // Safety watchdog -- 10 ms at 100 MHz = 10000000 ns
    // No underscore separator (not supported in Icarus Verilog 0.9.x)
    // -------------------------------------------------------------------------
    initial begin
        #10000000;
        $display("[TIMEOUT] Watchdog fired -- increase limit or check FSM.");
        $finish;
    end

endmodule