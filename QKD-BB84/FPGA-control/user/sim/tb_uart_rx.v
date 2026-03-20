`timescale 1ns/1ps

module tb_uart_rx;

localparam CLK_FREQ  = 100_000_000;
localparam BAUD_RATE = 10_000_000;  // Fast baud for simulation
localparam CLKS_PER_BIT = CLK_FREQ / BAUD_RATE;  // = 10

reg  clk, rst_n;
reg  uart_rx_in;
wire [7:0] rx_data;
wire       rx_valid;

uart_rx #(
    .CLK_FREQ (CLK_FREQ),
    .BAUD_RATE(BAUD_RATE)
) dut (
    .clk     (clk),
    .rst_n   (rst_n),
    .uart_rx (uart_rx_in),
    .rx_data (rx_data),
    .rx_valid(rx_valid)
);

initial clk = 0;
always #5 clk = ~clk;

// Task: send one byte over simulated UART
// Does NOT wait for the stop bit to complete, so caller can catch rx_valid
task send_byte;
    input [7:0] data;
    integer i;
    begin
        // Start bit
        uart_rx_in = 0;
        repeat(CLKS_PER_BIT) @(posedge clk);
        // Data bits LSB first
        for (i = 0; i < 8; i = i + 1) begin
            uart_rx_in = data[i];
            repeat(CLKS_PER_BIT) @(posedge clk);
        end
        // Stop bit — drive high but do NOT wait; let caller observe rx_valid
        uart_rx_in = 1;
    end
endtask

integer errors;

initial begin
    errors     = 0;
    rst_n      = 0;
    uart_rx_in = 1;  // Idle high
    repeat(4) @(posedge clk);
    rst_n = 1;
    repeat(2) @(posedge clk);

    // Test 1: send 0xA5
    send_byte(8'hA5);
    @(posedge rx_valid);
    if (rx_data !== 8'hA5) begin
        $display("FAIL: expected 0xA5, got 0x%02X", rx_data);
        errors = errors + 1;
    end
    repeat(CLKS_PER_BIT) @(posedge clk);  // Wait for stop bit to finish

    // Test 2: send 0x52 ('R')
    send_byte(8'h52);
    @(posedge rx_valid);
    if (rx_data !== 8'h52) begin
        $display("FAIL: expected 0x52, got 0x%02X", rx_data);
        errors = errors + 1;
    end
    repeat(CLKS_PER_BIT) @(posedge clk);

    // Test 3: back-to-back bytes
    send_byte(8'h00);
    @(posedge rx_valid);
    if (rx_data !== 8'h00) begin
        $display("FAIL: expected 0x00, got 0x%02X", rx_data);
        errors = errors + 1;
    end
    repeat(CLKS_PER_BIT) @(posedge clk);

    send_byte(8'hFF);
    @(posedge rx_valid);
    if (rx_data !== 8'hFF) begin
        $display("FAIL: expected 0xFF, got 0x%02X", rx_data);
        errors = errors + 1;
    end
    repeat(CLKS_PER_BIT) @(posedge clk);

    if (errors == 0)
        $display("PASS: uart_rx all checks passed");
    else
        $display("FAIL: %0d error(s)", errors);

    $finish;
end

endmodule
