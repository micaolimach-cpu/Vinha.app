begin;
-- Every fixture and mutation is rolled back. No authentication token is issued.
insert into auth.users(id,email,email_confirmed_at) values ('10000000-0000-4000-8000-000000000001','vinha-admin@example.invalid',now()),('10000000-0000-4000-8000-000000000002','vinha-seller@example.invalid',now());
insert into auth.sessions(id,user_id,created_at,updated_at) values ('20000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000001',now(),now()),('20000000-0000-4000-8000-000000000002','10000000-0000-4000-8000-000000000002',now(),now());
insert into vinha_private.users(email,role) values('vinha-admin@example.invalid','admin'),('vinha-seller@example.invalid','seller');
set local role service_role;
do $$
declare au uuid:='10000000-0000-4000-8000-000000000001';su uuid:='10000000-0000-4000-8000-000000000002';ase uuid:='20000000-0000-4000-8000-000000000001';sse uuid:='20000000-0000-4000-8000-000000000002';
 r jsonb;preview jsonb;cid bigint;vid bigint;rid bigint;sid bigint;uid bigint;bad boolean;d date:=(now() at time zone 'America/Sao_Paulo')::date;nxt date;payload jsonb;
begin
 r:=public.vinha_api(au,ase,'/me','GET');if r->'user'->>'role'<>'admin' then raise exception 'FAIL me';end if;
 r:=public.vinha_api(au,ase,'/team','GET');
 payload:=jsonb_build_object('records',jsonb_build_array(jsonb_build_object('cnpj','12345678000190','name','Fixture','seller','Fixture seller','channel','ON-TRADE','city','Porto Alegre','bairro','Centro','address','Rua de teste','frequency','Semanal','active',true,'central',true,'dates',jsonb_build_array(d))),'warnings','[]'::jsonb,'sheets',jsonb_build_array('Clientes'));
 preview:=public.vinha_api(au,ase,'/import/preview','POST',payload);
 r:=public.vinha_api(au,ase,'/import/confirm','POST',jsonb_build_object('import_id',preview->>'import_id'));
 if (r->>'clients_created')::int<>1 then raise exception 'FAIL import';end if;
 select id,seller_id into cid,sid from vinha_private.clients where cnpj='12345678000190';
 select id into uid from vinha_private.users where email='vinha-seller@example.invalid';
 r:=public.vinha_api(su,sse,'/clients','GET');if jsonb_array_length(r->'clients')<>0 then raise exception 'FAIL isolation';end if;
 r:=public.vinha_api(au,ase,'/team','POST',jsonb_build_object('email','vinha-seller@example.invalid','seller_id',sid));
 r:=public.vinha_api(su,sse,'/clients','GET');if jsonb_array_length(r->'clients')<>1 then raise exception 'FAIL grant';end if;
 bad:=false;begin perform public.vinha_api(su,sse,'/team','GET');exception when insufficient_privilege then bad:=true;end;if not bad then raise exception 'FAIL seller admin denial';end if;
 -- Insert today explicitly so the test also works on weekends/holidays.
 insert into vinha_private.visits(client_id,visit_date) values(cid,d) on conflict(client_id,visit_date) do nothing;
 select id into vid from vinha_private.visits where client_id=cid and visit_date=d;
 r:=public.vinha_api(su,sse,'/visits','GET','{}',jsonb_build_object('from',d,'to',d));if jsonb_array_length(r->'visits')<>1 then raise exception 'FAIL visits';end if;
 nxt:=d+1;while not vinha_private.business_day(nxt) loop nxt:=nxt+1;end loop;
 r:=public.vinha_api(su,sse,'/requests','POST',jsonb_build_object('visit_id',vid,'proposed_date',nxt,'frequency','Mensal','availability','Tarde','reason','Comprador ausente'));rid:=(r->>'id')::bigint;
 r:=public.vinha_api(au,ase,'/requests','GET');if jsonb_array_length(r->'requests')<>1 then raise exception 'FAIL requests';end if;
 r:=public.vinha_api(au,ase,'/requests/'||rid||'/review','POST',jsonb_build_object('decision','approve'));
 if (select visit_date from vinha_private.visits where id=vid)<>nxt then raise exception 'FAIL approval';end if;
 update vinha_private.visits set visit_date=d where id=vid;
 r:=public.vinha_api(su,sse,'/visits/'||vid||'/checkin','POST');
 bad:=false;begin perform public.vinha_api(au,ase,'/visits/'||vid||'/checkout','POST');exception when raise_exception then bad:=true;end;if not bad then raise exception 'FAIL checkout owner';end if;
 r:=public.vinha_api(su,sse,'/visits/'||vid||'/checkout','POST');if (select status from vinha_private.visits where id=vid)<>'Realizada' then raise exception 'FAIL checkout';end if;
 r:=public.vinha_api(au,ase,'/clients/'||cid,'PATCH',jsonb_build_object('version',(select version from vinha_private.clients where id=cid),'name','Manual edit','city','Porto Alegre','bairro','Centro','address','Rua','frequency','Semanal','availability','','active',true,'central',true));
 preview:=public.vinha_api(au,ase,'/import/preview','POST',payload);r:=public.vinha_api(au,ase,'/import/confirm','POST',jsonb_build_object('import_id',preview->>'import_id'));if (r->>'clients_preserved')::int<>1 or (select name from vinha_private.clients where id=cid)<>'Manual edit' then raise exception 'FAIL preserve';end if;
 r:=public.vinha_api(au,ase,'/schedule','POST',jsonb_build_object('client_id',cid,'start',nxt,'until',nxt+21,'frequency','Semanal'));if jsonb_array_length(r->'created')<1 then raise exception 'FAIL schedule';end if;
 select id into vid from vinha_private.visits where client_id=cid and visit_date=nxt;
 r:=public.vinha_api(au,ase,'/visits/'||vid,'PATCH',jsonb_build_object('visit_date',nxt,'version',(select version from vinha_private.visits where id=vid),'frequency','Mensal'));
 -- Capacity enforces the same maximum inside the server transaction.
 for i in 1..10 loop
 insert into vinha_private.clients(cnpj,name,seller_id,channel,frequency) values(lpad(i::text,14,'0'),'Capacity fixture',sid,'OFF-TRADE','Mensal') returning id into uid;
 insert into vinha_private.visits(client_id,visit_date) values(uid,nxt+100);
 end loop;
 bad:=false;begin perform vinha_private.capacity(cid,nxt+100);exception when raise_exception then bad:=true;end;if not bad then raise exception 'FAIL capacity';end if;
 select id into uid from vinha_private.users where email='vinha-seller@example.invalid';
 r:=public.vinha_api(au,ase,'/team/'||uid,'DELETE');
 bad:=false;begin perform public.vinha_api(su,sse,'/clients','GET');exception when invalid_authorization_specification then bad:=true;end;if not bad then raise exception 'FAIL revoke';end if;
end $$;
reset role;
select 'PASS: auth, permissions, import, duplicate preservation, visits, requests, approval, check-in/out, edit, scheduling, capacity and revocation' as result;
rollback;
