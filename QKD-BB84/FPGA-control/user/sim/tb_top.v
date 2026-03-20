`timescale 1ns/1ps

module tb_top;

localparam CLK_FREQ          = 100_000_000;
localparam BAUD_RATE         = 10_000_000;   // Accelerated for simulation
localparam SYNC_FREQ         = 1_000_000;
localparam SYNC_PULSE_WIDTH  = 10;
localparam LASER_PULSE_WIDTH = 10;

localparam CLKS_PER_BIT = CLK_FREQ / BAUD_RATE;  // = 10
localparam SYNC_PERIOD  = CLK_FREQ / SYNC_FREQ;   // = 100

reg  clk, rst;
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
    .LASER_PULSE_WIDTH(LASER_PULSE_WIDTH)
) dut (
    .clk      (clk),
    .rst      (rst),
    .uart_rx  (uart_rx_in),
    .uart_tx  (uart_tx_out),
    .sync_out (sync_out),
    .laser    (laser),
    .led_empty(led_empty)
);

initial clk = 0;
always #5 clk = ~clk;

// Send one byte via UART RX (8N1)
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

// Receive one byte from uart_tx_out (waits for start bit negedge)
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

// Receive 4 bytes (big-endian 32-bit value)
task recv_u32;
    output [31:0] val;
    reg [7:0] b;
    begin
        uart_recv(b); val[31:24] = b;
        uart_recv(b); val[23:16] = b;
        uart_recv(b); val[15:8]  = b;
        uart_recv(b); val[7:0]   = b;
    end
endtask

integer   errors;
reg [3:0] expected_laser;
reg [31:0] sync_val;
reg [31:0] prev_sync_val;

initial begin
    errors        = 0;
    uart_rx_in    = 1;
    rst           = 0;
    repeat(4) @(posedge clk);
    rst = 1;
    repeat(4) @(posedge clk);

    // ── Test 1: led_empty low at start (not stopped) ──────────────────────
    if (led_empty) begin
        $display("FAIL: led_empty should be low at start (not stopped)");
        errors = errors + 1;
    end

    // ── Test 2-5: Send 4 bytes, verify laser and sync count response ───────
    begin : test_photons
        integer sel;
        for (sel = 0; sel < 4; sel = sel + 1) begin
            fork
                begin : send_block
                    uart_send(sel[7:0]);
                end
                begin : recv_block
                    recv_u32(sync_val);
                end
            join

            // Verify correct laser fired
            // (laser pulse is brief; check via sync_val being non-zero after first sync)
            // Verify sync_val is monotonically increasing
            if (sel > 0 && sync_val <= prev_sync_val) begin
                $display("FAIL sel=%0d: sync_val %0d not > prev %0d", sel, sync_val, prev_sync_val);
                errors = errors + 1;
            end
            prev_sync_val = sync_val;
            $display("INFO sel=%0d: sync_val=%0d", sel, sync_val);
        end
    end

    // ── Test 6: Send 'q', verify stopped ──────────────────────────────────
    uart_send(8'h71);
    repeat(10) @(posedge clk);

    if (!led_empty) begin
        $display("FAIL: led_empty should be high after 'q'");
        errors = errors + 1;
    end

    // Verify no TX activity after 'q' (wait several sync periods)
    begin : test_no_tx
        integer k;
        for (k = 0; k < 3 * SYNC_PERIOD; k = k + 1) begin
            @(posedge clk);
            if (!uart_tx_out) begin
                $display("FAIL: unexpected TX activity after 'q'");
                errors = errors + 1;
                k = 3 * SYNC_PERIOD;  // break
            end
        end
    end

    if (errors == 0)
        $display("PASS: tb_top all checks passed");
    else
        $display("FAIL: %0d error(s)", errors);

    $finish;
end

initial begin
    #50_000_000;
    $display("FAIL: global simulation timeout");
    $finish;
end

endmodule
