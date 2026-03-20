`timescale 1ns/1ps

module tb_top;

localparam CLK_FREQ          = 100_000_000;
localparam BAUD_RATE         = 10_000_000;
localparam SYNC_FREQ         = 1_000_000;
localparam SYNC_PULSE_WIDTH  = 10;
localparam FIFO_DEPTH        = 1024;
localparam SYNC_DIV          = 1;
localparam LASER_PULSE_WIDTH = 10;

localparam CLKS_PER_BIT  = CLK_FREQ / BAUD_RATE;   // = 10
localparam SYNC_PERIOD   = CLK_FREQ / SYNC_FREQ;    // = 100

reg  clk, rst_n;
reg  uart_rx_in;
wire uart_tx_out;
wire sync_out;
wire [3:0] laser;
wire led_empty;

top #(
    .CLK_FREQ         (CLK_FREQ),
    .SYNC_FREQ        (SYNC_FREQ),
    .SYNC_PULSE_WIDTH (SYNC_PULSE_WIDTH),
    .BAUD_RATE        (BAUD_RATE),
    .FIFO_DEPTH       (FIFO_DEPTH),
    .SYNC_DIV         (SYNC_DIV),
    .LASER_PULSE_WIDTH(LASER_PULSE_WIDTH)
) dut (
    .clk      (clk),
    .rst_n    (rst_n),
    .uart_rx  (uart_rx_in),
    .uart_tx  (uart_tx_out),
    .sync_out (sync_out),
    .laser    (laser),
    .led_empty(led_empty)
);

initial clk = 0;
always #5 clk = ~clk;

// Send one byte via UART RX (includes stop bit wait)
task uart_send;
    input [7:0] data;
    integer i;
    begin
        uart_rx_in = 0;
        repeat(CLKS_PER_BIT) @(posedge clk);
        for (i = 0; i < 8; i = i + 1) begin
            uart_rx_in = data[i];
            repeat(CLKS_PER_BIT) @(posedge clk);
        end
        uart_rx_in = 1;
        repeat(CLKS_PER_BIT) @(posedge clk);
    end
endtask

// Receive one byte from uart_tx_out (waits for negedge start bit)
task uart_recv;
    output [7:0] data;
    integer i;
    reg [7:0] captured;
    begin
        @(negedge uart_tx_out);
        repeat(CLKS_PER_BIT / 2) @(posedge clk);
        for (i = 0; i < 8; i = i + 1) begin
            repeat(CLKS_PER_BIT) @(posedge clk);
            captured[i] = uart_tx_out;
        end
        repeat(CLKS_PER_BIT) @(posedge clk);
        data = captured;
    end
endtask

integer errors;
reg [7:0] rx_byte;
reg       tx_received;

localparam [7:0] D0 = 8'h00;
localparam [7:0] D1 = 8'h01;
localparam [7:0] D2 = 8'h02;
localparam [7:0] D3 = 8'h03;

initial begin
    errors      = 0;
    tx_received = 0;
    rst_n       = 0;
    uart_rx_in  = 1;
    repeat(4) @(posedge clk);
    rst_n = 1;
    repeat(4) @(posedge clk);

    // ── Step 1: FIFO starts empty ─────────────────────────────────────────
    if (!led_empty) begin
        $display("FAIL: led_empty should be high at start");
        errors = errors + 1;
    end

    // ── Step 2+3+4: Send bytes, drain FIFO, capture TX notification ───────
    // Start uart_recv listener BEFORE sending data so it doesn't miss the TX
    fork
        begin : recv_block
            uart_recv(rx_byte);
            tx_received = 1;
        end
        begin : main_block
            // Send 4 bytes
            uart_send(D0);
            uart_send(D1);
            uart_send(D2);
            uart_send(D3);
            repeat(4) @(posedge clk);

            if (led_empty) begin
                $display("FAIL: led_empty should be low after filling FIFO");
                errors = errors + 1;
            end

            // Wait for sync_gen to drain all 4 slots
            // Each slot = SYNC_PERIOD clocks; add margin
            repeat(6 * SYNC_PERIOD) @(posedge clk);

            if (!led_empty) begin
                $display("FAIL: led_empty should be high after FIFO drained");
                errors = errors + 1;
            end

            // Wait for TX notification to arrive (up to 200 clocks)
            repeat(200) @(posedge clk);
            if (!tx_received) begin
                $display("FAIL: timeout waiting for TX notification");
                errors = errors + 1;
                disable recv_block;
            end
        end
    join

    if (tx_received && rx_byte !== 8'h52) begin
        $display("FAIL: expected 0x52 ('R'), got 0x%02X", rx_byte);
        errors = errors + 1;
    end

    // ── Step 5: Send more data → led_empty goes low ───────────────────────
    uart_send(D0);
    repeat(4) @(posedge clk);
    if (led_empty) begin
        $display("FAIL: led_empty should be low after new data");
        errors = errors + 1;
    end

    if (errors == 0)
        $display("PASS: tb_top all checks passed");
    else
        $display("FAIL: %0d error(s)", errors);

    $finish;
end

initial begin
    #20_000_000;
    $display("FAIL: global simulation timeout");
    $finish;
end

endmodule
