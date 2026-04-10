// UART transmitter, 8N1
// Sends one byte when tx_start is pulsed high for one clock cycle
module uart_tx #(
    parameter CLK_FREQ  = 100_000_000,  // System clock frequency (Hz)
    parameter BAUD_RATE = 115_200       // Baud rate
) (
    input  wire       clk,
    input  wire       rst,
    input  wire [7:0] tx_data,
    input  wire       tx_start,
    output reg        tx_busy,
    output reg        uart_tx
);

localparam CLKS_PER_BIT = CLK_FREQ / BAUD_RATE;

localparam S_IDLE  = 2'd0;
localparam S_START = 2'd1;
localparam S_DATA  = 2'd2;
localparam S_STOP  = 2'd3;

reg [1:0]               state;
reg [15:0] baud_cnt;
reg [2:0]               bit_idx;
reg [7:0]               shift_reg;

always @(posedge clk) begin
    if (rst) begin
        state    <= S_IDLE;
        baud_cnt <= 0;
        bit_idx  <= 0;
        tx_busy  <= 0;
        uart_tx  <= 1;  // Idle high
    end else begin
        case (state)
            S_IDLE: begin
                uart_tx <= 1;
                tx_busy <= 0;
                if (tx_start) begin
                    state     <= S_START;
                    shift_reg <= tx_data;
                    baud_cnt  <= 0;
                    tx_busy   <= 1;
                end
            end
            S_START: begin
                uart_tx <= 0;  // Start bit
                if (baud_cnt == CLKS_PER_BIT - 1) begin
                    state    <= S_DATA;
                    baud_cnt <= 0;
                    bit_idx  <= 0;
                end else begin
                    baud_cnt <= baud_cnt + 1;
                end
            end
            S_DATA: begin
                uart_tx <= shift_reg[bit_idx];
                if (baud_cnt == CLKS_PER_BIT - 1) begin
                    baud_cnt <= 0;
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
                uart_tx <= 1;  // Stop bit
                if (baud_cnt == CLKS_PER_BIT - 1) begin
                    baud_cnt <= 0;
                    state    <= S_IDLE;
                    tx_busy  <= 0;
                end else begin
                    baud_cnt <= baud_cnt + 1;
                end
            end
        endcase
    end
end

endmodule
