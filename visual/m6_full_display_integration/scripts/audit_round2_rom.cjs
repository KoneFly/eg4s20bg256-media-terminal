// 从真正TD网表的两片BRAM INIT重建完整512行区段表，不能代签bit读回。
const fs=require('fs'),path=require('path'),crypto=require('crypto');
const [runArg,step]=process.argv.slice(2),run=path.resolve(runArg),task=path.resolve(__dirname,'..');
const file=path.join(run,`${step}_netlist.v`),gate=fs.readFileSync(file,'utf8');
const tag='// u_display/u_label_stream/mux55_syn_1_512x20';
const loAt=gate.indexOf(tag),hiAt=gate.indexOf(tag,loAt+tag.length);
if(loAt<0||hiAt<0)throw Error('Row-span physical ROM banks missing');
const lo=gate.slice(loAt,hiAt),hi=gate.slice(hiAt,gate.indexOf('// ',hiAt+tag.length));
const decode=(s,n)=>[...s.matchAll(new RegExp('\\.'+n+'_([0-9A-F]{2})\\(256.h([0-9A-F]+)\\)','g'))].reduce((v,m)=>v|(BigInt('0x'+m[2])<<BigInt(parseInt(m[1],16)*256)),0n);
const data=decode(lo,'INIT'),parity=decode(lo,'INITP'),high=decode(hi,'INIT');
const asset=path.join(task,'project/assets/rom_row_span.hex'),caseFile=path.join(task,'project/src/vendor/fdi_stream/fdi_row_span_rom.vh');
const sha=p=>crypto.createHash('sha256').update(fs.readFileSync(p)).digest('hex');
const words=fs.readFileSync(asset,'utf8').trim().split(/\r?\n/).map(v=>parseInt(v,16)>>>12);
const defaultWord=parseInt(fs.readFileSync(caseFile,'utf8').match(/default: fdi_row_span=20'h([0-9a-f]+);/)[1],16);
const mismatches=[];
for(let r=0;r<512;r++){
 const d=Number((data>>BigInt(r*16))&65535n),q=Number((parity>>BigInt(r*2))&3n),h=Number((high>>BigInt(r*2))&3n);
 const actual=(d&255)|((q&1)<<8)|(((d>>8)&255)<<9)|((q>>1)<<17)|(h<<18),expected=r<480?words[r]:defaultWord;
 if(actual!==expected)mismatches.push({row:r,expected,actual});
}
const result={status:mismatches.length?'FAIL':'PASS_ROM_INIT',words:512,mismatches,asset_sha256:sha(asset),netlist_sha256:sha(file),confidence:JSON.parse(fs.readFileSync(path.join(run,'RESULT.json'))).confidence,bit_readback_verified:false};
fs.writeFileSync(path.join(run,'ROM_AUDIT.json'),JSON.stringify(result,null,2)+'\n');
console.log(JSON.stringify(result));if(mismatches.length)process.exitCode=1;
