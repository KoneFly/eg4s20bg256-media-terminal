from pathlib import Path
import hashlib,json,re,sys
net=Path(sys.argv[1]);text=net.read_text(errors='replace');rows=[]
for lane in ['u_decay_lo','u_decay_hi','u_num_lo','u_num_hi']:
 found=[m for m in re.finditer(r'\bEG_PHY_MULT18\s*#\((.*?)\)\s*(\\[^\s()]+|[A-Za-z_]\w*)\s*\((.*?)\);',text,re.S) if m[2].lstrip('\\').split('/')[-1]==lane]
 assert len(found)==1,(lane,len(found))
 m=found[0];cfg=dict(re.findall(r'\.(\w+)\s*\(\s*"([^"]+)"\s*\)',m[1]))
 for k,v in {'INPUTREGA':'DISABLE','INPUTREGB':'DISABLE','OUTPUTREG':'DISABLE','MODE':'MULT18X18C','SIGNEDAMUX':'1','SIGNEDBMUX':'1','SOURCEAMUX':'1','SOURCEBMUX':'1'}.items():assert cfg.get(k)==v,(lane,k,cfg.get(k))
 for port in ['acin','bcin']:assert re.search(r'\.'+port+r"\s*\(\s*18'b0{18}\s*\)",m[3]),(lane,port,'unused cascade must be tied zero')
 rows.append({'lane':lane,'instance':m[2].lstrip('\\'),'signed_direct_no_register_configuration':True,'direct_A_B_source_mux':1,'unused_cascade_inputs_deselected_and_tied_zero':True})
print(json.dumps({'status':'PASS_FOUR_EXACT_DSP_SIGNED_NO_REGISTER_CELLS','netlist':str(net),'netlist_sha256':hashlib.sha256(net.read_bytes()).hexdigest(),'lanes':rows,'scope':'static actual primitive identity/configuration, not encrypted vendor simulation'},ensure_ascii=False,indent=2))
