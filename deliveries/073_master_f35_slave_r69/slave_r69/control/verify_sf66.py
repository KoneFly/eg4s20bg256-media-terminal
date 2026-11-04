"""S/F原函数→静态ROM→实际网表参数，逐字与逐段绑定；不宣称厂家功能仿真。"""
from pathlib import Path
import hashlib,json,re,sys
U=Path(__file__).resolve().parents[1]
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def params(s):return {family+'_'+i.upper():int(re.sub(r'[\s_]','',v),16 if base.lower()=='h' else 2) for family,i,base,v in re.findall(r"\.(INITP|INIT)_([0-9a-fA-F]{2})\s*\(\s*256'([hHbB])([0-9a-fA-F_\s]+)\s*\)",s)}
def cells(s):return [(m[2].lstrip('\\'),m[1]) for m in re.finditer(r'\bEG_PHY_BRAM\s*#\((.*?)\)\s*(\\[^\s()]+|[A-Za-z_]\w*)\s*\((.*?)\);',s,re.S)]
def source():
 text=(U/'rtl/anc_core_constants_r61.vh').read_text();words=[]
 for f in ['secondary_coefficient','feedback_coefficient']:
  part=text[text.index('function signed [17:0] '+f):];part=part[:part.index('endfunction')];assert 'default:'+f+"=18'sd0" in part
  row=[0]*256
  for a,v in re.findall(r"8'd(\d+):"+f+r"=18'sh([0-9a-fA-F]+)",part):
   n=int(v,16);n=n-(1<<18) if n&(1<<17) else n;assert -32768<=n<=32767;row[int(a)]=n
  words+=row
 result={}
 for lane,p in cells((U/'rtl/anc_sf_rom_r65.v').read_text()):
  if lane not in ['u_sf_lo','u_sf_hi']:continue
  values=params(p);assert len(values)==36 and all(values[f'INITP_{i:02X}']==0 for i in range(4))
  packed=sum(values[f'INIT_{i:02X}']<<(i*256) for i in range(32));shift=0 if lane.endswith('lo') else 8
  assert [(packed>>(8*i))&255 for i in range(1024)]==[(((v&65535)>>shift)&255) for v in words]+[0]*512
  result[lane]=values
 assert len(result)==2;return result
expected=source();net=Path(sys.argv[1]);actual=cells(net.read_text(errors='replace'));rows=[]
for lane,values in expected.items():
 found=[(n,p) for n,p in actual if n.split('/')[-1]==lane];assert len(found)==1,(lane,len(found))
 name,p=found[0];got=params(p);assert all(got.get(k)==v for k,v in values.items()),(lane,'INIT differs')
 cfg=dict(re.findall(r'\.(\w+)\s*\(\s*"([^"]+)"\s*\)',p))
 for k,v in {'DATA_WIDTH_A':'9','MODE':'DP8K','REGMODE_A':'NOREG','RESETMODE':'SYNC','RSTAMUX':'0'}.items():assert cfg.get(k)==v,(lane,k,cfg.get(k))
 rows.append({'lane':lane,'instance':name,'matched_segments':36})
print(json.dumps({'status':'PASS_SF_512_WORDS_72_SEGMENTS_BOUND_TO_ORIGINAL_FUNCTION','netlist':str(net),'netlist_sha256':sha(net),'source_function_sha256':sha(U/'rtl/anc_core_constants_r61.vh'),'source_ROM_sha256':sha(U/'rtl/anc_sf_rom_r65.v'),'lanes':rows,'limitation':'static initialization/configuration retention, not encrypted vendor simulation or board acceptance'},ensure_ascii=False,indent=2))
