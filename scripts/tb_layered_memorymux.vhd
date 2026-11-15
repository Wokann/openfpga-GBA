library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.pProc_bus_gba.all;

entity tb_layered_memorymux is end;
architecture test of tb_layered_memorymux is
    signal clk : std_logic := '0';
    signal reset : std_logic := '1';
    signal gb_on : std_logic := '0';
    signal cart_mode : std_logic := '1';
    signal hw_mode : std_logic := '1';
    signal tilt_mode, save_sram : std_logic := '0';
    signal sram_events : natural := 0;
    signal ss : proc_bus_gb_type := ((others=>'0'), (others=>'Z'), (others=>'0'), '1', '0', 'Z', "10", "1111", '1');
    signal adr, wdata, rdata : std_logic_vector(31 downto 0) := (others=>'0');
    signal ena, rnw, done : std_logic := '0';
    signal acc : std_logic_vector(1 downto 0) := ACCESS_8BIT;
    signal bus_addr : std_logic_vector(25 downto 0);
    signal bus_din : std_logic_vector(31 downto 0);
    signal bus_ena, bus_rnw, bus_done : std_logic := '0';
    signal ee_req, ee_rnw, ee_din, ee_dma, ee_done : std_logic := '0';
    signal dma : std_logic := '0';
    signal gpio_readable, gpio_req, gpio_write : std_logic := '0';
    signal special : std_logic := '0'; -- physical GPIO must not depend on ROM database
    signal g_req,g_rnw,g_done,g_readable : std_logic := '0';
    signal g_addr : std_logic_vector(1 downto 0);
    signal g_din,g_dout : std_logic_vector(15 downto 0) := (others=>'0');
    type gpio_regs is array(0 to 2) of std_logic_vector(15 downto 0);
    signal g_regs : gpio_regs := (others=>(others=>'0'));
    signal g_requests, local_reads, local_writes : natural := 0;
    signal sdram_req, sdram_done : std_logic := '0';
    signal ee_count : unsigned(16 downto 0) := to_unsigned(9,17);
    signal bus_requests, ee_requests, rom_requests : natural := 0;
    signal last_write : std_logic_vector(7 downto 0) := (others=>'0');
    signal last_address : std_logic_vector(15 downto 0) := (others=>'0');
