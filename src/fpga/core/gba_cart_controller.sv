// Physical saves integrated with the v1.0.1 slot/rumble ownership protocol.
// Save-bus timing is adapted from backup/layered-20260814 (f245435).
// Game ROM stays on SD; C4/C6/C8 transactions reach the physical ROM GPIO.
// SRAM/Flash use CS2 with data on A[23:16]. EEPROM uses ROMCS/A23/D0.
// Bus ownership is retained through an entire EEPROM session.
// Timing references: https://github.com/jojolebarjos/gba-cartridge and
// https://www.insidegadgets.com/2017/01/22/gbxcartread-part-3-gba-eeprom-readwrite-flash-write-and-determining-sizes/
`default_nettype none

module gba_cart_controller #(
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
    // The legacy half-pulse and recovery counts are preserved here.
    parameter integer EEPROM_HALF_CYCLE = 50, // clk_sys cycles per RD#/WR# half pulse
    parameter integer EEPROM_ADDR_SETUP = 16, // clk_sys cycles A23/D0 stable
                                             // before CS# falls (EEPROM)
    // Preserve the tested save-bus strobe recovery and data hold intervals.
    parameter integer RELEASE_DELAY = 32,
    parameter integer EEPROM_SESS_TIMEOUT = 1024, // clk_sys cycles without EEPROM
                                                  // access before releasing ROMCS/A23
    // Reuse upstream rumble bus phases (~270 ns), rescaled to clk_sys.
    parameter integer GPIO_PHASE = 27,
    parameter integer RESET_LEN  = 4096
) (
    input  wire        clk,
    input  wire        reset_n,

    // Shared-slot ownership: requests are latched before waiting for grant.
    input  wire        bus_grant,
    input  wire        bus_enable,
    output reg         bus_request,
    output wire        cart_ready,

    // ---- Pocket cartridge slot (from core_top) ----
    inout  wire [7:0]  cart_tran_bank2,    // GBA AD[15:8]
    output wire        cart_tran_bank2_dir,
    inout  wire [7:0]  cart_tran_bank3,    // GBA AD[7:0]
    output wire        cart_tran_bank3_dir,
    inout  wire [7:0]  cart_tran_bank1,    // GBA A[23:16]
    output wire        cart_tran_bank1_dir,
    inout  wire [7:4]  cart_tran_bank0,    // [7]=PHI# [6]=WR# [5]=RD# [4]=CS1#
    inout  wire        cart_tran_pin30,    // GBA CS2#/RES#

    // ---- Header DWORD index (0..3 for byte offsets 0xB0..0xBF) ----
    input  wire        rd_req,
    input  wire [1:0]  rd_addr,
    output reg  [31:0] rd_data,
    output reg         rd_ready,

    // ---- Save access (SRAM/Flash, from core_top save_router) ----
    input  wire        save_req,
    input  wire [15:0] save_addr,          // byte offset within save region
    input  wire        save_rnw,           // 1 = read, 0 = write
    input  wire [7:0]  save_din,
    output reg  [7:0]  save_dout,
    output reg         save_done,

    // Raw ROM GPIO halfword access. No peripheral-specific protocol here.
    input  wire        gpio_req,
    input  wire [1:0]  gpio_addr,         // 0=C4, 1=C6, 2=C8
    input  wire        gpio_rnw,
    input  wire [15:0] gpio_din,
    output reg  [15:0] gpio_dout,
    output reg         gpio_done,
    output reg         gpio_readable,    // acknowledged C8 bit 0

    // ---- EEPROM bit access (from gba_top, cart mode) ----
    input  wire        eeprom_req,
    input  wire        eeprom_rnw,         // 1 = read, 0 = write
    input  wire        eeprom_din,         // write data bit (D0)
    input  wire        eeprom_dma,         // 1 = bit access via DMA3 burst,
                                           // 0 = standalone CPU LDRH/STRH
                                           // (write-complete ready polling)
    output reg         eeprom_dout,        // read data bit (D0)
    output reg         eeprom_done

);

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
    localparam S_EEPROM    = 4'd6;   // bit-serial EEPROM forward
    localparam S_DONE      = 4'd10;
    localparam S_EEPROM_RESET = 4'd11; // /CS high pulse between EEPROM
                                       // command burst and data burst
    localparam S_ACQUIRE = 4'd7; // wait for the upstream rumble driver to finish

    localparam S_GPIO = 4'd8;
    reg [1:0] gpio_addr_r;
    reg gpio_rnw_r;
    reg [15:0] gpio_din_r;
    wire [7:0] gpio_word_addr = 8'h62 + {6'd0, gpio_addr_r};

    reg [3:0]  state;
    reg [3:0]  access_state;
    reg [7:0]  save_din_r;
    reg        eeprom_rnw_r, eeprom_din_r;
    reg        word_idx;
    reg [1:0]  header_index;
    localparam ROM_SAVE_CYCLES = ADDR_SETUP + ((ROM_WAIT > SAVE_WAIT) ? ROM_WAIT : SAVE_WAIT);
    localparam EEPROM_CYCLES = EEPROM_ADDR_SETUP + EEPROM_HALF_CYCLE;
    localparam ACCESS_CYCLES = ROM_SAVE_CYCLES > EEPROM_CYCLES ? ROM_SAVE_CYCLES : EEPROM_CYCLES;
    localparam HOLD_CYCLES = ACCESS_CYCLES > 2*RELEASE_DELAY ? ACCESS_CYCLES : 2*RELEASE_DELAY;
    localparam MAX_CYCLES = HOLD_CYCLES > 6*GPIO_PHASE ? HOLD_CYCLES : 6*GPIO_PHASE;
    localparam ACC_BITS = $clog2((MAX_CYCLES > 17 ? MAX_CYCLES : 17) + 1);
    reg [ACC_BITS-1:0] acc_cnt;
    reg [15:0] save_addr_r;
    reg        save_is_write;
    // EEPROM session: GBATEK requires /CS=LOW and A23=HIGH throughout the
    // whole DMA3 transfer, not just per-bit. We keep the chip selected for a
    // short timeout after the last bit; the next bit (DMA continues) reuses
    // the open session, and the session closes once DMA pauses.
    reg        eeprom_sess;
    reg        eeprom_new_session;
    reg [9:0]  eeprom_sess_cnt;
    // Latched per-access flag: 1 = this bit was requested by a DMA3 burst
    // (keep /CS low across the burst), 0 = standalone CPU access (polling,
    // each access is its own /CS low-high cycle so the cart chip updates its
    // busy/ready status on the /CS rising edge).
    reg        eeprom_dma_r;
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

    // Only the four DWORDs at byte offsets 0xB0..0xBF can be probed.
    wire [6:0] word_addr = 7'h58 + {4'd0, header_index, 1'b0} + word_idx;

    assign cart_ready = res_n;
    // Four-phase CDC handshake: a new access cannot reuse a stale grant
    // while the previous grant's deassertion is crossing the synchronizer.
    localparam SLOT_IDLE=0, SLOT_REQUEST=1, SLOT_OWNED=2, SLOT_RELEASE=3;
    reg [1:0] slot_state;
    wire need_bus = !res_n || state != S_IDLE || eeprom_sess;
    wire bus_acquired = slot_state == SLOT_OWNED && bus_grant;
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            slot_state <= SLOT_IDLE;
            bus_request <= 0;
        end else begin
            case (slot_state)
                SLOT_IDLE: if (!bus_grant && need_bus) begin
                    bus_request <= 1;
                    slot_state <= SLOT_REQUEST;
                end
                SLOT_REQUEST: if (bus_grant) slot_state <= SLOT_OWNED;
                SLOT_OWNED: if (!need_bus) begin
                    bus_request <= 0;
                    slot_state <= SLOT_RELEASE;
                end
                SLOT_RELEASE: if (!bus_grant) slot_state <= SLOT_IDLE;
            endcase
        end
    end

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state           <= S_IDLE;
            access_state    <= S_IDLE;
            save_din_r      <= 8'd0;
            eeprom_rnw_r    <= 1'b1;
            eeprom_din_r    <= 1'b0;
            word_idx        <= 1'b0;
            header_index    <= 2'd0;
            acc_cnt         <= '0;
            gpio_addr_r     <= 0;
            gpio_rnw_r      <= 1;
            gpio_din_r      <= 0;
            gpio_dout       <= 0;
            gpio_done       <= 0;
            gpio_readable   <= 0;
            rd_data         <= 32'd0;
            rd_ready        <= 1'b0;
            save_dout       <= 8'd0;
            save_done       <= 1'b0;
            save_addr_r     <= 16'd0;
            save_is_write   <= 1'b0;
            eeprom_dout     <= 1'b0;
            eeprom_done     <= 1'b0;
            eeprom_sess     <= 1'b0;
            eeprom_new_session <= 1'b1;
            eeprom_sess_cnt <= 10'd0;
            eeprom_rnw_prev <= 1'b1;
            eeprom_dma_r    <= 1'b1;
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
        end else begin
            gpio_done <= 1'b0;
            rd_ready  <= 1'b0;
            save_done <= 1'b0;
            eeprom_done <= 1'b0;
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
                        header_index <= rd_addr;
                        word_idx  <= 1'b0;
                        acc_cnt   <= '0;
                        access_state <= S_ROM_CS;
                        state <= S_ACQUIRE;
                    end else if (gpio_req) begin
                        eeprom_sess <= 1'b0;
                        gpio_addr_r <= gpio_addr;
                        gpio_rnw_r <= gpio_rnw;
                        gpio_din_r <= gpio_din;
                        acc_cnt <= '0;
                        access_state <= S_GPIO;
                        state <= S_ACQUIRE;
                    end else if (save_req) begin
                        eeprom_sess     <= 1'b0;
                        save_addr_r   <= save_addr;
                        save_is_write <= ~save_rnw;
                        acc_cnt       <= '0;
                        save_din_r <= save_din;
                        access_state <= S_SRAM;
                        state <= S_ACQUIRE;
                    end else if (eeprom_req) begin
                        eeprom_new_session <= !eeprom_sess || eeprom_rnw != eeprom_rnw_prev;
                        eeprom_sess     <= 1'b1;   // (re)open EEPROM session
                        eeprom_sess_cnt <= 10'd0;
                        eeprom_dma_r    <= eeprom_dma;
                        eeprom_rnw_r <= eeprom_rnw;
                        eeprom_din_r <= eeprom_din;
                        state <= S_ACQUIRE;
                        if (eeprom_sess && (eeprom_rnw != eeprom_rnw_prev)) begin
                            // Session in progress and the bit direction
                            // flipped (write burst -> read burst): the
                            // command burst is complete. Pulse /CS high so the
                            // cart chip latches the command (read) or starts
                            // programming (write -> ready polling), then
                            // start the read burst with /CS low again.
                            acc_cnt <= '0;
                            access_state <= S_EEPROM_RESET;
                        end else begin
                            acc_cnt <= '0;
                            access_state <= S_EEPROM;
                        end
                        eeprom_rnw_prev <= eeprom_rnw;

                    end
                end

                S_ACQUIRE: begin
                    if (bus_acquired && res_n) state <= access_state;
                end

                // ---- ROM: 16-bit read, CS# falling edge latches address ----
                // Per jojolebarjos/gba-cartridge:
                //   address must be driven before CS# falls (latched on ~CS edge)
                //   data sampled before ~RD rising edge; ~RD rising increments
                //   the latched address internally, but we re-drive it anyway.
                S_ROM_CS: begin
                    // Address setup phase: drive full 24-bit address, CS# high.
                    out_bank1     <= 8'h00;
                    out_bank2     <= 8'h00;
                    out_bank3     <= {1'b0, word_addr};
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
                        acc_cnt <= '0;
                        state   <= S_ROM_DATA;
                    end
                end

                S_ROM_DATA: begin
                    if (acc_cnt < ADDR_SETUP) begin
                        // CS# has fallen; hold the address on AD[15:0] for the
                        // latch hold time before releasing it to data.
                        rd_n <= 1'b1;
                        acc_cnt <= acc_cnt + 1'b1;
                    end else if (acc_cnt == ADDR_SETUP) begin
                        // Release AD bus (data comes from cart on AD[15:0])
                        // and start the read strobe.
                        out_bank2_dir <= 1'b0;
                        out_bank3_dir <= 1'b0;
                        rd_n          <= 1'b0;   // ~RD falling edge fetches data
                        acc_cnt       <= acc_cnt + 1'b1;
                    end else if (acc_cnt < ADDR_SETUP + ROM_WAIT - 1) begin
                        rd_n <= 1'b0;
                        acc_cnt <= acc_cnt + 1'b1;
                    end else begin
                        // Sample while ~RD is still low (data stable; the cart
                        // drives AD during the RD# low phase).
                        if (word_idx) rd_data[31:16] <= {cart_tran_bank2, cart_tran_bank3};
                        else rd_data[15:0] <= {cart_tran_bank2, cart_tran_bank3};
                        rd_n            <= 1'b1;
                        cs_n            <= 1'b1;  // end this word's transaction
                        acc_cnt         <= '0;
                        if (word_idx == 1'b1) begin
                            state <= S_ROM_DONE;
                        end else begin
                            word_idx <= word_idx + 1'b1;
                            state    <= S_ROM_CS;   // next word: re-drive address
                        end
                    end
                end

                S_ROM_DONE: begin
                    rd_n  <= 1'b1;
                    cs_n  <= 1'b1;
                    out_bank1_dir <= 1'b0;
                    out_bank2_dir <= 1'b0;
                    out_bank3_dir <= 1'b0;
                    rd_ready       <= 1'b1;
                    state          <= S_IDLE;
                end

                // Same six phases as the upstream physical rumble writer,
                // plus AD turnaround and sampling for reads. CS2 stays idle.
                S_GPIO: begin
                    out_bank1 <= 0;
                    out_bank1_dir <= 1;
                    cs2_n <= 1;
                    cs_n <= !(acc_cnt >= GPIO_PHASE && acc_cnt < 5*GPIO_PHASE);
                    rd_n <= !(gpio_rnw_r && acc_cnt >= 3*GPIO_PHASE && acc_cnt < 4*GPIO_PHASE);
                    wr_n <= !(!gpio_rnw_r && acc_cnt >= 3*GPIO_PHASE && acc_cnt < 4*GPIO_PHASE);
                    out_bank2 <= acc_cnt < 2*GPIO_PHASE ? 8'h00 : gpio_din_r[15:8];
                    out_bank3 <= acc_cnt < 2*GPIO_PHASE ? gpio_word_addr : gpio_din_r[7:0];
                    out_bank2_dir <= acc_cnt < 2*GPIO_PHASE || !gpio_rnw_r;
                    out_bank3_dir <= acc_cnt < 2*GPIO_PHASE || !gpio_rnw_r;
                    if (gpio_rnw_r && acc_cnt == 4*GPIO_PHASE)
                        gpio_dout <= {cart_tran_bank2, cart_tran_bank3};
                    if (acc_cnt == 6*GPIO_PHASE - 1) begin
                        out_bank1_dir <= 0;
                        out_bank2_dir <= 0;
                        out_bank3_dir <= 0;
                        if (!gpio_rnw_r && gpio_addr_r == 2)
                            gpio_readable <= gpio_din_r[0];
                        gpio_done <= 1;
                        state <= S_IDLE;
                    end else acc_cnt <= acc_cnt + 1'b1;
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
                            out_bank1     <= save_din_r;
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
                            acc_cnt <= '0;
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
                            acc_cnt   <= '0;
                            state     <= S_DONE;
                        end else begin
                            acc_cnt <= acc_cnt + 1'b1;
                        end
                    end
                end

                // ---- EEPROM: bit-serial forward (ROMCS, A23=high,
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
                    if (eeprom_rnw_r) begin
                        out_bank3_dir <= 1'b0;
                        wr_n          <= 1'b1;
                    end else begin
                        // Write bit: D0 driven from the very first cycle so it
                        // is stable long before WR# falls.
                        out_bank3     <= {7'b0, eeprom_din_r};
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
                        // A newly acquired slot must establish A23/D0 before
                        // lowering ROMCS, even after waiting for rumble.
                        cs_n  <= eeprom_new_session;
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
                    end else if (eeprom_rnw_r) begin
                        // Read bit: RD# low pulse, then sample D0 immediately
                        // after the RD# rising edge. insideGadgets' logic
                        // analyser capture reads AD0 right after RD goes high
                        // (the chip holds the bit briefly past the edge);
                        // waiting hundreds of ns reads the tri-stated bus.
                        if (acc_cnt < EEPROM_ADDR_SETUP + EEPROM_HALF_CYCLE - 1) begin
                            rd_n <= 1'b0;
                            acc_cnt <= acc_cnt + 1'b1;
                        end else if (acc_cnt == EEPROM_ADDR_SETUP + EEPROM_HALF_CYCLE - 1) begin
                            rd_n <= 1'b1;   // rising edge
                            acc_cnt <= acc_cnt + 1'b1;
                        end else begin
                            // Sample one cycle after the edge.
                            eeprom_dout <= cart_tran_bank3[0];
                            acc_cnt <= '0;
                            state   <= S_DONE;
                        end
                    end else begin
                        // Write bit: WR# low pulse (D0 held through the edge)
                        if (acc_cnt < EEPROM_ADDR_SETUP + EEPROM_HALF_CYCLE - 1) begin
                            wr_n <= 1'b0;
                            acc_cnt <= acc_cnt + 1'b1;
                        end else begin
                            wr_n    <= 1'b1;
                            acc_cnt <= '0;
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
                        acc_cnt <= '0;
                        state   <= S_EEPROM;     // begin the read burst
                    end
                end

                S_DONE: begin
                    rd_n  <= 1'b1;
                    wr_n  <= 1'b1;
                    if (acc_cnt < RELEASE_DELAY - 1) begin
                        // Phase 1 (write recovery): RD#/WR# are already high,
                        // the chip-selects stay low, and the AD bus stays
                        // driven. Real SRAM samples data on the WR# rising
                        // edge, Flash needs WE#-high-while-CE#-low recovery
                        // time. CS1# keeps its previous value (low for EEPROM
                        // write recovery, high for SRAM/Flash so the ROM chip
                        // is never selected); CS2# (pin30) likewise via the
                        // pin30 mux below.
                        acc_cnt <= acc_cnt + 1'b1;
                    end else if (acc_cnt == RELEASE_DELAY - 1) begin
                        // Phase 2: finish the save cycle, or retain ROMCS for
                        // a DMA EEPROM session until the next bit request.
                        if (eeprom_sess && eeprom_dma_r) begin
                            // Keep /CS LOW and A23 HIGH across consecutive
                            // EEPROM bit accesses (GBATEK requirement for DMA3).
                            cs_n          <= 1'b0;
                            out_bank1     <= 8'h80;
                            out_bank1_dir <= 1'b1;
                        end else begin
                            // Standalone access (or DMA burst finished):
                            // release /CS. For write-complete polling this is
                            // what lets the cart chip update its ready bit.
                            cs_n          <= 1'b1;
                            out_bank1_dir <= 1'b0;
                            eeprom_sess   <= 1'b0;
                        end
                        cs2_n         <= 1'b1;   // release CS2# one cycle later
                        acc_cnt       <= acc_cnt + 1'b1;
                    end else if (acc_cnt < RELEASE_DELAY * 2 - 1) begin
                        // Phase 3: CS# is already high, keep the AD bus
                        // driven for RELEASE_DELAY-1 more cycles so the
                        // cartridge gets a real data hold time after the
                        // CS# rising edge.
                        acc_cnt <= acc_cnt + 1'b1;
                    end else begin
                        // Phase 4: release the data bus and complete.
                        out_bank2_dir <= 1'b0;
                        out_bank3_dir <= 1'b0;
                        save_done     <= access_state == S_SRAM;
                        eeprom_done   <= access_state != S_SRAM;
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
    assign cart_tran_bank1     = (bus_enable && out_bank1_dir) ? out_bank1 : 8'hzz;
    assign cart_tran_bank1_dir = out_bank1_dir;
    assign cart_tran_bank2     = (bus_enable && out_bank2_dir) ? out_bank2 : 8'hzz;
    assign cart_tran_bank2_dir = out_bank2_dir;
    assign cart_tran_bank3     = (bus_enable && out_bank3_dir) ? out_bank3 : 8'hzz;
    assign cart_tran_bank3_dir = out_bank3_dir;

    // PHI is driven continuously by core_top, not by this bus owner.
    assign cart_tran_bank0[6:4] = bus_enable ? {wr_n, rd_n, cs_n} : 3'bzzz;

    // pin30: CS2#/RES# — CS2# active during SRAM/Flash accesses and for one
    // extra cycle in S_DONE (so WR#/RD# rise while CS2# is still low, as real
    // SRAM chips require); during EEPROM transfers pin30 stays at RES#
    // (EEPROM /CS is ROMCS, Pin 5).
    assign cart_tran_pin30        = !bus_enable ? 1'bz : ((state == S_SRAM) ||
                                     ((state == S_DONE) && (acc_cnt < RELEASE_DELAY - 1))) ? cs2_n : res_n;


endmodule

`default_nettype wire
