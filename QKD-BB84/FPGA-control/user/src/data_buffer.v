// Synchronous FIFO buffer
// Decouples UART receive rate from laser firing rate
module data_buffer #(
    parameter DATA_WIDTH = 8,
    parameter DEPTH      = 1024
) (
    input  wire                  clk,
    input  wire                  rst_n,
    input  wire                  wr_en,
    input  wire [DATA_WIDTH-1:0] wr_data,
    input  wire                  rd_en,
    output wire [DATA_WIDTH-1:0] rd_data,
    output wire                  empty,
    output wire                  full
);

localparam ADDR_WIDTH = $clog2(DEPTH);

reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];
reg [ADDR_WIDTH:0]   wr_ptr;  // Extra bit for full/empty distinction
reg [ADDR_WIDTH:0]   rd_ptr;

wire [ADDR_WIDTH-1:0] wr_addr = wr_ptr[ADDR_WIDTH-1:0];
wire [ADDR_WIDTH-1:0] rd_addr = rd_ptr[ADDR_WIDTH-1:0];

assign empty = (wr_ptr == rd_ptr);
assign full  = (wr_ptr[ADDR_WIDTH] != rd_ptr[ADDR_WIDTH]) &&
               (wr_ptr[ADDR_WIDTH-1:0] == rd_ptr[ADDR_WIDTH-1:0]);

assign rd_data = mem[rd_addr];

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        wr_ptr <= 0;
        rd_ptr <= 0;
    end else begin
        if (wr_en && !full)
            wr_ptr <= wr_ptr + 1;
        if (rd_en && !empty)
            rd_ptr <= rd_ptr + 1;
    end
end

always @(posedge clk) begin
    if (wr_en && !full)
        mem[wr_addr] <= wr_data;
end

endmodule
