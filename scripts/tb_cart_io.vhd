library ieee;
use ieee.std_logic_1164.all;
use std.env.all;

entity tb_cart_io is end;
architecture test of tb_cart_io is
    signal clk, on_gba, enable, irq_pin, ack, cpu_irq, phi : std_logic := '0';
    signal reset : std_logic := '1';
    signal select_phi : std_logic_vector(1 downto 0) := "00";
    signal flags, ie : std_logic_vector(15 downto 0) := x"0000";
    signal ime : std_logic_vector(0 downto 0) := "0";
begin
    clk <= not clk after 5 ns;
    dut: entity work.cart_io_fixture port map (
        clk100=>clk,reset=>reset,GBA_on=>on_gba,gpio_cart_mode=>enable,
        Cart_IRQ_in=>irq_pin,phi_select=>select_phi,IF_written=>ack,
        REG_IRP_IF=>x"2000",REG_IRP_IE=>ie,REG_IME=>ime,IRPFlags=>flags,
        cpu_IRP=>cpu_irq,Cart_PHI_out=>phi
    );
    process
        procedure cycles(n : natural) is
        begin
            for i in 1 to n loop wait until falling_edge(clk); end loop;
        end procedure;
        procedure check_phi(sel : std_logic_vector(1 downto 0); half : natural) is
            variable last_edge : time;
        begin
            select_phi<=sel;
            wait until rising_edge(phi);last_edge:=now;
            for i in 1 to 10 loop
                wait on phi;
                assert now-last_edge=half*10 ns report "wrong PHI half-period" severity failure;
                last_edge:=now;
            end loop;
        end procedure;
        variable saw_irq : boolean := false;
    begin
        irq_pin<='1';cycles(8);reset<='0';enable<='1';on_gba<='1';cycles(12);
        assert flags=x"0000" and phi='0' report "mode entry fabricated IRQ/PHI" severity failure;
        check_phi("01",12);check_phi("10",6);check_phi("11",3);
        -- Hardware clock continues with CPU paused, even between bus accesses.
        on_gba<='0';check_phi("01",12);
        irq_pin<='0';cycles(8);irq_pin<='1';cycles(8);
        assert flags=x"2000" report "paused core lost cartridge interrupt" severity failure;
        on_gba<='1';cycles(4);
        assert cpu_irq='0' report "masked IRQ reached CPU" severity failure;
        ie<=x"2000";ime<="1";cycles(4);
        assert cpu_irq='1' report "IF13 did not reach IE/IME path" severity failure;
        ack<='1';cycles(1);ack<='0';cycles(8);
        assert flags=x"0000" and cpu_irq='0' report "held pin retriggered acknowledged IRQ" severity failure;
        irq_pin<='0';cycles(8);
        assert flags=x"0000" report "wrong IRQ edge" severity failure;
        irq_pin<='1';cycles(8);
        assert flags=x"2000" severity failure;
        reset<='1';cycles(2);reset<='0';cycles(8);
        assert flags=x"0000" report "reset/high pin generated IRQ" severity failure;
        enable<='0';select_phi<="11";cycles(20);
        assert phi='0' severity failure;
        irq_pin<='0';cycles(8);irq_pin<='1';cycles(8);
        assert flags=x"0000" report "fallback accepted physical IRQ" severity failure;
        enable<='1';cycles(8);
        assert flags=x"0000" report "re-enable generated IRQ" severity failure;
        irq_pin<='0';cycles(8);ack<='1';irq_pin<='1';
        for i in 1 to 8 loop
            cycles(1);
            if flags(13)='1' then saw_irq:=true;exit;end if;
        end loop;
        assert saw_irq report "W1C erased a simultaneous new IRQ edge" severity failure;
        ack<='0';cycles(4);
        select_phi<="00";cycles(4);
        assert phi='0' report "WAITCNT did not disable PHI" severity failure;
        report "PASS: WAITCNT PHI /4 /2 /1/off + async IRQ + paused IF13 + IE/IME/W1C + fallback";
        stop;wait;
    end process;
    process begin wait for 20 us;assert false report "cart IO timeout" severity failure;end process;
end architecture;
