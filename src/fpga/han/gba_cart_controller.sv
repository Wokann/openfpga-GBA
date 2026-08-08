// gba_cart_controller.sv
//
// GBA cartridge bus controller for Analogue Pocket (HAN project).
//
// Provides a transparent bridge between the GBA core and a physical GBA
// cartridge in the Pocket slot:
//   - ROM reads  : 16-bit, CS1#, read-only   (used by rom_source_mux)
//   - Save access: 8-bit SRAM/Flash via CS2# (Flash commands are forwarded
//                  to the cart chip, which executes them itself), or
//                  EEPROM bit-serial via A23/RAMCS/D0
//   - GPIO access: 16-bit R/W at 0x080000C4..0x080000C8 (RTC, solar, gyro,
//                  rumble cart hardware)
//
// All timing constants are conservative placeholders; tune on real carts.
//
// PHI generation: clk_sys ~100.66 MHz / PHI_DIV = 16.78 MHz.

`default_nettype none

module gba_cart_controller #(
    parameter integer PHI_DIV    = 6,   // clk_sys / PHI
    parameter integer ROM_WAIT   = 24,  // clk_sys cycles per 16-bit ROM read
    parameter integer SAVE_WAIT  = 8,   // clk_sys cycles per 8-bit save access
    parameter integer ADDR_SETUP = 4,   // clk_sys cycles driving address
    parameter integer RESET_LEN  = 4096
) (
    input  wire        clk,
    input  wire        reset_n,

    // ---- Pocket cartridge slot (from core_top) ----
    inout  wire [7:0]  cart_tran_bank2,    // GBA AD[15:8]
    output wire        cart_tran_bank2_dir,
    inout  wire [7:0]  cart_tran_bank3,    // GBA AD[7:0]
    output wire        cart_tran_bank3_dir,
    inout  wire [7:0]  cart_tran_bank1,    // GBA A[23:16]
    output wire        cart_tran_bank1_dir,
    inout  wire [3:0]  cart_tran_bank0,    // [3]=PHI# [2]=WR# [1]=RD# [0]=CS1#
    output wire        cart_tran_bank0_dir,
    inout  wire        cart_tran_pin30,    // GBA CS2#/RES#
    output wire        cart_tran_pin30_dir,
    output wire        cart_pin30_pwroff_reset,
    inout  wire        cart_tran_pin31,    // GBA IRQ/DRQ (input, unused)
    output wire        cart_tran_pin31_dir,

    // ---- ROM read interface (sdram_pocket style, DWORD addresses) ----
    input  wire        rd_req,
    input  wire [24:0] rd_addr,
    output reg  [31:0] rd_data,
    output reg  [31:0] rd_data_second,
    output reg         rd_ready,

    // ---- Save access (from core_top save_router) ----
    input  wire        save_req,
    input  wire [16:0] save_addr,          // byte offset within save region
    input  wire        save_rnw,           // 1 = read, 0 = write
    input  wire [7:0]  save_din,
    output reg  [7:0]  save_dout,
    output reg         save_done,
    input  wire [1:0]  save_type,          // 0=SRAM 1=FLASH 2=EEPROM

    // ---- GPIO access (from gba_top, cart mode) ----
    input  wire        gpio_req,
    input  wire        gpio_rnw,           // 1 = read, 0 = write
    input  wire [1:0]  gpio_addr,          // 0..2 -> 0x080000C4..0x080000C8
    input  wire [3:0]  gpio_din,           // write data (D3..D0)
    output reg  [3:0]  gpio_dout,          // read data (D3..D0)
    output reg         gpio_done,

    // ---- status / debug ----
    output reg         cart_present,
    output reg  [7:0]  err_count
);

    // ------------------------------------------------------------------
    // PHI generation (bank0[3])
    // ------------------------------------------------------------------
    reg [2:0] phi_cnt;
    wire phi = (phi_cnt < (PHI_DIV / 2));

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n)
            phi_cnt <= 3'd0;
        else if (phi_cnt == PHI_DIV - 1)
            phi_cnt <= 3'd0;
        else
            phi_cnt <= phi_cnt + 1'b1;
    end

    // ------------------------------------------------------------------
    // Cartridge power-on reset (RES# low for RESET_LEN cycles)
    // ------------------------------------------------------------------
    reg [11:0] reset_cnt;
    reg        res_n;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            reset_cnt <= 12'd0;
            res_n     <= 1'b0;
        end else if (reset_cnt < RESET_LEN) begin
            reset_cnt <= reset_cnt + 1'b1;
            res_n     <= 1'b0;
        end else begin
            res_n <= 1'b1;
        end
    end

    // ------------------------------------------------------------------
    // Main access state machine
    // ------------------------------------------------------------------
    localparam S_IDLE      = 4'd0;
    localparam S_ROM       = 4'd1;   // 16-bit ROM read x4 (64-bit response)
    localparam S_ROM_DONE  = 4'd2;
    localparam S_SRAM      = 4'd3;   // 8-bit SRAM/Flash byte access (CS2#)
    localparam S_SRAM_W    = 4'd4;   // write strobe phase
    localparam S_EEPROM    = 4'd5;   // bit-serial EEPROM forward
    localparam S_GPIO_A    = 4'd6;   // GPIO 16-bit: address phase
    localparam S_GPIO_R    = 4'd7;   // GPIO read data phase
    localparam S_GPIO_W    = 4'd8;   // GPIO write data phase
    localparam S_DONE      = 4'd9;

    reg [3:0]  state;
    reg [1:0]  word_idx;
    reg [24:0] byte_addr;
    reg [7:0]  acc_cnt;
    reg [15:0] words [0:3];
    reg [16:0] save_addr_r;
    reg        save_is_write;
    reg [1:0]  save_type_r;
    reg [15:0] gpio_abs_addr;      // 0x00C4 + {gpio_addr,1'b0}
    reg [3:0]  gpio_din_r;

    // Bus output registers
    reg [7:0]  out_bank1, out_bank2, out_bank3;
    reg        out_bank1_dir, out_bank2_dir, out_bank3_dir;
    reg        rd_n, cs_n, cs2_n, wr_n;

    wire [23:0] word_addr = (byte_addr >> 1) + word_idx;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state           <= S_IDLE;
            word_idx        <= 2'd0;
            byte_addr       <= 25'd0;
            acc_cnt         <= 8'd0;
            rd_data         <= 32'd0;
            rd_data_second  <= 32'd0;
            rd_ready        <= 1'b0;
            save_dout       <= 8'd0;
            save_done       <= 1'b0;
            save_addr_r     <= 17'd0;
            save_is_write   <= 1'b0;
            save_type_r     <= 2'd0;
            gpio_abs_addr   <= 16'd0;
            gpio_din_r      <= 4'd0;
            gpio_dout       <= 4'd0;
            gpio_done       <= 1'b0;
            out_bank1       <= 8'h00;
            out_bank2       <= 8'h00;
            out_bank3       <= 8'h00;
            out_bank1_dir   <= 1'b0;
            out_bank2_dir   <= 1'b0;
            out_bank3_dir   <= 1'b0;
            rd_n            <= 1'b1;
            cs_n            <= 1'b1;
            cs2_n           <= 1'b1;
            wr_n            <= 1'b1;
            cart_present    <= 1'b0;
            err_count       <= 8'd0;
            words[0]        <= 16'd0;
            words[1]        <= 16'd0;
            words[2]        <= 16'd0;
            words[3]        <= 16'd0;
        end else begin
            rd_ready  <= 1'b0;
            save_done <= 1'b0;
            gpio_done <= 1'b0;

            case (state)
                S_IDLE: begin
                    rd_n  <= 1'b1;
                    cs_n  <= 1'b1;
                    cs2_n <= 1'b1;
                    wr_n  <= 1'b1;
                    out_bank1_dir <= 1'b0;
                    out_bank2_dir <= 1'b0;
                    out_bank3_dir <= 1'b0;

                    if (rd_req) begin
                        byte_addr <= {rd_addr, 2'b00};
                        word_idx  <= 2'd0;
                        acc_cnt   <= 8'd0;
                        state     <= S_ROM;
                    end else if (save_req) begin
                        save_addr_r   <= save_addr;
                        save_is_write <= ~save_rnw;
                        save_type_r   <= save_type;
                        acc_cnt       <= 8'd0;
                        state         <= (save_type == 2'd2) ? S_EEPROM : S_SRAM;
                    end else if (gpio_req) begin
                        gpio_abs_addr <= {8'h00, 2'b00, gpio_addr, 1'b0} + 16'h00C4;
                        gpio_din_r    <= gpio_din;
                        acc_cnt       <= 8'd0;
                        state         <= S_GPIO_A;
                    end
                end

                // ---- ROM: four 16-bit reads -> 64-bit response ----
                S_ROM: begin
                    if (acc_cnt < ADDR_SETUP) begin
                        out_bank1     <= word_addr[23:16];
                        out_bank2     <= word_addr[15:8];
                        out_bank3     <= word_addr[7:0];
                        out_bank1_dir <= 1'b1;
                        out_bank2_dir <= 1'b1;
                        out_bank3_dir <= 1'b1;
                        cs_n          <= 1'b0;
                        rd_n          <= 1'b1;
                        acc_cnt       <= acc_cnt + 1'b1;
                    end else if (acc_cnt == ADDR_SETUP) begin
                        out_bank2_dir <= 1'b0;
                        out_bank3_dir <= 1'b0;
                        rd_n          <= 1'b0;
                        acc_cnt       <= acc_cnt + 1'b1;
                    end else if (acc_cnt == ROM_WAIT - 1) begin
                        words[word_idx] <= {cart_tran_bank2, cart_tran_bank3};
                        acc_cnt         <= 8'd0;
                        if (word_idx == 2'd3) begin
                            state <= S_ROM_DONE;
                        end else begin
                            word_idx <= word_idx + 1'b1;
                        end
                    end else begin
                        acc_cnt <= acc_cnt + 1'b1;
                    end
                end

                S_ROM_DONE: begin
                    rd_n  <= 1'b1;
                    cs_n  <= 1'b1;
                    out_bank1_dir <= 1'b0;
                    out_bank2_dir <= 1'b0;
                    out_bank3_dir <= 1'b0;
                    rd_data        <= {words[1], words[0]};
                    rd_data_second <= {words[3], words[2]};
                    cart_present   <= 1'b1;
                    rd_ready       <= 1'b1;
                    state          <= S_IDLE;
                end

                // ---- SRAM / Flash byte access (CS2#, 8-bit data) ----
                S_SRAM: begin
                    out_bank1     <= 8'h0E;                 // A[23:16]
                    out_bank2     <= save_addr_r[15:8];     // A[15:8]
                    out_bank1_dir <= 1'b1;
                    out_bank2_dir <= 1'b1;
                    cs_n          <= 1'b1;
                    cs2_n         <= 1'b0;

                    if (acc_cnt < ADDR_SETUP) begin
                        // Address phase: drive A[7:0] on AD low byte
                        rd_n          <= 1'b1;
                        wr_n          <= 1'b1;
                        out_bank3 <= save_addr_r[7:0];
                        out_bank3_dir <= 1'b1;
                        acc_cnt  <= acc_cnt + 1'b1;
                    end else if (save_is_write) begin
                        // Data phase: hold write data on AD[7:0], strobe WR#
                        out_bank3 <= save_din;
                        out_bank3_dir <= 1'b1;
                        if (acc_cnt == ADDR_SETUP)
                            wr_n <= 1'b0;
                        if (acc_cnt == SAVE_WAIT - 1) begin
                            wr_n  <= 1'b1;
                            state <= S_DONE;
                        end
                        acc_cnt <= acc_cnt + 1'b1;
                    end else begin
                        // Read phase: release AD, sample data
                        out_bank2_dir <= 1'b0;
                        out_bank3_dir <= 1'b0;
                        if (acc_cnt == ADDR_SETUP)
                            rd_n <= 1'b0;
                        if (acc_cnt == SAVE_WAIT - 1) begin
                            save_dout <= cart_tran_bank3;
                            state     <= S_DONE;
                        end
                        acc_cnt <= acc_cnt + 1'b1;
                    end
                end

                // ---- EEPROM: bit-serial forward (A23=clk, D0=data, CS2#=cs) ----
                // Each CPU byte write to the EEPROM region advances one bit:
                // assert CS2#, pulse A23 (low->high), data on D0.
                S_EEPROM: begin
                    out_bank1_dir <= 1'b1;
                    out_bank2_dir <= 1'b1;
                    out_bank3_dir <= 1'b1;
                    cs_n          <= 1'b1;
                    cs2_n         <= 1'b0;
                    rd_n          <= 1'b1;
                    wr_n          <= 1'b1;

                    if (save_is_write) begin
                        // Drive D0 with the data bit, A23 low then high (clock pulse)
                        out_bank1 <= (acc_cnt == 0) ? 8'h0D : 8'h0F;  // A23 toggles
                        out_bank3 <= {7'b0, save_din[0]};
                        if (acc_cnt >= 1) begin
                            state <= S_DONE;
                        end
                    end else begin
                        out_bank1 <= 8'h0F;
                        out_bank2_dir <= 1'b0;
                        out_bank3_dir <= 1'b0;
                        if (acc_cnt >= 1) begin
                            save_dout <= {7'b0, cart_tran_bank3[0]};
                            state     <= S_DONE;
                        end
                    end
                    acc_cnt <= acc_cnt + 1'b1;
                end

                // ---- GPIO: 16-bit R/W at 0x080000C4..0x080000C8 ----
                S_GPIO_A: begin
                    out_bank1     <= 8'h08;
                    out_bank2     <= gpio_abs_addr[15:8];
                    out_bank3     <= gpio_abs_addr[7:0];
                    out_bank1_dir <= 1'b1;
                    out_bank2_dir <= 1'b1;
                    out_bank3_dir <= 1'b1;
                    cs_n          <= 1'b0;
                    rd_n          <= 1'b1;
                    wr_n          <= 1'b1;
                    if (acc_cnt == ADDR_SETUP - 1) begin
                        state <= gpio_rnw ? S_GPIO_R : S_GPIO_W;
                        acc_cnt <= 8'd0;
                    end else begin
                        acc_cnt <= acc_cnt + 1'b1;
                    end
                end

                S_GPIO_R: begin
                    out_bank2_dir <= 1'b0;
                    out_bank3_dir <= 1'b0;
                    rd_n          <= 1'b0;
                    if (acc_cnt == SAVE_WAIT - 1) begin
                        gpio_dout <= cart_tran_bank3[3:0];
                        state     <= S_DONE;
                    end
                    acc_cnt <= acc_cnt + 1'b1;
                end

                S_GPIO_W: begin
                    out_bank3     <= {4'b0, gpio_din_r};
                    out_bank3_dir <= 1'b1;
                    wr_n          <= 1'b0;
                    if (acc_cnt == SAVE_WAIT - 1) begin
                        wr_n  <= 1'b1;
                        state <= S_DONE;
                    end
                    acc_cnt <= acc_cnt + 1'b1;
                end

                S_DONE: begin
                    rd_n  <= 1'b1;
                    cs_n  <= 1'b1;
                    cs2_n <= 1'b1;
                    wr_n  <= 1'b1;
                    out_bank1_dir <= 1'b0;
                    out_bank2_dir <= 1'b0;
                    out_bank3_dir <= 1'b0;
                    save_done <= 1'b1;
                    gpio_done <= 1'b1;
                    state     <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    // ------------------------------------------------------------------
    // Pin drivers
    // ------------------------------------------------------------------
    assign cart_tran_bank1     = out_bank1_dir ? out_bank1 : 8'hzz;
    assign cart_tran_bank1_dir = out_bank1_dir;
    assign cart_tran_bank2     = out_bank2_dir ? out_bank2 : 8'hzz;
    assign cart_tran_bank2_dir = out_bank2_dir;
    assign cart_tran_bank3     = out_bank3_dir ? out_bank3 : 8'hzz;
    assign cart_tran_bank3_dir = out_bank3_dir;

    // bank0 bit layout: [3]=PHI# [2]=WR# [1]=RD# [0]=CS1#
    assign cart_tran_bank0     = {phi, wr_n, rd_n, cs_n};
    assign cart_tran_bank0_dir = 1'b1;

    // pin30: CS2#/RES# — CS2# active during save/EEPROM accesses, else RES#
    assign cart_tran_pin30        = ((state == S_SRAM) || (state == S_EEPROM)) ? cs2_n : res_n;
    assign cart_tran_pin30_dir    = 1'b1;
    assign cart_pin30_pwroff_reset = 1'b0;

    assign cart_tran_pin31     = 1'bz;
    assign cart_tran_pin31_dir = 1'b0;

endmodule

`default_nettype wire
