-- Commonroom admin control room. PIN hash is provisioned out-of-band in private.chat_admin_config.
create table if not exists private.chat_admin_config (
 singleton boolean primary key default true check(singleton), pin_salt bytea not null,
 pin_hash text not null, updated_at timestamptz not null default now()
);
revoke all on private.chat_admin_config from public,anon,authenticated;
create table if not exists private.chat_admin_login_attempts (
 id bigint generated always as identity primary key, client_ip inet not null, attempted_at timestamptz not null default now()
);
create index if not exists chat_admin_login_attempts_ip_time_idx on private.chat_admin_login_attempts(client_ip,attempted_at desc);
alter table private.chat_admin_login_attempts enable row level security;
revoke all on private.chat_admin_login_attempts from public,anon,authenticated;
create table if not exists private.chat_admin_sessions (
 token_hash text primary key, created_at timestamptz not null default now(), expires_at timestamptz not null
);
create index if not exists chat_admin_sessions_expiry_idx on private.chat_admin_sessions(expires_at);
alter table private.chat_admin_sessions enable row level security;
revoke all on private.chat_admin_sessions from public,anon,authenticated;
create table if not exists private.chat_admin_audit (
 id bigint generated always as identity primary key, action text not null, target_id uuid,
 details jsonb not null default '{}'::jsonb, created_at timestamptz not null default now()
);
create index if not exists chat_admin_audit_created_idx on private.chat_admin_audit(created_at desc);
alter table private.chat_admin_audit enable row level security;
revoke all on private.chat_admin_audit from public,anon,authenticated;
create unique index if not exists chat_guest_reports_message_reporter_uidx on public.chat_guest_reports(message_id,reporter_key);

create or replace function private.chat_admin_session_valid(p_token text)
returns boolean language sql stable security definer set search_path=pg_catalog,private as $$
 select p_token is not null and length(p_token)>=48 and exists(
  select 1 from private.chat_admin_sessions where token_hash=encode(sha256(convert_to(p_token,'UTF8')),'hex') and expires_at>now()
 );
$$;
revoke all on function private.chat_admin_session_valid(text) from public;
grant execute on function private.chat_admin_session_valid(text) to anon,authenticated;

create or replace function private.chat_admin_login(p_pin text)
returns jsonb language plpgsql security definer set search_path=pg_catalog,private as $$
declare h jsonb:=nullif(current_setting('request.headers',true),'')::jsonb; ip inet; fails integer; global_fails integer;
cfg private.chat_admin_config%rowtype; token text;
begin
 ip:=nullif(split_part(coalesce(h->>'x-forwarded-for',''),',',1),'')::inet;
 if ip is null then return jsonb_build_object('ok',false,'error','Unable to verify this connection.'); end if;
 perform pg_advisory_xact_lock(hashtext('commonroom-admin:'||ip::text));
 select count(*) into fails from private.chat_admin_login_attempts where client_ip=ip and attempted_at>now()-interval '15 minutes';
 select count(*) into global_fails from private.chat_admin_login_attempts where attempted_at>now()-interval '15 minutes';
 if fails>=5 or global_fails>=30 then return jsonb_build_object('ok',false,'error','Too many incorrect attempts. Try again in 15 minutes.'); end if;
 select * into cfg from private.chat_admin_config where singleton=true;
 if not found then return jsonb_build_object('ok',false,'error','Admin authentication is not configured.'); end if;
 if p_pin is null or p_pin !~ '^[0-9]{4}$' or encode(sha256(cfg.pin_salt||convert_to(p_pin,'UTF8')),'hex')<>cfg.pin_hash then
  insert into private.chat_admin_login_attempts(client_ip) values(ip);
  return jsonb_build_object('ok',false,'error','Incorrect PIN.');
 end if;
 delete from private.chat_admin_login_attempts where client_ip=ip;
 delete from private.chat_admin_sessions where expires_at<=now();
 token:=replace(gen_random_uuid()::text||gen_random_uuid()::text,'-','');
 insert into private.chat_admin_sessions(token_hash,expires_at) values(encode(sha256(convert_to(token,'UTF8')),'hex'),now()+interval '30 minutes');
 insert into private.chat_admin_audit(action,details) values('admin_login',jsonb_build_object('source','control_room'));
 return jsonb_build_object('ok',true,'token',token,'expires_at',now()+interval '30 minutes');
