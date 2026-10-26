-- Server-owned data. No table access is granted to browser roles.
create schema if not exists vinha_private;
revoke all on schema vinha_private from public, anon, authenticated;
grant usage on schema vinha_private to service_role;
create table vinha_private.users(id bigint generated always as identity primary key,email text unique not null check(email=lower(email)),role text not null check(role in ('admin','seller')),active boolean not null default true,revoked_before timestamptz not null default '-infinity');
create table vinha_private.sellers(id bigint generated always as identity primary key,name text unique not null check(length(name) between 1 and 200));
create table vinha_private.grants(user_id bigint primary key references vinha_private.users,seller_id bigint not null references vinha_private.sellers);
create table vinha_private.clients(id bigint generated always as identity primary key,cnpj text not null check(cnpj ~ '^[0-9]{14}$'),name text not null check(length(name) between 1 and 200),seller_id bigint not null references vinha_private.sellers,channel text not null check(channel in ('ON-TRADE','OFF-TRADE','A CLASSIFICAR')),city text not null default '' check(length(city)<=120),bairro text not null default '' check(length(bairro)<=120),address text not null default '' check(length(address)<=500),frequency text not null check(frequency in ('Semanal','Quinzenal','Mensal')),availability text not null default '' check(length(availability)<=1000),active boolean not null default true,central boolean not null default true,version integer not null default 1,unique(cnpj,seller_id));
create table vinha_private.visits(id bigint generated always as identity primary key,client_id bigint not null references vinha_private.clients,visit_date date not null,status text not null default 'Agendada' check(status in ('Agendada','Em atendimento','Realizada','Cancelada')),version integer not null default 1,checkin_at timestamptz,checkout_at timestamptz,checkin_user bigint references vinha_private.users,checkin_lat double precision check(checkin_lat between -90 and 90),checkin_lon double precision check(checkin_lon between -180 and 180),checkout_lat double precision check(checkout_lat between -90 and 90),checkout_lon double precision check(checkout_lon between -180 and 180),unique(client_id,visit_date));
create unique index one_live_checkin on vinha_private.visits(checkin_user) where status='Em atendimento';
create index visits_day on vinha_private.visits(visit_date);
create index clients_seller on vinha_private.clients(seller_id);
create index grants_seller on vinha_private.grants(seller_id);
create table vinha_private.requests(id bigint generated always as identity primary key,client_id bigint not null references vinha_private.clients,visit_id bigint not null references vinha_private.visits,user_id bigint not null references vinha_private.users,proposed_date date not null,frequency text not null check(frequency in ('Semanal','Quinzenal','Mensal')),availability text not null check(length(availability) between 1 and 1000),reason text not null check(length(reason) between 1 and 1000),status text not null default 'Pendente' check(status in ('Pendente','Aprovada','Recusada')),created timestamptz not null default now(),reviewed timestamptz,admin_note text,client_version integer not null,visit_version integer not null);
create unique index one_pending_request on vinha_private.requests(visit_id) where status='Pendente';
create index requests_client on vinha_private.requests(client_id);
create table vinha_private.imports(id uuid primary key default gen_random_uuid(),user_id bigint not null references vinha_private.users,expires timestamptz not null default now()+interval '30 minutes',payload jsonb not null);
create table vinha_private.audit(id bigint generated always as identity primary key,user_id bigint references vinha_private.users,action text not null,payload jsonb not null,created timestamptz not null default now());
alter table vinha_private.users enable row level security;
alter table vinha_private.sellers enable row level security;
alter table vinha_private.grants enable row level security;
alter table vinha_private.clients enable row level security;
alter table vinha_private.visits enable row level security;
alter table vinha_private.requests enable row level security;
alter table vinha_private.imports enable row level security;
alter table vinha_private.audit enable row level security;
revoke all on all tables in schema vinha_private from public, anon, authenticated;
grant all on all tables in schema vinha_private to service_role;
grant usage,select on all sequences in schema vinha_private to service_role;
insert into vinha_private.users(email,role) values('micael.oliveira@portoaporto.com.br','admin');

