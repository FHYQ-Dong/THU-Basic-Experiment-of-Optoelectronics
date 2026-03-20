## Timing constraint
set_property -dict {PACKAGE_PIN R4 IOSTANDARD LVCMOS33} [get_ports {clk}]

## Reset
# rst -> KEY3 -> K22
set_property -dict {PACKAGE_PIN K22 IOSTANDARD LVCMOS33} [get_ports {rst}]

## UART
set_property -dict {PACKAGE_PIN B20 IOSTANDARD LVCMOS33} [get_ports {uart_rx}]
set_property -dict {PACKAGE_PIN A20 IOSTANDARD LVCMOS33} [get_ports {uart_tx}]

## SYNC_OUT
# sync_out -> TEST_A0 -> AA3
set_property -dict {PACKAGE_PIN AA3 IOSTANDARD LVCMOS33} [get_ports {sync_out}]

## LASER
# laser[0] -> TEST_A1 -> AB3
set_property -dict {PACKAGE_PIN AB3 IOSTANDARD LVCMOS33} [get_ports {laser[0]}]
# laser[1] -> TEST_A3 -> AA5
set_property -dict {PACKAGE_PIN AA5 IOSTANDARD LVCMOS33} [get_ports {laser[1]}]
# laser[2] -> TEST_A5 -> AA6
set_property -dict {PACKAGE_PIN AA6 IOSTANDARD LVCMOS33} [get_ports {laser[2]}]
# laser[3] -> TEST_A7 -> AB7
set_property -dict {PACKAGE_PIN AB7 IOSTANDARD LVCMOS33} [get_ports {laser[3]}]

## LED (FIFO empty indicator)
set_property -dict {PACKAGE_PIN V2 IOSTANDARD LVCMOS33} [get_ports {led_empty}]
