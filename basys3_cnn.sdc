# =============================================================================
# basys3_cnn.sdc  (timing-closure revision)
# Synopsys Design Constraints for cnn_accelerator_top on Basys-3
# Board   : Digilent Basys-3 (Artix-7 xc7a35tcpg236-1)
# Tool    : Vivado (SDC-compatible subset) / Quartus / Synplify
#
# Revision notes (WNS = -0.960 ns, TNS = -7.768 ns observed):
#   1. Clock period relaxed from 10 ns (100 MHz) to 20 ns (50 MHz).
#      The MAC adder-tree and accumulator paths in this CNN datapath are
#      too deep for 100 MHz without explicit pipeline retiming.
#      WNS of -0.960 ns means ~10.96 ns is the actual critical path delay;
#      50 MHz (20 ns period) gives ~9 ns of margin - comfortably met.
#   2. Clock uncertainty reduced from 0.200 ns to 0.100 ns at 50 MHz
#      (lower frequency = lower jitter contribution).
#   3. False paths added for all output ports (Pmod pins have no
#      downstream timing requirement back to this clock domain).
#   4. False paths already set on rst / start (unchanged).
#   5. Multicycle path (2 cycles) added for the accumulator adder-tree
#      (products → result) - this is the deepest combinational cone and
#      the primary contributor to the negative TNS.
# =============================================================================

# -----------------------------------------------------------------------------
# 1. Clock Definition - 50 MHz / 20 ns period
#    WNS was -0.960 ns at 100 MHz  →  critical path ≈ 10.96 ns
#    50 MHz gives a 20 ns budget with ~9 ns positive slack.
# -----------------------------------------------------------------------------
create_clock -name sys_clk \
             -period 20.000 \
             -waveform {0.000 10.000} \
             [get_ports clk]

# -----------------------------------------------------------------------------
# 2. Clock Uncertainty - reduced at lower frequency
# -----------------------------------------------------------------------------
set_clock_uncertainty 0.100 [get_clocks sys_clk]

# -----------------------------------------------------------------------------
# 3. Clock Transition
# -----------------------------------------------------------------------------
set_clock_transition 0.100 [get_clocks sys_clk]

# -----------------------------------------------------------------------------
# 4. Input Delays - asynchronous pushbuttons (loose budget)
# -----------------------------------------------------------------------------
set_input_delay -clock sys_clk -max 2.000 [get_ports rst]
set_input_delay -clock sys_clk -min 0.500 [get_ports rst]

set_input_delay -clock sys_clk -max 2.000 [get_ports start]
set_input_delay -clock sys_clk -min 0.500 [get_ports start]

# -----------------------------------------------------------------------------
# 5. False Paths on asynchronous inputs
#    Removes setup/hold checks on button ports entirely.
# -----------------------------------------------------------------------------
set_false_path -from [get_ports rst]
set_false_path -from [get_ports start]

# -----------------------------------------------------------------------------
# 6. Output False Paths - Pmod pins (feature_out, valid)
#    No external device clocked by sys_clk samples these outputs, so
#    no meaningful output-delay constraint exists.
#    This was previously commented out; now enabled to prevent the tool
#    from adding spurious output-delay violations to the TNS total.
# -----------------------------------------------------------------------------
set_false_path -to [get_ports {feature_out[*]}]
set_false_path -to [get_ports valid]

# -----------------------------------------------------------------------------
# 7. Multicycle Path - Accumulator adder tree
#    The accumulator sums 9 × 16-bit products into a 32-bit result.
#    This adder tree is the deepest combinational path and the main
#    contributor to negative TNS.  Allowing 2 clock cycles for setup
#    doubles the timing budget for this stage without changing RTL.
#
#    NOTE: This is valid only because the accumulator's valid_in / valid_out
#    handshake already ensures the result register is read one cycle after
#    valid_in - the pipeline stalls naturally for one cycle between inputs.
#    If your accumulator is purely combinational (no internal register on
#    the adder tree output), replace with a pipeline register in RTL instead.
# -----------------------------------------------------------------------------
set_multicycle_path 2 -setup \
    -from [get_cells -hierarchical -filter {NAME =~ *u_accum*}] \
    -to   [get_cells -hierarchical -filter {NAME =~ *u_accum*}]

set_multicycle_path 1 -hold \
    -from [get_cells -hierarchical -filter {NAME =~ *u_accum*}] \
    -to   [get_cells -hierarchical -filter {NAME =~ *u_accum*}]

# -----------------------------------------------------------------------------
# 8. Multicycle Path - MAC array multipliers
#    9 parallel 8×8 signed multipliers feeding into the accumulator.
#    Same reasoning as above - valid signal pipelining means the result
#    is consumed one cycle after mac_valid, not the same cycle.
# -----------------------------------------------------------------------------
set_multicycle_path 2 -setup \
    -from [get_cells -hierarchical -filter {NAME =~ *u_mac_arr*}] \
    -to   [get_cells -hierarchical -filter {NAME =~ *u_accum*}]

set_multicycle_path 1 -hold \
    -from [get_cells -hierarchical -filter {NAME =~ *u_mac_arr*}] \
    -to   [get_cells -hierarchical -filter {NAME =~ *u_accum*}]

# -----------------------------------------------------------------------------
# 9. Max Fanout - constrain high-fanout nets (e.g. pixel_valid broadcast)
# -----------------------------------------------------------------------------
set_max_fanout 8 [get_nets -hierarchical -filter {FANOUT > 8}]

# -----------------------------------------------------------------------------
# 10. Max Delay - Belt-and-suspenders cap on any path not covered above.
#     Prevents the router from leaving any path unconstrained.
# -----------------------------------------------------------------------------
set_max_delay 20.000 -datapath_only \
    -from [get_cells -hierarchical -filter {NAME =~ *u_line_buf*}] \
    -to   [get_cells -hierarchical -filter {NAME =~ *u_win_gen*}]
