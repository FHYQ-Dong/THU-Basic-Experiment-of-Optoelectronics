// Top-level module for QKD BB84 FPGA controller
// Connects all submodules and implements LED + TX notification logic
module top #(
    parameter CLK_FREQ         = 100_000_000,
    parameter SYNC_FREQ        = 1_000_000,
    parameter SYNC_PULSE_WIDTH = 10,
    parameter BAUD_RATE        = 115_200,
    parameter FIFO_DEPTH       = 1024,
    parameter SYNC_DIV         = 1,
    parameter LASER_PULSE_WIDTH = 10
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       uart_rx,
    output wire       uart_tx,
    output wire       sync_out,
    output wire [3:0] laser,
    output wire       led_empty
);

// Internal signals
wire       rx_valid;
wire [7:0] rx_data;
wire       fifo_empty;
wire       fifo_full;
wire [7:0] fifo_rd_data;
wire       fifo_rd_en;
wire       tx_busy;

// ── Submodule instantiations ──────────────────────────────────────────────

sync_gen #(
    .CLK_FREQ   (CLK_FREQ),
    .SYNC_FREQ  (SYNC_FREQ),
    .PULSE_WIDTH(SYNC_PULSE_WIDTH)
) u_sync_gen (
    .clk     (clk),
    .rst_n   (rst_n),
    .sync_out(sync_out)
);

uart_rx #(
    .CLK_FREQ (CLK_FREQ),
    .BAUD_RATE(BAUD_RATE)
) u_uart_rx (
    .clk     (clk),
    .rst_n   (rst_n),
    .uart_rx (uart_rx),
    .rx_data (rx_data),
    .rx_valid(rx_valid)
);

data_buffer #(
    .DATA_WIDTH(8),
    .DEPTH     (FIFO_DEPTH)
) u_data_buffer (
    .clk    (clk),
    .rst_n  (rst_n),
    .wr_en  (rx_valid),
    .wr_data(rx_data),
    .rd_en  (fifo_rd_en),
    .rd_data(fifo_rd_data),
    .empty  (fifo_empty),
    .full   (fifo_full)
);

laser_ctrl #(
    .SYNC_DIV         (SYNC_DIV),
    .LASER_PULSE_WIDTH(LASER_PULSE_WIDTH)
) u_laser_ctrl (
    .clk       (clk),
    .rst_n     (rst_n),
    .sync_in   (sync_out),
    .fifo_data (fifo_rd_data),
    .fifo_empty(fifo_empty),
    .fifo_rd_en(fifo_rd_en),
    .laser     (laser)
);

// ── LED logic ─────────────────────────────────────────────────────────────
// LED lights up when FIFO is empty (waiting for data)
assign led_empty = fifo_empty;

// ── TX notification logic ─────────────────────────────────────────────────
// Send 0x52 ('R') to host on the rising edge of fifo_empty
reg  fifo_empty_r;
wire empty_rise = fifo_empty & ~fifo_empty_r;

reg  tx_start;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        fifo_empty_r <= 1;  // Assume empty at reset
        tx_start     <= 0;
    end else begin
        fifo_empty_r <= fifo_empty;
        // Trigger only on rising edge and only when TX is not busy
        tx_start <= empty_rise & ~tx_busy;
    end
end

uart_tx #(
    .CLK_FREQ (CLK_FREQ),
    .BAUD_RATE(BAUD_RATE)
) u_uart_tx (
    .clk     (clk),
    .rst_n   (rst_n),
    .tx_data (8'h52),   // 'R' = Ready
    .tx_start(tx_start),
    .tx_busy (tx_busy),
    .uart_tx (uart_tx)
);

endmodule
