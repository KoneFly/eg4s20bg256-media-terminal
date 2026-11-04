"""生成逐门级D端点约束；不使用get_regs别名或通配符。"""
from pathlib import Path
import hashlib
import json

TASK = Path(__file__).resolve().parent.parent
PIXEL = 'u_display/u_pll/u_video_pll.clkc[0]'
CTRL = 'u_clk/u_pll_0/pll_inst.clkc[1]'
meta = ['u_display/u_snapshot/request_meta', 'u_display/u_snapshot/ack_meta',
        *(f'u_display/u_snapshot/descriptor_meta[{i}]' for i in range(3)),
        'u_display/locked_meta',
        *(f'u_display/u_scan/{n}' for n in ('capture_meta','capture_ack_meta','label_meta','ready_meta','commit_meta','blank_meta','write_bad_meta')),
        *(f'u_display/u_scan/ctrl_error_meta[{i}]' for i in (0, 1, 4, 5, 7)),
        'u_display/u_scan/u_updater/ack_meta',
        *(f'u_display/u_label_stream/u_fifo/{n}[{i}]' for n in ('rd_gray_w1','wr_gray_r1') for i in range(11)),
        *(f'u_display/u_label_stream/{n}' for n in ('start_meta','ctrl_fault_meta','pixel_fault_meta')),
        *(f'u_display/fault_code_meta[{i}]' for i in range(8))]

def pin(name):
    if '[' in name:
        base, index = name.split('[', 1)
        return f'{base}_reg[{index}.d'
    return f'{name}_reg.d'

pins = [pin(n) for n in meta]
dest = [f'u_display/u_scan/u_updater/spectrum_reg[{i}].d' for i in range(1024)]
lines = [
 '# 第二轮精确门级D端点；禁止get_regs通配别名；源计数/移位与第二同步级正常STA。',
 'create_clock -name clk_50 -period 20 -waveform {0 10} [get_ports {clk_50}]',
 'create_clock -name phy1_rgmii_rx_clk -period 8 -waveform {0 4} [get_ports {phy1_rgmii_rx_clk}]',
 'derive_clocks',
 f'set_clock_uncertainty -setup 1.0 [get_clocks {{{CTRL}}}]',
 f'set_clock_uncertainty -hold 0.05 [get_clocks {{{CTRL}}}]',
 *(f'set_false_path -from [get_ports {{{n}}}]' for n in ('key1','key2','key3')),
 '# 以下两个原网口跨域边界继承已验基座，不扩大新CTRL/PIXEL域边界。',
 'set_false_path -from [get_clocks {phy1_rgmii_rx_clk}] -to [get_clocks {clk_50}]',
 'set_false_path -from [get_clocks {clk_50}] -to [get_clocks {phy1_rgmii_rx_clk}]',
 '# 每项只定位首级物理FF的数据D端，避免连CE/源D一并豁免。',
 *(f'set_false_path -to [get_pins {{{p}}}]' for p in pins),
 '# ctrl_error_meta[2/3/6]为综合常量，无首级FF；独立查询与netlist核验记录此折叠。',
 '# pixel数据+toggle同沿发布，ctrl第4沿捕获；只给CTRL谱捕获D端MC4/3。',
    *(f'set_multicycle_path 4 -setup -end -from [get_clocks {{{PIXEL}}}] -to [get_pins {{{p}}}]' for p in dest),
    *(f'set_multicycle_path 3 -hold -end -from [get_clocks {{{PIXEL}}}] -to [get_pins {{{p}}}]' for p in dest),
 '# TF接口设计预算；板级实测待验。',
 f'set_input_delay -clock [get_clocks {{{CTRL}}}] -max 10.0 [get_ports {{sd_miso}}]',
 f'set_input_delay -clock [get_clocks {{{CTRL}}}] -min 0.0 [get_ports {{sd_miso}}]',
 f'set_output_delay -clock [get_clocks {{{CTRL}}}] -max 2.0 [get_ports {{sd_dclk sd_mosi sd_ncs}}]',
 f'set_output_delay -clock [get_clocks {{{CTRL}}}] -min 0.0 [get_ports {{sd_dclk sd_mosi sd_ncs}}]',
]
text = '\n'.join(lines) + '\n'
(TASK / 'project/src/constraints/eth_m6_master.sdc').write_text(text, encoding='utf-8')
record = dict(false_data_endpoints=pins, mcp_data_endpoints=dest, mcp_source_clock=PIXEL,
              optimized_constant_meta=[f'u_display/u_scan/ctrl_error_meta[{i}]' for i in (2,3,6)],
              sdc_sha256=hashlib.sha256((TASK / 'project/src/constraints/eth_m6_master.sdc').read_bytes()).hexdigest(), wildcard_register_queries=0)
(TASK / 'doc/output/ROUND2_SDC_EXPECTED.json').write_text(json.dumps(record, indent=2)+'\n', encoding='utf-8')
print(json.dumps({'false_D_count': len(pins), 'mcp_D_count': len(dest), 'sdc_sha256': record['sdc_sha256']}))
