"""M1R单点修复签核与封存；新位仍待真板，不覆盖M1。"""
import hashlib,json,gzip,re,shutil
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
WORK=ROOT/'experiments/sdram_selftest_M1R'
RUN=WORK/'td_run/bit_m1r_final'
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
read=lambda p:json.loads(p.read_text(encoding='utf-8-sig'))
def save(p,obj):
 s=json.dumps(obj,ensure_ascii=False,indent=2)+'\n'
 if p.exists():assert p.read_text(encoding='utf-8')==s,'禁止覆盖封存'
 else:p.write_text(s,encoding='utf-8')
for name in ('M1_SDRAM_SELFTEST_EVIDENCE_INDEX_20261006.json','M1_BOARD_EVIDENCE_20261006.json'):
 for r in read(ROOT/'doc/output'/name)['files']:
  p=ROOT/r['path'];assert p.stat().st_size==r['bytes'] and sha(p)==r['sha256']
for r in read(ROOT/'doc/output/ROUND2_PREFLIGHT.json')['artifacts']:
 p=Path(r['path']);p=p if p.is_absolute() else ROOT/p
 content=p.read_bytes() if p.exists() else gzip.decompress(Path(str(p)+'.gz').read_bytes())
 assert len(content)==r['bytes'] and hashlib.sha256(content).hexdigest()==r['sha256']
for r in read(WORK/'doc/output/REFERENCE_ASSETS.json')['copied']:
 assert sha(Path(r['source']))==r['sha256']==sha(WORK/r['path'])
result=read(RUN/'RESULT.json');cdc=read(RUN/'CDC_AUDIT.json');native=read(RUN/'BIST_NATIVE_AUDIT.json')
assert result['timing_pass'] and result['measured']['mslices']<4900 and result['measured']['dsp']==0
assert cdc['status']=='PASS_PRECISE_SCOPE' and cdc['errors']==[]
assert native['status']=='PASS_NATIVE_BIST_AND_HARDMACRO_SOURCES' and len(native['physical_m1_snapshot_registers'])==321
manifest=read(RUN/'SOURCE_MANIFEST.json')
assert len(manifest['compiled_files'])==14
for r in manifest['files']:assert sha(WORK/'project/src'/r['path'])==r['sha256']==sha(RUN/'src'/r['path'])
route=WORK/'td_run/route_m1r_final'
assert manifest['signoff_cdc_sha256']==sha(route/'CDC_AUDIT.json')
assert manifest['signoff_native_bist_sha256']==sha(route/'BIST_NATIVE_AUDIT.json')
log=(RUN/'console.log').read_text(errors='replace')
assert all(s in log for s in ('report_route_status -drc','No multi-drive.','No abnormal timing path.'))
sources={p.name:p for p in (WORK/'project/src').rglob('*.v')}
sources.update({p.name:p for p in (WORK/'tb').rglob('*') if p.is_file()})
software=[]
for folder,marker in [('regression','M1_SDRAM_PASS'),('pages','M1_TOP_PAGES_PASS'),
                     ('saturation_old','OLD_M1_SATURATION_REPRO'),('saturation_fixed','M1R_SATURATION_PASS')]:
 sim=WORK/'sim'/folder
 for line in (sim/'SOURCE.sha256').read_text().splitlines():
  digest,name=line.split(None,1);name=name.strip();p=sources[name]
  if folder=='saturation_old' and name=='fdi_sdram_selftest.v':p=ROOT/'experiments/sdram_selftest_M1/project/src/rtl'/name
  assert sha(p)==digest==sha(sim/'src'/name)
 logs=sorted(sim.glob('scenario_*.log')) if folder=='regression' else [sim/'result.log']
 assert len(logs)==(11 if folder=='regression' else 1)
 assert all(marker in p.read_text() for p in logs)
 software.append(dict(name=folder,source_sha256=sha(sim/'SOURCE.sha256'),results=[dict(path=p.relative_to(WORK).as_posix(),sha256=sha(p)) for p in logs]))
assert all('--assert' in p.read_text() for p in (WORK/'sim').glob('run_*.sh') if p.name!='run_lint.sh')
lint=[]
for p in sorted((WORK/'sim/lint').glob('*.log')):
 text=p.read_text();assert '%Error' not in text
 warnings=len(re.findall('%Warning-',text))
 if p.name!='application.log':assert warnings==0
 lint.append(dict(path=p.relative_to(WORK).as_posix(),errors=0,warnings=warnings,sha256=sha(p)))
save(WORK/'doc/output/VALIDATION.json',dict(status='PASS_ASSERTED_REGRESSION_AND_SATURATION_BOUNDARY',
 assertions_enabled=True,software=software,lint=lint,application_warnings='OPEN',old_repro_accelerated=True,
 limits='65534边界注入后由真实ack推进饱和；非真实1秒/10分钟物理长期测量。'))
bit=RUN/'fdi_sdram_selftest_top.bit';assert sha(bit)==result['bit']['sha256']
target=ROOT/'deliverables'/f'M6_FDI_M1R_20261006_{sha(bit)[:8].upper()}.bit'
if target.exists():assert sha(target)==sha(bit)
else:shutil.copy2(bit,target)
delivery=ROOT/'deliverables/M1R_MANIFEST.json'
save(delivery,dict(status='DIAGNOSTIC_PENDING_BOARD',bit_sha256=sha(bit),bit_bytes=bit.stat().st_size,
 bit_path=target.relative_to(ROOT).as_posix(),version_decimal=5467,measured=result['measured'],sta=result['sta'],
 source_manifest_sha256=sha(RUN/'SOURCE_MANIFEST.json'),cdc_sha256=sha(RUN/'CDC_AUDIT.json'),
 native_audit_sha256=sha(RUN/'BIST_NATIVE_AUDIT.json'),parent_board_sha256=sha(ROOT/'doc/output/M1_BOARD_RESULT_20261006.json')))
