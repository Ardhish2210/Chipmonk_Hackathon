`timescale 1ns / 1ps
// =============================================================================
// tb_cnn_fpga_top.v  –  Updated testbench
// Additions vs original:
//   1. Saves RTL output to feature_map_out.txt  (decimal, one pixel/line)
//   2. Saves RTL output to feature_map_out.mem  (hex, one pixel/line)
//      (feature_map_store.v also writes these directly when capture completes)
//   3. Saves the input image  to input_image.txt (decimal, one pixel/line)
//      so Colab can display both input and output side by side.
// =============================================================================

`include "cnn_accelerator_top.v"

module tb_cnn_fpga_top;

    // -------------------------------------------------------------------------
    // Parameters
    // -------------------------------------------------------------------------
    parameter IMAGE_WIDTH  = 64;
    parameter IMAGE_HEIGHT = 64;
    parameter KERNEL_SIZE  = 3;
    parameter DATA_WIDTH   = 8;
    parameter PROD_WIDTH   = 16;
    parameter ACC_WIDTH    = 32;
    parameter OUT_WIDTH    = 8;
    parameter MAC_UNITS    = 9;
    parameter STORE_WIDTH  = 16;

    localparam OUT_W     = IMAGE_WIDTH  - KERNEL_SIZE + 1;  // 62
    localparam OUT_H     = IMAGE_HEIGHT - KERNEL_SIZE + 1;  // 62
    localparam TOTAL_OUT = OUT_W * OUT_H;                   // 3844

    // -------------------------------------------------------------------------
    // Clock – 100 MHz
    // -------------------------------------------------------------------------
    reg clk = 1'b0;
    always #5 clk = ~clk;

    // -------------------------------------------------------------------------
    // DUT ports
    // -------------------------------------------------------------------------
    reg                    rst   = 1'b1;
    reg                    start = 1'b0;
    wire [STORE_WIDTH-1:0] feature_out;
    wire                   valid;

    // -------------------------------------------------------------------------
    // DUT
    // -------------------------------------------------------------------------
    cnn_accelerator_top #(
        .IMAGE_WIDTH  (IMAGE_WIDTH),
        .IMAGE_HEIGHT (IMAGE_HEIGHT),
        .KERNEL_SIZE  (KERNEL_SIZE),
        .DATA_WIDTH   (DATA_WIDTH),
        .PROD_WIDTH   (PROD_WIDTH),
        .ACC_WIDTH    (ACC_WIDTH),
        .OUT_WIDTH    (OUT_WIDTH),
        .MAC_UNITS    (MAC_UNITS),
        .TOTAL_OUT    (TOTAL_OUT),
        .STORE_WIDTH  (STORE_WIDTH)
    ) dut (
        .clk         (clk),
        .rst         (rst),
        .start       (start),
        .feature_out (feature_out),
        .valid       (valid)
    );

    // -------------------------------------------------------------------------
    // Capture RTL output
    // -------------------------------------------------------------------------
    reg [STORE_WIDTH-1:0] captured [0:TOTAL_OUT-1];
    integer cap_idx = 0;

    always @(posedge clk) begin
        if (valid && cap_idx < TOTAL_OUT) begin
            captured[cap_idx] <= feature_out;
            cap_idx           <= cap_idx + 1;
        end
    end

    // -------------------------------------------------------------------------
    // SW golden model (Laplacian)
    // -------------------------------------------------------------------------
    reg [7:0]        img_raw  [0:4095];
    reg signed [7:0] img      [0:4095];
    reg signed [7:0] krn      [0:8];
    reg [15:0]       expected [0:TOTAL_OUT-1];

    integer i, rr, cc, kr, kc, acc_sw;
    integer pass_cnt, fail_cnt, mismatch;

    task compute_expected;
        begin
            for (rr = 0; rr < OUT_H; rr = rr + 1)
                for (cc = 0; cc < OUT_W; cc = cc + 1) begin
                    acc_sw = 0;
                    for (kr = 0; kr < KERNEL_SIZE; kr = kr + 1)
                        for (kc = 0; kc < KERNEL_SIZE; kc = kc + 1)
                            acc_sw = acc_sw
                                   + img[(rr+kr)*IMAGE_WIDTH + (cc+kc)]
                                   * krn[kr*KERNEL_SIZE + kc];
                    if (acc_sw < 0)   acc_sw = 0;
                    if (acc_sw > 255) acc_sw = 255;
                    expected[rr*OUT_W + cc] = acc_sw[15:0];
                end
        end
    endtask

    // -------------------------------------------------------------------------
    // File-save tasks
    // -------------------------------------------------------------------------
    integer fd;

    // Save input image as decimal (one signed pixel per line, 0-255 unsigned)
    task save_input_image;
        begin
            fd = $fopen("input_image.txt", "w");
            if (fd == 0) begin
                $display("[TB] ERROR: cannot open input_image.txt");
            end else begin
                for (i = 0; i < IMAGE_WIDTH * IMAGE_HEIGHT; i = i + 1)
                    // Store as unsigned 0-255 (add 256 if negative to get
                    // two's complement unsigned interpretation)
                    $fdisplay(fd, "%0d", img_raw[i]);
                $fclose(fd);
                $display("[TB] Wrote input_image.txt (%0d pixels, decimal unsigned)",
                          IMAGE_WIDTH * IMAGE_HEIGHT);
            end
        end
    endtask

    // Save RTL captured output as decimal
    task save_rtl_output;
        begin
            // Decimal .txt
            fd = $fopen("feature_map_rtl.txt", "w");
            if (fd == 0) begin
                $display("[TB] ERROR: cannot open feature_map_rtl.txt");
            end else begin
                for (i = 0; i < TOTAL_OUT; i = i + 1)
                    $fdisplay(fd, "%0d", captured[i]);
                $fclose(fd);
                $display("[TB] Wrote feature_map_rtl.txt  (%0d pixels, decimal)", TOTAL_OUT);
            end

            // Hex .mem
            fd = $fopen("feature_map_rtl.mem", "w");
            if (fd == 0) begin
                $display("[TB] ERROR: cannot open feature_map_rtl.mem");
            end else begin
                for (i = 0; i < TOTAL_OUT; i = i + 1)
                    $fdisplay(fd, "%02h", captured[i][7:0]);
                $fclose(fd);
                $display("[TB] Wrote feature_map_rtl.mem  (%0d pixels, hex)", TOTAL_OUT);
            end
        end
    endtask

    // Save SW reference output as decimal
    task save_sw_reference;
        begin
            fd = $fopen("feature_map_sw.txt", "w");
            if (fd == 0) begin
                $display("[TB] ERROR: cannot open feature_map_sw.txt");
            end else begin
                for (i = 0; i < TOTAL_OUT; i = i + 1)
                    $fdisplay(fd, "%0d", expected[i]);
                $fclose(fd);
                $display("[TB] Wrote feature_map_sw.txt   (%0d pixels, decimal)", TOTAL_OUT);
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // Stimulus
    // -------------------------------------------------------------------------
    initial begin
        $dumpfile("tb_cnn_fpga_top.vcd");
        $dumpvars(0, tb_cnn_fpga_top);

        pass_cnt = 0; fail_cnt = 0;

        // Load reference image
        $readmemh("image2.mem", img_raw);
        for (i = 0; i < 4096; i = i + 1)
            img[i] = $signed(img_raw[i]);

        // Laplacian kernel
        krn[0]=-8'd1; krn[1]=-8'd1; krn[2]=-8'd1;
        krn[3]=-8'd1; krn[4]= 8'd8; krn[5]=-8'd1;
        krn[6]=-8'd1; krn[7]=-8'd1; krn[8]=-8'd1;

        compute_expected;

        // Save input image file
        save_input_image;

        // Reset sequence
        rst = 1;
        repeat(8) @(posedge clk);
        @(negedge clk); rst = 0;
        repeat(4) @(posedge clk);

        // Wait for weight loading
        repeat(15) @(posedge clk);

        // Pulse start
        @(negedge clk); start = 1;
        @(posedge clk);
        @(negedge clk); start = 0;

        // Wait for all outputs
        begin : wait_loop
            integer timeout_cnt;
            timeout_cnt = 0;
            while (cap_idx < TOTAL_OUT && timeout_cnt < 200000) begin
                @(posedge clk);
                timeout_cnt = timeout_cnt + 1;
            end
            if (cap_idx < TOTAL_OUT)
                $display("[ERROR] Timed out: got %0d / %0d", cap_idx, TOTAL_OUT);
        end
        repeat(10) @(posedge clk);

        // ── Check results ─────────────────────────────────────────────────
        mismatch = 0;
        for (i = 0; i < TOTAL_OUT; i = i + 1)
            if (captured[i] !== expected[i]) begin
                mismatch = mismatch + 1;
                $display("  MISMATCH pixel[%0d] RTL=%0d  REF=%0d",
                          i, captured[i], expected[i]);
            end

        $display("========================================");
        if (mismatch == 0) begin
            $display("[PASS] All %0d pixels match!", TOTAL_OUT);
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("[FAIL] %0d mismatches.", mismatch);
            fail_cnt = fail_cnt + 1;
        end
        $display(" %0d PASSED  |  %0d FAILED", pass_cnt, fail_cnt);
        $display("========================================");

        // ── Save output files ────────────────────────────────────────────
        $display("");
        $display("Saving output files...");
        save_rtl_output;
        save_sw_reference;
        $display("Done. Files written:");
        $display("  input_image.txt       – 64x64 input  (decimal, 4096 lines)");
        $display("  feature_map_rtl.txt   – 62x62 RTL output (decimal, 3844 lines)");
        $display("  feature_map_rtl.mem   – 62x62 RTL output (hex,     3844 lines)");
        $display("  feature_map_sw.txt    – 62x62 SW  reference (decimal, 3844 lines)");
        $display("  feature_map_out.mem   – written by feature_map_store.v (hex)");
        $display("  feature_map_out.txt   – written by feature_map_store.v (decimal)");

        $finish;
    end

    // Watchdog
    initial begin
        #5000000;
        $display("[TIMEOUT]");
        $finish;
    end

endmodule