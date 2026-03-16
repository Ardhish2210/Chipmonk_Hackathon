# =============================================================================
# File        : cnn_accelerator.sdc
# Description : Synopsys Design Constraints (SDC) for the CNN Convolution
#               Accelerator targeting an FPGA (e.g., Xilinx Artix-7,
#               Zynq-7000, or Intel Cyclone V / MAX 10).
#
# Usage:
#   Xilinx Vivado  : Add this file as a Constraints source (.xdc or .sdc)
#   Intel Quartus  : Add via Assignment > Settings > Timing Analyzer
#   OpenROAD flow  : Pass with -sdc flag
#
# Design parameters assumed:
#   Clock target   : 100 MHz  (10 ns period)
#   DATA_WIDTH     : 8 bits (INT8)
#   IMAGE_WIDTH    : Parameterized
#   KERNEL_SIZE    : 3 (9 MAC units)
#   Async reset    : None (synchronous active-low rst_n)
# =============================================================================

# ─── 1. Primary Clock Definition ─────────────────────────────────────────────
# Target: 100 MHz (10 ns period) on the clock input port.
# Adjust -period to match your FPGA's PLL / oscillator if different.
# For timing margin: the accumulator adder chain is the critical path
# (~5-6 LUT levels at 8-bit + 32-bit add) → 10 ns is conservative.
# =============================================================================

create_clock \
    -name  sys_clk \
    -period 10.000 \
    -waveform {0.000 5.000} \
    [get_ports clk]

# ─── 2. Clock Uncertainty (jitter + skew) ────────────────────────────────────
# 200 ps setup / 100 ps hold uncertainty for on-chip clock network
set_clock_uncertainty -setup 0.200 [get_clocks sys_clk]
set_clock_uncertainty -hold  0.100 [get_clocks sys_clk]

# ─── 3. Clock Latency ────────────────────────────────────────────────────────
# Source latency: PCB trace / oscillator delay
# Network latency: FPGA global clock buffer (BUFG) ~0.5 ns
set_clock_latency -source 0.500 [get_clocks sys_clk]
set_clock_latency          0.500 [get_clocks sys_clk]

# ─── 4. Input Delay Constraints ──────────────────────────────────────────────
# All signals are registered externally; assume external FF-to-board setup
# time of 2.0 ns max and 0.5 ns min (hold skew).

# Control / handshake signals
set_input_delay -clock sys_clk -max 2.0 [get_ports start]
set_input_delay -clock sys_clk -min 0.5 [get_ports start]

# Weight loading interface
set_input_delay -clock sys_clk -max 2.0 [get_ports weight_wr_en]
set_input_delay -clock sys_clk -min 0.5 [get_ports weight_wr_en]
set_input_delay -clock sys_clk -max 2.0 [get_ports weight_wr_addr]
set_input_delay -clock sys_clk -min 0.5 [get_ports weight_wr_addr]
set_input_delay -clock sys_clk -max 2.0 [get_ports weight_wr_data]
set_input_delay -clock sys_clk -min 0.5 [get_ports weight_wr_data]

# Pixel stream inputs
set_input_delay -clock sys_clk -max 2.0 [get_ports pixel_in]
set_input_delay -clock sys_clk -min 0.5 [get_ports pixel_in]
set_input_delay -clock sys_clk -max 2.0 [get_ports pixel_valid]
set_input_delay -clock sys_clk -min 0.5 [get_ports pixel_valid]

# Reset (treated as false path – see section 7)
set_input_delay -clock sys_clk -max 2.0 [get_ports rst_n]
set_input_delay -clock sys_clk -min 0.5 [get_ports rst_n]

# ─── 5. Output Delay Constraints ─────────────────────────────────────────────
# Downstream logic captures feature_out / feature_valid on the next board clock.

# Feature map output
set_output_delay -clock sys_clk -max 2.0 [get_ports feature_out]
set_output_delay -clock sys_clk -min 0.5 [get_ports feature_out]
set_output_delay -clock sys_clk -max 2.0 [get_ports feature_valid]
set_output_delay -clock sys_clk -min 0.5 [get_ports feature_valid]

# Done signal
set_output_delay -clock sys_clk -max 2.0 [get_ports done]
set_output_delay -clock sys_clk -min 0.5 [get_ports done]

# ─── 6. Drive / Load Estimates (optional but improves synthesis) ─────────────
# Set driving cell strength from an upstream flip-flop output
set_driving_cell -lib_cell FDRE -pin Q [get_ports pixel_in]
set_driving_cell -lib_cell FDRE -pin Q [get_ports weight_wr_data]

# Load on outputs (estimated 4 standard loads each)
set_load 0.020 [get_ports feature_out]
set_load 0.010 [get_ports feature_valid]
set_load 0.010 [get_ports done]

# ─── 7. False Paths ──────────────────────────────────────────────────────────
# rst_n is a synchronous reset; for board-level safety, treat source path
# as a false path from the reset pin (no timing requirement on reset tree).
set_false_path -from [get_ports rst_n]

# ─── 8. Multi-Cycle Paths ────────────────────────────────────────────────────
# Weight-loading only happens before inference (static between runs).
# Loosen setup to 2 cycles for weight bus to ease routing.
set_multicycle_path -setup 2 -from [get_ports weight_wr_data]
set_multicycle_path -setup 2 -from [get_ports weight_wr_addr]
set_multicycle_path -hold  1 -from [get_ports weight_wr_data]
set_multicycle_path -hold  1 -from [get_ports weight_wr_addr]

# ─── 9. Maximum Fanout ───────────────────────────────────────────────────────
# Prevent over-fanout on enable signals that feed large pipeline arrays
set_max_fanout 16 [get_nets -hierarchical pipe_en]
set_max_fanout 16 [get_nets -hierarchical window_valid]

# ─── 10. Operating Conditions (for ASIC flows or Quartus TimeQuest) ──────────
# set_operating_conditions -model slow -voltage 1.0 -temperature 85
# (Comment in for ASIC; Vivado/Quartus derive conditions from device part)

# ─── 11. Timing Exceptions for Simulation-Only Nets ─────────────────────────
# (none in this design — all synthesis-clean RTL)

# =============================================================================
# End of cnn_accelerator.sdc
#
# Summary:
#   Clock    : sys_clk @ 100 MHz (10 ns period)
#   I delays : 2.0 ns max / 0.5 ns min
#   O delays : 2.0 ns max / 0.5 ns min
#   False    : rst_n tree
#   MCP      : weight bus relaxed to 2 cycles
#   Fanout   : pipe_en, window_valid limited to 16
# =============================================================================
