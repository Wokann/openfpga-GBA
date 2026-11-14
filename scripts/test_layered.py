#!/usr/bin/env python3
"""Exercise the production shared-slot RTL and GBA memory/save routing."""
from pathlib import Path
import os
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def tool(name):
    result = os.environ.get(name.upper()) or shutil.which(name)
    if not result:
        raise SystemExit(f'{name} is required (or set {name.upper()})')
    return result


def run(args, cwd):
    subprocess.run([str(x) for x in args], cwd=cwd, check=True)


def slot_fixture():
    """Extract the production integration, including the upstream rumble FSM."""
    source = (ROOT/'src/fpga/core/core_top.sv').read_text(encoding='utf-8')
    a = source.index('// ---- Layered saves:')
    b = source.index('// ---- Link Cable ----', a)
    block = source[a:b]
    return '''`timescale 1ns/1ps
module slot_fixture (
    input wire clk_sys, clk_74a, pll_core_locked, core_reset_s,
    input wire reset_n_s, dataslot_allcomplete_s, cfg, hw_cfg, motor,
    input wire tilt_game, phi_source,
    input wire save_req, save_rnw, input wire [16:0] save_addr,
    input wire [7:0] save_din,
    input wire e_req, e_rnw, e_din, e_dma,
    input wire g_req, g_rnw, input wire [1:0] g_addr, input wire [15:0] g_din,
    inout wire [7:0] cart_tran_bank1, cart_tran_bank2, cart_tran_bank3,
    inout wire [7:4] cart_tran_bank0, inout wire cart_tran_pin30,
    output wire cart_tran_bank1_dir, cart_tran_bank2_dir, cart_tran_bank3_dir,
    output wire cart_tran_bank0_dir, cart_tran_pin30_dir,
    output wire cart_pin30_pwroff_reset,
    inout wire cart_tran_pin31, output wire cart_tran_pin31_dir
);
''' + block + '''
wire layered_cfg = cfg;
wire cart_hw_cfg = hw_cfg;
wire quirk_tilt = tilt_game;
wire [25:0] bus_out_Adr = {9'd0,save_addr};
assign cart_phi = cart_hw_mode ? phi_source : 1'b0;
synch_3 hw_cfg_sync(.i(hw_cfg), .o(cart_hw_cfg_s), .clk(clk_sys), .rise(), .fall());
synch_3 cfg_sync(.i(cfg), .o(layered_cfg_s), .clk(clk_sys), .rise(), .fall());
assign cart_rumble = motor;
assign cart_gpio_req = g_req;
assign cart_gpio_rnw = g_rnw;
assign cart_gpio_addr = g_addr;
assign cart_gpio_din = g_din;
assign cart_eeprom_req = e_req;
assign cart_eeprom_rnw = e_rnw;
assign cart_eeprom_din = e_din;
assign cart_eeprom_dma = e_dma;
always @* begin
    cart_save_req = save_req && cart_byte_access;
    cart_save_rnw = save_rnw;
    cart_save_addr = save_addr;
    cart_save_din = save_din;
end
endmodule
'''


def cart_io_fixture():
    """Use the real gba_top interrupt process, including IF/IE/IME/ack ordering."""
    source = (ROOT/'src/fpga/gba/gba_top.vhd').read_text(encoding='utf-8')
    a = source.index('   igba_cart_io :')
    b = source.index('   igba_gpioRTCSolarGyro :', a)
    c = source.index('   ------------- interrupt')
    d = source.index('   ------------- cycling', c)
    return '''library ieee;
use ieee.std_logic_1164.all;
entity cart_io_fixture is
port (
    clk100, reset, GBA_on, gpio_cart_mode, Cart_IRQ_in : in std_logic;
    phi_select : in std_logic_vector(1 downto 0);
    IF_written : in std_logic;
    REG_IRP_IF, REG_IRP_IE : in std_logic_vector(15 downto 0);
    REG_IME : in std_logic_vector(0 downto 0);
    IRPFlags : buffer std_logic_vector(15 downto 0);
    cpu_IRP, Cart_PHI_out : out std_logic
);
end;
architecture test of cart_io_fixture is
    constant SPEEDDIV : positive := 6;
    signal REG_WAITCNT : std_logic_vector(14 downto 0);
    signal IRP_Gamepak, gbaon, new_halt : std_logic;
    constant SAVESTATE_IRP : std_logic_vector(15 downto 0) := x"0000";
    constant REG_HALTCNT : std_logic_vector(15 downto 0) := x"0000";
    constant REG_HALTCNT_written, loading_savestate : std_logic := '0';
    constant IRP_VBlank, IRP_HBlank, IRP_LCDStat, IRP_Serial, IRP_Joypad : std_logic := '0';
    constant IRP_Timer, IRP_DMA : std_logic_vector(3 downto 0) := "0000";
begin
    REG_WAITCNT <= "00" & phi_select & "00000000000";
''' + source[a:b] + source[c:d] + 'end architecture;\n'


