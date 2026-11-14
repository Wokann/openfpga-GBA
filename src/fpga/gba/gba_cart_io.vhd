library ieee;
use ieee.std_logic_1164.all;

-- Physical Game Pak sideband signals, independent of ROM/save transactions.
-- WAITCNT[12:11]: PHI off, GBA clock/4, /2, /1. The core runs at 6x GBA.
-- The cartridge slot IRQ rises after the RTC /IRQ inverter (GBATEK;
-- also ares/gba/cartridge/rtc.cpp). Do not invert that signal again.
entity gba_cart_io is
   generic (SPEEDDIV : positive := 6);
   port (
      clk          : in  std_logic;
      reset        : in  std_logic;
      enable       : in  std_logic;
      phi_select   : in  std_logic_vector(1 downto 0);
      irq_pin      : in  std_logic;
      phi_pin      : out std_logic := '0';
      irq_pulse    : out std_logic := '0'
   );
end entity;

architecture arch of gba_cart_io is
   signal phi_count : integer range 0 to 2*SPEEDDIV-1 := 0;
   signal phi_level : std_logic := '0';
   signal phi_prev  : std_logic_vector(1 downto 0) := "00";
   signal irq_sync  : std_logic_vector(2 downto 0) := (others => '0');
   signal irq_prev  : std_logic := '0';
   signal irq_arm   : integer range 0 to 4 := 0;
begin
   phi_pin <= phi_level;
   process(clk)
      variable half_period : positive range 1 to 2*SPEEDDIV;
   begin
      if rising_edge(clk) then
         irq_sync <= irq_sync(1 downto 0) & irq_pin;
         irq_prev <= irq_sync(2);
         irq_pulse <= '0';
         phi_prev <= phi_select;
         case phi_select is
            when "01" => half_period := 2*SPEEDDIV;
            when "10" => half_period := SPEEDDIV;
            when others => half_period := SPEEDDIV/2;
         end case;
         if reset = '1' or enable = '0' then
            phi_count <= 0;
            phi_level <= '0';
            irq_arm <= 0;
         else
            -- Ignore the initial pin level while the synchronizer settles;
            -- enabling the route must not manufacture a cartridge interrupt.
            if irq_arm < 4 then
               irq_arm <= irq_arm + 1;
            else
               irq_pulse <= irq_sync(2) and not irq_prev;
            end if;
            if phi_select = "00" or phi_select /= phi_prev then
               phi_count <= 0;
               phi_level <= '0';
            elsif phi_count = half_period - 1 then
               phi_count <= 0;
               phi_level <= not phi_level;
            else
               phi_count <= phi_count + 1;
            end if;
         end if;
      end if;
   end process;
end architecture;
