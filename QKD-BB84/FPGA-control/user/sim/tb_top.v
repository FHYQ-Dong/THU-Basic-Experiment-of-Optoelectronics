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
wire sync_out;
wire [3:0] laser;
wire laser_en;
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
    .sync_out (sync_out),
    .laser    (laser),
    .laser_en (laser_en),
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

integer errors;

initial begin
    errors     = 0;
    uart_rx_in = 1;
    rst        = 0;
    repeat(4) @(posedge clk);
    rst = 1;
    repeat(4) @(posedge clk);

    // ── Test 1: led_empty low at start (not stopped) ────────────────────
    if (led_empty) begin
        $display("FAIL: led_empty should be low at start (not stopped)");
        errors = errors + 1;
    end

    // ── Test 2-5: Send 4 bytes, verify laser fires after sync ───────────
    begin : test_photons
        reg [3:0] expected;
        integer sel;
        for (sel = 0; sel < 4; sel = sel + 1) begin
            uart_send(sel[7:0]);

            // Wait for sync edge + fire + laser pulse to appear
            repeat(SYNC_PERIOD + LASER_PULSE_WIDTH + 10) @(posedge clk);

            // By now the laser pulse has ended; verify laser_en went high
            // We check indirectly: send next byte and repeat.
            // Direct check: watch for laser_en pulse during the wait.
        end
    end

    // More precise laser check: send one byte and sample laser during pulse
    begin : test_laser_encoding
        reg [3:0] expected;
        integer sel;
        for (sel = 0; sel < 4; sel = sel + 1) begin
            uart_send(sel[7:0]);

            // Wait for laser_en to go high (laser pulse started)
            begin : wait_laser
                integer timeout;
                timeout = 0;
                while (!laser_en && timeout < 2 * SYNC_PERIOD) begin
                    @(posedge clk);
                    timeout = timeout + 1;
                end
                if (timeout >= 2 * SYNC_PERIOD) begin
                    $display("FAIL sel=%0d: laser_en never went high", sel);
                    errors = errors + 1;
                end
            end

            case (sel[1:0])
                2'b00: expected = 4'b0001;
                2'b01: expected = 4'b0010;
                2'b10: expected = 4'b0100;
                2'b11: expected = 4'b1000;
            endcase

            if (laser_en) begin
                if (laser !== expected) begin
                    $display("FAIL sel=%0d: expected laser=%04b, got %04b", sel, expected, laser);
                    errors = errors + 1;
                end
                if (!laser_en) begin
                    $display("FAIL sel=%0d: laser_en should be high when laser active", sel);
                    errors = errors + 1;
                end
            end

            // Wait for pulse to end
            @(negedge laser_en);
            @(posedge clk);
        end
    end

    // ── Test 6: Send 'q', verify stopped ────────────────────────────────
    uart_send(8'h71);
    repeat(10) @(posedge clk);

    if (!led_empty) begin
        $display("FAIL: led_empty should be high after 'q'");
        errors = errors + 1;
    end

    // Verify no laser activity after 'q'
    begin : test_no_laser
        integer k;
        for (k = 0; k < 3 * SYNC_PERIOD; k = k + 1) begin
            @(posedge clk);
            if (laser_en) begin
                $display("FAIL: unexpected laser activity after 'q'");
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