end;
$$;
revoke all on function private.chat_admin_login(text) from public;
grant execute on function private.chat_admin_login(text) to anon,authenticated;

create or replace function private.chat_admin_logout(p_token text)
returns boolean language plpgsql security definer set search_path=pg_catalog,private as $$
declare n integer;
begin
 delete from private.chat_admin_sessions where token_hash=encode(sha256(convert_to(coalesce(p_token,''),'UTF8')),'hex');
 get diagnostics n=row_count; return n=1;
end;
$$;
revoke all on function private.chat_admin_logout(text) from public;
grant execute on function private.chat_admin_logout(text) to anon,authenticated;

create or replace function private.chat_admin_overview(p_token text)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,private as $$
declare result jsonb;
begin
 if not private.chat_admin_session_valid(p_token) then raise exception 'Admin session expired. Please sign in again.' using errcode='28000'; end if;
 select jsonb_build_object(
  'stats',jsonb_build_object(
   'rooms',(select count(*) from public.chat_rooms),
   'messages',(select count(*) from public.chat_guest_messages),
   'messages_today',(select count(*) from public.chat_guest_messages where created_at>=date_trunc('day',now())),
   'reactions',(select count(*) from public.chat_guest_reactions),
   'open_reports',(select count(*) from public.chat_guest_reports where status='open')
  ),
  'rooms',(select coalesce(jsonb_agg(to_jsonb(r) order by r.name),'[]'::jsonb) from (select id,slug,name,description,created_at from public.chat_rooms order by name) r),
  'messages',(select coalesce(jsonb_agg(to_jsonb(m) order by m.created_at desc),'[]'::jsonb) from
    (select m.id,m.room_id,r.name as room_name,m.sender_name,m.body,m.created_at,m.edited_at from public.chat_guest_messages m join public.chat_rooms r on r.id=m.room_id order by m.created_at desc limit 40) m),
  'reports',(select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc),'[]'::jsonb) from
    (select g.id,g.message_id,g.reason,g.details,g.status,g.created_at,m.sender_name,m.body,r.name as room_name
     from public.chat_guest_reports g left join public.chat_guest_messages m on m.id=g.message_id
     left join public.chat_rooms r on r.id=m.room_id where g.status='open' order by g.created_at desc limit 40) x),
  'audit',(select coalesce(jsonb_agg(to_jsonb(a) order by a.created_at desc),'[]'::jsonb) from
    (select id,action,target_id,details,created_at from private.chat_admin_audit order by created_at desc limit 20) a)
 ) into result;
 return result;
end;
$$;
revoke all on function private.chat_admin_overview(text) from public;
grant execute on function private.chat_admin_overview(text) to anon,authenticated;

create or replace function private.chat_admin_delete_message(p_token text,p_message_id uuid)
returns boolean language plpgsql security definer set search_path=pg_catalog,public,private as $$
declare n integer;
begin
 if not private.chat_admin_session_valid(p_token) then raise exception 'Admin session expired.' using errcode='28000'; end if;
 delete from public.chat_guest_messages where id=p_message_id; get diagnostics n=row_count;
 if n=1 then insert into private.chat_admin_audit(action,target_id) values('delete_message',p_message_id); end if;
 return n=1;
end;
$$;
revoke all on function private.chat_admin_delete_message(text,uuid) from public;
grant execute on function private.chat_admin_delete_message(text,uuid) to anon,authenticated;

create or replace function private.chat_admin_resolve_report(p_token text,p_report_id uuid,p_status text)
returns boolean language plpgsql security definer set search_path=pg_catalog,public,private as $$
declare n integer;
begin
 if not private.chat_admin_session_valid(p_token) then raise exception 'Admin session expired.' using errcode='28000'; end if;
 if p_status not in ('reviewed','dismissed') then raise exception 'Invalid report status.'; end if;
 update public.chat_guest_reports set status=p_status where id=p_report_id and status='open'; get diagnostics n=row_count;
 if n=1 then insert into private.chat_admin_audit(action,target_id,details) values('resolve_report',p_report_id,jsonb_build_object('status',p_status)); end if;
 return n=1;
