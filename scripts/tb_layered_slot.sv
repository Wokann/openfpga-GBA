`timescale 1ns/1ps
module tb_layered_slot;
    reg clk=0, clk74=0, reset_n=0, restart=0, cfg=1, motor=0;
    always #5 clk=~clk;
    always #6.734 clk74=~clk74;
    tri [7:0] b1,b2,b3;
    tri [7:4] b0;
    tri pin30, pin31;
    wire d1,d2,d3,d0,d30,d31,power_reset;
    reg save_req=0, save_rnw=1;
    reg [16:0] save_addr=0;
    reg [7:0] save_din=0;
    reg e_req=0,e_rnw=0,e_din=0,e_dma=1;
    slot_fixture dut (
        .clk_sys(clk), .clk_74a(clk74), .pll_core_locked(reset_n),
        .core_reset_s(restart), .reset_n_s(1'b1), .dataslot_allcomplete_s(1'b1),
        .cfg(cfg), .motor(motor), .save_req(save_req), .save_rnw(save_rnw),
        .save_addr(save_addr), .save_din(save_din),
        .e_req(e_req), .e_rnw(e_rnw), .e_din(e_din), .e_dma(e_dma),
        .cart_tran_bank1(b1), .cart_tran_bank2(b2), .cart_tran_bank3(b3),
        .cart_tran_bank0(b0), .cart_tran_pin30(pin30), .cart_tran_pin31(pin31),
        .cart_tran_bank1_dir(d1), .cart_tran_bank2_dir(d2), .cart_tran_bank3_dir(d3),
        .cart_tran_bank0_dir(d0), .cart_tran_pin30_dir(d30), .cart_tran_pin31_dir(d31),
        .cart_pin30_pwroff_reset(power_reset)
    );
    // Model the external side of pin30's level translator. Upstream leaves
    // it disconnected while driving rumble, whereas the save master drives it.
    wire cs2 = dut.cart_slot_owner ? pin30 : 1'b1;
    wire cs=b0[4], rd=b0[5], wr=b0[6];
    reg [23:0] rom_addr;
    reg [15:0] save_latch;
    reg e_active=0,e_bit=0;
    reg [7:0] ram [0:131071];
    reg flash_mode=0, bank=0;
    integer flash_state=0, rumble_writes=0, save_writes=0, rom_reads=0, e_writes=0;
    integer i;
    initial for(i=0;i<131072;i=i+1) ram[i]=8'hFF;
    always @(negedge cs) begin
        if (d2 && d3) rom_addr <= #1 {b1,b2,b3};
        e_active <= (b1[7]===1'b1);
    end
    always @(posedge cs) e_active<=0;
    always @(negedge cs2) if(d2&&d3) save_latch<={b2,b3};
    always @(negedge rd) begin
        if(!cs && e_active) e_bit<=~e_bit;
        else if(!cs && dut.cart_slot_owner) begin
            if(rom_addr<24'h58 || rom_addr>24'h5F) $fatal(1,"non-header ROM read");
            rom_reads=rom_reads+1;
        end
    end
    wire [15:0] rom_word = rom_addr[15:0]^16'hA55A;
    assign b2=(!cs && !rd && !e_active) ? rom_word[15:8] : 8'hzz;
    assign b3=(!cs && e_active && wr && !d3) ? {7'b0,e_bit} :
              (!cs && !rd && !e_active) ? rom_word[7:0] : 8'hzz;
    assign b1=(!cs2 && !rd && cs) ? ram[{bank,save_latch}] : 8'hzz;
    always @(posedge wr) begin
        if(!cs2) begin
            if(!d1 || !d2 || !d3 || !cs) $fatal(1,"save bus direction/select error");
            save_writes=save_writes+1;
            if(!flash_mode) ram[{bank,save_latch}]<=b1;
            else case(flash_state)
                0: if(save_latch==16'h5555 && b1==8'hAA) flash_state=1;
                1: if(save_latch==16'h2AAA && b1==8'h55) flash_state=2;
                2: if(save_latch==16'h5555 && b1==8'hB0) flash_state=3;
                   else if(save_latch==16'h5555 && b1==8'hA0) flash_state=4;
                   else $fatal(1,"Flash command lost");
                3: begin bank<=b1[0]; flash_state=0; end
                4: begin ram[{bank,save_latch}]<=b1; flash_state=0; end
            endcase
        end else if(!cs && e_active) e_writes=e_writes+1;
        else if(!cs && !dut.cart_slot_owner) begin
            if(rom_addr!=24'h62 && rom_addr!=24'h63) $fatal(1,"rumble address changed");
            rumble_writes=rumble_writes+1;
        end
    end
    // A grant must never cut a rumble/save strobe in half.
    reg previous_owner=0;
    always @(posedge clk74) begin
        if(dut.cart_slot_owner!==previous_owner && reset_n) begin
            if(cs!==1'b1 || rd!==1'b1 || wr!==1'b1)
                $fatal(1,"slot changed owner while a bus transaction was active");
        end
        previous_owner<=dut.cart_slot_owner;
    end
    task save_access(input bit reading,input [16:0] addr,input [7:0] value,input [7:0] expected);
        begin
            @(negedge clk); save_addr=addr;save_rnw=reading;save_din=value;save_req=1;
            @(negedge clk);save_req=0;save_din=8'hCC;
            wait(dut.cart_save_done); #1;
            if(reading && dut.cart_save_dout!==expected)
                $fatal(1,"save read %h: got %h expected %h",addr,dut.cart_save_dout,expected);
            @(negedge clk);
        end
    endtask
    task e_access(input bit reading,input bit value,input bit dma);
        begin
            @(negedge clk);e_rnw=reading;e_din=value;e_dma=dma;e_req=1;
            @(negedge clk);e_req=0;
            wait(dut.cart_eeprom_done); #1;
            if(reading && dut.cart_eeprom_dout!==e_bit) $fatal(1,"EEPROM read sampling failed");
            @(negedge clk);
        end
    endtask
    integer before_rumble,before_saves;
    initial begin
        repeat(5) @(negedge clk); reset_n=1;
        wait(dut.cart_probe_done);#1;
        if(!dut.layered_save_mode || rom_reads!=16) $fatal(1,"valid header not detected");
        motor=1;
        // Queue a save request in the middle of the upstream two-write rumble update.
        wait(dut.wr_busy && dut.wr_cnt==65);
        save_access(0,17'h01234,8'h5A,0);
        save_access(1,17'h01234,0,8'h5A);
        // Back-to-back requests exercise deassert/reassert while CDC grant is stale.
        for(i=0;i<20;i=i+1) begin
            save_access(0,i,8'(i^8'hA7),0);
            save_access(1,i,0,8'(i^8'hA7));
        end
        flash_mode=1;
        save_access(0,'h5555,'hAA,0);save_access(0,'h2AAA,'h55,0);
        save_access(0,'h5555,'hB0,0);save_access(0,0,1,0);
        save_access(0,'h5555,'hAA,0);save_access(0,'h2AAA,'h55,0);
        save_access(0,'h5555,'hA0,0);save_access(0,'h3210,'h37,0);
        save_access(1,'h3210,0,'h37);
        save_access(0,'h5555,'hAA,0);save_access(0,'h2AAA,'h55,0);
        save_access(0,'h5555,'hB0,0);save_access(0,0,0,0);
        save_access(1,'h3210,0,'hFF);
        flash_mode=0;
        before_saves=save_writes;
        e_access(0,1,1);
        before_rumble=rumble_writes;
        motor=0; dut.refresh_due=1;
        repeat(8) begin
            e_access(0,0,1);
            if(cs!==0 || !dut.cart_slot_owner) $fatal(1,"EEPROM DMA session lost bus");
            if(rumble_writes!=before_rumble) $fatal(1,"rumble interrupted EEPROM DMA");
        end
        e_access(1,0,1);
        e_access(1,0,1);
        if(save_writes!=before_saves) $fatal(1,"EEPROM touched SRAM/Flash");
        e_access(1,0,0);
        if(cs!==1) $fatal(1,"standalone EEPROM poll did not release CS");
        wait(rumble_writes>before_rumble);
        cfg=0;#1;
        if(dut.layered_save_mode) $fatal(1,"disabled mode not restored");
        @(negedge clk); restart=1;
        repeat(10) @(negedge clk);
        restart=0;
        repeat(5000) @(negedge clk);
        if(rom_reads!=16 || dut.cart_slot_owner)
            $fatal(1,"disabled mode still probed or owned the cartridge bus");
        $display("PASS: header + queued SRAM + Flash bank1 + EEPROM DMA/poll + concurrent upstream rumble");
        $finish;
    end
    initial begin #3000000; $fatal(1,"shared slot test timeout"); end
endmodule