def main():
    iverilog, vvp, ghdl = tool('iverilog'), tool('vvp'), tool('ghdl')
    with tempfile.TemporaryDirectory(prefix='gba-layered-') as temp:
        work = Path(temp)
        fixture = work/'slot_fixture.sv'
        fixture.write_text(slot_fixture(), encoding='utf-8')
        files = [ROOT/'src/fpga/core'/name for name in
                 ('gba_cart_controller.sv', 'cart_header_probe.sv')]
        # synch_3 lives in the shared APF utility source.
        sync = next(p for p in (ROOT/'src/fpga').rglob('*.v')
                    if re.search(r'module\s+synch_3\b', p.read_text(errors='replace')))
        run([iverilog, '-g2012', '-s', 'tb_layered_slot', '-o', work/'slot.vvp',
             *files, sync, fixture, ROOT/'scripts/tb_layered_slot.sv'], work)
        run([vvp, work/'slot.vvp'], work)
        run([iverilog, '-g2012', '-s', 'tb_cart_header_probe', '-o', work/'probe.vvp',
             ROOT/'src/fpga/core/cart_header_probe.sv',
             ROOT/'scripts/tb_cart_header_probe.sv'], work)
        run([vvp, work/'probe.vvp'], work)
        qsf = ROOT/'src/fpga/build/ap_core.qsf'
        groups = {'MEM': [], 'work': []}
        for line in qsf.read_text(encoding='utf-8').splitlines():
            match = re.match(r'set_global_assignment -name VHDL_FILE (\S+)(?: -library (\S+))?', line)
            if match:
                groups[match[2] or 'work'].append((qsf.parent/match[1]).resolve())
        # GHDL uses the existing behavioral RAM; omit the Intel-only generate
        # and library clauses in a temporary copy, never in production sources.
        ram = ROOT/'src/fpga/gba/SyncRamDualByteEnable.vhd'
        ram_source = ram.read_text(encoding='utf-8')
        ram_source = re.sub(r'(?im)^(?:LIBRARY altera_mf;|USE altera_mf\.altera_mf_components\.all;)\s*', '', ram_source)
        a, b = ram_source.index('   gsynth_cyclone5 :'), ram_source.index('   gsimu :')
        sim_ram = work/ram.name
        sim_ram.write_text(ram_source[:a] + ram_source[b:], encoding='utf-8')
        groups['MEM'] = [sim_ram if p == ram else p for p in groups['MEM']]
        # Quartus uses the older VHDL interface rules. Check production RTL
        # under those rules too; only the testbench needs VHDL-2008/std.env.
        for standard in ('02', '08'):
            for lib, paths in groups.items():
                run([ghdl, '-i', f'--std={standard}', '-frelaxed-rules', f'--work={lib}', *paths], work)
            run([ghdl, '-m', f'--std={standard}', '-frelaxed-rules', 'gba_memorymux'], work)
            run([ghdl, '-m', f'--std={standard}', '-frelaxed-rules', 'gba_cart_io'], work)
        flags = ['--std=08', '-frelaxed-rules']
        run([ghdl, '-a', *flags, ROOT/'scripts/tb_layered_memorymux.vhd'], work)
        run([ghdl, '-m', *flags, 'tb_layered_memorymux'], work)
        # Upstream RAM/cache address registers are undefined before the first
        # access. Keep testbench assertions enabled while suppressing numeric_std
        # warnings about those power-on metavalues.
        run([ghdl, '-r', *flags, 'tb_layered_memorymux', '--assert-level=error', '--ieee-asserts=disable'], work)
        io_fixture = work/'cart_io_fixture.vhd'
        io_fixture.write_text(cart_io_fixture(), encoding='utf-8')
        run([ghdl, '-a', *flags, ROOT/'src/fpga/gba/gba_cart_io.vhd', io_fixture,
             ROOT/'scripts/tb_cart_io.vhd'], work)
        run([ghdl, '-m', *flags, 'tb_cart_io'], work)
        run([ghdl, '-r', *flags, 'tb_cart_io', '--assert-level=error'], work)
    print('PASS: layered GPIO/save/tilt routing, header probe, PHI and cartridge IRQ')


if __name__ == '__main__':
    main()
