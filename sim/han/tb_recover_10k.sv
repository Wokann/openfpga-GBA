`timescale 1ns/1ps
// Regression check for the real 100us recovery: with GPIO_RECOVER=10000
// and the 14-bit acc_cnt the controller must return to S_IDLE between
// accesses (an 8-bit acc_cnt silently wrapped and either hung or shortened
// the recovery). Runtime override register (gpio_recover_set) is tied to 0
// so the parameter is used.
module tb_recover_10k;
  logic clk = 0;
  logic reset_n = 0;
  always #5 clk = ~clk;  // 100MHz

  logic        gpio_req = 0;
  logic        gpio_rnw = 0;
  logic [1:0]  gpio_addr = 0;
  logic [3:0]  gpio_din = 0;
  logic [3:0]  gpio_dout;
  logic        gpio_done;
  logic [2:0]  gpio_timing_mode = 0;
  logic [13:0] gpio_recover_set = 0;
  logic [7:0]  gpio_diag;

  logic [24:0] rd_addr = 0;
  logic        rd_req = 0;
  logic [31:0] rd_data, rd_data_second;
  logic        rd_ready;
  logic        save_req = 0;
  logic [16:0] save_addr = 0;
  logic        save_rnw = 1;
  logic [7:0]  save_din = 0;
  logic [7:0]  save_dout;
  logic        save_done;
  logic        eeprom_req = 0;
  logic        eeprom_rnw = 1;
  logic        eeprom_din = 0;
  logic        eeprom_dma = 1;
  logic        eeprom_dout;
  logic        eeprom_done;
  logic [1:0]  phi_sel = 0;
  logic [7:0]  cart_tran_bank0, cart_tran_bank1, cart_tran_bank2, cart_tran_bank3;
  logic        cart_tran_bank0_dir, cart_tran_bank1_dir, cart_tran_bank2_dir, cart_tran_bank3_dir;
  logic        cart_tran_pin30, cart_tran_pin30_dir;
  logic        cart_pin30_pwroff_reset;
  logic        cart_tran_pin31, cart_tran_pin31_dir;
  logic        cart_present, cart_write_protect;
  logic [7:0]  err_count;

  gba_cart_controller #(
    .GPIO_RECOVER(10000)
  ) dut (
    .clk(clk), .reset_n(reset_n),
    .phi_sel(phi_sel),
    .cart_tran_bank0(cart_tran_bank0), .cart_tran_bank0_dir(cart_tran_bank0_dir),
    .cart_tran_bank1(cart_tran_bank1), .cart_tran_bank1_dir(cart_tran_bank1_dir),
    .cart_tran_bank2(cart_tran_bank2), .cart_tran_bank2_dir(cart_tran_bank2_dir),
    .cart_tran_bank3(cart_tran_bank3), .cart_tran_bank3_dir(cart_tran_bank3_dir),
    .cart_tran_pin30(cart_tran_pin30), .cart_tran_pin30_dir(cart_tran_pin30_dir),
    .cart_pin30_pwroff_reset(cart_pin30_pwroff_reset),
    .cart_tran_pin31(cart_tran_pin31), .cart_tran_pin31_dir(cart_tran_pin31_dir),
    .rd_req(rd_req), .rd_addr(rd_addr), .rd_data(rd_data),
    .rd_data_second(rd_data_second), .rd_ready(rd_ready),
    .save_req(save_req), .save_addr(save_addr), .save_rnw(save_rnw),
    .save_din(save_din), .save_dout(save_dout), .save_done(save_done),
    .eeprom_req(eeprom_req), .eeprom_rnw(eeprom_rnw), .eeprom_din(eeprom_din),
    .eeprom_dma(eeprom_dma), .eeprom_dout(eeprom_dout), .eeprom_done(eeprom_done),
    .gpio_req(gpio_req), .gpio_rnw(gpio_rnw), .gpio_addr(gpio_addr),
    .gpio_din(gpio_din), .gpio_dout(gpio_dout), .gpio_done(gpio_done),
    .gpio_timing_mode(gpio_timing_mode), .gpio_recover_set(gpio_recover_set),
    .gpio_diag(gpio_diag),
    .cart_present(cart_present), .err_count(err_count)
  );

  int writes = 0;
  int cycles_between = 0;
  int prev_done_cycle = 0;
  int cur_cycle = 0;

  always @(posedge clk) begin
    cur_cycle++;
    if (gpio_done) begin
      if (writes > 0) cycles_between = cur_cycle - prev_done_cycle;
      prev_done_cycle = cur_cycle;
      writes++;
    end
  end

  task issue_write(logic [3:0] val);
    begin
      @(posedge clk);
      gpio_req = 1; gpio_rnw = 0; gpio_addr = 0; gpio_din = val;
      @(posedge clk);
      while (!gpio_done) @(posedge clk);
      gpio_req = 0;
      @(posedge clk);
    end
  endtask

  initial begin
    #20 reset_n = 1;
    #10;
    issue_write(4'h5);
    issue_write(4'h7);
    issue_write(4'hF);
    #50;
    $display("PASS: GPIO writes=%0d, cycles between done pulses=%0d (expect > 10000)", writes, cycles_between);
    if (writes != 3 || cycles_between < 10000) begin
      $display("FAIL: unexpected counts");
      $finish(1);
    end
    $finish(0);
  end
endmodule
