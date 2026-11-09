## ============================================================
## XDC Constraints File - riscv_soc
## Board  : Real Digital Blackboard (Rev D)
## Device : xc7z007sclg400-1
## Clock  : 100 MHz PL oscillator (H16)
## Pin data from Real Digital's Blackboard master XDC.
## ============================================================

## ---------------- CLOCK (100 MHz, bank 35) ----------------
set_property -dict { PACKAGE_PIN H16 IOSTANDARD LVCMOS33 } [get_ports clk]
create_clock -period 10.000 -name sys_clk -waveform {0.000 5.000} [get_ports clk]

## ---------------- RESET (active HIGH in RTL) ----------------
## BTN0 = W14. If the button turns out to be active-low on your board,
## the design will sit in reset when idle -> invert it in RTL.
set_property -dict { PACKAGE_PIN W14 IOSTANDARD LVCMOS33 } [get_ports rst]

## ---------------- UART on Pmod B (PL side) ----------------
## The on-board USB-UART goes to the PS (MIO48/49), NOT the PL, so use a
## 3.3 V USB-serial adapter on Pmod B:
##   FPGA uart_rx (D19, JB1_P)  <-  adapter TX
##   FPGA uart_tx (D20, JB1_N)  ->  adapter RX
##   plus a common GND. Check the physical pin position on the silkscreen.
set_property -dict { PACKAGE_PIN D19 IOSTANDARD LVCMOS33 PULLUP true } [get_ports uart_rx]
set_property -dict { PACKAGE_PIN D20 IOSTANDARD LVCMOS33 }             [get_ports uart_tx]

## ---------------- DEBUG LEDs (LD0..LD3, bank 34) ----------------
set_property -dict { PACKAGE_PIN N20 IOSTANDARD LVCMOS33 } [get_ports {debug_led[0]}]
set_property -dict { PACKAGE_PIN P20 IOSTANDARD LVCMOS33 } [get_ports {debug_led[1]}]
set_property -dict { PACKAGE_PIN R19 IOSTANDARD LVCMOS33 } [get_ports {debug_led[2]}]
set_property -dict { PACKAGE_PIN T20 IOSTANDARD LVCMOS33 } [get_ports {debug_led[3]}]

## ---------------- SEVEN-SEGMENT DISPLAY ----------------
## Blackboard Rev D
## Active-low common-anode display
## seg[0]=A, seg[1]=B, ... seg[6]=G

## Segment cathodes
set_property -dict { PACKAGE_PIN K14 IOSTANDARD LVCMOS33 } [get_ports {seg[0]}]
set_property -dict { PACKAGE_PIN H15 IOSTANDARD LVCMOS33 } [get_ports {seg[1]}]
set_property -dict { PACKAGE_PIN J18 IOSTANDARD LVCMOS33 } [get_ports {seg[2]}]
set_property -dict { PACKAGE_PIN J15 IOSTANDARD LVCMOS33 } [get_ports {seg[3]}]
set_property -dict { PACKAGE_PIN M17 IOSTANDARD LVCMOS33 } [get_ports {seg[4]}]
set_property -dict { PACKAGE_PIN J16 IOSTANDARD LVCMOS33 } [get_ports {seg[5]}]
set_property -dict { PACKAGE_PIN H18 IOSTANDARD LVCMOS33 } [get_ports {seg[6]}]

## Digit anodes
set_property -dict { PACKAGE_PIN K19 IOSTANDARD LVCMOS33 } [get_ports {an[0]}]
set_property -dict { PACKAGE_PIN H17 IOSTANDARD LVCMOS33 } [get_ports {an[1]}]
set_property -dict { PACKAGE_PIN M18 IOSTANDARD LVCMOS33 } [get_ports {an[2]}]
set_property -dict { PACKAGE_PIN L16 IOSTANDARD LVCMOS33 } [get_ports {an[3]}]

## ---------------- TIMING ----------------
## Asynchronous / non-timing-critical I/O: no input/output delays,
## just exclude them from timing analysis.
set_false_path -from [get_ports {rst uart_rx}]
set_false_path -to [get_ports {uart_tx debug_led[*] seg[*] an[*]}]

## ---------------- BITSTREAM ----------------
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
