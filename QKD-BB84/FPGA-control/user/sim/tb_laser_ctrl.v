`timescale 1ns/1ps

module tb_laser_ctrl;

localparam SYNC_DIV          = 2;
localparam LASER_PULSE_WIDTH = 3;

reg  clk, rst_n;
reg  sync_in;
reg  [7:0] fifo_data;
reg        fifo_empty;
wire       fifo_rd_en;
wire [3:0] laser;

laser_ctrl #(
    .SYNC_DIV         (SYNC_DIV),
    .LASER_PULSE_WIDTH(LASER_PULSE_WIDTH)
) dut (
    .clk       (clk),
    .rst_n     (rst_n),
    .sync_in   (sync_in),
    .fifo_data (fifo_data),
    .fifo_empty(fifo_empty),
    .fifo_rd_en(fifo_rd_en),
    .laser     (laser)
);

initial clk = 0;
always #5 clk = ~clk;

// Generate one sync rising edge, then wait for the rest of the period
// Returns after the full period (10 clocks total)
task sync_pulse;
    begin
        @(posedge clk); #1 sync_in = 1;  // Rising edge seen by DUT on next posedge
        @(posedge clk); #1 sync_in = 0;
        repeat(8) @(posedge clk);
    end
endtask

// Generate N-1 non-triggering pulses, then one triggering pulse.
// After the trigger rising edge, wait 'extra' clocks before returning.
// This lets the caller sample laser at the right time.
task fire_slot;
    input integer extra_wait;
    integer p;
    begin
        // N-1 non-triggering pulses
        for (p = 0; p < SYNC_DIV - 1; p = p + 1)
            sync_pulse;
        // Triggering pulse: only drive the rising edge, then wait extra clocks
        @(posedge clk); #1 sync_in = 1;   // trigger rising edge
        @(posedge clk); #1 sync_in = 0;
        repeat(extra_wait) @(posedge clk);
    end
endtask

integer errors;

// Simulate FIFO: update fifo_data one cycle after rd_en (matches data_buffer read latency)
reg [7:0] fifo_queue [0:3];
integer   fifo_head;
reg       rd_en_r;

always @(posedge clk) begin
    rd_en_r <= fifo_rd_en;
    if (rd_en_r && !fifo_empty) begin
        fifo_head  = fifo_head + 1;
        fifo_data  = fifo_queue[fifo_head < 4 ? fifo_head : 3];
        fifo_empty = (fifo_head >= 4);
    end
end

initial begin
    errors     = 0;
    rst_n      = 0;
    sync_in    = 0;
    fifo_empty = 1;
    fifo_data  = 0;
    fifo_head  = 0;

    fifo_queue[0] = 8'h00;  // laser[0]
    fifo_queue[1] = 8'h01;  // laser[1]
    fifo_queue[2] = 8'h02;  // laser[2]
    fifo_queue[3] = 8'h03;  // laser[3]

    repeat(4) @(posedge clk);
    rst_n = 1;
    repeat(2) @(posedge clk);

    // ── Test 1: FIFO empty → no laser fires ──────────────────────────────
    fifo_empty = 1;
    // fire_slot with extra_wait=4 so we can check laser during DRIVE window
    fire_slot(4);
    if (laser !== 4'b0000) begin
        $display("FAIL: laser should be 0 when FIFO empty, got %04b", laser);
        errors = errors + 1;
    end
    // Drain remaining period
    repeat(6) @(posedge clk);

    // ── Test 2: Each encoding ─────────────────────────────────────────────
    fifo_head  = 0;
    fifo_data  = fifo_queue[0];
    fifo_empty = 0;

    begin : test_encodings
        reg [3:0] expected_laser;
        integer slot;
        for (slot = 0; slot < 4; slot = slot + 1) begin
            // Trigger and wait 4 clocks: trigger→READ(+1)→DRIVE(+2)→laser stable(+3), sample at +4
            fire_slot(4);

            case (fifo_queue[slot][1:0])
                2'b00: expected_laser = 4'b0001;
                2'b01: expected_laser = 4'b0010;
                2'b10: expected_laser = 4'b0100;
                2'b11: expected_laser = 4'b1000;
            endcase

            if (laser !== expected_laser) begin
                $display("FAIL slot %0d: expected laser=%04b, got %04b",
                         slot, expected_laser, laser);
                errors = errors + 1;
            end

            // Wait for pulse to end (LASER_PULSE_WIDTH - already waited 2 clocks in DRIVE)
            // pulse_cnt starts at 0 in DRIVE, ends at LASER_PULSE_WIDTH-1
            // We sampled at DRIVE+2, pulse ends at DRIVE+LASER_PULSE_WIDTH
            // Wait remaining + margin
            repeat(LASER_PULSE_WIDTH + 4) @(posedge clk);

            if (laser !== 4'b0000) begin
                $display("FAIL slot %0d: laser should be 0 after pulse", slot);
                errors = errors + 1;
            end
        end
    end

    // ── Test 3: FIFO exhausted → laser stays low ─────────────────────────
    fire_slot(4);
    if (laser !== 4'b0000) begin
        $display("FAIL: laser should be 0 after FIFO exhausted");
        errors = errors + 1;
    end
    repeat(LASER_PULSE_WIDTH + 4) @(posedge clk);

    if (errors == 0)
        $display("PASS: laser_ctrl all checks passed");
    else
        $display("FAIL: %0d error(s)", errors);

    $finish;
end

endmodule
