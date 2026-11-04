"""制作/检查M6受控卡镜像：分区前固定BMP，FAT32分区内保留052裸PCM契约。"""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import zlib

SECTOR = 512
LABEL_LBA = 64
LABEL_BYTES = 921654
LABEL_SECTORS = 1801
PART_LBA = 2048
DISK_SECTORS = 262144  # 128MiB镜像；保留足够FAT32簇数，不声明支持任意现存卡。
BMP_SHA = "938219a71dde50745624d8821554cca0822c748149b2e3f9cd8d31eccfe26516"
BMP_CRC = 0x47E2A01D
LABEL_CRC = 0xA1E4D4E1

def crc_labels(bmp):
    labels = bytearray(614400)
    for i in range(307200):
        b, g, r = bmp[54 + i * 3:57 + i * 3]
        struct.pack_into('<H', labels, i * 2, ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3))
    return zlib.crc32(labels)

def checked_bmp(p):
    bmp = p.read_bytes()
    if len(bmp) != LABEL_BYTES or hashlib.sha256(bmp).hexdigest() != BMP_SHA:
        raise ValueError("BMP不等于本包冻结黄金，拒绝制作")
    if zlib.crc32(bmp) != BMP_CRC or crc_labels(bmp) != LABEL_CRC:
        raise ValueError("冻结文件/物理标签CRC不匹配")
    return bmp

