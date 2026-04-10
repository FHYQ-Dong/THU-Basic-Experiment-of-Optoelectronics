// Laser controller
// Fires one of 4 lasers on a fire strobe, drives pulse for LASER_PULSE_WIDTH cycles
// Constraint: LASER_PULSE_WIDTH < CLK_FREQ/SYNC_FREQ
module laser_ctrl #(
    parameter LASER_PULSE_WIDTH = 10
) (
    input  wire       clk,
    input  wire       rst,
    input  wire [1:0] laser_sel,  // Laser select from rx_data[1:0]
    input  wire       fire,       // One-cycle strobe to start pulse
    output reg  [3:0] laser,
    output reg        busy
);

localparam S_IDLE  = 1'd0;
localparam S_DRIVE = 1'd1;

(* fsm_encoding = "none" *) reg       state;
reg [15:0] pulse_cnt;
reg [1:0]                             sel_latch;

always @(posedge clk) begin
    if (rst) begin
        state     <= S_IDLE;
        laser     <= 4'b0000;
        busy      <= 0;
        pulse_cnt <= 0;
        sel_latch <= 0;
    end else begin
        case (state)
            S_IDLE: begin
                laser <= 4'b0000;
                busy  <= 0;
                if (fire) begin
                    sel_latch <= laser_sel;
                    pulse_cnt <= 0;
                    state     <= S_DRIVE;
                end
            end
            S_DRIVE: begin
                busy <= 1;
                case (sel_latch)
                    2'b00: laser <= 4'b0001;  // laser[0]: 0° (H)
                    2'b01: laser <= 4'b0010;  // laser[1]: 90° (V)
                    2'b10: laser <= 4'b0100;  // laser[2]: +45°
                    2'b11: laser <= 4'b1000;  // laser[3]: -45°
                endcase
                if (pulse_cnt == LASER_PULSE_WIDTH) begin
                    laser <= 4'b0000;
                    busy  <= 0;
                    state <= S_IDLE;
                end else begin
                    pulse_cnt <= pulse_cnt + 1;
                end
            end
        endcase
    end
end

endmodule