create function vinha_private.business_day(d date) returns boolean language sql immutable set search_path='' as $$
select extract(isodow from d)<6 and to_char(d,'MM-DD') not in ('01-01','04-21','05-01','09-07','10-12','11-02','11-15','11-20','12-25') $$;
create function vinha_private.capacity(cid bigint,d date,exclude_id bigint default null) returns void language plpgsql set search_path='' as $$
declare c vinha_private.clients; used integer;
begin
 select * into strict c from vinha_private.clients where id=cid;
 if not c.active or not c.central then raise exception 'Cliente inativo ou filial sem visita individual.'; end if;
 if c.channel='A CLASSIFICAR' then raise exception 'Defina o canal antes de agendar.'; end if;
 select coalesce(sum(case cl.channel when 'ON-TRADE' then 1 else 2 end),0) into used from vinha_private.visits v join vinha_private.clients cl on cl.id=v.client_id where cl.seller_id=c.seller_id and v.visit_date=d and v.status<>'Cancelada' and (exclude_id is null or v.id<>exclude_id);
 if used+(case c.channel when 'ON-TRADE' then 1 else 2 end)>20 then raise exception 'Limite diário excedido: 20 ON, 10 OFF ou carga mista proporcional.'; end if;
end $$;
revoke all on all functions in schema vinha_private from public,anon,authenticated;
grant execute on all functions in schema vinha_private to service_role;

grant select(id,email,email_confirmed_at,banned_until) on auth.users to service_role;
grant select(id,user_id,created_at,not_after) on auth.sessions to service_role;

-- Called only by the Edge Function after Auth validates the bearer token.
-- SECURITY INVOKER: browser roles cannot invoke this RPC or access its tables.
create function public.vinha_api(p_uid uuid,p_session uuid,p_path text,p_method text,p_body jsonb default '{}',p_query jsonb default '{}') returns jsonb language plpgsql security invoker set search_path='' as $$
declare
 u vinha_private.users; c vinha_private.clients; v vinha_private.visits; rq vinha_private.requests;
 a auth.users; session_created timestamptz; out_data jsonb; row_data jsonb; imp vinha_private.imports;
 ident bigint; sid bigint; uid bigint; d date; start_d date; end_d date; next_month date; freq text; email_value text;
 today_d date := (now() at time zone 'America/Sao_Paulo')::date;
 made jsonb := '[]'; skipped jsonb := '[]'; warns jsonb := '[]'; days jsonb; did text; import_id uuid;
 new_clients integer:=0; old_clients integer:=0; new_visits integer:=0;
 lat double precision; lon double precision; allowed boolean; approved boolean;
