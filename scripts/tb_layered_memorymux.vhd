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
    signal ss : proc_bus_gb_type := ((others=>'0'), (others=>'Z'), (others=>'0'), '1', '0', 'Z', "10", "1111", '1');
    signal adr, wdata, rdata : std_logic_vector(31 downto 0) := (others=>'0');
    signal ena, rnw, done : std_logic := '0';
    signal acc : std_logic_vector(1 downto 0) := ACCESS_8BIT;
    signal bus_addr : std_logic_vector(25 downto 0);
    signal bus_din : std_logic_vector(31 downto 0);
    signal bus_ena, bus_rnw, bus_done : std_logic := '0';
    signal ee_req, ee_rnw, ee_din, ee_dma, ee_done : std_logic := '0';
    signal dma : std_logic := '0';
    signal gpio_readable, gpio_req : std_logic := '0';
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
        save_eeprom=>open, save_sram=>open, save_flash=>open,
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
        specialmodule=>'1', GPIO_readEna=>gpio_req, GPIO_done=>gpio_req,
        GPIO_Din=>"0101", GPIO_Dout=>open, GPIO_writeEna=>open, GPIO_addr=>open, GPIO_readable=>gpio_readable,
        EEPROM_ext_req=>ee_req, EEPROM_ext_rnw=>ee_rnw,
        EEPROM_ext_din=>ee_din, EEPROM_ext_dma=>ee_dma, EEPROM_ext_dout=>'1', EEPROM_ext_done=>ee_done,
        save_cart_mode=>cart_mode, tilt=>'0', AnalogTiltX=>(others=>'0'), AnalogTiltY=>(others=>'0'), debug_mem=>open
    );
    process(clk)
        variable bus_delay, ee_delay, rom_delay : natural := 0;
    begin
        if rising_edge(clk) then
            bus_done<='0'; ee_done<='0'; sdram_done<='0';
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
            assert completed report "memory access timeout" severity failure;
        end procedure;
        variable n, e, r : natural;
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
        -- The upstream GPIO read-enable remains in effect in layered mode.
        r:=rom_requests;
        access_bus(16#080000C4#,'1',0,ACCESS_16BIT);
        assert rom_requests>r report "GPIO disabled read did not return ROM" severity failure;
        gpio_readable<='1';
        access_bus(16#080000C4#,'1',0,ACCESS_16BIT);
        assert rdata=x"00000005" report "upstream GPIO read path changed" severity failure;
        -- Disabled mode restores the upstream internal EEPROM and Flash FSMs.
        cart_mode<='0';
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
        report "PASS: Flash passthrough, EEPROM DMA/CPU + halfword rotation, upstream GPIO and disabled-mode fallback";
        stop;
        wait;
    end process;
end architecture;
