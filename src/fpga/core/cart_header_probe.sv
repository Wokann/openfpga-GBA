// Read 0xB0..0xBF twice before choosing physical cartridge saves.
// A matching, nonzero, non-FF header is evidence of a cartridge, not a
// guarantee that every contact or save chip is working.
`default_nettype none
module cart_header_probe #(
    parameter integer TIMEOUT = 4000
) (
    input wire clk,
    input wire reset_n,
    input wire start,
    output reg rd_req,
    output reg [1:0] rd_addr,
    input wire rd_ready,
    input wire [31:0] rd_data,
    output reg done,
    output reg present
);
    localparam IDLE=0, ISSUE=1, WAIT_DATA=2, GAP=3, FINISH=4, COMPLETE=5;
    reg [2:0] state;
    reg [2:0] count;
    reg [31:0] words [0:3];
    reg [31:0] acc_or, acc_and;
    reg header_matches;
    localparam TIMER_BITS = TIMEOUT > 0 ? $clog2(TIMEOUT + 1) : 1;
    reg [TIMER_BITS-1:0] timer;

    always @(posedge clk) begin
        rd_req <= 1'b0;
        if (!reset_n) begin
            state <= IDLE;
            count <= 0;
            rd_req <= 0;
            rd_addr <= 2'd0;
            done <= 0;
            present <= 0;
            header_matches <= 1;
            acc_or <= 0;
            acc_and <= 32'hFFFFFFFF;
            timer <= 0;
        end else begin
            case (state)
                IDLE: if (start) state <= ISSUE;
                ISSUE: begin
                    rd_req <= 1'b1;
                    timer <= TIMEOUT;
                    state <= WAIT_DATA;
                end
                WAIT_DATA: begin
                    if (rd_ready) begin
                        acc_or <= acc_or | rd_data;
                        acc_and <= acc_and & rd_data;
                        if (!count[2]) words[count[1:0]] <= rd_data;
                        else if (words[count[1:0]] != rd_data) header_matches <= 0;
                        if (count == 7) state <= FINISH;
                        else begin
                            count <= count + 1'b1;
                            // The two-bit addition intentionally wraps 3 -> 0.
                            rd_addr <= count[1:0] + 2'd1;
                            state <= GAP;
                        end
                    end else if (timer == 0) begin
                        done <= 1;
                        present <= 0;
                        state <= COMPLETE;
                    end else timer <= timer - 1'b1;
                end
                GAP: state <= ISSUE;
                FINISH: begin
                    present <= header_matches && acc_or != 0 && acc_and != 32'hFFFFFFFF;
                    done <= 1;
                    state <= COMPLETE;
                end
                COMPLETE: ;
                default: state <= IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire
