// gba_cart_controller.sv
//
// GBA cartridge bus controller for Analogue Pocket (HAN project).
//
// Provides a transparent bridge between the GBA core and a physical GBA
// cartridge in the Pocket slot:
//   - ROM reads  : 16-bit, CS1#, read-only   (used by rom_source_mux)
//   - Save access: 8-bit SRAM/Flash via CS2# (Flash commands are forwarded
//                  to the cart chip, which executes them itself)
//   - EEPROM     : bit-serial via ROMCS#/A23/D0 (per-bit forward, the real
//                  EEPROM chip executes the command itself). GBATEK
//                  "Pin-Outs": EEPROM pins 1..8 connect to ROMCS, RD, WR,
//                  AD0, GND, GND, A23, VDD — the chip-select is ROMCS
//                  (Pin 5 / CS1#), NOT CS2# (Pin 30).
//   - GPIO access: 16-bit R/W at 0x080000C4..0x080000C8 (RTC, solar, gyro,
//                  rumble cart hardware)
//
// Timing is modeled on the measured cartridge protocol from
//   https://github.com/jojolebarjos/gba-cartridge
// and on GBATEK (WAITCNT defaults). All wait-state constants remain
// conservative placeholders and MUST be tuned on real carts.
//
// PHI generation: clk_sys ~100.66 MHz / PHI_DIV = 16.78 MHz.

