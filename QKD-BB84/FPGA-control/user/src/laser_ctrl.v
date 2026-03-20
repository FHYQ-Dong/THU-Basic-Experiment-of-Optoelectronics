// Laser controller
// Fires one of 4 lasers per slot, triggered every SYNC_DIV sync pulses
// Constraint: LASER_PULSE_WIDTH < CLK_FREQ/SYNC_FREQ * SYNC_DIV
module laser_ctrl #(
    parameter SYNC_DIV          = 1,   // Fire one slot every N sync pulses
    parameter LASER_PULSE_WIDTH = 10  // Laser pulse width in clock cycles
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       sync_in,        // Sync signal from sync_gen
    input  wire [7:0] fifo_data,      // Data read from FIFO
    input  wire       fifo_empty,
    output reg        fifo_rd_en,
    output reg  [3:0] laser
);

localparam S_IDLE  = 2'd0;
localparam S_READ  = 2'd1;
localparam S_DRIVE = 2'd2;

reg [1:0]                        state;
reg [$clog2(SYNC_DIV+1)-1:0]    sync_cnt;
reg [$clog2(LASER_PULSE_WIDTH+1)-1:0] pulse_cnt;
reg [7:0]                        data_latch;
reg                              sync_prev;

wire sync_rise = sync_in & ~sync_prev;
wire trigger   = sync_rise && (sync_cnt == SYNC_DIV - 1);

// sync_cnt counts sync pulses continuously across all states
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        sync_cnt  <= 0;
        sync_prev <= 0;
    end else begin
        sync_prev <= sync_in;
        if (sync_rise) begin
            if (sync_cnt == SYNC_DIV - 1)
                sync_cnt <= 0;
            else
                sync_cnt <= sync_cnt + 1;
        end
    end
end

// FSM
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state      <= S_IDLE;
        fifo_rd_en <= 0;
        laser      <= 4'b0000;
        pulse_cnt  <= 0;
        data_latch <= 0;
    end else begin
        fifo_rd_en <= 0;
        case (state)
            S_IDLE: begin
                laser <= 4'b0000;
                if (trigger && !fifo_empty) begin
                    fifo_rd_en <= 1;
                    state      <= S_READ;
                end
            end
            S_READ: begin
                // fifo_rd_en was pulsed last cycle; rd_data is now valid
                data_latch <= fifo_data;
                pulse_cnt  <= 0;
                state      <= S_DRIVE;
            end
            S_DRIVE: begin
                // Decode data[1:0] -> one-hot laser select
                case (data_latch[1:0])
                    2'b00: laser <= 4'b0001;  // laser[0]: 0° (H)
                    2'b01: laser <= 4'b0010;  // laser[1]: 90° (V)
                    2'b10: laser <= 4'b0100;  // laser[2]: +45°
                    2'b11: laser <= 4'b1000;  // laser[3]: -45°
                endcase
                if (pulse_cnt == LASER_PULSE_WIDTH - 1) begin
                    laser <= 4'b0000;
                    state <= S_IDLE;
                end else begin
                    pulse_cnt <= pulse_cnt + 1;
                end
            end
        endcase
    end
end

endmodule
