// Synchronization signal generator
// Generates a narrow pulse at configurable frequency derived from system clock
module sync_gen #(
    parameter CLK_FREQ   = 100_000_000,  // System clock frequency (Hz)
    parameter SYNC_FREQ  = 1_000_000,    // Sync signal frequency (Hz)
    parameter PULSE_WIDTH = 10           // Pulse width in clock cycles
) (
    input  wire clk,
    input  wire rst,
    output wire sync_out
);

localparam PERIOD = CLK_FREQ / SYNC_FREQ;  // Clock cycles per sync period

reg [31:0] cnt;

always @(posedge clk) begin
    if (rst)
        cnt <= 0;
    else if (cnt == PERIOD - 1)
        cnt <= 0;
    else
        cnt <= cnt + 1;
end

assign sync_out = (cnt < PULSE_WIDTH);

endmodule
