## =============================================================================
## basys3_cnn.xdc  –  Constraints for cnn_accelerator_top on Basys-3
## Board : Digilent Basys-3 (Artix-7 xc7a35tcpg236-1)
## =============================================================================

## ── Clock ─────────────────────────────────────────────────────────────────
## 100 MHz on-board oscillator
set_property PACKAGE_PIN W5   [get_ports clk]
set_property IOSTANDARD  LVCMOS33 [get_ports clk]
create_clock -period 10.000 -name sys_clk_pin -waveform {0.000 5.000} \
             -add [get_ports clk]

## ── Reset  (BTNC – Centre pushbutton, active-HIGH) ────────────────────────
set_property PACKAGE_PIN T17  [get_ports rst]
set_property IOSTANDARD  LVCMOS33 [get_ports rst]

## ── Start  (BTNL – Left pushbutton, active-HIGH) ─────────────────────────
set_property PACKAGE_PIN W19  [get_ports start]
set_property IOSTANDARD  LVCMOS33 [get_ports start]

## ── feature_out[15:0]  – mapped to JA + JB Pmod headers ─────────────────
## JA (bits 7:0)
set_property PACKAGE_PIN J1   [get_ports {feature_out[0]}]
set_property PACKAGE_PIN L2   [get_ports {feature_out[1]}]
set_property PACKAGE_PIN J2   [get_ports {feature_out[2]}]
set_property PACKAGE_PIN G2   [get_ports {feature_out[3]}]
set_property PACKAGE_PIN H1   [get_ports {feature_out[4]}]
set_property PACKAGE_PIN K2   [get_ports {feature_out[5]}]
set_property PACKAGE_PIN H2   [get_ports {feature_out[6]}]
set_property PACKAGE_PIN G3   [get_ports {feature_out[7]}]

## JB (bits 15:8)
set_property PACKAGE_PIN A14  [get_ports {feature_out[8]}]
set_property PACKAGE_PIN A16  [get_ports {feature_out[9]}]
set_property PACKAGE_PIN B15  [get_ports {feature_out[10]}]
set_property PACKAGE_PIN B16  [get_ports {feature_out[11]}]
set_property PACKAGE_PIN A15  [get_ports {feature_out[12]}]
set_property PACKAGE_PIN A17  [get_ports {feature_out[13]}]
set_property PACKAGE_PIN C15  [get_ports {feature_out[14]}]
set_property PACKAGE_PIN C16  [get_ports {feature_out[15]}]

set_property IOSTANDARD LVCMOS33 [get_ports {feature_out[*]}]

## ── valid  – JC pin 1 (Pmod JC) ──────────────────────────────────────────
set_property PACKAGE_PIN K17  [get_ports valid]
set_property IOSTANDARD  LVCMOS33 [get_ports valid]

## ── Timing false-path on async button inputs ─────────────────────────────
set_false_path -from [get_ports rst]
set_false_path -from [get_ports start]

## =============================================================================
## Optional: 7-segment display to show valid pulse count (debug aid)
##   Uncomment if you add a display driver wrapper.
## =============================================================================
## set_property PACKAGE_PIN W7  [get_ports {seg[0]}]
## set_property PACKAGE_PIN W6  [get_ports {seg[1]}]
## set_property PACKAGE_PIN U8  [get_ports {seg[2]}]
## set_property PACKAGE_PIN V8  [get_ports {seg[3]}]
## set_property PACKAGE_PIN U5  [get_ports {seg[4]}]
## set_property PACKAGE_PIN V5  [get_ports {seg[5]}]
## set_property PACKAGE_PIN U7  [get_ports {seg[6]}]
## set_property IOSTANDARD LVCMOS33 [get_ports {seg[*]}]
