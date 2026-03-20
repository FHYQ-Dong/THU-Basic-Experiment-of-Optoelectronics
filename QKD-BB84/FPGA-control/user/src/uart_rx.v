// UART receiver, 8N1
// Outputs rx_data and a one-cycle rx_valid pulse when a byte is received
module uart_rx #(
    parameter CLK_FREQ = 100_000_000,  // System clock frequency (Hz)
    parameter BAUD_RATE = 115_200      // Baud rate
) (
    input  wire       clk,
    input  wire       rst,
    input  wire       uart_rx,
    output reg  [7:0] rx_data,
    output reg        rx_valid
);

localparam CLKS_PER_BIT  = CLK_FREQ / BAUD_RATE;
localparam HALF_BIT      = CLKS_PER_BIT / 2;

localparam S_IDLE  = 2'd0;
localparam S_START = 2'd1;
localparam S_DATA  = 2'd2;
localparam S_STOP  = 2'd3;

reg [1:0]               state;
reg [$clog2(CLKS_PER_BIT)-1:0] baud_cnt;
reg [2:0]               bit_idx;
reg [7:0]               shift_reg;

// Two-stage synchronizer for uart_rx input
reg rx_sync0, rx_sync1;
always @(posedge clk) begin
    rx_sync0 <= uart_rx;
    rx_sync1 <= rx_sync0;
end

always @(posedge clk) begin
    if (rst) begin
        state    <= S_IDLE;
        baud_cnt <= 0;
        bit_idx  <= 0;
        rx_data  <= 0;
        rx_valid <= 0;
    end else begin
        rx_valid <= 0;
        case (state)
            S_IDLE: begin
                if (!rx_sync1) begin  // Start bit detected (falling edge)
                    state    <= S_START;
                    baud_cnt <= 0;
                end
            end
            S_START: begin
                // Wait to sample at middle of start bit
                if (baud_cnt == HALF_BIT - 1) begin
                    if (!rx_sync1) begin  // Confirm start bit is still low
                        state    <= S_DATA;
                        baud_cnt <= 0;
                        bit_idx  <= 0;
                    end else begin
                        state <= S_IDLE;  // False start, abort
                    end
                end else begin
                    baud_cnt <= baud_cnt + 1;
                end
            end
            S_DATA: begin
                if (baud_cnt == CLKS_PER_BIT - 1) begin
                    baud_cnt            <= 0;
                    shift_reg[bit_idx]  <= rx_sync1;
                    if (bit_idx == 7) begin
                        state   <= S_STOP;
                        bit_idx <= 0;
                    end else begin
                        bit_idx <= bit_idx + 1;
                    end
                end else begin
                    baud_cnt <= baud_cnt + 1;
                end
            end
            S_STOP: begin
                if (baud_cnt == CLKS_PER_BIT - 1) begin
                    baud_cnt <= 0;
                    state    <= S_IDLE;
                    if (rx_sync1) begin  // Valid stop bit
                        rx_data  <= shift_reg;
                        rx_valid <= 1;
                    end
                end else begin
                    baud_cnt <= baud_cnt + 1;
                end
            end
        endcase
    end
end

endmodule