end;
$$;
revoke all on function private.chat_admin_resolve_report(text,uuid,text) from public;
grant execute on function private.chat_admin_resolve_report(text,uuid,text) to anon,authenticated;

create or replace function private.chat_admin_delete_room(p_token text,p_room_id uuid)
returns boolean language plpgsql security definer set search_path=pg_catalog,public,private as $$
declare slug_value text; n integer;
begin
 if not private.chat_admin_session_valid(p_token) then raise exception 'Admin session expired.' using errcode='28000'; end if;
 select slug into slug_value from public.chat_rooms where id=p_room_id;
 if slug_value is null or slug_value='general' or (select count(*) from public.chat_rooms)<=1 then return false; end if;
 delete from public.chat_rooms where id=p_room_id; get diagnostics n=row_count;
 if n=1 then insert into private.chat_admin_audit(action,target_id,details) values('delete_room',p_room_id,jsonb_build_object('slug',slug_value)); end if;
 return n=1;
end;
$$;
revoke all on function private.chat_admin_delete_room(text,uuid) from public;
grant execute on function private.chat_admin_delete_room(text,uuid) to anon,authenticated;

create or replace function private.chat_admin_update_room(p_token text,p_room_id uuid,p_name text,p_description text)
returns boolean language plpgsql security definer set search_path=pg_catalog,public,private as $$
declare n integer;
begin
 if not private.chat_admin_session_valid(p_token) then raise exception 'Admin session expired.' using errcode='28000'; end if;
 if p_name is null or length(btrim(p_name)) not between 2 and 40 or p_description is null or length(p_description)>180 then return false; end if;
 update public.chat_rooms set name=btrim(p_name),description=btrim(p_description) where id=p_room_id; get diagnostics n=row_count;
 if n=1 then insert into private.chat_admin_audit(action,target_id,details) values('update_room',p_room_id,jsonb_build_object('name',btrim(p_name))); end if;
 return n=1;
end;
$$;
revoke all on function private.chat_admin_update_room(text,uuid,text,text) from public;
grant execute on function private.chat_admin_update_room(text,uuid,text,text) to anon,authenticated;

create or replace function private.submit_guest_report(p_message_id uuid,p_reporter_key uuid,p_reason text,p_details text)
returns boolean language plpgsql security definer set search_path=pg_catalog,public,private as $$
declare n integer;
begin
 if p_reason not in ('spam','harassment','hate','personal-info','other') or p_details is null or length(p_details)>300 then return false; end if;
 insert into public.chat_guest_reports(message_id,reporter_key,reason,details)
 select p_message_id,p_reporter_key,p_reason,btrim(p_details)
 where exists(select 1 from public.chat_guest_messages where id=p_message_id)
 on conflict(message_id,reporter_key) do nothing;
 get diagnostics n=row_count; return n=1;
end;
$$;
revoke all on function private.submit_guest_report(uuid,uuid,text,text) from public;
grant execute on function private.submit_guest_report(uuid,uuid,text,text) to anon,authenticated;

