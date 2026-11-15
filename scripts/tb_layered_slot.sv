`timescale 1ns/1ps
module tb_layered_slot;
    reg clk=0, clk74=0, reset_n=0, restart=0, cfg=1, hw_cfg=0, motor=0;
    reg tilt_game=0,phi_source=0;
    reg switch_idle=1;
    always #5 clk=~clk;
    always #6.734 clk74=~clk74;
    always #120 phi_source=~phi_source;
    tri [7:0] b1,b2,b3;
    tri [7:4] b0;
    tri pin30, pin31;
    wire d1,d2,d3,d0,d30,d31,power_reset;
    reg save_req=0, save_rnw=1;
    reg [16:0] save_addr=0;
    reg [7:0] save_din=0;
    reg e_req=0,e_rnw=0,e_din=0,e_dma=1;
    reg g_req=0,g_rnw=0;
    reg [1:0] g_addr=0;
    reg [15:0] g_din=0;
    slot_fixture dut (
        .clk_sys(clk), .clk_74a(clk74), .pll_core_locked(reset_n),
        .core_reset_s(restart), .reset_n_s(1'b1), .dataslot_allcomplete_s(1'b1),
        .cfg(cfg), .hw_cfg(hw_cfg), .motor(motor), .save_req(save_req), .save_rnw(save_rnw),
        .tilt_game(tilt_game), .phi_source(phi_source), .switch_idle(switch_idle),
        .save_addr(save_addr), .save_din(save_din),
        .e_req(e_req), .e_rnw(e_rnw), .e_din(e_din), .e_dma(e_dma),
        .g_req(g_req), .g_rnw(g_rnw), .g_addr(g_addr), .g_din(g_din),
        .cart_tran_bank1(b1), .cart_tran_bank2(b2), .cart_tran_bank3(b3),
        .cart_tran_bank0(b0), .cart_tran_pin30(pin30), .cart_tran_pin31(pin31),
        .cart_tran_bank1_dir(d1), .cart_tran_bank2_dir(d2), .cart_tran_bank3_dir(d3),
        .cart_tran_bank0_dir(d0), .cart_tran_pin30_dir(d30), .cart_tran_pin31_dir(d31),
        .cart_pin30_pwroff_reset(power_reset)
    );
    // Model the external side of pin30's level translator. Upstream leaves
    // it disconnected while driving rumble, whereas the save master drives it.
    wire cs2 = d30 === 1'b1 ? pin30 : 1'b1;
    wire cs=b0[4], rd=b0[5], wr=b0[6];
    reg [23:0] rom_addr;
    reg [15:0] save_latch;
    reg e_active=0,e_bit=0;
    reg [7:0] ram [0:131071];
    reg flash_mode=0, bank=0;
    integer flash_state=0, rumble_writes=0, save_writes=0, rom_reads=0, e_writes=0;
    reg header_present=1;
    reg ds_card=0;
    reg [15:0] ds_pullup_mask=0;
    reg [15:0] ds_read_clear=0;
    reg ds_latched_ad1=0;
    integer ds_ticks=0, ds_pulses=0;
    reg [3:0] gpio_data=0,gpio_dir=0,gpio_input=0;
    reg gpio_enable=1; // warm cartridge: initialization must turn this off
    integer gpio_writes=0,gpio_reads=0;
    reg rtc_mode=0;
    reg [7:0] rtc_command=0;
    localparam [7:0] RTC_RESPONSE=8'hA6;
    integer rtc_command_bits=0,rtc_bit=0;
    wire [3:0] gpio_pins = (gpio_data & gpio_dir) |
        ((rtc_mode ? {2'b00,RTC_RESPONSE[rtc_bit],1'b0} : gpio_input) & ~gpio_dir);
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
            if(rom_addr>=24'h62 && rom_addr<=24'h64) begin
                if(d2 || d3 || !cs2) $fatal(1,"GPIO read direction/CS2 error");
                gpio_reads=gpio_reads+1;
            end else begin
                if(rom_addr<24'h58 || rom_addr>24'h5F) $fatal(1,"non-header ROM read");
                rom_reads=rom_reads+1;
            end
        end
    end
    wire [15:0] rom_word = ds_card ? (((rom_addr[15:0] & 16'hFFFD) | ds_pullup_mask) & ~ds_read_clear) :
        (rom_addr==24'h62 && gpio_enable) ? {12'd0,gpio_pins} :
        (rom_addr==24'h63 && gpio_enable) ? {12'd0,gpio_dir} :
        (rom_addr==24'h64 && gpio_enable) ? 16'h0001 :
        header_present ? (rom_addr[15:0]^16'hA55A) : 16'hFFFF;
    assign b2=(!cs && !rd && !e_active) ? rom_word[15:8] : 8'hzz;
    assign b3=(!cs && e_active && wr && !d3) ? {7'b0,e_bit} :
              (!cs && !rd && !e_active) ? rom_word[7:0] : 8'hzz;
    assign b1=(!cs2 && !rd && cs) ? ram[{bank,save_latch}] : 8'hzz;
    always @(posedge wr) begin
        if(dut.wr_busy && dut.wr_ds_only && !dut.cart_slot_owner) begin
            if(cs!==1'b1 || cs2!==1'b1 || rd!==1'b1 || !d3 || d30!==1'b1)
                $fatal(1,"DS pulse selected GBA ROM/save or did not drive /CS2 high");
            ds_pulses=ds_pulses+1;
        end
        // The DS actuator observes AD1 on /WR rising, irrespective of /CS.
        // Count actual external pin transitions, not just internal motor state.
        if(ds_card && d3) begin
            if(b3[1] !== 1'b0 && b3[1] !== 1'b1) $fatal(1,"DS AD1 is undriven on /WR rise");
            if(b3[1] != ds_latched_ad1) ds_ticks=ds_ticks+1;
            ds_latched_ad1=b3[1];
        end
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
        else if(!cs && dut.cart_slot_owner) begin
            if(!d1 || !d2 || !d3 || !cs2) $fatal(1,"GPIO write direction/CS2 error");
            gpio_writes=gpio_writes+1;
            if(!ds_card) case(rom_addr)
                24'h62: begin
                    if(rtc_mode) begin
                        if(!b3[2] || !gpio_data[2]) begin
                            rtc_command_bits=0;rtc_command=0;rtc_bit=0;
                        end else if(!gpio_data[0] && b3[0] && gpio_dir[1]) begin
                            if(rtc_command_bits>=8) $fatal(1,"unexpected RTC command clock");
                            rtc_command[rtc_command_bits]=b3[1];
                            rtc_command_bits=rtc_command_bits+1;
                        end else if(gpio_data[0] && !b3[0] && !gpio_dir[1]) begin
                            rtc_bit=(rtc_bit+1)%8;
                        end
                    end
                    gpio_data=b3[3:0];
                end
                24'h63: gpio_dir=b3[3:0];
                24'h64: gpio_enable=b3[0];
                default: $fatal(1,"GPIO wrote outside C4/C6/C8");
            endcase
        end
        else if(!cs && !dut.cart_slot_owner) begin
            if(rom_addr!=24'h62 && rom_addr!=24'h63) $fatal(1,"rumble address changed");
            rumble_writes=rumble_writes+1;
        end
    end
    // A grant must never cut a rumble/save strobe in half.
    reg previous_owner=0;
    always @(negedge clk) begin
        #1;
        if(reset_n && b0[7] !== (dut.cart_hw_mode ? phi_source : 1'b0))
            $fatal(1,"PHI interrupted by bus ownership");
    end
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
    task gpio_access(input bit reading,input [1:0] addr,input [15:0] value,input [15:0] expected);
        begin
            @(negedge clk);g_addr=addr;g_rnw=reading;g_din=value;g_req=1;
            @(negedge clk);g_req=0;g_din=16'hDEAD;g_addr=3;g_rnw=~reading;
            wait(dut.cart_gpio_done);#1;
            if(reading && dut.cart_gpio_dout!==expected)
                $fatal(1,"GPIO %d: got %h expected %h",addr,dut.cart_gpio_dout,expected);
            if(dut.cart_hw_mode && (!cs || !rd || !wr)) $fatal(1,"GPIO completed before physical strobes ended");
            @(negedge clk);
        end
    endtask
    integer before_rumble,before_rumble_writes,before_saves,before_gpio,before_ticks,j;
    reg [7:0] command;
    reg [3:0] expected_pins;
    initial begin
        repeat(5) @(negedge clk); reset_n=1;
        wait(dut.cart_boot_done);#1;
        if(!dut.layered_save_mode || rom_reads!=16) $fatal(1,"valid header not detected");
        wait(dut.cart_gpio_initialized);#1;
        if(gpio_enable || dut.cart_gpio_readable || gpio_writes!=1 || rumble_writes!=0)
            $fatal(1,"GPIO startup or rumble inhibition failed");
        motor=1;
        // Raw GPIO and save traffic share the same owner. Synthetic rumble
        // must remain silent even while the controller has released the slot.
        gpio_access(0,2,1,0);
        if(!dut.cart_gpio_readable) $fatal(1,"acknowledged C8 enable not tracked");
        gpio_access(1,2,0,1);
        for(j=0;j<16;j=j+1) begin
            gpio_access(0,1,j,0);
            gpio_access(1,1,0,j);
            gpio_input=4'(j^5);
            gpio_access(0,0,4'(j^10),0);
            expected_pins=(4'(j^10)&4'(j)) | (gpio_input&~4'(j));
            gpio_access(1,0,0,{12'd0,expected_pins});
        end
        // A real RTC-style serial command and response, with a save access
        // and a forced refresh between clock edges. No FPGA RTC emulation.
        rtc_mode=1;command=8'h63;
        gpio_access(0,1,15,0);
        gpio_access(0,0,9,0);
        gpio_access(0,0,13,0);
        for(j=0;j<8;j=j+1) begin
            gpio_access(0,0,12|(command[j]<<1),0);
            gpio_access(0,0,13|(command[j]<<1),0);
        end
        gpio_access(0,0,12,0);
        if(rtc_command!==command || rtc_command_bits!=8) $fatal(1,"RTC command corrupted");
        gpio_access(0,1,13,0);
        for(j=0;j<8;j=j+1) begin
            gpio_access(0,0,13,0);
            if(j==3) begin
                dut.refresh_due=1;
                save_access(0,17'h42,8'h99,0);
                before_rumble=ds_pulses;before_gpio=gpio_writes;
                repeat(210000) @(negedge clk74);
                if(ds_pulses<=before_rumble || gpio_writes!=before_gpio || gpio_data!=13 || gpio_dir!=13)
                    $fatal(1,"DS tick did not coexist with a paused RTC serial transfer");
            end
            gpio_access(1,0,0,13|(RTC_RESPONSE[j]<<1));
            gpio_access(0,0,12,0);
        end
        gpio_access(0,0,0,0);rtc_mode=0;
        // GPIO3 rumble is just another data bit; saving must preserve it.
        gpio_access(0,1,15,0);gpio_access(0,0,13,0);
        before_gpio=gpio_writes;
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
        // Cross a real 14.1 ms refresh interval while GPIO is idle.
        repeat(1100000) @(negedge clk74);
        if(rumble_writes!=0 || gpio_writes!=before_gpio || gpio_data!=13 || gpio_dir!=15 || save_writes!=before_saves)
            $fatal(1,"idle/save/EEPROM traffic corrupted GPIO state");
        if(ds_pulses==0) $fatal(1,"raw GPIO3 output did not also drive unselected DS pulses");
        gpio_access(0,2,0,0);
        if(dut.cart_gpio_readable) $fatal(1,"C8 disable not acknowledged");
        // With cartridge saves enabled, hardware is forced on despite hw_cfg=0.
        if(!dut.cart_hw_mode) $fatal(1,"cartridge saves did not force hardware");
        // SD saves plus real GPIO: probing and raw GPIO must stay available.
        cfg=0;hw_cfg=1;
        @(negedge clk);restart=1;
        repeat(20) @(negedge clk);restart=0;
        wait(dut.cart_gpio_initialized);#1;
        if(dut.layered_save_mode || !dut.cart_hw_mode) $fatal(1,"SD saves/GPIO selection coupled");
        gpio_access(0,2,1,0);gpio_access(0,1,15,0);gpio_access(0,0,9,0);
        gpio_access(1,0,0,9);
        // Physical sensor bytes work with SD saves. Other save bytes must
        // never reach the cartridge, including adjacent SRAM addresses.
        tilt_game=1;
        save_access(0,'h8000,'h55,0);save_access(0,'h8100,'hAA,0);
        ram['h8200]=8'h42;
        save_access(1,'h8200,0,'h42);
        before_saves=save_writes;
        @(negedge clk);save_addr='h8201;save_req=1;save_rnw=0;save_din='h5A;
        @(negedge clk);save_req=0;
        repeat(200) @(negedge clk);
        if(save_writes!=before_saves) $fatal(1,"SD SRAM byte redirected into sensor bus");
        tilt_game=0;
        @(negedge clk);save_addr='h8000;save_req=1;
        @(negedge clk);save_req=0;
        repeat(200) @(negedge clk);
        if(save_writes!=before_saves) $fatal(1,"ordinary SRAM game treated as tilt game");
        hw_cfg=0;repeat(5) @(negedge clk);
        if(dut.layered_save_mode) $fatal(1,"disabled mode not restored");
        @(negedge clk); restart=1;
        repeat(10) @(negedge clk);
        restart=0;
        repeat(5000) @(negedge clk);
        dut.refresh_due=1;
        wait(dut.wr_busy && dut.wr_cnt==65);
        if(rom_reads!=32 || dut.cart_slot_owner)
            $fatal(1,"disabled mode still probed or owned the cartridge bus");
        // Probe failure must also restore the unchanged upstream rumble driver.
        header_present=0;cfg=0;hw_cfg=1;restart=1;
        repeat(20) @(negedge clk);restart=0;
        wait(dut.cart_probe_done);#1;
        if(dut.layered_save_mode || dut.cart_gpio_initialized) $fatal(1,"empty cart did not fall back");
        before_rumble=rumble_writes;motor=1;dut.refresh_due=1;
        wait(rumble_writes>before_rumble);
        // Live off/on reprobes a DS option pak without any game reset.
        motor=0;hw_cfg=0;
        repeat(20) @(negedge clk);
        wait(!dut.cart_switch_hold);
        if(!dut.cart_boot_done || dut.cart_hw_mode) $fatal(1,"live off reset the game");
        ds_card=1;ds_pullup_mask=16'hFFF9;hw_cfg=1;
        repeat(20) @(negedge clk);
        wait(!dut.cart_switch_hold);
        if(!dut.cart_ds_mode || dut.cart_hw_mode || dut.layered_save_mode)
            $fatal(1,"DS pak routed as GBA saves/GPIO");
        before_gpio=gpio_writes;
        gpio_access(0,2,1,0);
        gpio_access(0,0,8,0); // Input pin: does not turn on the upstream motor latch.
        gpio_access(0,1,8,0);
        repeat(100) @(negedge clk);
        if(dut.hw_rumble) $fatal(1,"direction write revived an ignored input-mode motor write");
        gpio_access(0,0,8,0);
        gpio_access(1,1,0,8);gpio_access(1,0,0,8);
        before_rumble=ds_pulses;
        wait(ds_pulses>before_rumble);
        if(!dut.cart_rumble || gpio_writes!=before_gpio || b0[7]!==0)
            $fatal(1,"DS motor depended on local GPIO or used physical GPIO/PHI");
        before_ticks=ds_ticks;
        repeat(400000) @(negedge clk74);
        if(ds_ticks < before_ticks+2) $fatal(1,"DS motor-on did not produce periodic physical AD1 ticks");
        gpio_access(0,0,0,0);wait(!dut.cart_rumble_74);
        wait(!dut.wr_busy);
        before_ticks=ds_ticks;
        repeat(210000) @(negedge clk74);
        if(ds_ticks!=before_ticks) $fatal(1,"DS motor-off kept ticking");
        // Raw GPIO is still a working DS rumble source when the bus signature
        // is unrecognized. It must not need either cart_ds_mode or local Force.
        hw_cfg=0;repeat(20) @(negedge clk);wait(!dut.cart_switch_hold);
        ds_read_clear=16'h0008;hw_cfg=1;
        repeat(20) @(negedge clk);wait(!dut.cart_switch_hold);
        if(!dut.cart_hw_mode || dut.cart_ds_mode || motor)
            $fatal(1,"unrecognized DS response did not exercise raw GPIO route");
        gpio_access(0,2,1,0);gpio_access(0,1,8,0);gpio_access(0,0,8,0);
        before_ticks=ds_ticks;before_gpio=gpio_writes;before_rumble_writes=rumble_writes;
        repeat(400000) @(negedge clk74);
        if(ds_ticks<before_ticks+2 || gpio_writes!=before_gpio || rumble_writes!=before_rumble_writes)
            $fatal(1,"raw-route DS rumble needed identification or injected GBA writes");
        gpio_access(0,1,0,0);wait(!dut.cart_rumble_74);wait(!dut.wr_busy);
        before_ticks=ds_ticks;
        repeat(210000) @(negedge clk74);
        if(ds_ticks!=before_ticks) $fatal(1,"direction input did not stop raw-route DS rumble");
        ds_read_clear=0;
        // Do not cut an upstream rumble pulse when switching off.
        gpio_access(0,1,8,0);gpio_access(0,0,8,0);
        wait(dut.wr_busy && dut.wr_cnt==65);hw_cfg=0;
        repeat(20) @(negedge clk);wait(!dut.cart_switch_hold);
        if(dut.cart_ds_mode || !dut.cart_boot_done) $fatal(1,"DS live disable failed");
        // Delay acknowledgement to represent a busy CPU/DMA memory access.
        ds_card=0;header_present=1;switch_idle=0;j=rom_reads;hw_cfg=1;
        repeat(200) @(negedge clk);
        if(!dut.cart_switch_hold || rom_reads!=j || !dut.cart_boot_done)
            $fatal(1,"reprobe did not wait for the memory request");
        switch_idle=1;wait(dut.cart_hw_mode && !dut.cart_switch_hold);
        if(dut.cart_ds_mode || dut.layered_save_mode) $fatal(1,"live GBA route failed");
        // A pending physical GPIO write must complete on the old route.
        @(negedge clk);g_addr=0;g_din=8;g_rnw=0;g_req=1;switch_idle=0;
        @(negedge clk);g_req=0;hw_cfg=0;
        wait(dut.cart_gpio_done);#1;
        if(!dut.cart_hw_mode || gpio_data!=8) $fatal(1,"live toggle lost GPIO write");
        switch_idle=1;wait(!dut.cart_switch_hold);
        if(dut.cart_hw_mode || !dut.cart_boot_done) $fatal(1,"live GPIO disable reset game");
        // A second menu change during probing is applied after draining it.
        ds_card=1;hw_cfg=1;
        wait(dut.cart_route_state==dut.CART_PROBE);hw_cfg=0;
        repeat(20) @(negedge clk);wait(!dut.cart_switch_hold);
        if(dut.cart_hw_mode || dut.cart_ds_mode || !dut.cart_boot_done)
            $fatal(1,"toggle during probe left the wrong active route");
        // Saves force hardware on, but a DS pak must never receive save traffic.
        cfg=1;restart=1;
        repeat(20) @(negedge clk);restart=0;
        wait(dut.cart_boot_done);#1;
        if(!dut.cart_ds_mode || dut.cart_hw_mode || dut.layered_save_mode)
            $fatal(1,"DS pak with forced hardware enabled physical saves");
        $display("PASS: DS AD1 ticks without DS identification/Force + inactive GBA chip selects + live switching");
        $display("PASS: raw GPIO + RTC serial read during DS ticks + saves/EEPROM isolation + local fallback");
        $finish;
    end
    initial begin #50000000; $fatal(1,"shared slot timeout: ROM=%0d GPIO W/R=%0d/%0d save=%0d rumble=%0d init=%b state=%d",rom_reads,gpio_writes,gpio_reads,save_writes,rumble_writes,dut.cart_gpio_initialized,dut.u_layered_cart.state); end
endmodule
