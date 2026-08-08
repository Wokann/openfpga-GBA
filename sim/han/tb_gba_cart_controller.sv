// tb_gba_cart_controller.sv
//
// Behavioral cartridge model + test bench covering:
//   ROM reads, SRAM/Flash byte R/W, EEPROM bit forward, GPIO R/W.

`timescale 1ns / 1ps

module cart_rom_model (
    inout  wire [7:0] bank2,
    inout  wire [7:0] bank3,
    inout  wire [7:0] bank1,
    inout  wire [3:0] bank0,
    inout  wire       pin30
);
    wire rd_n = bank0[1];
    wire cs_n = bank0[0];
    wire wr_n = bank0[2];
    wire cs2_n = pin30;

    // Address latch while host drives AD (CS1# low, RD#/WR# high)
    reg [23:0] addr_latch;
    always @(*) begin
        if (rd_n && wr_n && !cs_n)
            addr_latch = {bank1, bank2, bank3};
    end
    wire [15:0] rom_dout = addr_latch[15:0] ^ 16'hA55A;

    // SRAM (save region via CS2#): latch address on CS2# falling edge
    reg [7:0] sram_mem [0:65535];
    reg [15:0] sram_addr_latch;
    always @(negedge cs2_n) begin
        sram_addr_latch <= {bank2, bank3};
    end
    integer i;
    initial begin
        for (i = 0; i < 65536; i = i + 1)
            sram_mem[i] = i[7:0] ^ 8'hA5;
    end
    always @(posedge wr_n) begin
        if (!cs2_n)
            sram_mem[sram_addr_latch] <= bank3;
    end
    wire [7:0] sram_dout = sram_mem[sram_addr_latch];

    // GPIO (16-bit access at 0x080000C4.., data in D3..D0)
    reg [3:0] gpio_reg [0:2];
    initial begin gpio_reg[0] = 4'h5; gpio_reg[1] = 4'h9; gpio_reg[2] = 4'h3; end
    reg [23:0] gpio_addr_latch;
    always @(negedge cs_n) begin
        if (bank1 == 8'h08)
            gpio_addr_latch <= {bank1, bank2, bank3};
    end
    wire [1:0] gpio_idx = (gpio_addr_latch[7:0] - 8'hC4) >> 1;
    always @(posedge wr_n) begin
        if (!cs_n && gpio_addr_latch[23:16] == 8'h08 && gpio_idx <= 2'd2)
            gpio_reg[gpio_idx] <= bank3[3:0];
    end

    // Bus drive priority: GPIO / SRAM / ROM depending on active select
    reg [7:0] bank3_drv;
    reg       bank3_en;
    always @(*) begin
        if (!rd_n && !cs_n && gpio_addr_latch[23:16] == 8'h08) begin
            bank3_drv = {4'b0, gpio_reg[gpio_idx]};
            bank3_en  = 1'b1;
        end else if (!rd_n && !cs2_n && cs_n) begin
            bank3_drv = sram_dout;
            bank3_en  = 1'b1;
        end else if (!rd_n && !cs_n) begin
            bank3_drv = rom_dout[7:0];
            bank3_en  = 1'b1;
        end else begin
            bank3_drv = 8'hzz;
            bank3_en  = 1'b0;
        end
    end
    assign bank3 = bank3_en ? bank3_drv : 8'hzz;
    assign bank1 = 8'hzz;
    assign bank2 = (!rd_n && !cs_n) ? rom_dout[15:8] : 8'hzz;
endmodule


module tb_gba_cart_controller;
    reg        clk = 0;
    reg        reset_n = 0;

    wire [7:0] cart_tran_bank2, cart_tran_bank3, cart_tran_bank1;
    wire       cart_tran_bank2_dir, cart_tran_bank3_dir, cart_tran_bank1_dir;
    wire [3:0] cart_tran_bank0;
    wire       cart_tran_bank0_dir;
    wire       cart_tran_pin30;
    wire       cart_tran_pin30_dir;
    wire       cart_pin30_pwroff_reset;
    wire       cart_tran_pin31;
    wire       cart_tran_pin31_dir;

    reg        rd_req = 0;
    reg  [24:0] rd_addr = 0;
    wire [31:0] rd_data;
    wire [31:0] rd_data_second;
    wire        rd_ready;

    reg        save_req = 0;
    reg  [16:0] save_addr = 0;
    reg        save_rnw = 1;
    reg  [7:0]  save_din = 0;
    wire [7:0]  save_dout;
    wire        save_done;
    reg  [1:0]  save_type = 0;

    reg        gpio_req = 0;
    reg        gpio_rnw = 1;
    reg  [1:0] gpio_addr = 0;
    reg  [3:0] gpio_din = 0;
    wire [3:0] gpio_dout;
    wire       gpio_done;

    wire        cart_present;
    wire [7:0]  err_count;

    gba_cart_controller dut (
        .clk                    (clk),
        .reset_n                (reset_n),
        .cart_tran_bank2        (cart_tran_bank2),
        .cart_tran_bank2_dir    (cart_tran_bank2_dir),
        .cart_tran_bank3        (cart_tran_bank3),
        .cart_tran_bank3_dir    (cart_tran_bank3_dir),
        .cart_tran_bank1        (cart_tran_bank1),
        .cart_tran_bank1_dir    (cart_tran_bank1_dir),
        .cart_tran_bank0        (cart_tran_bank0),
        .cart_tran_bank0_dir    (cart_tran_bank0_dir),
        .cart_tran_pin30        (cart_tran_pin30),
        .cart_tran_pin30_dir    (cart_tran_pin30_dir),
        .cart_pin30_pwroff_reset(cart_pin30_pwroff_reset),
        .cart_tran_pin31        (cart_tran_pin31),
        .cart_tran_pin31_dir    (cart_tran_pin31_dir),
        .rd_req                 (rd_req),
        .rd_addr                (rd_addr),
        .rd_data                (rd_data),
        .rd_data_second         (rd_data_second),
        .rd_ready               (rd_ready),
        .save_req               (save_req),
        .save_addr              (save_addr),
        .save_rnw               (save_rnw),
        .save_din               (save_din),
        .save_dout              (save_dout),
        .save_done              (save_done),
        .save_type              (save_type),
        .gpio_req               (gpio_req),
        .gpio_rnw               (gpio_rnw),
        .gpio_addr              (gpio_addr),
        .gpio_din               (gpio_din),
        .gpio_dout              (gpio_dout),
        .gpio_done              (gpio_done),
        .cart_present           (cart_present),
        .err_count              (err_count)
    );

    cart_rom_model cart (
        .bank2 (cart_tran_bank2),
        .bank3 (cart_tran_bank3),
        .bank1 (cart_tran_bank1),
        .bank0 (cart_tran_bank0),
        .pin30 (cart_tran_pin30)
    );

    always #5 clk = ~clk;   // 100 MHz

    integer errors = 0;

    task pulse_req;
        input req_bit;
        begin
            @(posedge clk);
            if (req_bit) rd_req <= 1; else save_req <= 1;
            @(posedge clk);
            rd_req <= 0; save_req <= 0;
        end
    endtask

    initial begin
        repeat (10) @(posedge clk);
        reset_n <= 1;
        repeat (4200) @(posedge clk);

        // ---- ROM read regression (byte 0) ----
        @(posedge clk);
        rd_req <= 1; rd_addr <= 25'd0;
        @(posedge clk);
        rd_req <= 0;
        wait (rd_ready);
        @(posedge clk);
        if (rd_data !== 32'hA55B_A55A || rd_data_second !== 32'hA559_A558) begin
            $display("FAIL: ROM read");
            errors = errors + 1;
        end

        // ---- SRAM write + read-back ----
        save_type = 0;
        @(posedge clk);
        save_req <= 1; save_addr <= 17'h1234; save_rnw <= 0; save_din <= 8'hAB;
        @(posedge clk);
        save_req <= 0;
        wait (save_done);
        @(posedge clk);

        @(posedge clk);
        save_req <= 1; save_addr <= 17'h1234; save_rnw <= 1;
        @(posedge clk);
        save_req <= 0;
        wait (save_done);
        @(posedge clk);
        if (save_dout !== 8'hAB) begin
            $display("FAIL: SRAM read-back got %02h expected AB", save_dout);
            errors = errors + 1;
        end

        // ---- GPIO read ----
        @(posedge clk);
        gpio_req <= 1; gpio_rnw <= 1; gpio_addr <= 2'd1;
        @(posedge clk);
        gpio_req <= 0;
        wait (gpio_done);
        @(posedge clk);
        if (gpio_dout !== 4'h9) begin
            $display("FAIL: GPIO read got %h expected 9", gpio_dout);
            errors = errors + 1;
        end

        // ---- GPIO write + read-back ----
        @(posedge clk);
        gpio_req <= 1; gpio_rnw <= 0; gpio_addr <= 2'd2; gpio_din <= 4'h7;
        @(posedge clk);
        gpio_req <= 0;
        wait (gpio_done);
        @(posedge clk);
        @(posedge clk);
        gpio_req <= 1; gpio_rnw <= 1; gpio_addr <= 2'd2;
        @(posedge clk);
        gpio_req <= 0;
        wait (gpio_done);
        @(posedge clk);
        if (gpio_dout !== 4'h7) begin
            $display("FAIL: GPIO write read-back got %h expected 7", gpio_dout);
            errors = errors + 1;
        end

        // ---- EEPROM write bit forward (must complete without hang) ----
        save_type = 2;
        @(posedge clk);
        save_req <= 1; save_addr <= 17'h0; save_rnw <= 0; save_din <= 8'h01;
        @(posedge clk);
        save_req <= 0;
        wait (save_done);
        @(posedge clk);

        if (errors == 0)
            $display("PASS: all checks passed");
        else
            $display("FAIL: %0d check(s) failed", errors);
        $finish;
    end
endmodule