begin
    clk <= not clk after 5 ns;
    dut: entity work.gba_memorymux generic map (
        is_simu=>'1', Softmap_GBA_Gamerom_ADDR=>0, Softmap_GBA_WRam_ADDR=>131072,
        Softmap_GBA_FLASH_ADDR=>0, Softmap_GBA_EEPROM_ADDR=>0
    ) port map (
        clk100=>clk, gb_on=>gb_on, reset=>reset, savestate_bus=>ss,
        sdram_read_ena=>sdram_req, sdram_read_done=>sdram_done, sdram_read_addr=>open,
        sdram_read_data=>x"12345678", sdram_second_dword=>x"ABCDEF01",
        bus_out_Din=>bus_din, bus_out_Dout=>x"0000005A", bus_out_Adr=>bus_addr,
        bus_out_rnw=>bus_rnw, bus_out_ena=>bus_ena, bus_out_be=>open, bus_out_done=>bus_done,
        mem_bus_Adr=>adr, mem_bus_rnw=>rnw, mem_bus_ena=>ena, mem_bus_acc=>acc,
        mem_bus_dout=>wdata, mem_bus_din=>rdata, mem_bus_done=>done, mem_bus_unread=>open,
        bus_lowbits=>"00", dma_soon=>'0', settle=>open,
        save_eeprom=>open, save_sram=>save_sram, save_flash=>open,
        new_cycles=>(others=>'0'), new_cycles_valid=>'0', PC_in_BIOS=>'0',
        lastread=>(others=>'0'), lastread_dma=>(others=>'0'), last_access_dma=>dma,
        dma_eepromcount=>ee_count, flash_1m=>'1', MaxPakAddr=>(others=>'1'),
        SramFlashEnable=>'1', memory_remap=>'0', bitmapdrawmode=>'0',
        VRAM_Lo_addr=>open, VRAM_Lo_datain=>open, VRAM_Lo_dataout=>(others=>'0'), VRAM_Lo_we=>open, VRAM_Lo_be=>open,
        VRAM_Hi_addr=>open, VRAM_Hi_datain=>open, VRAM_Hi_dataout=>(others=>'0'), VRAM_Hi_we=>open, VRAM_Hi_be=>open,
        vram_blocked=>'0', vram_cycle=>open,
        OAMRAM_PROC_addr=>open, OAMRAM_PROC_datain=>open, OAMRAM_PROC_dataout=>(others=>'0'), OAMRAM_PROC_we=>open,
        PALETTE_BG_addr=>open, PALETTE_BG_datain=>open, PALETTE_BG_dataout=>(others=>'0'), PALETTE_BG_we=>open,
        PALETTE_OAM_addr=>open, PALETTE_OAM_datain=>open, PALETTE_OAM_dataout=>(others=>'0'), PALETTE_OAM_we=>open,
        specialmodule=>special, GPIO_readEna=>gpio_req, GPIO_done=>gpio_req,
        GPIO_Din=>"0101", GPIO_Dout=>open, GPIO_writeEna=>gpio_write, GPIO_addr=>open, GPIO_readable=>gpio_readable,
        GPIO_ext_req=>g_req, GPIO_ext_addr=>g_addr, GPIO_ext_rnw=>g_rnw,
        GPIO_ext_din=>g_din, GPIO_ext_dout=>g_dout, GPIO_ext_done=>g_done, GPIO_ext_readable=>g_readable,
        EEPROM_ext_req=>ee_req, EEPROM_ext_rnw=>ee_rnw,
        EEPROM_ext_din=>ee_din, EEPROM_ext_dma=>ee_dma, EEPROM_ext_dout=>'1', EEPROM_ext_done=>ee_done,
        save_cart_mode=>cart_mode, gpio_cart_mode=>hw_mode, tilt_cart_mode=>tilt_mode,
        tilt=>'0', AnalogTiltX=>(others=>'0'), AnalogTiltY=>(others=>'0'), debug_mem=>open
    );
    process(clk)
        variable bus_delay, ee_delay, rom_delay, g_delay : natural := 0;
        variable g_saved_addr : integer range 0 to 2 := 0;
        variable g_saved_rnw : std_logic := '0';
        variable g_saved_data : std_logic_vector(15 downto 0);
    begin
        if rising_edge(clk) then
            bus_done<='0'; ee_done<='0'; sdram_done<='0';g_done<='0';
            if save_sram='1' then sram_events<=sram_events+1; end if;
            if gpio_req='1' then local_reads<=local_reads+1; end if;
            if gpio_write='1' then local_writes<=local_writes+1; end if;
            if g_req='1' then
                assert g_delay=0 report "overlapping GPIO request" severity failure;
                g_requests<=g_requests+1;g_delay:=12;
                g_saved_addr:=to_integer(unsigned(g_addr));g_saved_rnw:=g_rnw;g_saved_data:=g_din;
            elsif g_delay>0 then
                assert done='0' report "CPU completed before physical GPIO" severity failure;
                g_delay:=g_delay-1;
                if g_delay=0 then
                    g_done<='1';
                    if g_saved_rnw='1' then g_dout<=g_regs(g_saved_addr);
                    else
                        g_regs(g_saved_addr)<=g_saved_data;
                        if g_saved_addr=2 then g_readable<=g_saved_data(0); end if;
                    end if;
                end if;
            end if;
            if bus_ena='1' then
                bus_requests<=bus_requests+1; bus_delay:=4;
                if bus_rnw='0' then last_write<=bus_din(7 downto 0); last_address<=bus_addr(15 downto 0); end if;
            elsif bus_delay>0 then
                bus_delay:=bus_delay-1;
                if bus_delay=0 then bus_done<='1'; end if;
            end if;
            if ee_req='1' then
                ee_requests<=ee_requests+1; ee_delay:=7;
            elsif ee_delay>0 then
                ee_delay:=ee_delay-1;
                if ee_delay=0 then ee_done<='1'; end if;
            end if;
            if sdram_req='1' and rom_delay=0 then
                rom_requests<=rom_requests+1; rom_delay:=3;
            elsif rom_delay>0 then
                rom_delay:=rom_delay-1;
                if rom_delay=0 then sdram_done<='1'; end if;
            end if;
        end if;
    end process;
    process
        procedure access_bus(a : natural; reading : std_logic; value : natural; width : std_logic_vector(1 downto 0)) is
            variable completed : boolean := false;
        begin
            wait until falling_edge(clk);
            adr<=std_logic_vector(to_unsigned(a,32)); rnw<=reading;
            wdata<=std_logic_vector(to_unsigned(value,32)); acc<=width; ena<='1';
            wait until falling_edge(clk); ena<='0';
            for i in 0 to 150 loop
                wait until falling_edge(clk);
                if done='1' then completed:=true; exit; end if;
            end loop;
            assert completed report "memory access timeout at " & to_hstring(std_logic_vector(to_unsigned(a,32))) severity failure;
        end procedure;
        variable n, e, r : natural;
        variable base_addr, reg_value, data_value, dir_value : natural;
        variable store_width : std_logic_vector(1 downto 0);
        variable expect_word, expect_read : unsigned(31 downto 0);
    begin
        wait for 40 ns;
        wait until falling_edge(clk); ss.rst<='0';
        wait until falling_edge(clk); reset<='0'; gb_on<='1';
        -- The ROM cache clears its valid tags after GBA power-on.
        for i in 0 to 1100 loop wait until falling_edge(clk); end loop;
        -- Every Flash command, including bank select, must reach the physical bus.
        access_bus(16#0E005555#,'0',16#AA#,ACCESS_8BIT);
        assert last_write=x"AA" and last_address=x"5555" severity failure;
        access_bus(16#0E002AAA#,'0',16#55#,ACCESS_8BIT);
        assert last_write=x"55" and last_address=x"2AAA" severity failure;
        access_bus(16#0E005555#,'0',16#B0#,ACCESS_8BIT);
        access_bus(16#0E000000#,'0',1,ACCESS_8BIT);
        assert bus_requests=4 and last_write=x"01" report "Flash commands consumed by emulator" severity failure;
        access_bus(16#0E003210#,'1',0,ACCESS_8BIT);
        assert rdata(7 downto 0)=x"5A" severity failure;
        n:=bus_requests; e:=ee_requests;
        dma<='1';
        access_bus(16#0D000000#,'0',1,ACCESS_16BIT);
        assert ee_rnw='0' and ee_din='1' and ee_dma='1' severity failure;
        access_bus(16#0D000000#,'1',0,ACCESS_16BIT);
        assert rdata(15 downto 0)=x"0001" severity failure;
        access_bus(16#0D000002#,'1',0,ACCESS_16BIT);
        assert rdata(15 downto 0)=x"0001" report "odd DMA halfword rotated away bit0" severity failure;
        dma<='0'; ee_count<=(others=>'0');
        access_bus(16#0DFFFF00#,'1',0,ACCESS_16BIT);
        assert ee_dma='0' and rdata(0)='1' severity failure;
        assert ee_requests=e+4 and bus_requests=n report "EEPROM used PSRAM path" severity failure;
        -- Write-only mode returns the SD ROM, even if the local simulator
        -- thinks reads are enabled. A GPIO STRB is one physical halfword write.
        gpio_readable<='1';special<='1';r:=rom_requests;e:=g_requests;
        access_bus(16#080000C4#,'1',0,ACCESS_16BIT);
        assert rom_requests>r and g_requests=e severity failure;
        access_bus(16#080000C8#,'0',1,ACCESS_8BIT);
        assert g_requests=e+1 and g_readable='1' report "GPIO byte control write was dropped" severity failure;
        special<='0';
        access_bus(16#080000C8#,'0',1,ACCESS_16BIT);
        assert g_readable='1' severity failure;
        access_bus(16#080000C4#,'0',16#000D000B#,ACCESS_32BIT);
        assert g_regs(0)=x"000B" and g_regs(1)=x"000D" report "32-bit GPIO write split failed" severity failure;
        access_bus(16#080000C4#,'1',0,ACCESS_32BIT);
        assert rdata=x"000D000B" report "32-bit GPIO read merge failed" severity failure;
        access_bus(16#080000C6#,'1',0,ACCESS_16BIT);
        assert rdata=x"0000000D" severity failure;
        access_bus(16#080000C7#,'1',0,ACCESS_16BIT);
        assert rdata=x"0D000000" report "unaligned halfword rotation failed" severity failure;
        access_bus(16#080000C7#,'1',0,ACCESS_8BIT);
        assert rdata=x"00000000" report "GPIO high-byte read failed" severity failure;
        access_bus(16#080000C5#,'1',0,ACCESS_32BIT);
        assert rdata=x"0B000D00" report "unaligned GPIO word read failed" severity failure;
        access_bus(16#0A0000C6#,'0',7,ACCESS_16BIT);
        access_bus(16#0C0000C6#,'1',0,ACCESS_16BIT);
        assert rdata=x"00000007" report "ROM waitstate alias failed" severity failure;
        access_bus(16#080000C8#,'1',0,ACCESS_32BIT);
        assert rdata=x"12340001" report "C8 word read did not preserve SD ROM CA halfword" severity failure;
        access_bus(16#080000CA#,'1',0,ACCESS_32BIT);
        assert rdata=x"00011234" report "C8 aligned word rotation failed" severity failure;
        access_bus(16#080000CA#,'1',0,ACCESS_16BIT);
        assert rdata=x"00001234" report "ordinary SD ROM changed" severity failure;
        assert local_reads=0 and local_writes=0 report "physical access leaked into local RTC" severity failure;
        e:=g_requests;
        access_bus(16#080000C8#,'0',16#55AA0000#,ACCESS_32BIT);
        assert g_requests=e+1 and g_readable='0' report "C8 word write escaped GPIO registers" severity failure;
        e:=g_requests;
        access_bus(16#080000C4#,'1',0,ACCESS_16BIT);
        assert g_requests=e and rdata=x"00005678" report "disabled GPIO did not restore SD ROM" severity failure;
        -- Disabled mode restores the upstream internal EEPROM and Flash FSMs.
        -- SD-save mode keeps raw GPIO while restoring local save decoding.
        cart_mode<='0';special<='1';
        access_bus(16#080000C8#,'0',1,ACCESS_16BIT);
        access_bus(16#080000C6#,'1',0,ACCESS_16BIT);
        assert rdata=x"00000007" and local_reads=0 report "SD saves disabled raw GPIO" severity failure;
        -- A homebrew SD ROM has no database GPIO flag. With physical GPIO
        -- selected, both states of the combined database/Force Quirk input
        -- must deliver the same motor commands, without local GPIO writes.
        for forced in 0 to 1 loop
            if forced=0 then special<='0'; else special<='1'; end if;
          for width in 0 to 1 loop
            if width=0 then store_width:=ACCESS_8BIT; else store_width:=ACCESS_16BIT; end if;
            e:=g_requests;
            -- Original Pinball 1.2/1.3 patch sequence, also checked as STRH.
            access_bus(16#080000C8#,'0',1,store_width);
            access_bus(16#080000C6#,'0',8,store_width);
            access_bus(16#080000C4#,'0',8,store_width);
            access_bus(16#080000C4#,'1',0,ACCESS_16BIT);
            assert rdata=x"00000008" and g_regs(1)=x"0008"
                report "SD homebrew motor-on depends on Force Quirk" severity failure;
            access_bus(16#080000C4#,'0',0,store_width);
            access_bus(16#080000C4#,'1',0,ACCESS_16BIT);
            assert rdata=x"00000000" and g_requests=e+6 and local_reads=0 and local_writes=0
                report "SD homebrew motor-off leaked into local GPIO" severity failure;
          end loop;
        end loop;
        -- STRB uses only the low source byte, even when its upper bits are
        -- nonzero. Cover all six byte addresses and all ROM waitstate windows.
        special<='0';
        for window in 0 to 2 loop
            base_addr:=16#08000000#+window*16#02000000#;
            for offset in 0 to 5 loop
                e:=g_requests;
                access_bus(base_addr+16#C4#+offset,'0',16#12AB005B#,ACCESS_8BIT);
                assert g_requests=e+1 and g_regs(offset/2)=x"005B"
                    report "GPIO byte payload/address alias is incorrect" severity failure;
            end loop;
            -- STR rounds down to a word boundary; do not rotate write data.
            for offset in 0 to 3 loop
                e:=g_requests;
                access_bus(base_addr+16#C4#+offset,'0',16#00340012#,ACCESS_32BIT);
                assert g_requests=e+2 and g_regs(0)=x"0012" and g_regs(1)=x"0034"
                    report "32-bit GPIO write alignment/split failed" severity failure;
                e:=g_requests;
                access_bus(base_addr+16#C8#+offset,'0',16#56780001#,ACCESS_32BIT);
                assert g_requests=e+1 and g_regs(2)=x"0001"
                    report "32-bit C8 write escaped into ordinary ROM" severity failure;
            end loop;
        end loop;
        e:=g_requests;
        access_bus(16#080000C2#,'0',8,ACCESS_8BIT);
        access_bus(16#080000CA#,'0',8,ACCESS_8BIT);
        access_bus(16#08001000#,'0',2,ACCESS_8BIT);
        access_bus(16#09FE0000#,'0',16#D200#,ACCESS_16BIT);
        assert g_requests=e and local_reads=0 and local_writes=0
            report "ordinary ROM/flashcart commands leaked into GPIO" severity failure;
        special<='1';
        tilt_mode<='1';n:=bus_requests;r:=sram_events;e:=ee_requests;
        access_bus(16#0E008000#,'0',16#55#,ACCESS_8BIT);
        assert last_address=x"8000" and last_write=x"55" severity failure;
        access_bus(16#0E008100#,'0',16#AA#,ACCESS_8BIT);
        assert last_address=x"8100" and last_write=x"AA" severity failure;
        for i in 0 to 3 loop
            access_bus(16#0E008200#+i*256,'1',0,ACCESS_8BIT);
            assert bus_addr(15 downto 0)=std_logic_vector(to_unsigned(16#8200#+i*256,16)) and rdata=x"0000005A"
                report "tilt register did not use physical byte bus" severity failure;
        end loop;
        assert bus_requests=n+6 and sram_events=r report "sensor accesses marked SRAM dirty" severity failure;
        access_bus(16#0DFFFF00#,'1',0,ACCESS_16BIT);
        assert ee_requests=e and rdata(0)='1' report "physical sensor forced physical EEPROM" severity failure;
        tilt_mode<='0';
        hw_mode<='0';
        e:=g_requests;
        access_bus(16#080000C4#,'1',0,ACCESS_16BIT);
        assert rdata=x"00000005" and local_reads=1 and g_requests=e report "local GPIO fallback failed" severity failure;
        access_bus(16#080000C6#,'0',7,ACCESS_16BIT);
        wait until falling_edge(clk); -- upstream acknowledges local writes with the request pulse
        assert local_writes=1 and g_requests=e report "local GPIO write fallback failed" severity failure;
        e:=ee_requests; n:=bus_requests;
        access_bus(16#0DFFFF00#,'1',0,ACCESS_16BIT);
        assert ee_requests=e and rdata(0)='1' report "disabled mode still used physical EEPROM" severity failure;
        -- Reinitialize the Flash emulator before testing its command decoder.
        wait until falling_edge(clk); reset<='1';
        wait until falling_edge(clk); reset<='0';
        access_bus(16#0E005555#,'0',16#AA#,ACCESS_8BIT);
        access_bus(16#0E002AAA#,'0',16#55#,ACCESS_8BIT);
        access_bus(16#0E005555#,'0',16#A0#,ACCESS_8BIT);
        access_bus(16#0E001234#,'0',16#7B#,ACCESS_8BIT);
        assert bus_requests=n+1 and last_write=x"7B" report "upstream Flash emulator regression" severity failure;
        report "PASS: Flash/EEPROM + GPIO completion, 8/16/32-bit reads, word writes, aliases, SD ROM overlay and local fallback";
        -- Exhaustive byte/halfword offsets and word rotations in all three
        -- ROM windows. Poison the shared result with a full save-bus read
        -- before each GPIO read, so stale unused halves cannot hide a bug.
        cart_mode<='1';hw_mode<='1';special<='0';
        access_bus(16#080000C8#,'0',1,ACCESS_16BIT);
        for pattern in 0 to 1 loop
            if pattern=0 then data_value:=16#A55A#;dir_value:=16#5AA5#;
            else data_value:=16#1234#;dir_value:=16#ABCD#;end if;
            access_bus(16#080000C4#,'0',data_value,ACCESS_16BIT);
            access_bus(16#080000C6#,'0',dir_value,ACCESS_16BIT);
            for window_id in 0 to 2 loop
                base_addr:=16#08000000#+window_id*16#02000000#;
                for reg_id in 0 to 2 loop
                    if reg_id=0 then reg_value:=data_value;
                    elsif reg_id=1 then reg_value:=dir_value;
                    else reg_value:=1;end if;
                    for byte_offset in 0 to 1 loop
                        access_bus(16#0E003210#,'1',0,ACCESS_32BIT);
                        assert rdata=x"5A5A5A5A" report "result poison failed" severity failure;
                        access_bus(base_addr+16#C4#+reg_id*2+byte_offset,'1',0,ACCESS_8BIT);
                        expect_read:=to_unsigned((reg_value/(256**byte_offset)) mod 256,32);
                        assert unsigned(rdata)=expect_read report "byte result depends on stale rotate_data" severity failure;
                        access_bus(16#0E003210#,'1',0,ACCESS_32BIT);
                        access_bus(base_addr+16#C4#+reg_id*2+byte_offset,'1',0,ACCESS_16BIT);
                        expect_read:=rotate_right(to_unsigned(reg_value,32),8*byte_offset);
                        assert unsigned(rdata)=expect_read report "halfword result depends on stale rotate_data" severity failure;
                    end loop;
                end loop;
                for word_id in 0 to 1 loop
                    if word_id=0 then
                        expect_word:=shift_left(to_unsigned(dir_value,32),16) or to_unsigned(data_value,32);
                    else expect_word:=x"12340001";end if;
                    for byte_offset in 0 to 3 loop
                        access_bus(16#0E003210#,'1',0,ACCESS_32BIT);
                        access_bus(base_addr+16#C4#+word_id*4+byte_offset,'1',0,ACCESS_32BIT);
                        expect_read:=rotate_right(expect_word,8*byte_offset);
                        assert unsigned(rdata)=expect_read report "word assembly/rotation depends on stale rotate_data" severity failure;
                    end loop;
                end loop;
            end loop;
        end loop;
        report "PASS: 120 poisoned-result GPIO reads across widths, rotations and ROM windows";
        stop;
        wait;
    end process;
end architecture;
