// Top-level module for QKD BB84 FPGA controller
// Implements request-response protocol: receive 1 byte, wait for sync edge,
// fire laser, send back 32-bit sync counter (big-endian). Stop on 'q' (0x71).
module top #(
    parameter CLK_FREQ          = 100_000_000,
    parameter SYNC_FREQ         = 1_000_000,
    parameter SYNC_PULSE_WIDTH  = 10,
    parameter BAUD_RATE         = 115_200,
    parameter LASER_PULSE_WIDTH = 10
) (
    input  wire       clk,
    input  wire       rst,
    input  wire       uart_rx,
    output wire       uart_tx,
    output wire       sync_out,
    output wire [3:0] laser,
    output wire       led_empty
);

// ── Internal signals ──────────────────────────────────────────────────────
wire       rx_valid;
wire [7:0] rx_data;
wire       tx_busy;
reg        tx_start;
reg  [7:0] tx_data_r;
wire       laser_busy;
reg        fire;

// ── Submodule instantiations ──────────────────────────────────────────────

sync_gen #(
    .CLK_FREQ   (CLK_FREQ),
    .SYNC_FREQ  (SYNC_FREQ),
    .PULSE_WIDTH(SYNC_PULSE_WIDTH)
) u_sync_gen (
    .clk     (clk),
    .rst     (rst),
    .sync_out(sync_out)
);

uart_rx #(
    .CLK_FREQ (CLK_FREQ),
    .BAUD_RATE(BAUD_RATE)
) u_uart_rx (
    .clk     (clk),
    .rst     (rst),
    .uart_rx (uart_rx),
    .rx_data (rx_data),
    .rx_valid(rx_valid)
);

uart_tx #(
    .CLK_FREQ (CLK_FREQ),
    .BAUD_RATE(BAUD_RATE)
) u_uart_tx (
    .clk     (clk),
    .rst     (rst),
    .tx_data (tx_data_r),
    .tx_start(tx_start),
    .tx_busy (tx_busy),
    .uart_tx (uart_tx)
);

laser_ctrl #(
    .LASER_PULSE_WIDTH(LASER_PULSE_WIDTH)
) u_laser_ctrl (
    .clk      (clk),
    .rst      (rst),
    .laser_sel(data_latch[1:0]),
    .fire     (fire),
    .laser    (laser),
    .busy     (laser_busy)
);

// ── Sync counter ──────────────────────────────────────────────────────────
reg        sync_prev;
wire       sync_rise = sync_out & ~sync_prev;
reg [31:0] sync_cnt;

always @(posedge clk) begin
    if (rst) begin
        sync_prev <= 0;
        sync_cnt  <= 0;
    end else begin
        sync_prev <= sync_out;
        if (sync_rise) sync_cnt <= sync_cnt + 1;
    end
end

// ── Main FSM ──────────────────────────────────────────────────────────────
localparam S_WAIT_RX   = 3'd0;
localparam S_CHECK_Q   = 3'd1;
localparam S_WAIT_SYNC = 3'd2;
localparam S_FIRE      = 3'd3;
localparam S_TX_LOAD   = 3'd4;
localparam S_TX_WAIT   = 3'd5;
localparam S_STOPPED   = 3'd6;

reg [2:0]  state;
reg [7:0]  data_latch;
reg [31:0] cnt_latch;
reg [1:0]  byte_idx;
reg        tx_was_busy;

always @(posedge clk) begin
    if (rst) begin
        state       <= S_WAIT_RX;
        data_latch  <= 0;
        cnt_latch   <= 0;
        byte_idx    <= 0;
        tx_start    <= 0;
        tx_data_r   <= 0;
        fire        <= 0;
        tx_was_busy <= 0;
    end else begin
        // Default: deassert single-cycle signals
        tx_start <= 0;
        fire     <= 0;

        case (state)
            S_WAIT_RX: begin
                if (rx_valid) begin
                    data_latch <= rx_data;
                    state      <= S_CHECK_Q;
                end
            end

            S_CHECK_Q: begin
                if (data_latch == 8'h71)  // 'q'
                    state <= S_STOPPED;
                else
                    state <= S_WAIT_SYNC;
            end

            S_WAIT_SYNC: begin
                if (sync_rise) begin
                    cnt_latch <= sync_cnt;
                    state     <= S_FIRE;
                end
            end

            S_FIRE: begin
                fire     <= 1;
                byte_idx <= 0;
                state    <= S_TX_LOAD;
            end

            S_TX_LOAD: begin
                case (byte_idx)
                    2'd0: tx_data_r <= cnt_latch[31:24];
                    2'd1: tx_data_r <= cnt_latch[23:16];
                    2'd2: tx_data_r <= cnt_latch[15:8];
                    2'd3: tx_data_r <= cnt_latch[7:0];
                endcase
                tx_start    <= 1;
                tx_was_busy <= 0;
                state       <= S_TX_WAIT;
            end

            S_TX_WAIT: begin
                if (tx_busy) tx_was_busy <= 1;
                if (tx_was_busy && !tx_busy) begin
                    if (byte_idx == 2'd3) begin
                        state <= S_WAIT_RX;
                    end else begin
                        byte_idx <= byte_idx + 1;
                        state    <= S_TX_LOAD;
                    end
                end
            end

            S_STOPPED: begin
                // Stay here until reset; laser_ctrl idles with laser=0
            end
        endcase
    end
end

// LED on when stopped
assign led_empty = (state == S_STOPPED);

endmodule
