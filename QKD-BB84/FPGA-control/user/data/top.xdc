## Timing constraint
create_clock -period 10.000 -name clk [get_ports clk]

## Reset
#set_property PACKAGE_PIN <PIN> [get_ports rst_n]
#set_property IOSTANDARD LVCMOS33 [get_ports rst_n]

## UART
#set_property PACKAGE_PIN <PIN> [get_ports uart_rx]
#set_property IOSTANDARD LVCMOS33 [get_ports uart_rx]
#set_property PACKAGE_PIN <PIN> [get_ports uart_tx]
#set_property IOSTANDARD LVCMOS33 [get_ports uart_tx]

## Sync output (to TCSPC)
#set_property PACKAGE_PIN <PIN> [get_ports sync_out]
#set_property IOSTANDARD LVCMOS33 [get_ports sync_out]

## Laser outputs
#set_property PACKAGE_PIN <PIN> [get_ports {laser[0]}]
#set_property IOSTANDARD LVCMOS33 [get_ports {laser[0]}]
#set_property PACKAGE_PIN <PIN> [get_ports {laser[1]}]
#set_property IOSTANDARD LVCMOS33 [get_ports {laser[1]}]
#set_property PACKAGE_PIN <PIN> [get_ports {laser[2]}]
#set_property IOSTANDARD LVCMOS33 [get_ports {laser[2]}]
#set_property PACKAGE_PIN <PIN> [get_ports {laser[3]}]
#set_property IOSTANDARD LVCMOS33 [get_ports {laser[3]}]

## LED (FIFO empty indicator)
#set_property PACKAGE_PIN <PIN> [get_ports led_empty]
#set_property IOSTANDARD LVCMOS33 [get_ports led_empty]
