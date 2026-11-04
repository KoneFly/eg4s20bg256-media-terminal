"""四级缩至两级的首轮候选；A0未烧且Hold未过，不放宽原0/0门禁。"""
from pathlib import Path
import difflib
import hashlib
import json
import shutil

BASE=Path(__file__).resolve().parent.parent
A0=BASE/'experiments/board_0x46_A0_work'
OUT=BASE/'experiments/board_0x46_A2_work'
if OUT.exists():raise SystemExit('Refuse overwrite')
OUT.mkdir(parents=True)
for directory in ('project','scripts','tb','sim/integration_lint'):
    shutil.copytree(A0/directory,OUT/directory,ignore=shutil.ignore_patterns('__pycache__'))
(OUT/'doc/output').mkdir(parents=True)
shutil.copy2(BASE/'doc/output/ROUND2_SDC_EXPECTED.json',OUT/'doc/output/ROUND2_SDC_EXPECTED.json')
for name in ('run_round2_loader.sh','run_round2_lint.sh','run_probe_snapshot.sh'):
    shutil.copy2(A0/'sim'/name,OUT/'sim'/name)
for p in (OUT/'scripts').iterdir():
    if p.is_file():
        text=p.read_text(encoding='utf-8').replace('A0','A2').replace('a0','a2').replace('05460','05462')
        p.write_text(text,encoding='utf-8',newline='\n')
for p in (OUT/'sim').rglob('*.sh'):
    p.write_text(p.read_text(encoding='utf-8').replace('a0','a2'),encoding='utf-8',newline='\n')
sources=OUT/'sim/integration_lint/sources.f'
sources.write_text(sources.read_text(encoding='utf-8').replace('board_0x46_A0_work','board_0x46_A2_work'),encoding='utf-8')
original=(BASE/'project/src/rtl/fdi_label_store.v').read_text(encoding='utf-8')
start=original.index(' // MISO恒等缓冲');end=original.index(' reg init_start',start)
buffers=original[start:end].replace('wire [4:0] miso_hold','wire [2:0] miso_hold').replace('miso_stage<4','miso_stage<2')
buffers=buffers.replace('// MISO恒等缓冲保留为实际LUT级，补偿PAD到CTRL捕获端的物理Hold；无新增拍。',
                        '// A2单点实验：原四级MISO恒等缓冲缩为两级；无新增拍。')
store=OUT/'project/src/rtl/fdi_label_store.v'
text=store.read_text(encoding='utf-8')
text=text.replace(' // A0单点实验：PAD直达原采样端，不加入缓冲或新拍。\n',buffers)
assert 'miso_stage<2' in text
text=text.replace('.spi_miso(sd_miso)','.spi_miso(miso_hold[2])').replace('.sd_miso(sd_miso)','.sd_miso(miso_hold[2])')
store.write_text(text,encoding='utf-8',newline='\n')
top=OUT/'project/src/rtl/v9_udp_m6_master_top.v'
top.write_text(top.read_text(encoding='utf-8').replace('A0','A2').replace("16'd5460","16'd5462"),encoding='utf-8',newline='\n')
guard=json.loads((A0/'doc/output/SOURCE_GUARD.json').read_text(encoding='utf-8'))
guard['experiment']='A2: four MISO buffers reduced to two, read-only pre-error snapshot'
diff=[]
for row in guard['source_files']:
    new=OUT/'project/src'/row['path'];old=BASE/'project/src'/row['path']
    row['after_sha256']=hashlib.sha256(new.read_bytes()).hexdigest()
    row['changed']=row['before_sha256']!=row['after_sha256']
    if row['changed']:diff.extend(difflib.unified_diff(old.read_text(encoding='utf-8').splitlines(True),new.read_text(encoding='utf-8').splitlines(True),fromfile='R2/'+row['path'],tofile='A2/'+row['path']))
(OUT/'doc/output/SOURCE_GUARD.json').write_text(json.dumps(guard,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
(OUT/'doc/output/SOURCE_DIFF.patch').write_text(''.join(diff),encoding='utf-8')
# 单点恢复核验按缩减后的原缓冲块，而非零缓冲原型。
validator=OUT/'scripts/validate_probe_sources.py'
text=validator.read_text(encoding='utf-8')
start=text.index("start=old.index(' // MISO恒等缓冲')")
end=text.index("actual=(PROBE/relative)",start)
text=text[:start]+'''single=old.replace('wire [4:0] miso_hold','wire [2:0] miso_hold').replace('miso_stage<4','miso_stage<2')
single=single.replace('miso_hold[4]','miso_hold[2]').replace('// MISO恒等缓冲保留为实际LUT级，补偿PAD到CTRL捕获端的物理Hold；无新增拍。','// A2单点实验：原四级MISO恒等缓冲缩为两级；无新增拍。')
'''+text[end:]
text=text.replace('加载功能正文除去MISO缓冲后必须原样一致','加载功能正文仅允许MISO四级缩为两级')
text=text.replace('MISO four buffers removed','MISO four buffers reduced to two')
validator.write_text(text,encoding='utf-8',newline='\n')
doc=(A0/'doc/output/BOARD_PROBE_A0.md').read_text(encoding='utf-8').replace('A0','A2').replace('05460','05462')
doc=doc.replace('去掉原 MISO 的四级 EG_LOGIC_BUF，直接接原 SPI 采样端','原 MISO 四级 EG_LOGIC_BUF 缩减为两级')
(OUT/'doc/output/BOARD_PROBE_A2.md').write_text(doc,encoding='utf-8')
(OUT/'doc/output/PROBE_CHOICE.md').write_text('A0零缓冲未上板：无路由冲突的测量为4683 MSlice、Setup +0.288ns/0违例、Hold -0.532ns/2违例，全部来自MISO读端。按用户允许的缩减路径，首轮最终候选转为A2（四级至两级），仍保留故障前观测；不免除正式0/0门禁。不依据模型判断根因。\n',encoding='utf-8')
print(OUT)