create or replace function public.admin_login(p_pin text) returns jsonb language sql security invoker set search_path=pg_catalog,public as $$ select private.chat_admin_login(p_pin); $$;
create or replace function public.admin_logout(p_token text) returns boolean language sql security invoker set search_path=pg_catalog,public as $$ select private.chat_admin_logout(p_token); $$;
create or replace function public.admin_overview(p_token text) returns jsonb language sql security invoker set search_path=pg_catalog,public as $$ select private.chat_admin_overview(p_token); $$;
create or replace function public.admin_delete_message(p_token text,p_message_id uuid) returns boolean language sql security invoker set search_path=pg_catalog,public as $$ select private.chat_admin_delete_message(p_token,p_message_id); $$;
create or replace function public.admin_resolve_report(p_token text,p_report_id uuid,p_status text) returns boolean language sql security invoker set search_path=pg_catalog,public as $$ select private.chat_admin_resolve_report(p_token,p_report_id,p_status); $$;
create or replace function public.admin_delete_room(p_token text,p_room_id uuid) returns boolean language sql security invoker set search_path=pg_catalog,public as $$ select private.chat_admin_delete_room(p_token,p_room_id); $$;
create or replace function public.admin_update_room(p_token text,p_room_id uuid,p_name text,p_description text) returns boolean language sql security invoker set search_path=pg_catalog,public as $$ select private.chat_admin_update_room(p_token,p_room_id,p_name,p_description); $$;
create or replace function public.submit_guest_report(p_message_id uuid,p_reporter_key uuid,p_reason text,p_details text) returns boolean language sql security invoker set search_path=pg_catalog,public as $$ select private.submit_guest_report(p_message_id,p_reporter_key,p_reason,p_details); $$;
revoke all on function public.admin_login(text) from public;
revoke all on function public.admin_logout(text) from public;
revoke all on function public.admin_overview(text) from public;
revoke all on function public.admin_delete_message(text,uuid) from public;
revoke all on function public.admin_resolve_report(text,uuid,text) from public;
revoke all on function public.admin_delete_room(text,uuid) from public;
revoke all on function public.admin_update_room(text,uuid,text,text) from public;
revoke all on function public.submit_guest_report(uuid,uuid,text,text) from public;
grant execute on function public.admin_login(text) to anon,authenticated;
grant execute on function public.admin_logout(text) to anon,authenticated;
grant execute on function public.admin_overview(text) to anon,authenticated;
grant execute on function public.admin_delete_message(text,uuid) to anon,authenticated;
grant execute on function public.admin_resolve_report(text,uuid,text) to anon,authenticated;
grant execute on function public.admin_delete_room(text,uuid) to anon,authenticated;
grant execute on function public.admin_update_room(text,uuid,text,text) to anon,authenticated;
grant execute on function public.submit_guest_report(uuid,uuid,text,text) to anon,authenticated;


-- Correctly qualify the request IP variable used by the admin login limiter.
create or replace function private.chat_admin_login(p_pin text)
returns jsonb language plpgsql security definer set search_path=pg_catalog,private as $$
declare
  request_headers jsonb := nullif(current_setting('request.headers',true),'')::jsonb;
  v_client_ip inet;
  failed_attempts integer;
  global_attempts integer;
  config_row private.chat_admin_config%rowtype;
  session_token text;
begin
  v_client_ip:=nullif(split_part(coalesce(request_headers->>'x-forwarded-for',''),',',1),'')::inet;
  if v_client_ip is null then return jsonb_build_object('ok',false,'error','Unable to verify this connection.'); end if;
  perform pg_advisory_xact_lock(hashtext('commonroom-admin:'||v_client_ip::text));
  select count(*) into failed_attempts from private.chat_admin_login_attempts a
    where a.client_ip=v_client_ip and a.attempted_at>now()-interval '15 minutes';
  select count(*) into global_attempts from private.chat_admin_login_attempts a
    where a.attempted_at>now()-interval '15 minutes';
  if failed_attempts>=5 or global_attempts>=30 then return jsonb_build_object('ok',false,'error','Too many incorrect attempts. Try again in 15 minutes.'); end if;
  select * into config_row from private.chat_admin_config where singleton=true;
  if not found then return jsonb_build_object('ok',false,'error','Admin authentication is not configured.'); end if;
  if p_pin is null or p_pin !~ '^[0-9]{4}$'
     or encode(sha256(config_row.pin_salt||convert_to(p_pin,'UTF8')),'hex')<>config_row.pin_hash then
    insert into private.chat_admin_login_attempts(client_ip) values(v_client_ip);
    return jsonb_build_object('ok',false,'error','Incorrect PIN.');
  end if;
  delete from private.chat_admin_login_attempts a where a.client_ip=v_client_ip;
  delete from private.chat_admin_sessions where expires_at<=now();
  session_token:=replace(gen_random_uuid()::text||gen_random_uuid()::text,'-','');
  insert into private.chat_admin_sessions(token_hash,expires_at) values(encode(sha256(convert_to(session_token,'UTF8')),'hex'),now()+interval '30 minutes');
  insert into private.chat_admin_audit(action,details) values('admin_login',jsonb_build_object('source','control_room'));
  return jsonb_build_object('ok',true,'token',session_token,'expires_at',now()+interval '30 minutes');
end;
$$;