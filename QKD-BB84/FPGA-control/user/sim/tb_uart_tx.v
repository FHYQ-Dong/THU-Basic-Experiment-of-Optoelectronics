`timescale 1ns/1ps

module tb_uart_tx;

localparam CLK_FREQ  = 100_000_000;
localparam BAUD_RATE = 10_000_000;
localparam CLKS_PER_BIT = CLK_FREQ / BAUD_RATE;  // = 10

reg  clk, rst;
reg  [7:0] tx_data;
reg        tx_start;
wire       tx_busy;
wire       uart_tx_out;

uart_tx #(
    .CLK_FREQ (CLK_FREQ),
    .BAUD_RATE(BAUD_RATE)
) dut (
    .clk     (clk),
    .rst   (rst),
    .tx_data (tx_data),
    .tx_start(tx_start),
    .tx_busy (tx_busy),
    .uart_tx (uart_tx_out)
);

initial clk = 0;
always #5 clk = ~clk;

// Capture one transmitted byte (call before or concurrent with tx_start)
task recv_byte;
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
        repeat(CLKS_PER_BIT * 2) @(posedge clk);  // Stop bit + margin for S_IDLE
        data = captured;
    end
endtask

integer errors;
reg [7:0] received;

initial begin
    errors   = 0;
    rst    = 0;
    tx_start = 0;
    tx_data  = 0;
    repeat(4) @(posedge clk);
    rst = 1;
    repeat(2) @(posedge clk);

    // ── Test 1: send 0xA5 ────────────────────────────────────────────────
    // Fork recv_byte (waits for negedge) and tx_start pulse in parallel
    fork
        recv_byte(received);
        begin
            @(posedge clk); #1 tx_data = 8'hA5; tx_start = 1;
            @(posedge clk); #1 tx_start = 0;
        end
    join
    if (received !== 8'hA5) begin
        $display("FAIL: expected 0xA5, received 0x%02X", received);
        errors = errors + 1;
    end
    repeat(2) @(posedge clk);  // Wait for DUT to return to S_IDLE
    if (tx_busy) begin
        $display("FAIL: tx_busy should be low after transmission");
        errors = errors + 1;
    end

    // ── Test 2: send 0x52 ('R') ───────────────────────────────────────────
    fork
        recv_byte(received);
        begin
            @(posedge clk); #1 tx_data = 8'h52; tx_start = 1;
            @(posedge clk); #1 tx_start = 0;
        end
    join
    if (received !== 8'h52) begin
        $display("FAIL: expected 0x52, received 0x%02X", received);
        errors = errors + 1;
    end

    // ── Test 3: tx_start during tx_busy is ignored ────────────────────────
    fork
        recv_byte(received);
        begin
            @(posedge clk); #1 tx_data = 8'hBB; tx_start = 1;
            @(posedge clk); #1 tx_start = 0;
            // Pulse tx_start again while DUT is busy — should be ignored
            @(posedge clk); #1 tx_start = 1;
            @(posedge clk); #1 tx_start = 0;
        end
    join
    if (received !== 8'hBB) begin
        $display("FAIL: expected 0xBB, received 0x%02X", received);
        errors = errors + 1;
    end
    // Line should stay idle (no spurious second byte)
    repeat(CLKS_PER_BIT * 3) @(posedge clk);
    if (!uart_tx_out) begin
        $display("FAIL: spurious second transmission detected");
        errors = errors + 1;
    end

    if (errors == 0)
        $display("PASS: uart_tx all checks passed");
    else
        $display("FAIL: %0d error(s)", errors);

    $finish;
end

initial begin
    #5_000_000;
    $display("FAIL: simulation timeout");
    $finish;
end

endmodule