begin
 select id,email,email_confirmed_at,banned_until into a.id,a.email,a.email_confirmed_at,a.banned_until from auth.users where id=p_uid and email_confirmed_at is not null and (banned_until is null or banned_until<now());
 if not found then raise exception 'Entre com seu e-mail autorizado.' using errcode='28000'; end if;
 select * into u from vinha_private.users where email=lower(a.email) and active;
 if not found then raise exception 'Seu acesso não está autorizado. Fale com o gestor.' using errcode='28000'; end if;
 select created_at into session_created from auth.sessions where id=p_session and user_id=p_uid and (not_after is null or not_after>now());
 if session_created is null or session_created<now()-interval '8 hours' or session_created<=u.revoked_before then raise exception 'Sessão encerrada. Solicite um novo link de acesso.' using errcode='28000'; end if;
 if p_method<>'GET' then perform pg_advisory_xact_lock(774411); end if;
 if p_path='/me' and p_method='GET' then return jsonb_build_object('user',jsonb_build_object('id',u.id,'email',u.email,'role',u.role),'today',today_d,'demo',false,'csrf',''); end if;
 if p_path='/clients' and p_method='GET' then
 select coalesce(jsonb_agg(to_jsonb(q)),'[]') into out_data from (select cl.*,s.name seller,(select count(*) from vinha_private.visits vi where vi.client_id=cl.id and vi.status<>'Cancelada') visits_count from vinha_private.clients cl join vinha_private.sellers s on s.id=cl.seller_id where u.role='admin' or exists(select 1 from vinha_private.grants g where g.user_id=u.id and g.seller_id=cl.seller_id) order by cl.name) q;
 return jsonb_build_object('clients',out_data); end if;
 if p_path='/visits' and p_method='GET' then
 start_d:=coalesce((p_query->>'from')::date,today_d);end_d:=coalesce((p_query->>'to')::date,start_d);
 if end_d-start_d>93 then raise exception 'Consulte até 93 dias por vez.'; end if;
 select coalesce(jsonb_agg(to_jsonb(q)),'[]') into out_data from (select vi.*,cl.name,cl.cnpj,cl.channel,cl.city,cl.bairro,cl.address,cl.frequency,cl.availability,cl.seller_id,s.name seller from vinha_private.visits vi join vinha_private.clients cl on cl.id=vi.client_id join vinha_private.sellers s on s.id=cl.seller_id where vi.visit_date between start_d and end_d and (u.role='admin' or exists(select 1 from vinha_private.grants g where g.user_id=u.id and g.seller_id=cl.seller_id)) order by vi.visit_date,s.name,cl.city,cl.bairro,cl.name) q;
 return jsonb_build_object('visits',out_data); end if;
 if p_path='/requests' and p_method='GET' then
 select coalesce(jsonb_agg(to_jsonb(q)),'[]') into out_data from (select r.*,cl.name,cl.seller_id,cl.frequency current_frequency,s.name seller,vi.visit_date as current_date from vinha_private.requests r join vinha_private.clients cl on cl.id=r.client_id join vinha_private.sellers s on s.id=cl.seller_id join vinha_private.visits vi on vi.id=r.visit_id where u.role='admin' or exists(select 1 from vinha_private.grants g where g.user_id=u.id and g.seller_id=cl.seller_id) order by r.id desc) q;
 return jsonb_build_object('requests',out_data); end if;
 -- Seller operations resolve the visit and check its owner on the server.
 if (p_path='/requests' and p_method='POST') or (p_path ~ '^/visits/[0-9]+/(checkin|checkout)$' and p_method='POST') then
 ident:=case when p_path='/requests' then (p_body->>'visit_id')::bigint else split_part(p_path,'/',3)::bigint end;
 select * into v from vinha_private.visits where id=ident; if not found then raise exception 'Visita não encontrada.'; end if;
 select * into strict c from vinha_private.clients where id=v.client_id;
 if u.role<>'admin' and not exists(select 1 from vinha_private.grants where user_id=u.id and seller_id=c.seller_id) then raise exception 'Visita não encontrada.' using errcode='42501'; end if;
 if v.status in ('Cancelada','Realizada') then raise exception 'Visita concluída ou cancelada.'; end if;
 if p_path='/requests' then
 insert into vinha_private.requests(client_id,visit_id,user_id,proposed_date,frequency,availability,reason,client_version,visit_version) values(c.id,v.id,u.id,(p_body->>'proposed_date')::date,p_body->>'frequency',trim(p_body->>'availability'),trim(p_body->>'reason'),c.version,v.version) returning id into ident;
 out_data:=jsonb_build_object('id',ident,'message','Solicitação enviada ao gestor.');
 else
 if v.visit_date<>today_d then raise exception 'Check-in e check-out são permitidos somente nas visitas de hoje.'; end if;
 lat:=(p_body->>'latitude')::double precision;lon:=(p_body->>'longitude')::double precision;
 if (lat is null)<>(lon is null) or lat not between -90 and 90 or lon not between -180 and 180 then raise exception 'Localização inválida.'; end if;
 if p_path like '%/checkin' then
 if v.checkin_at is not null then raise exception 'Check-in já registrado.'; end if;
 if exists(select 1 from vinha_private.visits where checkin_user=u.id and status='Em atendimento') then raise exception 'Conclua o atendimento atual antes de iniciar o próximo.'; end if;
 update vinha_private.visits set status='Em atendimento',checkin_at=now(),checkin_user=u.id,checkin_lat=lat,checkin_lon=lon,version=version+1 where id=v.id;
 else
 if v.checkin_at is null or v.checkin_user<>u.id then raise exception 'Somente quem iniciou o atendimento pode encerrá-lo.'; end if;
 update vinha_private.visits set status='Realizada',checkout_at=now(),checkout_lat=lat,checkout_lon=lon,version=version+1 where id=v.id;
 end if;
 out_data:='{"ok":true}';
 end if;
 insert into vinha_private.audit(user_id,action,payload) values(u.id,p_path,jsonb_build_object('id',ident));return out_data;
 end if;
 if u.role<>'admin' then raise exception 'Acesso reservado ao gestor.' using errcode='42501'; end if;
 if p_path='/team' and p_method='GET' then
 return jsonb_build_object('sellers',(select coalesce(jsonb_agg(to_jsonb(q)),'[]') from (select s.*,(select count(*) from vinha_private.clients cl where cl.seller_id=s.id) client_count from vinha_private.sellers s order by s.name) q),'users',(select coalesce(jsonb_agg(to_jsonb(q)),'[]') from (select us.id,us.email,us.role,us.active,g.seller_id from vinha_private.users us left join vinha_private.grants g on g.user_id=us.id order by us.email) q)); end if;
 if p_path='/team' and p_method='POST' then
 email_value:=lower(trim(p_body->>'email'));sid:=(p_body->>'seller_id')::bigint;
 if email_value is null or length(email_value)>254 or email_value !~ '^[^\s@]+@[^\s@]+\.[^\s@]+$' then raise exception 'Informe um e-mail válido.'; end if;
 if not exists(select 1 from vinha_private.sellers where id=sid) then raise exception 'Selecione um vendedor cadastrado.'; end if;
 if exists(select 1 from vinha_private.users where email=email_value and role='admin') then raise exception 'Este e-mail já é do gestor.'; end if;
 if exists(select 1 from vinha_private.users us join vinha_private.grants g on g.user_id=us.id where us.email=email_value and g.seller_id<>sid) then raise exception 'E-mail já vinculado a outra carteira.'; end if;
 insert into vinha_private.users(email,role) values(email_value,'seller') on conflict(email) do update set active=true returning id into uid;
 insert into vinha_private.grants values(uid,sid) on conflict(user_id) do nothing;
 out_data:='{"message":"E-mail autorizado. O vendedor já pode solicitar seu acesso."}';
 elsif p_path ~ '^/team/[0-9]+$' and p_method='DELETE' then
 update vinha_private.users set active=false,revoked_before=now() where id=split_part(p_path,'/',3)::bigint and role='seller';if not found then raise exception 'Acesso não encontrado.';end if;out_data:='{"ok":true}';
 elsif p_path ~ '^/clients/[0-9]+$' and p_method='PATCH' then
 select * into c from vinha_private.clients where id=split_part(p_path,'/',3)::bigint;
 if not found or c.version is distinct from (p_body->>'version')::integer then raise exception 'Cadastro alterado. Atualize a tela antes de salvar.'; end if;
 if coalesce((p_body->>'seller_id')::bigint,c.seller_id)<>c.seller_id or coalesce(p_body->>'channel',c.channel)<>c.channel then raise exception 'Troca de vendedor/canal exige revisão da agenda.';end if;
 update vinha_private.clients set name=trim(p_body->>'name'),city=p_body->>'city',bairro=p_body->>'bairro',address=p_body->>'address',frequency=p_body->>'frequency',availability=p_body->>'availability',active=(p_body->>'active')::boolean,central=(p_body->>'central')::boolean,version=version+1 where id=c.id;
 if not (p_body->>'active')::boolean or not (p_body->>'central')::boolean then update vinha_private.visits set status='Cancelada',version=version+1 where client_id=c.id and visit_date>=today_d and status='Agendada'; end if;
 out_data:='{"message":"Cadastro salvo. Use Agendar para gerar novas datas."}';
 elsif p_path='/schedule' and p_method='POST' then
 select * into c from vinha_private.clients where id=(p_body->>'client_id')::bigint;if not found then raise exception 'Cliente não encontrado.'; end if;
 start_d:=(p_body->>'start')::date;end_d:=(p_body->>'until')::date;freq:=p_body->>'frequency';d:=start_d;
 if start_d is null or end_d is null or end_d<start_d or end_d-start_d>93 or freq not in ('Semanal','Quinzenal','Mensal') or freq is null then raise exception 'Escolha frequência e período válido de até 93 dias.'; end if;
 while d<=end_d loop
 begin
 if not vinha_private.business_day(d) then raise exception 'Fim de semana ou feriado nacional';end if;
 if exists(select 1 from vinha_private.visits where client_id=c.id and visit_date=d) then raise exception 'Já existe visita nesta data';end if;
 perform vinha_private.capacity(c.id,d);
 insert into vinha_private.visits(client_id,visit_date) values(c.id,d);made:=made||jsonb_build_array(d);
 exception when raise_exception then skipped:=skipped||jsonb_build_array(jsonb_build_object('date',d,'reason',sqlerrm));end;
 if freq='Mensal' then next_month:=(date_trunc('month',d)+interval '1 month')::date;d:=next_month+least(extract(day from start_d)::int,extract(day from (next_month+interval '1 month - 1 day'))::int)-1;
 else d:=d+case freq when 'Semanal' then 7 else 14 end;end if;
 end loop;
 if jsonb_array_length(made)>0 then update vinha_private.clients set frequency=freq,version=version+1 where id=c.id;end if;
 out_data:=jsonb_build_object('created',made,'skipped',skipped);
 elsif (p_path ~ '^/visits/[0-9]+$' and p_method='PATCH') or (p_path ~ '^/requests/[0-9]+/review$' and p_method='POST') then
 approved:=true;
 if p_path like '/requests/%' then
 select * into rq from vinha_private.requests where id=split_part(p_path,'/',3)::bigint;
 if not found or rq.status<>'Pendente' then raise exception 'Pedido já analisado ou não encontrado.';end if;
 if p_body->>'decision' is null or p_body->>'decision' not in ('approve','reject') then raise exception 'Decisão inválida.';end if;
 approved:=p_body->>'decision'='approve';ident:=rq.visit_id;d:=coalesce((p_body->>'date')::date,rq.proposed_date);freq:=coalesce(p_body->>'frequency',rq.frequency);
 else ident:=split_part(p_path,'/',3)::bigint;d:=(p_body->>'visit_date')::date;freq:=p_body->>'frequency';end if;
 if approved then
 select * into v from vinha_private.visits where id=ident;if not found then raise exception 'Visita não encontrada.';end if;
 select * into strict c from vinha_private.clients where id=v.client_id;
 if v.status<>'Agendada' then raise exception 'Somente visitas agendadas podem ser remarcadas.';end if;
 if p_path like '/requests/%' then
 if v.version<>rq.visit_version or c.version<>rq.client_version then raise exception 'A agenda mudou desde o pedido. Atualize a visita e recuse este pedido antigo.';end if;
 elsif v.version is distinct from (p_body->>'version')::integer then raise exception 'Visita alterada. Atualize a tela.';end if;
 if d is null or not vinha_private.business_day(d) then raise exception 'Escolha um dia útil.';end if;
 perform vinha_private.capacity(c.id,d,v.id);
 update vinha_private.visits set visit_date=d,version=version+1 where id=v.id;
 update vinha_private.clients set frequency=freq,availability=case when p_path like '/requests/%' then rq.availability else availability end,version=version+1 where id=c.id;
 end if;
 if p_path like '/requests/%' then update vinha_private.requests set status=case when approved then 'Aprovada' else 'Recusada' end,reviewed=now(),admin_note=left(coalesce(p_body->>'note',''),1000) where id=rq.id;end if;
 out_data:='{"ok":true}';
 elsif p_path='/import/preview' and p_method='POST' then
 if jsonb_typeof(p_body->'records') is distinct from 'array' or jsonb_array_length(p_body->'records')>15000 then raise exception 'Importe até 15 mil clientes por arquivo.'; end if;
 for row_data in select value from jsonb_array_elements(p_body->'records') loop
 if coalesce(row_data->>'cnpj','') !~ '^[0-9]{14}$' or length(coalesce(row_data->>'name','')) not between 1 and 200 or length(coalesce(row_data->>'seller','')) not between 1 and 200 or jsonb_typeof(row_data->'dates') is distinct from 'array' or jsonb_array_length(row_data->'dates')>94 then raise exception 'Há um cadastro inválido na importação.';end if;
 end loop;
 delete from vinha_private.imports where expires<now();
 insert into vinha_private.imports(user_id,payload) values(u.id,p_body) returning id into import_id;
 return jsonb_build_object('import_id',import_id,'clients',jsonb_array_length(p_body->'records'),'visits',(select coalesce(sum(jsonb_array_length(value->'dates')),0) from jsonb_array_elements(p_body->'records')),'sellers',(select coalesce(jsonb_agg(s),'[]') from (select distinct value->>'seller' s from jsonb_array_elements(p_body->'records')) t),'warnings',coalesce(p_body->'warnings','[]'),'sample',(select coalesce(jsonb_agg(value),'[]') from (select value from jsonb_array_elements(p_body->'records') limit 8) t),'sheets',p_body->'sheets');
 elsif p_path='/import/confirm' and p_method='POST' then
 select * into imp from vinha_private.imports where id=(p_body->>'import_id')::uuid and user_id=u.id and expires>now();if not found then raise exception 'Prévia expirada. Leia a planilha novamente.';end if;
 warns:=coalesce(imp.payload->'warnings','[]');
 for row_data in select value from jsonb_array_elements(imp.payload->'records') loop
 insert into vinha_private.sellers(name) values(row_data->>'seller') on conflict(name) do nothing;
 select id into sid from vinha_private.sellers where name=row_data->>'seller';
 select * into c from vinha_private.clients where cnpj=row_data->>'cnpj' and seller_id=sid;
 if found then old_clients:=old_clients+1;
 else
 insert into vinha_private.clients(cnpj,name,seller_id,channel,city,bairro,address,frequency,active,central) values(row_data->>'cnpj',row_data->>'name',sid,row_data->>'channel',row_data->>'city',row_data->>'bairro',row_data->>'address',row_data->>'frequency',(row_data->>'active')::boolean,(row_data->>'central')::boolean) returning * into c;
 new_clients:=new_clients+1;end if;
 for did in select jsonb_array_elements_text(row_data->'dates') loop
 begin
 d:=did::date;
 if not exists(select 1 from vinha_private.visits where client_id=c.id and visit_date=d) then
 if not vinha_private.business_day(d) then raise exception 'Fim de semana ou feriado nacional';end if;
 perform vinha_private.capacity(c.id,d);insert into vinha_private.visits(client_id,visit_date) values(c.id,d);new_visits:=new_visits+1;end if;
 exception when raise_exception or invalid_datetime_format or datetime_field_overflow then warns:=warns||jsonb_build_array(c.name||' em '||did||': '||sqlerrm);end;
 end loop;
 end loop;
 delete from vinha_private.imports where id=imp.id;
 out_data:=jsonb_build_object('clients_created',new_clients,'clients_preserved',old_clients,'visits_created',new_visits,'warnings',warns);
 else raise exception 'Operação não encontrada.';end if;
 insert into vinha_private.audit(user_id,action,payload) values(u.id,p_path,out_data);return out_data;
end $$;
revoke all on function public.vinha_api(uuid,uuid,text,text,jsonb,jsonb) from public,anon,authenticated;
grant execute on function public.vinha_api(uuid,uuid,text,text,jsonb,jsonb) to service_role;
