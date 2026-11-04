"""独立BMP→受控扇区/物理RGB565黄金；不引用加载RTL或PC制作器解码。"""
from pathlib import Path
import json
import hashlib
import struct
import zlib

task = Path(__file__).resolve().parents[2]
out = task / 'sim/round2_loader'
out.mkdir(parents=True, exist_ok=True)
bmp = (task / 'project/assets/PCB.BMP').read_bytes()
image = bytearray(4096 * 512)
# 分区字段和PCM区带明显哨兵；加载器只能请求[64,1865)，不解释任何文件系统。
image[:512] = bytes([0xA7]) * 512
struct.pack_into('<II', image, 454, 2048, 260096)
image[510:512] = b'\x55\xaa'
image[2048*512:] = bytes([0x5C]) * (2048 * 512)
image[64*512:64*512+len(bmp)] = bmp
labels = bytearray(614400)
for i in range(307200):
    b, g, r = bmp[54+3*i:57+3*i]
    pixel = (r & 0xF8) * 256 + (g & 0xFC) * 8 + b // 8
    struct.pack_into('<H', labels, 2*i, pixel)
assert zlib.crc32(bmp) == 0x47E2A01D and zlib.crc32(labels) == 0xA1E4D4E1
(out / 'controlled_image.memh').write_text('\n'.join(image[i:i+4].hex() for i in range(0, len(image), 4)) + '\n', encoding='ascii')
(out / 'label_words.memh').write_text('\n'.join(f'{v:08x}' for (v,) in struct.iter_unpack('<I', labels)) + '\n', encoding='ascii')
manifest = {'label_lba': 64, 'end_lba_exclusive': 1865, 'bmp_bytes': len(bmp),
            'physical_words': 153600, 'bmp_sha256': hashlib.sha256(bmp).hexdigest(),
            'file_crc32': f'{zlib.crc32(bmp):08X}', 'label_crc32': f'{zlib.crc32(labels):08X}'}
(out / 'FIXTURE.json').write_text(json.dumps(manifest, indent=2)+'\n', encoding='utf-8')
print(json.dumps(manifest))