def build(args):
    output = args.output.resolve()
    if output.suffix.lower() not in ('.img', '.bin') or str(output).startswith(('\\\\.\\', '\\\\?\\')):
        raise ValueError('只允许普通.img/.bin镜像文件，不允许直接写物理设备')
    if output.exists():
        raise ValueError("拒绝覆盖已有镜像；请使用新输出文件名")
    bmp = checked_bmp(args.bmp)
    tracks = []
    for slot, p in enumerate(args.pcm, 1):
        data = p.read_bytes()
        if not data or len(data) % 2 or len(data) > 1920000 or data[:4] in (b'RIFF', b'RF64', b'RIFX'):
            raise ValueError(f"WAV{slot}: 要求无RIFF头、16bit LE mono裸PCM，非零偶数长度，最长20秒/1920000B")
        tracks.append((slot, p.resolve(), data))
    total = DISK_SECTORS - PART_LBA
    reserved, nfats, fat_sectors = 32, 2, 1
    # 单扇区簇兼容052的8192簇上限；20秒仅3750簇。
    while True:
        clusters = total - reserved - nfats * fat_sectors
        required = ((clusters + 2) * 4 + SECTOR - 1) // SECTOR
        if fat_sectors >= required:
            break
        fat_sectors = required
    first_data = PART_LBA + reserved + nfats * fat_sectors
    assert LABEL_LBA + LABEL_SECTORS <= PART_LBA and clusters >= 65525
    mbr = bytearray(SECTOR)
    mbr[446:462] = struct.pack('<B3sB3sII', 0, b'\xfe\xff\xff', 0x0C, b'\xfe\xff\xff', PART_LBA, total)
    mbr[510:512] = b'\x55\xaa'
    boot = bytearray(SECTOR)
    boot[0:11] = b'\xeb\x58\x90M6FDI2  '
    struct.pack_into('<HBHBHHBHHHIII', boot, 11, SECTOR, 1, reserved, nfats, 0, 0, 0xF8, 0, 63, 255, PART_LBA, total, fat_sectors)
    struct.pack_into('<HHIHH', boot, 40, 0, 0, 2, 1, 6)
    boot[64:67] = b'\x80\x00\x29'
    struct.pack_into('<I', boot, 67, 0x4D364632)
    boot[71:82], boot[82:90], boot[510:512] = b'M6_CTRLTF  ', b'FAT32   ', b'\x55\xaa'
    fat, root = bytearray(fat_sectors * SECTOR), bytearray(SECTOR)
    for c, value in ((0, 0x0FFFFFF8), (1, 0x0FFFFFFF), (2, 0x0FFFFFFF)):
        struct.pack_into('<I', fat, c * 4, value)
    next_cluster, files = 3, []
    for slot, p, data in tracks:
        count = (len(data) + SECTOR - 1) // SECTOR
        for c in range(next_cluster, next_cluster + count):
            struct.pack_into('<I', fat, c * 4, c + 1 if c < next_cluster + count - 1 else 0x0FFFFFFF)
        entry = (slot - 1) * 32
        root[entry:entry + 11], root[entry + 11] = f'WAV{slot}    WAV'.encode('ascii'), 0x20
        struct.pack_into('<H', root, entry + 20, next_cluster >> 16)
        struct.pack_into('<HI', root, entry + 26, next_cluster & 65535, len(data))
        files.append(dict(name=f'WAV{slot}.WAV', source=str(p), bytes=len(data), first_cluster=next_cluster,
                          first_lba=first_data + next_cluster - 2, clusters=count, sha256=hashlib.sha256(data).hexdigest()))
        next_cluster += count
    info = bytearray(SECTOR)
    struct.pack_into('<I', info, 0, 0x41615252)
    struct.pack_into('<III', info, 484, 0x61417272, clusters - (next_cluster - 2), next_cluster)
    struct.pack_into('<I', info, 508, 0xAA550000)
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open('xb') as f:
        f.truncate(DISK_SECTORS * SECTOR)
        def put(lba, data):
            f.seek(lba * SECTOR)
            f.write(data)
        put(0, mbr)
        put(LABEL_LBA, bmp + bytes(LABEL_SECTORS * SECTOR - len(bmp)))
        for b in (0, 6):
            put(PART_LBA + b, boot)
            put(PART_LBA + b + 1, info)
        for i in range(nfats):
            put(PART_LBA + reserved + i * fat_sectors, fat)
        put(first_data, root)
        for record, (_, _, data) in zip(files, tracks):
            put(record['first_lba'], data)
    manifest = dict(format='M6-FDI controlled TF v2', image_bytes=DISK_SECTORS * SECTOR,
                    label_lba=LABEL_LBA, label_end_lba_exclusive=LABEL_LBA + LABEL_SECTORS,
                    label_bytes=LABEL_BYTES, label_file_sha256=BMP_SHA, file_crc32=f'{BMP_CRC:08X}',
                    physical_label_crc32=f'{LABEL_CRC:08X}', pcm_partition_lba=PART_LBA,
                    pcm_partition_sectors=total, sectors_per_cluster=1, fat_sectors=fat_sectors,
                    pcm_data_lba=first_data, pcm_files=files, hardware_card_written=False)
    result = verify(output)
    manifest['image_sha256'] = result['image_sha256']
    output.with_suffix(output.suffix + '.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(result, ensure_ascii=False))

def verify(image):
    with image.open('rb') as f:
        mbr = f.read(SECTOR)
        part, length = struct.unpack_from('<II', mbr, 454)
        if mbr[510:512] != b'\x55\xaa' or mbr[450] != 0x0C or part != PART_LBA or length != DISK_SECTORS - PART_LBA:
            raise ValueError('MBR受控PCM分区契约不匹配')
        if image.stat().st_size != DISK_SECTORS * SECTOR:
            raise ValueError('镜像长度不匹配')
        f.seek(LABEL_LBA * SECTOR)
        bmp = f.read(LABEL_BYTES)
        if hashlib.sha256(bmp).hexdigest() != BMP_SHA or zlib.crc32(bmp) != BMP_CRC or crc_labels(bmp) != LABEL_CRC:
            raise ValueError('标签双CRC/文件身份失败')
        if f.read(LABEL_SECTORS * SECTOR - LABEL_BYTES) != bytes(LABEL_SECTORS * SECTOR - LABEL_BYTES):
            raise ValueError('标签末扇区补零不匹配')
        f.seek(part * SECTOR)
        boot = f.read(SECTOR)
        bps, spc, reserved, nfats = struct.unpack_from('<HBHB', boot, 11)
        fatsz = struct.unpack_from('<I', boot, 36)[0]
        data_lba = part + reserved + nfats * fatsz
        clusters = length - reserved - nfats * fatsz
        if ((bps, spc, reserved, nfats) != (512, 1, 32, 2) or
            clusters < 65525 or fatsz * SECTOR < (clusters + 2) * 4 or
            data_lba >= DISK_SECTORS or boot[510:512] != b'\x55\xaa' or
            struct.unpack_from('<I', boot, 28)[0] != PART_LBA or
            struct.unpack_from('<I', boot, 32)[0] != length or
            struct.unpack_from('<I', boot, 44)[0] != 2):
            raise ValueError('FAT32几何不匹配')
        f.seek((part + reserved) * SECTOR)
        fat = f.read(fatsz * SECTOR)
        f.seek((part + reserved + fatsz) * SECTOR)
        if f.read(fatsz * SECTOR) != fat:
            raise ValueError('FAT副本不匹配')
        f.seek(data_lba * SECTOR)
        root = f.read(SECTOR)
        recovered, occupied = [], set()
        for i in range(4):
            entry = root[i * 32:(i + 1) * 32]
            if entry[0] == 0:
                break
            if entry[:11] != f'WAV{i + 1}    WAV'.encode('ascii') or entry[11] != 0x20:
                raise ValueError('根目录槽名错误')
            cluster = (struct.unpack_from('<H', entry, 20)[0] << 16) | struct.unpack_from('<H', entry, 26)[0]
            count = struct.unpack_from('<I', entry, 28)[0]
            seen, pcm = set(), bytearray()
            while cluster < 0x0FFFFFF8:
                if cluster < 3 or cluster > clusters + 1 or cluster in seen or cluster in occupied or len(seen) >= 8192 or cluster * 4 >= len(fat):
                    raise ValueError('PCM簇链超限/回环/范围错误')
                seen.add(cluster)
                lba = data_lba + cluster - 2
                if lba < PART_LBA or lba >= DISK_SECTORS:
                    raise ValueError('PCM数据越界或侵入标签区')
                f.seek(lba * SECTOR)
                pcm += f.read(SECTOR)
                cluster = struct.unpack_from('<I', fat, cluster * 4)[0] & 0x0FFFFFFF
            if not count or count % 2 or count > 1920000 or len(seen) != (count + SECTOR - 1) // SECTOR or pcm[:4] in (b'RIFF', b'RF64', b'RIFX'):
                raise ValueError('PCM长度契约失败')
            occupied.update(seen)
            recovered.append(dict(name=f'WAV{i + 1}.WAV', bytes=count, clusters=len(seen), sha256=hashlib.sha256(pcm[:count]).hexdigest()))
    with image.open('rb') as f:
        image_sha = hashlib.file_digest(f, 'sha256').hexdigest()
    return dict(status='PASS_IMAGE', label_lba=LABEL_LBA, sectors=LABEL_SECTORS,
                pcm_partition_lba=PART_LBA, pcm_files=recovered, image_sha256=image_sha,
                hardware_card_written=False)

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    make = sub.add_parser('build')
    make.add_argument('--bmp', type=Path, default=Path(__file__).resolve().parent.parent / 'project/assets/PCB.BMP')
    make.add_argument('--output', type=Path, required=True)
    make.add_argument('--pcm', type=Path, nargs='*', default=[])
    check = sub.add_parser('verify')
    check.add_argument('image', type=Path)
    args = parser.parse_args()
    if args.command == 'build':
        if len(args.pcm) > 4:
            parser.error('PCM最多4槽')
        build(args)
    else:
        print(json.dumps(verify(args.image), ensure_ascii=False))
