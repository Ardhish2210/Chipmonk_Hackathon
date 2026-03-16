`timescale 1ns / 1ps
// =============================================================================
// tb_cnn_fpga_top.v
// Tests the Basys-3-compatible cnn_accelerator_top.
// The image ROM is now internal; only clk/rst/start are driven externally.
// feature_out (16-bit) and valid are monitored for the 36 output pixels.
// =============================================================================

`include "cnn_accelerator_top.v"

module tb_cnn_fpga_top;

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
    parameter STORE_WIDTH  = 16;

    localparam OUT_W     = IMAGE_WIDTH  - KERNEL_SIZE + 1;  // 6
    localparam OUT_H     = IMAGE_HEIGHT - KERNEL_SIZE + 1;  // 6
    localparam TOTAL_OUT = OUT_W * OUT_H;                   // 36

    // -------------------------------------------------------------------------
    // Clock – 100 MHz
    // -------------------------------------------------------------------------
    reg clk = 1'b0;
    always #5 clk = ~clk;

    // -------------------------------------------------------------------------
    // DUT ports
    // -------------------------------------------------------------------------
    reg                   rst   = 1'b1;
    reg                   start = 1'b0;
    wire [STORE_WIDTH-1:0] feature_out;
    wire                   valid;

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
    // Capture output
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
    // SW golden model (Laplacian, same as before)
    // -------------------------------------------------------------------------
    reg [7:0]        img_raw  [0:63];
    reg signed [7:0] img      [0:63];
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
    // Stimulus
    // -------------------------------------------------------------------------
    initial begin
        $dumpfile("tb_cnn_fpga_top.vcd");
        $dumpvars(0, tb_cnn_fpga_top);

        pass_cnt = 0; fail_cnt = 0;

        // ── Load reference image (same file as image_rom uses) ────────────
        $readmemh("image.mem", img_raw);
        for (i = 0; i < 64; i = i + 1)
            img[i] = $signed(img_raw[i]);

        // ── Laplacian kernel ──────────────────────────────────────────────
        krn[0]=-8'd1; krn[1]=-8'd1; krn[2]=-8'd1;
        krn[3]=-8'd1; krn[4]= 8'd8; krn[5]=-8'd1;
        krn[6]=-8'd1; krn[7]=-8'd1; krn[8]=-8'd1;

        compute_expected;

        // ── Reset: hold for 8 cycles, then release ────────────────────────
        rst = 1;
        repeat(8) @(posedge clk);
        @(negedge clk); rst = 0;   // release on negedge to avoid setup race
        repeat(4) @(posedge clk);

        // ── Wait for weight loading to finish (9 writes + 2 spare cycles) ─
        // The top module auto-loads weights immediately after reset; we just
        // wait long enough before pulsing start.
        repeat(15) @(posedge clk);

        // ── Pulse start for one cycle ──────────────────────────────────────
        @(negedge clk); start = 1;
        @(posedge clk);
        @(negedge clk); start = 0;

        // ── Wait for all 36 outputs (cycle-count loop, not blocking wait) ──
        begin : wait_loop
            integer timeout_cnt;
            timeout_cnt = 0;
            while (cap_idx < TOTAL_OUT && timeout_cnt < 2000) begin
                @(posedge clk);
                timeout_cnt = timeout_cnt + 1;
            end
            if (cap_idx < TOTAL_OUT)
                $display("[ERROR] Timed out waiting for outputs: got %0d / %0d",
                          cap_idx, TOTAL_OUT);
        end
        repeat(10) @(posedge clk);

        // ── Display & check ───────────────────────────────────────────────
        $display("========================================");
        $display(" CNN FPGA Top  –  Output Feature Map");
        $display("========================================");
        $display("  RTL output (16-bit, 6x6):");
        $display("      C0    C1    C2    C3    C4    C5");
        for (rr = 0; rr < OUT_H; rr = rr + 1) begin
            $write(" R%0d |", rr);
            for (cc = 0; cc < OUT_W; cc = cc + 1)
                $write("  %3d |", captured[rr*OUT_W+cc]);
            $display("");
        end
        $display("");
        $display("  SW reference (6x6):");
        $display("      C0    C1    C2    C3    C4    C5");
        for (rr = 0; rr < OUT_H; rr = rr + 1) begin
            $write(" R%0d |", rr);
            for (cc = 0; cc < OUT_W; cc = cc + 1)
                $write("  %3d |", expected[rr*OUT_W+cc]);
            $display("");
        end
        $display("");

        mismatch = 0;
        for (i = 0; i < TOTAL_OUT; i = i + 1)
            if (captured[i] !== expected[i]) begin
                mismatch = mismatch + 1;
                $display("  MISMATCH pixel[%0d] RTL=%0d  REF=%0d",
                          i, captured[i], expected[i]);
            end

        if (mismatch == 0) begin
            $display("[PASS] All %0d pixels match!", TOTAL_OUT);
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("[FAIL] %0d mismatches.", mismatch);
            fail_cnt = fail_cnt + 1;
        end

        $display("========================================");
        $display(" %0d PASSED  |  %0d FAILED", pass_cnt, fail_cnt);
        $display("========================================");
        $finish;
    end

    // Watchdog
    initial begin
        #5000000;
        $display("[TIMEOUT]");
        $finish;
    end

endmodule