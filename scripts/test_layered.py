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
    input wire reset_n_s, dataslot_allcomplete_s, cfg, motor,
    input wire save_req, save_rnw, input wire [16:0] save_addr,
    input wire [7:0] save_din,
    input wire e_req, e_rnw, e_din, e_dma,
    inout wire [7:0] cart_tran_bank1, cart_tran_bank2, cart_tran_bank3,
    inout wire [7:4] cart_tran_bank0, inout wire cart_tran_pin30,
    output wire cart_tran_bank1_dir, cart_tran_bank2_dir, cart_tran_bank3_dir,
    output wire cart_tran_bank0_dir, cart_tran_pin30_dir,
    output wire cart_pin30_pwroff_reset,
    inout wire cart_tran_pin31, output wire cart_tran_pin31_dir
);
''' + block + '''
assign layered_cfg_s = cfg;
assign cart_rumble = motor;
assign cart_eeprom_req = e_req;
assign cart_eeprom_rnw = e_rnw;
assign cart_eeprom_din = e_din;
assign cart_eeprom_dma = e_dma;
always @* begin
    cart_save_req = save_req;
    cart_save_rnw = save_rnw;
    cart_save_addr = save_addr;
    cart_save_din = save_din;
end
endmodule
'''


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
        for lib, paths in groups.items():
            run([ghdl, '-i', '--std=08', '-frelaxed-rules', f'--work={lib}', *paths], work)
        flags = ['--std=08', '-frelaxed-rules']
        run([ghdl, '-m', *flags, 'gba_memorymux'], work)
        run([ghdl, '-a', *flags, ROOT/'scripts/tb_layered_memorymux.vhd'], work)
        run([ghdl, '-m', *flags, 'tb_layered_memorymux'], work)
        # Upstream RAM/cache address registers are undefined before the first
        # access. Keep testbench assertions enabled while suppressing numeric_std
        # warnings about those power-on metavalues.
        run([ghdl, '-r', *flags, 'tb_layered_memorymux', '--assert-level=error', '--ieee-asserts=disable'], work)
    print('PASS: layered slot, header probe and production VHDL memory/save routing')


if __name__ == '__main__':
    main()
