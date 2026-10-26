const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const ORIGIN = 'https://micaolimach-cpu.github.io';
const headers = {'Access-Control-Allow-Origin':ORIGIN,'Access-Control-Allow-Headers':'authorization, apikey, content-type, x-client-info','Access-Control-Allow-Methods':'GET, POST, PATCH, DELETE, OPTIONS','Content-Type':'application/json','Cache-Control':'no-store','Vary':'Origin'};
const json=(data:unknown,status=200)=>new Response(JSON.stringify(data),{status,headers});
Deno.serve(async(req:Request)=>{
 if(req.method==='OPTIONS')return new Response(null,{status:204,headers});
 const url=new URL(req.url),path=url.pathname.replace(/^.*\/vinha-api/,'')||'/';
 if(req.method==='GET'&&path==='/config')return json({demo:false});
 try {
  const bearer=req.headers.get('Authorization')||'';
  if(!bearer.startsWith('Bearer '))return json({error:'Entre com seu e-mail autorizado.'},401);
  const verified=await fetch(SUPABASE_URL+'/auth/v1/user',{headers:{Authorization:bearer,apikey:SERVICE_KEY}});
  if(!verified.ok)return json({error:'Sessão expirada. Entre novamente.'},401);
  const user=await verified.json();
  if(!user.id||!user.email_confirmed_at)return json({error:'Confirme seu e-mail para entrar.'},401);
  // JWT payload is read only AFTER the Auth service has validated this exact token.
  const part=bearer.slice(7).split('.')[1].replace(/-/g,'+').replace(/_/g,'/');
  const claims=JSON.parse(atob(part));
  if(!claims.session_id)return json({error:'Sessão inválida.'},401);
  if(Number(req.headers.get('content-length')||0)>12*1024*1024)return json({error:'Importação muito grande. Divida a planilha.'},413);
  const raw=req.method==='GET'?'{}':await req.text();
  if(raw.length>12*1024*1024)return json({error:'Importação muito grande. Divida a planilha.'},413);
  const body=JSON.parse(raw||'{}');
  const response=await fetch(SUPABASE_URL+'/rest/v1/rpc/vinha_api',{
   method:'POST',headers:{apikey:SERVICE_KEY,Authorization:'Bearer '+SERVICE_KEY,'Content-Type':'application/json'},
   body:JSON.stringify({p_uid:user.id,p_session:claims.session_id,p_path:path,p_method:req.method,p_body:body,p_query:Object.fromEntries(url.searchParams)})
  });
  const result=await response.json();
  if(!response.ok){
   const code=result.code,status=code==='28000'?401:code==='42501'?403:400;
   const friendly=code==='23505'?'Já existe um registro ou atendimento nesta situação. Atualize a tela.':code?.startsWith('22')||code==='23514'||code==='23502'?'Confira os campos obrigatórios, datas e tamanhos dos textos.':code==='P0001'||code==='28000'||code==='42501'?result.message:'Não foi possível concluir a operação. Tente novamente.';
   return json({error:friendly},status);
  }
  return json(result);
 }catch{return json({error:'Não foi possível concluir a operação. Confira a conexão e tente novamente.'},400);}
});