`default_nettype none

module gba_cart_controller #(
    parameter integer PHI_DIV    = 6,   // clk_sys / PHI
    parameter integer PHI_ENABLE = 0,   // 0 = PHI pin idle high (default WAITCNT=4317h),
                                        // 1 = generate PHI at clk_sys/PHI_DIV
    // Wait-state placeholders, in clk_sys (100 MHz) cycles.
    // GBATEK default WAITCNT=4317h: ROM N/S = 3/1 waits (access = 1+waits
    // GBA cycles); SRAM = 8 waits; EEPROM WS2 = 8/8 waits. One GBA cycle
    // ~= 6 clk_sys cycles, so ROM non-sequential ~= 4*6=24 clk_sys cycles
    // and SRAM ~= 9*6=54 clk_sys cycles. Tune on real carts.
    parameter integer ROM_WAIT   = 24,  // clk_sys cycles per 16-bit ROM read
    parameter integer SAVE_WAIT  = 54,  // clk_sys cycles per 8-bit SRAM/Flash access
    parameter integer ADDR_SETUP = 4,   // clk_sys cycles driving address
    // insideGadgets GBxCartRead Part 3 measured the real GBA EEPROM bit
    // clock at ~600 ns full period (~300 ns half) on a logic analyser.
    // Our earlier ~380 ns bit period was too fast for the physical 9853/9854
    // chip. HALF_CYCLE=50 gives ~620 ns bit period, matching the real bus.
    parameter integer EEPROM_HALF_CYCLE = 50, // clk_sys cycles per RD#/WR# half pulse
    parameter integer EEPROM_ADDR_SETUP = 4, // clk_sys cycles A23/D0 stable
                                             // before CS# falls (EEPROM)
    parameter integer RELEASE_DELAY = 4,     // clk_sys cycles CS2# stays low
                                             // after WR#/RD# rise (write
                                             // recovery, real Flash needs it)
    parameter integer EEPROM_SESS_TIMEOUT = 1024, // clk_sys cycles without EEPROM
                                                  // access before releasing CS2#/A23
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

    // ---- Save access (SRAM/Flash, from core_top save_router) ----
    input  wire        save_req,
    input  wire [16:0] save_addr,          // byte offset within save region
    input  wire        save_rnw,           // 1 = read, 0 = write
    input  wire [7:0]  save_din,
    output reg  [7:0]  save_dout,
    output reg         save_done,

    // ---- EEPROM bit access (from gba_top, cart mode) ----
    input  wire        eeprom_req,
    input  wire        eeprom_rnw,         // 1 = read, 0 = write
    input  wire        eeprom_din,         // write data bit (D0)
    output reg         eeprom_dout,        // read data bit (D0)
    output reg         eeprom_done,

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
        end else if (reset_cnt == RESET_LEN - 1) begin
            reset_cnt <= reset_cnt;      // saturate
            res_n     <= 1'b1;
        end else begin
            reset_cnt <= reset_cnt + 1'b1;
            res_n     <= 1'b0;
        end
    end

    // ------------------------------------------------------------------
    // Main access state machine
    // ------------------------------------------------------------------
    localparam S_IDLE      = 4'd0;
    localparam S_ROM_CS    = 4'd1;   // drive address, then assert CS1#
    localparam S_ROM_DATA  = 4'd2;   // release AD, strobe RD#, sample 16-bit
    localparam S_ROM_DONE  = 4'd3;
    localparam S_SRAM      = 4'd4;   // 8-bit SRAM/Flash byte access (CS2#)
    localparam S_SRAM_W    = 4'd5;   // write strobe phase
    localparam S_EEPROM    = 4'd6;   // bit-serial EEPROM forward
    localparam S_GPIO_A    = 4'd7;   // GPIO 16-bit: address phase
    localparam S_GPIO_R    = 4'd8;   // GPIO read data phase
    localparam S_GPIO_W    = 4'd9;   // GPIO write data phase
    localparam S_DONE      = 4'd10;
    localparam S_EEPROM_RESET = 4'd11; // /CS high pulse between EEPROM
                                       // command burst and data burst

    reg [3:0]  state;
    reg [1:0]  word_idx;
    reg [24:0] byte_addr;
    reg [7:0]  acc_cnt;
    reg [15:0] words [0:3];
    reg [16:0] save_addr_r;
    reg        save_is_write;
    reg [15:0] gpio_abs_addr;      // 0x00C4 + {gpio_addr,1'b0}
    reg [3:0]  gpio_din_r;
    // EEPROM session: GBATEK requires /CS=LOW and A23=HIGH throughout the
    // whole DMA3 transfer, not just per-bit. We keep the chip selected for a
    // short timeout after the last bit; the next bit (DMA continues) reuses
    // the open session, and the session closes once DMA pauses.
    reg        eeprom_sess;
    reg [9:0]  eeprom_sess_cnt;
    // Direction of the last EEPROM bit of the current session. The game
    // writes the read/write command as a burst of write bits (rnw=0) and then
    // reads data as a burst of read bits (rnw=1). The rnw transition means
    // the command burst is over: real carts latch the command when /CS rises,
    // so we must pulse /CS high before starting the read burst.
    reg        eeprom_rnw_prev;

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
            eeprom_dout     <= 1'b0;
            eeprom_done     <= 1'b0;
            gpio_abs_addr   <= 16'd0;
            gpio_din_r      <= 4'd0;
            gpio_dout       <= 4'd0;
            gpio_done       <= 1'b0;
            eeprom_sess     <= 1'b0;
            eeprom_sess_cnt <= 10'd0;
            eeprom_rnw_prev <= 1'b1;
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
            eeprom_done <= 1'b0;
            gpio_done <= 1'b0;

            case (state)
                S_IDLE: begin
                    rd_n  <= 1'b1;
                    cs_n  <= 1'b1;
                    wr_n  <= 1'b1;
                    out_bank2_dir <= 1'b0;
                    out_bank3_dir <= 1'b0;

                    if (eeprom_sess) begin
                        // GBATEK: /CS must stay LOW and A23 HIGH for the whole
                        // DMA3 transfer. Keep the session open while bits keep
                        // arriving; close it after EEPROM_SESS_TIMEOUT cycles
                        // of inactivity (DMA finished / paused).
                        cs2_n         <= 1'b0;
                        cs_n          <= 1'b0;    // ROMCS stays low (EEPROM /CS)
                        cs2_n         <= 1'b1;    // pin30 stays RES# high
                        out_bank1     <= 8'h80;   // A23 = 1
                        out_bank1_dir <= 1'b1;
                        if (eeprom_sess_cnt == EEPROM_SESS_TIMEOUT - 1) begin
                            eeprom_sess <= 1'b0;   // release next cycle
                        end else begin
                            eeprom_sess_cnt <= eeprom_sess_cnt + 1'b1;
                        end
                    end else begin
                        cs_n          <= 1'b1;
                        cs2_n         <= 1'b1;
                        out_bank1_dir <= 1'b0;
                    end

                    if (rd_req) begin
                        eeprom_sess     <= 1'b0;   // other access: close session
                        byte_addr <= {rd_addr, 2'b00};
                        word_idx  <= 2'd0;
                        acc_cnt   <= 8'd0;
                        state     <= S_ROM_CS;
                    end else if (save_req) begin
                        eeprom_sess     <= 1'b0;
                        save_addr_r   <= save_addr;
                        save_is_write <= ~save_rnw;
                        acc_cnt       <= 8'd0;
                        state         <= S_SRAM;
                    end else if (eeprom_req) begin
                        eeprom_sess     <= 1'b1;   // (re)open EEPROM session
                        eeprom_sess_cnt <= 10'd0;
                        if (eeprom_sess && (eeprom_rnw != eeprom_rnw_prev)) begin
                            // Session in progress and the bit direction
                            // flipped (write burst -> read burst): the
                            // command burst is complete. Pulse /CS high so the
                            // cart chip latches the command (read) or starts
                            // programming (write -> ready polling), then
                            // start the read burst with /CS low again.
                            acc_cnt <= 8'd0;
                            state   <= S_EEPROM_RESET;
                        end else begin
                            acc_cnt <= 8'd0;
                            state   <= S_EEPROM;
                        end
                        eeprom_rnw_prev <= eeprom_rnw;
                    end else if (gpio_req) begin
                        eeprom_sess     <= 1'b0;
                        // Halfword address: 0x080000C4..0x080000C8 (byte) >> 1
                        // = 0x04000062..0x04000064. The cartridge bus always
                        // carries halfword addresses for ROM-space access.
                        gpio_abs_addr <= 16'h0062 + {14'd0, gpio_addr};
                        gpio_din_r    <= gpio_din;
                        acc_cnt       <= 8'd0;
                        state         <= S_GPIO_A;
                    end
                end

                // ---- ROM: 16-bit read, CS# falling edge latches address ----
                // Per jojolebarjos/gba-cartridge:
                //   address must be driven before CS# falls (latched on ~CS edge)
                //   data sampled before ~RD rising edge; ~RD rising increments
                //   the latched address internally, but we re-drive it anyway.
                S_ROM_CS: begin
                    // Address setup phase: drive full 24-bit address, CS# high.
                    out_bank1     <= word_addr[23:16];
                    out_bank2     <= word_addr[15:8];
                    out_bank3     <= word_addr[7:0];
                    out_bank1_dir <= 1'b1;
                    out_bank2_dir <= 1'b1;
                    out_bank3_dir <= 1'b1;
                    rd_n          <= 1'b1;
                    wr_n          <= 1'b1;
                    cs_n          <= 1'b1;        // default: keep CS# high
                    if (acc_cnt < ADDR_SETUP - 1) begin
                        acc_cnt <= acc_cnt + 1'b1;
                    end else begin
                        cs_n    <= 1'b0;          // ~CS falling edge latches address
                        acc_cnt <= 8'd0;
                        state   <= S_ROM_DATA;
                    end
                end

                S_ROM_DATA: begin
                    if (acc_cnt == 0) begin
                        // Release AD bus (data comes from cart on AD[15:0])
                        out_bank2_dir <= 1'b0;
                        out_bank3_dir <= 1'b0;
                        rd_n          <= 1'b0;   // ~RD falling edge fetches data
                    end
                    if (acc_cnt == ROM_WAIT - 1) begin
                        words[word_idx] <= {cart_tran_bank2, cart_tran_bank3};
                        rd_n            <= 1'b1;
                        cs_n            <= 1'b1;  // end this word's transaction
                        acc_cnt         <= 8'd0;
                        if (word_idx == 2'd3) begin
                            state <= S_ROM_DONE;
                        end else begin
                            word_idx <= word_idx + 1'b1;
                            state    <= S_ROM_CS;   // next word: re-drive address
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

                // ---- SRAM / Flash byte access (CS2#) ----
                // Real GBA SRAM protocol: 16-bit address on AD[15:0],
                // 8-bit data on A[23:16] (bank1), selected by ~CS2.
                S_SRAM: begin
                    // Address phase: drive AD[15:0]. CS2# falls only after the
                    // address has been stable for >=2 cycles. For writes the
                    // data on A[23:16] is pre-driven from the first cycle so
                    // it is stable >=4 cycles before WR# falls. Real Flash
                    // samples address+data on the WE# falling edge and needs
                    // ~30-50ns data setup; SRAM samples on the WE# rising edge
                    // so it tolerates the earlier data too.
                    out_bank2     <= save_addr_r[15:8];
                    out_bank3     <= save_addr_r[7:0];
                    out_bank2_dir <= 1'b1;
                    out_bank3_dir <= 1'b1;
                    cs_n          <= 1'b1;

                    if (acc_cnt < ADDR_SETUP) begin
                        // CS2# falls only after the address has settled
                        if (acc_cnt >= 2) cs2_n <= 1'b0;
                        else              cs2_n <= 1'b1;
                        if (save_is_write) begin
                            out_bank1     <= save_din;
                            out_bank1_dir <= 1'b1;
                        end else begin
                            out_bank1_dir <= 1'b0;   // data bus input for read
                        end
                        rd_n <= 1'b1;   // keep strobes high during address setup
                        wr_n <= 1'b1;
                        acc_cnt <= acc_cnt + 1'b1;
                    end else if (acc_cnt == ADDR_SETUP) begin
                        // One extra cycle so address+data are fully stable,
                        // then start the strobe.
                        if (save_is_write) begin
                            wr_n <= 1'b0;
                            rd_n <= 1'b1;
                        end else begin
                            rd_n <= 1'b0;
                            wr_n <= 1'b1;
                        end
                        acc_cnt <= acc_cnt + 1'b1;
                    end else if (save_is_write) begin
                        // Write strobe phase
                        rd_n <= 1'b1;
                        if (acc_cnt == ADDR_SETUP + SAVE_WAIT - 1) begin
                            wr_n  <= 1'b1;
                            acc_cnt <= 8'd0;
                            state   <= S_DONE;
                        end else begin
                            acc_cnt <= acc_cnt + 1'b1;
                        end
                    end else begin
                        // Read strobe phase: sample data on A[23:16]
                        out_bank1_dir <= 1'b0;
                        wr_n          <= 1'b1;
                        if (acc_cnt == ADDR_SETUP + SAVE_WAIT - 1) begin
                            rd_n      <= 1'b1;
                            save_dout <= cart_tran_bank1;
                            acc_cnt   <= 8'd0;
                            state     <= S_DONE;
                        end else begin
                            acc_cnt <= acc_cnt + 1'b1;
                        end
                    end
                end

                // ---- EEPROM: bit-serial forward (CS2#=ROMCS, A23=high,
                //      RD#/WR# = bit clock, D0 = data) ----
                // Per GBATEK "GBA Cart Backup EEPROM": during the whole DMA
                // transfer the cart sees /CS=LOW and A23=HIGH, and each bit is
                // driven by one 16-bit DMA access (RD# for reads, WR# for
                // writes), data on AD0. /CS is ROMCS (Pin 5), not CS2#.
                // We forward one bit per request.
                S_EEPROM: begin
                    // A23 (=bank1[7]) stays HIGH during the whole transfer,
                    // as on the real GBA bus when addressing 0x0Dxxxxxx.
                    out_bank1     <= 8'h80;
                    out_bank1_dir <= 1'b1;
                    out_bank2_dir <= 1'b0;
                    cs2_n         <= 1'b1;   // pin30 stays RES# high
                    if (eeprom_rnw) begin
                        out_bank3_dir <= 1'b0;
                        wr_n          <= 1'b1;
                    end else begin
                        // Write bit: D0 driven from the very first cycle so it
                        // is stable long before WR# falls.
                        out_bank3     <= {7'b0, eeprom_din};
                        out_bank3_dir <= 1'b1;
                        rd_n          <= 1'b1;
                    end

                    if (acc_cnt < EEPROM_ADDR_SETUP) begin
                        // Address/data setup: A23 (+D0) stable.
                        // First bit of a new session: CS# starts high, then
                        // falls. Subsequent bits of the same DMA transfer:
                        // CS# MUST stay low - GBATEK requires /CS=LOW and
                        // A23=HIGH throughout the whole transfer; raising CS#
                        // between bits resets the serial EEPROM chip.
                        // eeprom_sess here is the OLD value: 0 on the first
                        // request, 1 on later requests of the same session.
                        cs_n  <= ~eeprom_sess;
                        rd_n  <= 1'b1;
                        wr_n  <= 1'b1;
                        acc_cnt <= acc_cnt + 1'b1;
                    end else if (acc_cnt == EEPROM_ADDR_SETUP) begin
                        // CS# falls with A23/D0 already stable (first bit),
                        // or simply stays low (session in progress).
                        cs_n  <= 1'b0;
                        rd_n  <= 1'b1;
                        wr_n  <= 1'b1;
                        acc_cnt <= acc_cnt + 1'b1;
                    end else if (acc_cnt < EEPROM_ADDR_SETUP + 2) begin
                        // Hold CS# low one cycle before starting the bit pulse
                        rd_n  <= 1'b1;
                        wr_n  <= 1'b1;
                        acc_cnt <= acc_cnt + 1'b1;
                    end else if (eeprom_rnw) begin
                        // Read bit: RD# low pulse, then sample D0 AFTER the
                        // RD# rising edge (insideGadgets measures the data
                        // being read right after RD goes high).
                        if (acc_cnt < EEPROM_ADDR_SETUP + EEPROM_HALF_CYCLE) begin
                            rd_n <= 1'b0;
                            acc_cnt <= acc_cnt + 1'b1;
                        end else if (acc_cnt < EEPROM_ADDR_SETUP + EEPROM_HALF_CYCLE + 4) begin
                            // RD# rising edge; hold high and give the EEPROM
                            // chip a few cycles to drive D0 after the edge
                            // (insideGadgets: data appears right after RD
                            // goes high). 4 cycles @100MHz = 40ns.
                            rd_n <= 1'b1;
                            acc_cnt <= acc_cnt + 1'b1;
                        end else begin
                            eeprom_dout <= cart_tran_bank3[0];
                            acc_cnt <= 8'd0;
                            state   <= S_DONE;
                        end
                    end else begin
                        // Write bit: WR# low pulse (D0 held through the edge)
                        if (acc_cnt < EEPROM_ADDR_SETUP + EEPROM_HALF_CYCLE - 1) begin
                            wr_n <= 1'b0;
                            acc_cnt <= acc_cnt + 1'b1;
                        end else begin
                            wr_n    <= 1'b1;
                            acc_cnt <= 8'd0;
                            state   <= S_DONE;
                        end
                    end
                end

                // ---- EEPROM command-latch pulse ----
                // After the write (command) burst ends and the read burst
                // begins, the real cart needs /CS to rise once so the chip
                // latches the command. Keep A23 high, hold /CS high for a few
                // cycles, then let S_EEPROM pull it low again for the read
                // burst (S_EEPROM keeps /CS low when eeprom_sess is active).
                S_EEPROM_RESET: begin
                    out_bank1     <= 8'h80;      // A23 stays HIGH
                    out_bank1_dir <= 1'b1;
                    out_bank2_dir <= 1'b0;
                    out_bank3_dir <= 1'b0;
                    cs_n          <= 1'b1;       // /CS high pulse
                    rd_n          <= 1'b1;
                    wr_n          <= 1'b1;
                    cs2_n         <= 1'b1;
                    if (acc_cnt < 16) begin
                        acc_cnt <= acc_cnt + 1'b1;
                    end else begin
                        acc_cnt <= 8'd0;
                        state   <= S_EEPROM;     // begin the read burst
                    end
                end

                // ---- GPIO: 16-bit R/W at 0x080000C4..0x080000C8 ----
                S_GPIO_A: begin
                    // Halfword address: 0x04000062 + reg (see gpio_abs_addr).
                    out_bank1     <= 8'h04;      // A[23:16] of halfword address
                    out_bank2     <= gpio_abs_addr[15:8];
                    out_bank3     <= gpio_abs_addr[7:0];
                    out_bank1_dir <= 1'b1;
                    out_bank2_dir <= 1'b1;
                    out_bank3_dir <= 1'b1;
                    cs_n          <= 1'b1;      // address setup, CS# high
                    rd_n          <= 1'b1;
                    wr_n          <= 1'b1;
                    if (acc_cnt == ADDR_SETUP - 1) begin
                        cs_n <= 1'b0;           // CS# falling edge latches addr
                        state <= gpio_rnw ? S_GPIO_R : S_GPIO_W;
                        acc_cnt <= 8'd0;
                    end else begin
                        acc_cnt <= acc_cnt + 1'b1;
                    end
                end

                S_GPIO_R: begin
                    out_bank2_dir <= 1'b0;
                    out_bank3_dir <= 1'b0;
                    if (acc_cnt < SAVE_WAIT - 2) begin
                        rd_n <= 1'b0;
                        acc_cnt <= acc_cnt + 1'b1;
                    end else if (acc_cnt == SAVE_WAIT - 2) begin
                        // Sample while RD# is still LOW: the GPIO/ROM chip
                        // drives data during the RD# low phase and the CPU
                        // latches it on the RD# rising edge, so sampling must
                        // happen before the edge (same as S_ROM_DATA).
                        gpio_dout <= cart_tran_bank3[3:0];
                        acc_cnt <= acc_cnt + 1'b1;
                    end else begin
                        rd_n    <= 1'b1;   // RD# rising edge
                        acc_cnt   <= 8'd0;
                        state     <= S_DONE;
                    end
                end

                S_GPIO_W: begin
                    // Drive the write data first and hold WR# high during a
                    // setup phase, so the ROM-chip GPIO registers sample
                    // stable data when WR# falls (real GBA drives data before
                    // asserting WR#; writing data and WR# on the same cycle
                    // gives zero setup time and can store the old address
                    // byte instead of the GPIO data).
                    out_bank3     <= {4'b0, gpio_din_r};
                    out_bank3_dir <= 1'b1;
                    if (acc_cnt < ADDR_SETUP) begin
                        wr_n    <= 1'b1;   // data setup, WR# high
                        acc_cnt <= acc_cnt + 1'b1;
                    end else if (acc_cnt < ADDR_SETUP + SAVE_WAIT - 1) begin
                        wr_n    <= 1'b0;   // WR# low pulse
                        acc_cnt <= acc_cnt + 1'b1;
                    end else begin
                        wr_n    <= 1'b1;
                        acc_cnt <= 8'd0;
                        state   <= S_DONE;
                    end
                end

                S_DONE: begin
                    rd_n  <= 1'b1;
                    cs_n  <= 1'b1;
                    wr_n  <= 1'b1;
                    out_bank2_dir <= 1'b0;
                    out_bank3_dir <= 1'b0;
                    if (acc_cnt < RELEASE_DELAY - 1) begin
                        // Release RD#/WR# first while CS2# (SRAM/Flash select)
                        // stays low: real SRAM samples data on the WR# rising
                        // edge, and Flash needs write-recovery time (WE# high
                        // while CE# is still low).
                        acc_cnt <= acc_cnt + 1'b1;
                    end else begin
                        if (eeprom_sess) begin
                            // Keep /CS LOW and A23 HIGH across consecutive
                            // EEPROM bit accesses (GBATEK requirement for DMA3).
                            cs_n          <= 1'b0;
                            out_bank1     <= 8'h80;
                            out_bank1_dir <= 1'b1;
                        end else begin
                            cs_n          <= 1'b1;
                            out_bank1_dir <= 1'b0;
                        end
                        cs2_n         <= 1'b1;   // release CS2# one cycle later
                        save_done     <= 1'b1;
                        eeprom_done   <= 1'b1;
                        gpio_done     <= 1'b1;
                        state         <= S_IDLE;
                    end
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
    // GBATEK: default WAITCNT (4317h) disables the PHI terminal output.
    assign cart_tran_bank0     = {PHI_ENABLE ? phi : 1'b1, wr_n, rd_n, cs_n};
    assign cart_tran_bank0_dir = 1'b1;

    // pin30: CS2#/RES# — CS2# active during SRAM/Flash accesses and for one
    // extra cycle in S_DONE (so WR#/RD# rise while CS2# is still low, as real
    // SRAM chips require); during EEPROM transfers pin30 stays at RES#
    // (EEPROM /CS is ROMCS, Pin 5).
    assign cart_tran_pin30        = ((state == S_SRAM) ||
                                     ((state == S_DONE) && (acc_cnt < RELEASE_DELAY - 1))) ? cs2_n : res_n;
    assign cart_tran_pin30_dir    = 1'b1;
    assign cart_pin30_pwroff_reset = 1'b0;

    assign cart_tran_pin31     = 1'bz;
    assign cart_tran_pin31_dir = 1'b0;

endmodule

`default_nettype wire
