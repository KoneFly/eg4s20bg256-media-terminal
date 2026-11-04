// 构造只含固定PCB.BMP的FAT32测试盘；黄金图只读引用，不改产物。
const fs=require('fs'),path=require('path'),crypto=require('crypto');
const base=path.resolve(__dirname,'../../../../../../..');
const bmpPath=path.join(base,'golden/pcb/PCB.BMP');
const b=fs.readFileSync(bmpPath), image=Buffer.alloc(4096*512);
const u16=(a,v)=>image.writeUInt16LE(v,a),u32=(a,v)=>image.writeUInt32LE(v>>>0,a);
image[0]=0xeb;u16(11,512);image[13]=8;u16(14,32);image[16]=1;
u32(32,4096);u32(36,8);u32(44,2);image[510]=0x55;image[511]=0xaa;
u32(32*512,0x0ffffff8);u32(32*512+4,0x0fffffff);u32(32*512+8,0x0fffffff);
const clusters=Math.ceil(b.length/4096);
for(let k=3;k<3+clusters;k++)u32(32*512+k*4,k==2+clusters?0x0fffffff:k+1);
image.write('PCB     BMP',40*512,'ascii');image[40*512+11]=0x20;
u16(40*512+26,3);u32(40*512+28,b.length);b.copy(image,48*512);
const lines=[];for(let i=0;i<image.length;i+=4)lines.push(image.readUInt32BE(i).toString(16).padStart(8,'0'));
fs.writeFileSync(path.join(__dirname,'label_image.memh'),lines.join('\n')+'\n');
const labels=[];for(let i=54;i<b.length;i+=6){
const l=j=>((b[j+2]>>3)<<11)|((b[j+1]>>2)<<5)|(b[j]>>3);
labels.push(((l(i+3)*65536)+l(i)).toString(16).padStart(8,'0'));}
fs.writeFileSync(path.join(__dirname,'label_words.memh'),labels.join('\n')+'\n');
fs.writeFileSync(path.join(__dirname,'fixture_manifest.json'),JSON.stringify({bmpPath,
bmpSha256:crypto.createHash('sha256').update(b).digest('hex'),imageSha256:crypto.createHash('sha256').update(image).digest('hex'),
sectors:4096,sectorsPerCluster:8,fileCluster:3,fileBytes:b.length,words:labels.length},null,2)+'\n');
console.log('FIXTURE_OK bytes='+b.length+' labels32='+labels.length);
