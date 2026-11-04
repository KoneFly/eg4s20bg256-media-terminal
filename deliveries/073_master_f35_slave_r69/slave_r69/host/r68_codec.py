"""AC68只读诊断帧；CRC由Python标准库独立计算。"""
import binascii,struct,json
from pathlib import Path
ROM_EXPECTED=json.loads(Path(__file__).with_name('expected_rom.json').read_text())
MAGIC=b'AC68';SIZE=26
FAULT_NAMES=['native_fault','divider_collision','weight_RAM','actuator_RAM','SOS_RAM','reference_RAM','gradient_RAM','arithmetic_dispatch','dot_length','dot_overrun','ratio_overflow','monitor_overrun','sample_before_ready','deadline','dot_context','dot_range','SOS_RAM_not_valid','SOS_clipped','SOS_context','SOS_range','scalar_overflow','scalar_context','power_range','divide_zero','output_range','weight_fault','weight_context','weight_overflow','primary_plus_virtual_range','kernel_fault_latched','guard_FAULT','guard_WAIT_SOURCE']
GUARD_NAMES=['IDLE','LEARN','WAIT_BAND','RAMP','RUN','VERIFY_OFF','FAULT','WAIT_SOURCE']
NATIVE_NAMES=['MIC1_native_clip','MIC2_native_clip','MIC1_frontend_clip','MIC2_frontend_clip','frontend_overlap','audio_pair_overrun','actuator_fault']
def decode(raw):
    assert len(raw)==SIZE and raw[:4]==MAGIC and raw[7]==16
    assert binascii.crc_hqx(raw[:24],0xffff)==int.from_bytes(raw[24:26],'little')
    b=raw[8:24]
    def num(offset,size,signed=False):return int.from_bytes(b[offset:offset+size],'little',signed=signed)
    mask=num(4,4);step=num(8,2);native=b[10];q=b[11];controls=b[1]
    state=b[3]&15;reason=b[3]>>4
    result={'sequence':int.from_bytes(raw[4:6],'little'),'type':'FIRST_FAULT' if raw[6]==1 else 'LIVE','switches':b[0],'controls':controls,'led_mask':b[2],
      'guard_state':state,'guard_name':GUARD_NAMES[state] if state<8 else 'UNKNOWN','guard_reason':reason,
      'fault_mask':mask,'faults':[n for i,n in enumerate(FAULT_NAMES) if mask&(1<<i)],'core_state':step>>5,'operation':step&31,
      'native_flags':native,'native_faults':[n for i,n in enumerate(NATIVE_NAMES) if native&(1<<i)],
      'qualifiers':{'band':bool(q&1),'virtual_ready':bool(q&2),'reference_ok':bool(q&4),'guard_adapt':bool(q&8),'frame_adapt':bool(q&16),'monitor_busy':bool(q&32),'RAM_ready':bool(q&64),'core_ready':bool(q&128)},
      'mic1':num(12,2,True),'mic2':num(14,2,True)}
    return result
class Parser:
    def __init__(self):self.buffer=bytearray();self.crc_errors=0;self.skipped=0;self.frames=0
    def feed(self,data):
        self.buffer.extend(data);out=[]
        while True:
            k=self.buffer.find(MAGIC)
            if k<0:
                drop=max(0,len(self.buffer)-3);self.skipped+=drop;del self.buffer[:drop];break
            if k:self.skipped+=k;del self.buffer[:k]
            if len(self.buffer)<SIZE:break
            raw=bytes(self.buffer[:SIZE])
            if raw[7]!=16 or raw[6]>1 or binascii.crc_hqx(raw[:24],0xffff)!=int.from_bytes(raw[24:],'little'):
                self.crc_errors+=1;self.skipped+=1;del self.buffer[0];continue
            out.append(decode(raw));self.frames+=1;del self.buffer[:SIZE]
        return out
