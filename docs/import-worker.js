'use strict';
importScripts('./xlsx.full.min.js','./import-parser.js');
onmessage=async({data:{file,sheet}})=>{
 try{
  if(file.size>50*1024*1024)throw Error('Limite de 50 MB por planilha.');
  const bytes=await file.arrayBuffer(),v=new DataView(bytes);let pos=-1;
  for(let i=bytes.byteLength-22;i>=Math.max(0,bytes.byteLength-65557);i--){if(v.getUint32(i,true)===0x06054b50){pos=i;break;}}
  if(pos<0)throw Error('Arquivo XLSX inválido.');
  const entries=v.getUint16(pos+10,true);if(entries>2000)throw Error('Planilha excede os limites de leitura.');
  let offset=v.getUint32(pos+16,true),size=0;
  for(let i=0;i<entries;i++){
   if(v.getUint32(offset,true)!==0x02014b50)throw Error('Arquivo XLSX inválido.');
   const partSize=v.getUint32(offset+24,true),nameLength=v.getUint16(offset+28,true),extra=v.getUint16(offset+30,true),comment=v.getUint16(offset+32,true);
   const name=new TextDecoder().decode(new Uint8Array(bytes,offset+46,nameLength));size+=partSize;
   if(size>512*1024*1024||(name.includes('sharedStrings')&&partSize>30*1024*1024))throw Error('Planilha excede os limites de leitura segura.');
   offset+=46+nameLength+extra+comment;
  }
  const book=XLSX.read(bytes,{type:'array',cellDates:false,sheetRows:20000,cellHTML:false,cellFormula:false});
  postMessage({result:parseWorkbook(book,sheet,XLSX)});
 }catch(e){postMessage({error:e.message||'Não foi possível ler a planilha.'});}
};
