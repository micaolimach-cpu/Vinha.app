'use strict';
function parseWorkbook(book,requestedSheet,XLSX){
 const norm=v=>String(v??'').normalize('NFKD').replace(/[\u0300-\u036f]/g,'').toLowerCase().replace(/[^a-z0-9]/g,'');
 const aliases={cnpj:['cnpj','cnpjcpf','documento','cnpj14digitos'],name:['nomedopn','cliente','clientecentral','razaosocial'],seller:['vendedor','representante'],channel:['canal'],city:['cidade','municipio','cidadedodestinatario','cidadedestinatario'],bairro:['bairro'],address:['endereco','enderecocompleto'],number:['numero'],date:['data','datadavisita','datavisita'],frequency:['frequencia','frequenciasugerida'],status:['situacaocadastral'],person:['tipopessoa']};
 let found=[];
 for(const name of requestedSheet?[requestedSheet]:book.SheetNames){
  if(!book.Sheets[name])throw Error('Aba não encontrada.');
  const sheet=book.Sheets[name];if(!sheet['!ref'])continue;
  const range=XLSX.utils.decode_range(sheet['!ref']);range.s.r=0;range.s.c=0;range.e.r=Math.min(range.e.r,19999);range.e.c=Math.min(range.e.c,39);
  const rows=XLSX.utils.sheet_to_json(sheet,{header:1,range,raw:true,defval:null});
  for(let h=0;h<Math.min(40,rows.length);h++){
   const keys=rows[h].map(norm),m=Object.fromEntries(Object.entries(aliases).map(([k,a])=>[k,keys.findIndex(v=>a.includes(v))]));
   if(m.cnpj>=0&&m.name>=0){found.push({name,rows,h,m});break;}
  }
 }
 if(!found.length)throw Error('Não localizei as colunas CNPJ e Cliente/Nome do PN.');
 if(!requestedSheet){const routes=found.filter(s=>s.m.date>=0);found=routes.length?routes:[found.find(s=>['planilha1','baseenviada','enderecoscnpj'].includes(norm(s.name)))||found[0]];}
 const records=new Map(),warnings=[];let count=0;
 const dateText=value=>{
  let y,m,d;
  if(typeof value==='number'){const z=XLSX.SSF.parse_date_code(value);if(!z)throw Error();({y,m,d}=z);}
  else if(value instanceof Date){y=value.getUTCFullYear();m=value.getUTCMonth()+1;d=value.getUTCDate();}
  else {const t=String(value).trim();let z=t.match(/^(\d{4})-(\d{2})-(\d{2})$/);if(z)[,y,m,d]=z;else {z=t.match(/^(\d{1,2})\/(\d{1,2})\/(\d{4})$/);if(!z)throw Error();[,d,m,y]=z;}}
  y=+y;m=+m;d=+d;const dt=new Date(Date.UTC(y,m-1,d));if(y<1900||y>2200||dt.getUTCFullYear()!==y||dt.getUTCMonth()+1!==m||dt.getUTCDate()!==d)throw Error();
  return `${y}-${String(m).padStart(2,'0')}-${String(d).padStart(2,'0')}`;
 };
 for(const s of found){let empty=0;for(let i=s.h+1;i<s.rows.length;i++){
  const row=s.rows[i],get=k=>s.m[k]>=0?row[s.m[k]]:null;
  if(!get('name')){if(++empty>=200)break;continue;}empty=0;if(++count>15000)throw Error('Importe até 15 mil linhas por vez.');
  let id=get('cnpj');const digits=String(typeof id==='number'?Math.trunc(id):id??'').replace(/\D/g,'');
  if(norm(get('person'))==='pessoafisica'||digits.length>14||!digits||(digits.length<12&&norm(get('person'))!=='pessoajuridica')){warnings.push(`${s.name}, linha ${i+1}: documento fora do escopo CNPJ.`);continue;}
  const cnpj=digits.padStart(14,'0'),seller=String(get('seller')||s.name).trim(),key=cnpj+'|'+seller;
  let channel=String(get('channel')||'').trim().toUpperCase().replace(/ /g,'-');if(!['ON-TRADE','OFF-TRADE'].includes(channel))channel='A CLASSIFICAR';
  let frequency=String(get('frequency')||(channel==='ON-TRADE'?'Semanal':'Mensal')).trim();if(!['Semanal','Quinzenal','Mensal'].includes(frequency))frequency='Mensal';
  if(!records.has(key))records.set(key,{cnpj,name:String(get('name')).trim().slice(0,200),seller,channel,city:String(get('city')||'').slice(0,120),bairro:String(get('bairro')||'').slice(0,120),address:(String(get('address')||'')+(get('number')?', '+get('number'):'')).slice(0,500),frequency,active:!['BAIXADA','INAPTA','SUSPENSA'].includes(String(get('status')||'').toUpperCase()),central:cnpj.slice(8,12)==='0001',dates:[]});
  if(get('date'))try{const day=dateText(get('date')),r=records.get(key);if(!r.dates.includes(day))r.dates.push(day);}catch{warnings.push(`${s.name}, linha ${i+1}: data inválida; cliente cadastrado sem essa visita.`);}
 }}
 return {records:[...records.values()],warnings,sheets:found.map(s=>s.name),source_rows:count};
}
if(typeof module!=='undefined')module.exports={parseWorkbook};
