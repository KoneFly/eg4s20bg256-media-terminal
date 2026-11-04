"""独立重建四槽PCM并注入布局/CRC/簇链错误；不接触真实卡。"""
from pathlib import Path
import contextlib
import hashlib
import importlib.util
import io
import json
import struct
import tempfile
from types import SimpleNamespace

TASK = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('card_tool', TASK / 'scripts/make_controlled_card.py')
tool = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tool)
checks = []

def reject(name, action):
    try:
        action()
    except ValueError as error:
        checks.append(dict(name=name, result='PASS_REJECT', reason=str(error)))
    else:
        raise AssertionError(name)

with tempfile.TemporaryDirectory(prefix='fdi_controlled_card_') as scratch:
    root = Path(scratch)
    sizes = [2, 512, 514, 1920000]
    tracks = []
    for i, size in enumerate(sizes):
        p = root / f'synthetic_pcm{i}.pcm'
        p.write_bytes(bytes((j * (i * 2 + 1) + i + 7) % 256 for j in range(size)))
        tracks.append(p)
    image = root / 'four_pcm.img'
    args = SimpleNamespace(output=image, bmp=TASK / 'project/assets/PCB.BMP', pcm=tracks)
    with contextlib.redirect_stdout(io.StringIO()):
        tool.build(args)
    result = tool.verify(image)
    for p, actual in zip(tracks, result['pcm_files']):
        assert actual['sha256'] == hashlib.sha256(p.read_bytes()).hexdigest()
    checks.append(dict(name='four_PCM_exact_reconstruction_boundary_sizes', result='PASS', bytes=sizes,
                       image_sha256=result['image_sha256']))
    reject('refuse_existing_output', lambda: tool.build(args))
    odd = root / 'odd.pcm'; odd.write_bytes(b'abc')
    reject('odd_PCM', lambda: tool.build(SimpleNamespace(output=root / 'odd.img', bmp=args.bmp, pcm=[odd])))
    riff = root / 'header.pcm'; riff.write_bytes(b'RIFF'+bytes(20))
    reject('RIFF_PCM', lambda: tool.build(SimpleNamespace(output=root / 'riff.img', bmp=args.bmp, pcm=[riff])))
    def changed(offset, data, name):
        with image.open('r+b') as f:
            f.seek(offset); before = f.read(len(data)); f.seek(offset); f.write(data)
        reject(name, lambda: tool.verify(image))
        with image.open('r+b') as f:
            f.seek(offset); f.write(before)
    changed(64*512+100, b'\xff', 'bad_label_identity_CRC')
    changed(454, struct.pack('<I', 1024), 'PCM_partition_invades_label_reservation')
    manifest = json.loads(image.with_suffix('.img.json').read_text())
    data_lba, fatsz = manifest['pcm_data_lba'], manifest['fat_sectors']
    changed(data_lba*512+32+26, struct.pack('<H', 3), 'PCM_cross_file_cluster_overlap')
    # 两FAT副本同时造回环，防止仅靠副本比较检出。
    offsets = [(2048+32+i*fatsz)*512+3*4 for i in range(2)]
    before = []
    with image.open('r+b') as f:
        for offset in offsets:
            f.seek(offset); before.append(f.read(4)); f.seek(offset); f.write(struct.pack('<I',3))
    reject('PCM_cluster_cycle_both_FATs', lambda: tool.verify(image))
    with image.open('r+b') as f:
        for offset, data in zip(offsets, before):
            f.seek(offset); f.write(data)
    assert tool.verify(image)['image_sha256'] == result['image_sha256']
out = TASK / 'sim/round2_card/TOOL_VALIDATION.json'
out.write_text(json.dumps(dict(status='PASS', synthetic_PCM_only=True, hardware_card_written=False, checks=checks), indent=2)+'\n')
print(f'PASS card tool: {len(checks)} checks, four PCM slots reconstructed; no physical card writes')