report=ROOT/'doc/output/M1R_REPORT_20261006.md'
text=f'''# M1R刷新计数饱和误报修复（2026-10-06）

状态：软件及原生TD通过，修订位真板待测。旧M1封存及报告不覆盖。

旧M1 BDDEBAE7真实板测：d0=5466、d1=255、d2=43528、d3=0、d4=4、d5=1、d6=0、d7=65280；P1=16640、P2=128、P3=65535、P4=16639，彩条正常。0xAA08表示请求方HOLD(5)、引擎IDLE(10)、错误码8；首通过已完成，128次写及16640个正确读字，未见数据不匹配。当前错误来自新增自检判据，不能判成SDRAM硬件或TF错误，也不能签完整FDI通过。

根因：refreshes为饱和16位诊断计数，到65535后不再增长。旧HOLD以refreshes==refresh_base作为缺少刷新判据，约1秒后必然误报。旧11项回归最长约20ms，漏掉该边界，这是本轮修正的验证缺口。

单点修复：计数仍饱和，不回绕；新增1位refresh_seen_in_hold，进入每个保持窗口清零，窗口内收到真实refresh_ack置1；窗口结束以该位或当拍ack判断刷新活性。删除无用refresh_base。冻结SDRAM命令引擎、刷新定时器、50MHz/180°时钟、DQ捕获、SPI及其他功能均未改；顶层仅另设版本05467。没有绕过刷新或关闭错误8。

旧代码边界注入65534后，由真实原引擎ack推进到65535，模型精确复现flags=255/code=43528/address=040000。修复代码在饱和后继续巡检而无误报；随后真正屏蔽保持窗口ack，仍正确报8。原11项功能/故障、实际顶层16页映射回归全部通过，实际开启--assert，编译输入及SOURCE.sha256绑定最终源。边界注入缩短仿真时间，不宣称真实≥1秒或≥10分钟硬件验收。

原生TD最终：{result['measured']['mslices']}/4900 MSlice，{result['measured']['lut']} LUT、{result['measured']['reg']} REG、10×9K/0×32K、0 DSP/3 PLL；Setup {result['sta']['setup_wns_ns']:+.3f}ns、Hold {result['sta']['hold_wns_ns']:+.3f}ns，0/0违例，最终告警{result['warnings']['count']}条。9个首级查询及219个动态结果MC4/3精确审计通过，别名OPEN=0；另外9个地址位原生buf证明恒零。原生计数58位、参考LOGIC锥29位、321位M1快照寄存器及32位DQ I/O捕获核验通过。布局阶段违例/别名过程告警原文保留；物理映射器仅补充真实非转义二位总线Q语法解析，未扩大约束范围。route_m1r首次准备在映射完成前退出，未启动TD；成功阶段route_m1r_final/bit_m1r_final。

应用lint {next(r['warnings'] for r in lint if 'application' in r['path'])}条告警OPEN、0错误；新请求方/捕获模块默认严格lint各0/0。旧M1的403项封存、板测补充及81项保护资产校验一致。完整M6-FDI启动故障根因仍待分层恢复定位。

主板烧 **{target.name}**（{bit.stat().st_size}B），SHA256：`{sha(bit)}`。副板7175ECC3及TF卡布局不变，HDMI-B。

复位KEY1（本板丝印KEY2）约1秒后放开，等2秒，SW0=1，每页等0.3秒读取：**d0=05467，d1=00127，d2=00000，d3=00255，d4=00024，d5=d6=23130，d7=65280**。SW0=0：P1=256、P2=128、P3首次通过时刷新数（模型513，要求有刷新）、P4=16639、P5=P6=50597。以上为冻结首通过结果，持续巡检计数不在正常P页实时更新。

请先确认2秒读数及彩条，再持续≥10分钟复读d1/d2/P4并记录彩条，最后KEY1复位复现。异常就保持运行并记录全页；不代签板测。本位通过后进入原TF读链。板测状态PENDING_M1R_BOARD_TEST，未自动烧录、未写BURN_INDEX。
'''
if report.exists():assert report.read_text(encoding='utf-8')==text
else:report.write_text(text,encoding='utf-8')
paths=[p for p in WORK.rglob('*') if p.is_file() and 'obj_dir' not in p.parts and '__pycache__' not in p.parts]
paths += [target,delivery,report,Path(__file__).resolve(),ROOT/'scripts/prepare_m1r.py',
          ROOT/'doc/brief/BOARD_DIAGNOSTIC_PROGRESS_M1R_20261006.md']
save(ROOT/'doc/output/M1R_EVIDENCE_INDEX_20261006.json',dict(status='SEALED_DIAGNOSTIC_NATIVE_AND_SOFTWARE',
 hardware_status='PENDING_M1R_BOARD_TEST',prior_board_evidence_sha256=sha(ROOT/'doc/output/M1_BOARD_EVIDENCE_20261006.json'),
 bit_sha256=sha(bit),files=[dict(path=p.relative_to(ROOT).as_posix(),bytes=p.stat().st_size,sha256=sha(p)) for p in sorted(set(paths))]))
print(json.dumps(dict(bit=target.as_posix(),sha256=sha(bit),measured=result['measured'],sta=result['sta']),ensure_ascii=False))
