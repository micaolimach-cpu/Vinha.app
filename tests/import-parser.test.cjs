const test=require('node:test'),assert=require('node:assert/strict');
const XLSX=require('../docs/xlsx.full.min.js');
const {parseWorkbook}=require('../docs/import-parser.js');
const make=rows=>{const b=XLSX.utils.book_new();XLSX.utils.book_append_sheet(b,XLSX.utils.aoa_to_sheet(rows),'Clientes');return b;};
test('maps header aliases, preserves repeat dates and ignores CPF',()=>{
 const p=parseWorkbook(make([['CNPJ','Cliente','Vendedor','Canal','Data'],['12345678000190','Loja A','Ana','ON TRADE','27/10/2026'],['12345678000190','Loja A','Ana','ON TRADE','28/10/2026'],['12345678901','Pessoa','Ana','OFF TRADE','27/10/2026']]),'',XLSX);
 assert.equal(p.records.length,1);assert.deepEqual(p.records[0].dates,['2026-10-27','2026-10-28']);assert.equal(p.records[0].channel,'ON-TRADE');assert.equal(p.warnings.length,1);
});
test('invalid calendar dates are not silently normalized',()=>{const p=parseWorkbook(make([['CNPJ','Cliente','Data'],['12345678000190','Loja','31/02/2026']]),'',XLSX);assert.deepEqual(p.records[0].dates,[]);assert.equal(p.warnings.length,1);});
test('base without date never invents visits',()=>{const p=parseWorkbook(make([['CNPJ','Cliente','Canal'],['12345678000270','Filial','OFF TRADE']]),'',XLSX);assert.equal(p.records[0].central,false);assert.deepEqual(p.records[0].dates,[]);assert.equal(p.records[0].frequency,'Mensal');});
