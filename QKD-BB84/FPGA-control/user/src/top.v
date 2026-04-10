// Top-level module for QKD BB84 FPGA controller
// Protocol: receive 1 byte, wait for sync edge, fire laser. Stop on 'q' (0x71).
module top #(
    parameter CLK_FREQ          = 100_000_000,
    parameter SYNC_FREQ         = 50_000,
    parameter SYNC_PULSE_WIDTH  = 1000,
    parameter BAUD_RATE         = 115_200,
    parameter LASER_PULSE_WIDTH = 1000
) (
    input  wire       clk,
    input  wire       rst,
    input  wire       uart_rx,
    output wire       sync_out,
    output wire [3:0] laser,
    output wire       laser_en,
    output wire       led_empty
);

// ── Internal signals ──────────────────────────────────────────────────────
wire       rx_valid;
wire [7:0] rx_data;
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

uart_receiver #(
    .CLK_FREQ (CLK_FREQ),
    .BAUD_RATE(BAUD_RATE)
) u_uart_rx (
    .clk     (clk),
    .rst     (rst),
    .rxd     (uart_rx),
    .rx_data (rx_data),
    .rx_valid(rx_valid)
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

// ── Laser enable: high when any laser is active ──────────────────────────
assign laser_en = |laser;

// ── Sync rising edge detection ───────────────────────────────────────────
reg  sync_prev;
wire sync_rise = sync_out & ~sync_prev;

always @(posedge clk) begin
    if (rst)
        sync_prev <= 0;
    else
        sync_prev <= sync_out;
end

// ── Main FSM ──────────────────────────────────────────────────────────────
localparam S_WAIT_RX   = 2'd0;
localparam S_CHECK_Q   = 2'd1;
localparam S_WAIT_SYNC = 2'd2;
localparam S_STOPPED   = 2'd3;

(* fsm_encoding = "none" *) reg [1:0] state;
reg [7:0] data_latch;

always @(posedge clk) begin
    if (rst) begin
        state      <= S_WAIT_RX;
        data_latch <= 0;
        fire       <= 0;
    end else begin
        fire <= 0;

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
                    fire  <= 1;
                    state <= S_WAIT_RX;
                end
            end

            S_STOPPED: begin
                // Stay here until reset
            end
        endcase
    end
end

// DEBUG: latch rx_valid — LED stays on after first byte received
reg dbg_rx_seen;
always @(posedge clk) begin
    if (rst)
        dbg_rx_seen <= 0;
    else if (rx_valid)
        dbg_rx_seen <= 1;
end
assign led_empty = dbg_rx_seen;

endmodule
