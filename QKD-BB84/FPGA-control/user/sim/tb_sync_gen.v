`timescale 1ns/1ps

module tb_sync_gen;

localparam CLK_FREQ   = 100;
localparam SYNC_FREQ  = 10;
localparam PULSE_WIDTH = 2;
localparam PERIOD     = CLK_FREQ / SYNC_FREQ;  // = 10
localparam CLK_PERIOD = 10;  // ns per clock cycle

reg  clk, rst;
wire sync_out;

sync_gen #(
    .CLK_FREQ   (CLK_FREQ),
    .SYNC_FREQ  (SYNC_FREQ),
    .PULSE_WIDTH(PULSE_WIDTH)
) dut (
    .clk     (clk),
    .rst   (rst),
    .sync_out(sync_out)
);

initial clk = 0;
always #5 clk = ~clk;

integer errors;
time t_rise, t_fall, t_rise2;
integer measured_high, measured_period;

initial begin
    errors = 0;
    rst  = 0;
    repeat(4) @(posedge clk);
    rst = 1;

    // Align to first rising edge
    @(posedge sync_out);

    repeat(3) begin
        t_rise = $time;
        @(negedge sync_out);
        t_fall = $time;
        @(posedge sync_out);
        t_rise2 = $time;

        measured_high   = (t_fall  - t_rise)  / CLK_PERIOD;
        measured_period = (t_rise2 - t_rise)   / CLK_PERIOD;

        if (measured_high !== PULSE_WIDTH) begin
            $display("FAIL: pulse width = %0d cycles, expected %0d", measured_high, PULSE_WIDTH);
            errors = errors + 1;
        end
        if (measured_period !== PERIOD) begin
            $display("FAIL: period = %0d cycles, expected %0d", measured_period, PERIOD);
            errors = errors + 1;
        end
    end

    if (errors == 0)
        $display("PASS: sync_gen all checks passed");
    else
        $display("FAIL: %0d error(s)", errors);

    $finish;
end

endmodule
