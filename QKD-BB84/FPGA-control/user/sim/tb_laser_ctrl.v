`timescale 1ns/1ps

module tb_laser_ctrl;

localparam LASER_PULSE_WIDTH = 3;

reg  clk, rst;
reg  [1:0] laser_sel;
reg        fire;
wire [3:0] laser;
wire       busy;

laser_ctrl #(
    .LASER_PULSE_WIDTH(LASER_PULSE_WIDTH)
) dut (
    .clk      (clk),
    .rst      (rst),
    .laser_sel(laser_sel),
    .fire     (fire),
    .laser    (laser),
    .busy     (busy)
);

initial clk = 0;
always #5 clk = ~clk;

// Fire one pulse and wait for it to complete
task do_fire;
    input [1:0] sel;
    begin
        @(posedge clk); #1;
        laser_sel = sel;
        fire      = 1;
        @(posedge clk); #1;
        fire = 0;
        // Wait for busy to go high then low
        @(posedge busy);
        @(negedge busy);
        @(posedge clk); #1;
    end
endtask

integer errors;

initial begin
    errors    = 0;
    rst       = 0;
    fire      = 0;
    laser_sel = 0;

    repeat(4) @(posedge clk);
    rst = 1;
    repeat(2) @(posedge clk);

    // ── Test 1: Each encoding fires correct laser ─────────────────────────
    begin : test_encodings
        reg [3:0] expected;
        integer   sel;
        for (sel = 0; sel < 4; sel = sel + 1) begin
            @(posedge clk); #1;
            laser_sel = sel[1:0];
            fire      = 1;
            @(posedge clk); #1;
            fire = 0;

            // Wait for DRIVE state (busy goes high)
            @(posedge busy);
            @(posedge clk); #1;

            case (sel[1:0])
                2'b00: expected = 4'b0001;
                2'b01: expected = 4'b0010;
                2'b10: expected = 4'b0100;
                2'b11: expected = 4'b1000;
            endcase

            if (laser !== expected) begin
                $display("FAIL sel=%0d: expected laser=%04b, got %04b", sel, expected, laser);
                errors = errors + 1;
            end

            // Wait for pulse to end
            @(negedge busy);
            @(posedge clk); #1;

            if (laser !== 4'b0000) begin
                $display("FAIL sel=%0d: laser should be 0 after pulse", sel);
                errors = errors + 1;
            end
        end
    end

    // ── Test 2: busy signal duration = LASER_PULSE_WIDTH cycles ──────────
    begin : test_pulse_width
        integer cnt;
        cnt = 0;
        @(posedge clk); #1;
        laser_sel = 2'b00;
        fire      = 1;
        @(posedge clk); #1;
        fire = 0;

        @(posedge busy);
        // Count cycles while busy
        while (busy) begin
            @(posedge clk); #1;
            cnt = cnt + 1;
        end

        if (cnt !== LASER_PULSE_WIDTH) begin
            $display("FAIL: pulse width = %0d, expected %0d", cnt, LASER_PULSE_WIDTH);
            errors = errors + 1;
        end
    end

    // ── Test 3: fire ignored while busy ───────────────────────────────────
    begin : test_busy_ignore
        // Fire sel=01 (laser[1])
        @(posedge clk); #1;
        laser_sel = 2'b01;
        fire      = 1;
        @(posedge clk); #1;
        fire = 0;

        // While busy, attempt to fire sel=10 (should be ignored)
        @(posedge busy);
        @(posedge clk); #1;
        laser_sel = 2'b10;
        fire      = 1;
        @(posedge clk); #1;
        fire = 0;

        // Should still be laser[1] (sel=01), not laser[2] (sel=10)
        if (laser !== 4'b0010) begin
            $display("FAIL: fire during busy changed laser to %04b", laser);
            errors = errors + 1;
        end

        @(negedge busy);
        @(posedge clk); #1;
    end

    if (errors == 0)
        $display("PASS: laser_ctrl all checks passed");
    else
        $display("FAIL: %0d error(s)", errors);

    $finish;
end

endmodule
