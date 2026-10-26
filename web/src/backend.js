import {createClient} from '@supabase/supabase-js';
const url='https://lxiofrdhlqhzyuheikoc.supabase.co';
const key='sb_publishable_Y_iDZFkWiaMg-f4XdJH6RQ_JAaNydO5';
const client=createClient(url,key,{auth:{persistSession:true,autoRefreshToken:true,detectSessionInUrl:true,flowType:'implicit'}});
function readWorkbook(file,sheet){return new Promise((resolve,reject)=>{
 const worker=new Worker('./import-worker.js');
 const timer=setTimeout(()=>{worker.terminate();reject(Error('A leitura demorou demais. Divida a planilha e tente novamente.'));},60000);
 const finish=()=>{clearTimeout(timer);worker.terminate();};
 worker.onmessage=e=>{finish();e.data.error?reject(Error(e.data.error)):resolve(e.data.result);};
 worker.onerror=()=>{finish();reject(Error('Não foi possível ler a planilha.'));};worker.postMessage({file,sheet});
});}
window.Vinha={
 async api(path,method='GET',body=null,raw=false){
  if(path==='/config')return {demo:false};
  if(path==='/auth/request'){
   const {error}=await client.auth.signInWithOtp({email:body.email.trim().toLowerCase(),options:{emailRedirectTo:'https://micaolimach-cpu.github.io/Vinha.app/'}});
   if(error)throw Error(error.status===429?'Aguarde um minuto antes de pedir outro link.':'Não foi possível enviar o link. O gestor precisa verificar o envio de e-mails no Supabase.');
   return {message:'Confira sua caixa de entrada e o spam para acessar o Vinha.'};
  }
  if(path==='/logout'){const {error}=await client.auth.signOut();if(error)throw Error('Não foi possível encerrar a sessão. Tente novamente.');return {ok:true};}
  const {data:{session},error}=await client.auth.getSession();
  if(error||!session)throw Object.assign(Error('Entre com seu e-mail autorizado.'),{status:401});
  if(raw){const query=new URL(path,'https://local.invalid');body=await readWorkbook(body,query.searchParams.get('sheet')||'');}
  const response=await fetch(url+'/functions/v1/vinha-api'+path,{method,headers:{apikey:key,Authorization:'Bearer '+session.access_token,'Content-Type':'application/json'},body:method==='GET'?undefined:JSON.stringify(body||{})});
  const result=await response.json();
  if(!response.ok){if(response.status===401)await client.auth.signOut({scope:'local'});throw Object.assign(Error(result.error||'Não foi possível concluir.'),{status:response.status});}
  return result;
 },
 async ready(){await client.auth.getSession();if(location.hash)history.replaceState(null,'',location.pathname+location.search);}
};
