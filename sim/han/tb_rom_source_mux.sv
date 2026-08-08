// tb_rom_source_mux.sv
//
// Verifies pass-through (cart_mode=0) and cartridge routing (cart_mode=1).

`timescale 1ns / 1ps

module tb_rom_source_mux;
    reg         clk = 0;
    reg         cart_mode = 0;

    reg         gba_rd_req = 0;
    reg  [24:0] gba_rd_addr = 0;
    wire        gba_rd_ready;
    wire [31:0] gba_rd_data;
    wire [31:0] gba_rd_data_second;

    wire        sdram_rd_req;
    wire [24:0] sdram_rd_addr;
    reg         sdram_rd_ready = 0;
    reg  [31:0] sdram_rd_data = 0;
    reg  [31:0] sdram_rd_data_second = 0;

    wire        cart_rd_req;
    wire [24:0] cart_rd_addr;
    reg         cart_rd_ready = 0;
    reg  [31:0] cart_rd_data = 0;
    reg  [31:0] cart_rd_data_second = 0;

    rom_source_mux dut (
        .clk                (clk),
        .cart_mode          (cart_mode),
        .gba_rd_req         (gba_rd_req),
        .gba_rd_addr        (gba_rd_addr),
        .gba_rd_ready       (gba_rd_ready),
        .gba_rd_data        (gba_rd_data),
        .gba_rd_data_second (gba_rd_data_second),
        .sdram_rd_req       (sdram_rd_req),
        .sdram_rd_addr      (sdram_rd_addr),
        .sdram_rd_ready     (sdram_rd_ready),
        .sdram_rd_data      (sdram_rd_data),
        .sdram_rd_data_second(sdram_rd_data_second),
        .cart_rd_req        (cart_rd_req),
        .cart_rd_addr       (cart_rd_addr),
        .cart_rd_ready      (cart_rd_ready),
        .cart_rd_data       (cart_rd_data),
        .cart_rd_data_second(cart_rd_data_second)
    );

    always #5 clk = ~clk;

    integer errors = 0;

    initial begin
        // SD mode: request forwarded to SDRAM only, SDRAM response returned
        cart_mode = 0;
        @(posedge clk);
        gba_rd_req  = 1;
        gba_rd_addr = 25'h12345;
        @(posedge clk);
        gba_rd_req = 0;
        if (!sdram_rd_req || cart_rd_req || sdram_rd_addr !== 25'h12345) begin
            $display("FAIL: SD mode request routing");
            errors = errors + 1;
        end
        sdram_rd_ready = 1;
        sdram_rd_data  = 32'hDEAD_BEEF;
        sdram_rd_data_second = 32'hCAFE_F00D;
        @(posedge clk);
        if (gba_rd_data !== 32'hDEAD_BEEF || gba_rd_data_second !== 32'hCAFE_F00D || !gba_rd_ready) begin
            $display("FAIL: SD mode response");
            errors = errors + 1;
        end
        sdram_rd_ready = 0;

        // Cart mode: request forwarded to cartridge only, cart response returned
        cart_mode = 1;
        @(posedge clk);
        gba_rd_req  = 1;
        gba_rd_addr = 25'h2AAAA;
        @(posedge clk);
        gba_rd_req = 0;
        if (!cart_rd_req || sdram_rd_req || cart_rd_addr !== 25'h2AAAA) begin
            $display("FAIL: cart mode request routing");
            errors = errors + 1;
        end
        cart_rd_ready = 1;
        cart_rd_data  = 32'h1357_9BDF;
        cart_rd_data_second = 32'h0246_8ACE;
        @(posedge clk);
        if (gba_rd_data !== 32'h1357_9BDF || gba_rd_data_second !== 32'h0246_8ACE || !gba_rd_ready) begin
            $display("FAIL: cart mode response");
            errors = errors + 1;
        end
        cart_rd_ready = 0;

        if (errors == 0)
            $display("PASS: rom_source_mux all checks passed");
        else
            $display("FAIL: %0d check(s) failed", errors);
        $finish;
    end
endmodule
