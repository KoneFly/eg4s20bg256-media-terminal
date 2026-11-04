"""只接收板载CH340串口，不发送控制命令、不操作板卡下载。"""
from pathlib import Path
from datetime import datetime
import argparse,json,time,hashlib
from r68_codec import Parser
def main():
 import serial
 from serial.tools import list_ports
 p=argparse.ArgumentParser();p.add_argument('--port',default='AUTO');p.add_argument('--seconds',type=float,default=20);p.add_argument('--out',type=Path)
 a=p.parse_args();port=a.port
 if port=='AUTO':
  ports=[q for q in list_ports.comports() if q.vid is not None]
  if len(ports)!=1:raise SystemExit('请连接副板USB-UART Type-C；下载线不是串口。若有多个USB串口，用--port明确指定。当前USB端口：'+str([(q.device,q.description) for q in ports]))
  port=ports[0].device
 out=a.out or Path('captures')/datetime.now().strftime('run_%Y%m%d_%H%M%S');out.mkdir(parents=True,exist_ok=False)
 parser=Parser();last=None;first_faults=[];seen_first=set();start=time.monotonic();chunks=[];epoch=0;last_sequence=None;sequence_gaps=0
 with serial.Serial(port,1000000,timeout=.05,xonxoff=False,rtscts=False,dsrdtr=False) as rx,(out/'frames.jsonl').open('x',encoding='utf-8') as log:
  rx.set_buffer_size(rx_size=1048576,tx_size=8192)
  print('LISTENING',port,'1000000 8N1；保持大场地摆位/声源，KEY1复位→SW3+SW4→KEY2→KEY3；采集期间不要重复按键。',flush=True)
  while time.monotonic()-start<a.seconds:
   data=rx.read(16384)
   if not data:continue
   chunks.append(data)
   for f in parser.feed(data):
    if last_sequence is not None:
     delta=(f['sequence']-last_sequence)&65535
     if delta==0 or delta>=32768:epoch+=1
     elif delta>1:sequence_gaps+=delta-1
    last_sequence=f['sequence'];f['capture_epoch']=epoch
    f['host_seconds']=time.monotonic()-start;log.write(json.dumps(f,ensure_ascii=False)+'\n')
    status=(f['guard_state'],f['guard_reason'],f['controls'],f['fault_mask'])
    key=(epoch,f['fault_mask'],f['core_state'],f['operation'],f['mic1'],f['mic2'])
    novel_first=f['type']=='FIRST_FAULT' and key not in seen_first
    if (f['type']=='LIVE' and status!=last) or novel_first:
     print(json.dumps({k:f[k] for k in ['type','guard_name','guard_reason','faults','native_faults','core_state','operation','mic1','mic2','qualifiers']},ensure_ascii=False),flush=True)
     if f['type']=='LIVE':last=status
    if novel_first:seen_first.add(key);first_faults.append(f)
 raw=b''.join(chunks);(out/'capture.raw').write_bytes(raw)
 result={'port':port,'valid_frames':parser.frames,'CRC_errors':parser.crc_errors,'skipped_bytes':parser.skipped,'buffered_bytes':len(parser.buffer),'capture_epochs':epoch+1,'sequence_gaps':sequence_gaps,'raw_sha256':hashlib.sha256(raw).hexdigest(),'first_faults':first_faults,'serial_TX_used':False,'output':str(out),'interpretation':'只解CRC正确帧。FIRST_FAULT保存触发前同拍状态，LIVE显示后续响应；复位可能中断在途帧，原始数据保留。观察数据不自动证明ANC或硬件通过。'}
 (out/'summary.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n',encoding='utf-8');print(json.dumps(result,ensure_ascii=False,indent=2))
 if not parser.frames:raise SystemExit('未收到AC68有效帧；检查已加载R68诊断位及串口。')
if __name__=='__main__':main()
