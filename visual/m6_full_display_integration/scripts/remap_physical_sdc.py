"""由真实Slice Q定位FF数据端，并用捕获时钟过滤LUT输入别名的源域扇出。"""
from pathlib import Path
import hashlib
import json
import re
import sys

TASK = Path(__file__).resolve().parent.parent
run = Path(sys.argv[1]).resolve()
step = sys.argv[2]
expected = json.loads((TASK/'doc/output/ROUND2_SDC_EXPECTED.json').read_text())
text = (run/f'{step}_netlist.v').read_text(errors='replace')
wanted = expected['false_data_endpoints'] + expected['mcp_data_endpoints']

def semantic(pin):
    return pin.removesuffix('.d').replace('_reg[','[').removesuffix('_reg')

by_signal = {semantic(p): p for p in wanted}
mapped = {}
pattern = r'\b(EG_PHY_[ML]SLICE)\s*#\(\s*(.*?)\)\s+(?:\\)?(\S+)\s+\((.*?)\);'
for primitive, params, inst, ports in re.findall(pattern, text, re.S):
    q = re.search(r'\.q\((.*?)\)', ports, re.S)
    if not q:
        continue
    raw = q[1].strip()
    if raw.startswith('{') and raw.endswith('}'):
        nets = raw[1:-1].split(',')
    else:
        span = re.fullmatch(r'\\(\S+)\s+\[(\d+):(\d+)\]',raw)
        if not span or int(span[2])-int(span[3])!=1:
            continue
        nets = [f'\\{span[1]}[{i}]' for i in (int(span[2]),int(span[3]))]
    if len(nets) != 2:
        continue
    for index, net in enumerate(reversed(nets)):
        signal = re.sub(r'\s+', '', net).removeprefix('\\')
        if signal not in by_signal:
            continue
        original = by_signal[signal]
        sd = re.search(rf'\.REG{index}_SD\("(.*?)"\)', params)
        if not sd:
            raise ValueError(f'目标FF缺少数据选择: {original}')
        if sd[1] == 'MI':
            data_pins = [f'{inst}.mi[{index}]']
        elif sd[1] == 'F' and original in expected['false_data_endpoints']:
            # 首级前的组合选择被吸入LUT；只接受同半片独立LUT。
            # TD对LUT输入的-to会扩展扇出；后面必须同时指定接收时钟和
            # -through此数据引脚，实际范围再由原生例外端点报告核对。
            if primitive == 'EG_PHY_LSLICE':
                init_f = re.search(rf'\.INIT_LUTF{index}\((.*?)\)', params)
                init_g = re.search(rf'\.INIT_LUTG{index}\((.*?)\)', params)
                mux = re.search(rf'\.LSFMUX{index}\("(.*?)"\)', params)
                if not init_f or not init_g or not mux or mux[1] not in ('LUTF','FUNC5'):
                    raise ValueError(f'首级组合数据不是独立同半片LUT: {original}')
                init_values = [init_f[1],init_g[1]] if mux[1]=='FUNC5' else [init_f[1]]
            elif not re.search(rf'\.INIT_LUT{index}\(',params):
                raise ValueError(f'MSlice首级LUT缺少真值表: {original}')
            else:
                init_values = [re.search(rf'\.INIT_LUT{index}\((.*?)\)', params)[1]]
            tables = [int(value.split("'")[1][1:], 2 if "'b" in value else 16) for value in init_values]
            dependencies = [port for bit,port in enumerate(('a','b','c','d'))
                            if any(any(((table>>n)&1)!=((table>>(n^(1<<bit)))&1) for n in range(16)) for table in tables)]
            if len(tables)==2 and tables[0]!=tables[1]:
                dependencies.append('e')
            data_pins = []
            for port in dependencies:
                connected = re.search(rf'\.{port}\((.*?)\)', ports, re.S)
                if connected:
                    expression = connected[1].strip()
                    wires = expression[1:-1].split(',') if expression.startswith('{') else []
                    span = re.fullmatch(r'\\(\S+)\s+\[(\d+):(\d+)\]',expression)
                    variable = span and int(span[2])-int(span[3])==1
                    if variable or (len(wires)==2 and not wires[1-index].strip().startswith('open_') and "'" not in wires[1-index]):
                        data_pins.append(f'{inst}.{port}[{index}]')
            if not data_pins:
                raise ValueError(f'首级LUT没有数据输入: {original}')
        else:
            raise ValueError(f'不接受此数据选择映射: {original}: {sd[1]}')
        if original in mapped:
            raise ValueError(f'目标Q存在重复物理FF: {original}')
        mapped[original] = dict(original_pin=original, physical_pins=data_pins,
                                q_signal=signal, primitive=primitive, register_index=index, data_mux=sd[1],
                                clock_net=re.search(r'\.clk\((.*?)\)',ports,re.S)[1].strip().removeprefix('\\'))
missing = set(wanted)-mapped.keys()
if missing:
    raise ValueError(f'未映射目标Q: {sorted(missing)}')
physical = (TASK/'project/src/constraints/eth_m6_master.sdc').read_text(encoding='utf-8')
for p in wanted:
    item = mapped[p]
    if item['data_mux']=='F':
        clocks={'u_display/pixel_clk':expected['mcp_source_clock'],
                'u_display/u_label_store/u_check_buffer/wr_clk':'u_clk/u_pll_0/pll_inst.clkc[1]',
                'u_decimal/clk':'clk_50'}
        if item['clock_net'] not in clocks:
            raise ValueError(f'未知首级捕获时钟: {item}')
        item['capture_clock']=clocks[item['clock_net']]
        line = f'set_false_path -to [get_pins {{{p}}}]'
        physical = physical.replace(line, '\n'.join(f'set_false_path -to [get_clocks {{{item["capture_clock"]}}}] -through [get_pins {{{end}}}]' for end in item['physical_pins']))
    elif len(item['physical_pins']) == 1:
        physical = physical.replace('{'+p+'}', '{'+mapped[p]['physical_pins'][0]+'}')
    else:
        line = f'set_false_path -to [get_pins {{{p}}}]'
        physical = physical.replace(line, '\n'.join(f'set_false_path -to [get_pins {{{end}}}]' for end in mapped[p]['physical_pins']))
physical = '# 由真实物理MSlice Q/REGn_SD=MI逐FF映射；其他FF/CE/SR正常STA。\n'+physical
target = run/'physical.sdc'
target.write_text(physical, encoding='utf-8', newline='\n')
record = dict(false_data_endpoints=[end for p in expected['false_data_endpoints'] for end in mapped[p]['physical_pins']],
              mcp_data_endpoints=[end for p in expected['mcp_data_endpoints'] for end in mapped[p]['physical_pins']],
              mcp_source_clock=expected['mcp_source_clock'], sdc_sha256=hashlib.sha256(target.read_bytes()).hexdigest(),
              source_netlist_sha256=hashlib.sha256((run/f'{step}_netlist.v').read_bytes()).hexdigest(),
              logical_sdc_sha256=expected['sdc_sha256'], mapping=list(mapped.values()), wildcard_register_queries=0)
(run/'PHYSICAL_SDC_EXPECTED.json').write_text(json.dumps(record, indent=2)+'\n')
print(json.dumps({'mapped_false':len(record['false_data_endpoints']), 'mapped_mcp':len(record['mcp_data_endpoints']), 'sha256':record['sdc_sha256']}))
