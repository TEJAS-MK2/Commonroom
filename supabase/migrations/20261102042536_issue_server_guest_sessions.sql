-- Add server-issued guest identities. Legacy sender-key overloads remain temporarily
-- for a safe rolling deployment and are removed after the new browser bundle is live.
create table if not exists private.chat_guest_sessions (
  token_hash text primary key check (token_hash ~ '^[a-f0-9]{64}$'),
  sender_key uuid not null unique,
  display_name text not null check (char_length(display_name) between 2 and 32),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  expires_at timestamptz not null
);
create index if not exists chat_guest_sessions_expires_idx on private.chat_guest_sessions(expires_at);
alter table private.chat_guest_sessions enable row level security;
revoke all on table private.chat_guest_sessions from public, anon, authenticated;

create or replace function private.create_guest_session(p_display_name text)
returns jsonb language plpgsql security definer set search_path=pg_catalog,private as $$
declare
  v_display_name text := coalesce(nullif(btrim(p_display_name),''),'Guest');
  v_token text;
  v_sender_key uuid := gen_random_uuid();
  v_expires_at timestamptz := now()+interval '7 days';
begin
  if char_length(v_display_name) not between 2 and 32 then
    raise exception 'Display name must contain 2 to 32 characters.' using errcode='22023';
  end if;
  delete from private.chat_guest_sessions where expires_at<=now();
  v_token:=replace(gen_random_uuid()::text||gen_random_uuid()::text,'-','');
  insert into private.chat_guest_sessions(token_hash,sender_key,display_name,expires_at)
  values(encode(sha256(convert_to(v_token,'UTF8')),'hex'),v_sender_key,v_display_name,v_expires_at);
  return jsonb_build_object('ok',true,'token',v_token,'sender_key',v_sender_key,'display_name',v_display_name,'expires_at',v_expires_at);
end;
$$;

create or replace function private.resume_guest_session(p_session_token text)
returns jsonb language plpgsql security definer set search_path=pg_catalog,private as $$
declare v_sender_key uuid; v_display_name text; v_expires_at timestamptz;
begin
  if p_session_token is null or p_session_token !~ '^[a-f0-9]{64}$' then return jsonb_build_object('ok',false); end if;
  update private.chat_guest_sessions set updated_at=now(),expires_at=now()+interval '7 days'
   where token_hash=encode(sha256(convert_to(p_session_token,'UTF8')),'hex') and expires_at>now()
   returning sender_key,display_name,expires_at into v_sender_key,v_display_name,v_expires_at;
  if not found then return jsonb_build_object('ok',false); end if;
  return jsonb_build_object('ok',true,'sender_key',v_sender_key,'display_name',v_display_name,'expires_at',v_expires_at);
end;
$$;

create or replace function private.update_guest_session_name(p_session_token text,p_display_name text)
returns boolean language plpgsql security definer set search_path=pg_catalog,private as $$
begin
  if p_session_token is null or p_session_token !~ '^[a-f0-9]{64}$'
     or p_display_name is null or char_length(btrim(p_display_name)) not between 2 and 32 then return false; end if;
  update private.chat_guest_sessions set display_name=btrim(p_display_name),updated_at=now(),expires_at=now()+interval '7 days'
   where token_hash=encode(sha256(convert_to(p_session_token,'UTF8')),'hex') and expires_at>now();
  return found;
end;
$$;

create or replace function private.create_guest_message(
  p_room_id uuid,p_session_token text,p_sender_name text,p_body text,p_reply_to uuid,p_token_hash text
)
returns uuid language plpgsql security definer set search_path=pg_catalog,public,private as $$
declare v_message_id uuid; v_sender_key uuid;
begin
  if p_room_id is null or p_session_token is null or p_session_token !~ '^[a-f0-9]{64}$'
     or p_sender_name is null or char_length(btrim(p_sender_name)) not between 2 and 32
     or p_body is null or char_length(btrim(p_body)) not between 1 and 2000
     or p_token_hash is null or p_token_hash !~ '^[a-f0-9]{64}$' then
    raise exception 'Invalid message payload.' using errcode='22023';
  end if;
  update private.chat_guest_sessions set display_name=btrim(p_sender_name),updated_at=now(),expires_at=now()+interval '7 days'
   where token_hash=encode(sha256(convert_to(p_session_token,'UTF8')),'hex') and expires_at>now()
   returning sender_key into v_sender_key;
  if not found then raise exception 'Guest session expired. Refresh the page.' using errcode='28000'; end if;
  if p_reply_to is not null and not exists(select 1 from public.chat_guest_messages where id=p_reply_to and room_id=p_room_id) then
    raise exception 'Replies must point to a message in the same room.' using errcode='23503';
  end if;
  insert into public.chat_guest_messages(room_id,sender_key,sender_name,body,reply_to)
  values(p_room_id,v_sender_key,btrim(p_sender_name),btrim(p_body),p_reply_to) returning id into v_message_id;
  insert into private.chat_guest_message_tokens(message_id,token_hash) values(v_message_id,p_token_hash);
  return v_message_id;
end;
$$;

create or replace function private.create_guest_reaction(p_message_id uuid,p_session_token text,p_emoji text,p_token_hash text)
returns uuid language plpgsql security definer set search_path=pg_catalog,public,private as $$
declare v_reaction_id uuid; v_sender_key uuid;
begin
  if p_message_id is null or p_session_token is null or p_session_token !~ '^[a-f0-9]{64}$'
     or p_emoji not in ('👍','❤️','😂','🎉','🔥','👀','🙌','🤔')
     or p_token_hash is null or p_token_hash !~ '^[a-f0-9]{64}$' then
    raise exception 'Invalid reaction payload.' using errcode='22023';
  end if;
  update private.chat_guest_sessions set updated_at=now(),expires_at=now()+interval '7 days'
   where token_hash=encode(sha256(convert_to(p_session_token,'UTF8')),'hex') and expires_at>now()
   returning sender_key into v_sender_key;
  if not found then raise exception 'Guest session expired. Refresh the page.' using errcode='28000'; end if;
  insert into public.chat_guest_reactions(message_id,sender_key,emoji) values(p_message_id,v_sender_key,p_emoji) returning id into v_reaction_id;
  insert into private.chat_guest_reaction_tokens(reaction_id,token_hash) values(v_reaction_id,p_token_hash);
  return v_reaction_id;
end;
$$;

create or replace function private.submit_guest_report(p_message_id uuid,p_session_token text,p_reason text,p_details text)
returns boolean language plpgsql security definer set search_path=pg_catalog,public,private as $$
declare v_reporter_key uuid; inserted integer;
begin
  if p_session_token is null or p_session_token !~ '^[a-f0-9]{64}$'
     or p_reason not in ('spam','harassment','hate','personal-info','other')
     or p_details is null or length(p_details)>300 then return false; end if;
  update private.chat_guest_sessions set updated_at=now(),expires_at=now()+interval '7 days'
   where token_hash=encode(sha256(convert_to(p_session_token,'UTF8')),'hex') and expires_at>now()
   returning sender_key into v_reporter_key;
  if not found then return false; end if;
  insert into public.chat_guest_reports(message_id,reporter_key,reason,details)
  select p_message_id,v_reporter_key,p_reason,btrim(p_details)
   where exists(select 1 from public.chat_guest_messages where id=p_message_id)
  on conflict(message_id,reporter_key) do nothing;
  get diagnostics inserted=row_count;
  return inserted=1;
end;
$$;

create or replace function public.create_guest_session(p_display_name text)
returns jsonb language sql set search_path=pg_catalog,public as $$ select private.create_guest_session(p_display_name); $$;
create or replace function public.resume_guest_session(p_session_token text)
returns jsonb language sql set search_path=pg_catalog,public as $$ select private.resume_guest_session(p_session_token); $$;
create or replace function public.update_guest_session_name(p_session_token text,p_display_name text)
returns boolean language sql set search_path=pg_catalog,public as $$ select private.update_guest_session_name(p_session_token,p_display_name); $$;
create or replace function public.create_guest_message(p_room_id uuid,p_session_token text,p_sender_name text,p_body text,p_reply_to uuid,p_token_hash text)
returns uuid language sql set search_path=pg_catalog,public as $$ select private.create_guest_message(p_room_id,p_session_token,p_sender_name,p_body,p_reply_to,p_token_hash); $$;
create or replace function public.create_guest_reaction(p_message_id uuid,p_session_token text,p_emoji text,p_token_hash text)
returns uuid language sql set search_path=pg_catalog,public as $$ select private.create_guest_reaction(p_message_id,p_session_token,p_emoji,p_token_hash); $$;
create or replace function public.submit_guest_report(p_message_id uuid,p_session_token text,p_reason text,p_details text)
returns boolean language sql set search_path=pg_catalog,public as $$ select private.submit_guest_report(p_message_id,p_session_token,p_reason,p_details); $$;

revoke all on function private.create_guest_session(text) from public;
revoke all on function private.resume_guest_session(text) from public;
revoke all on function private.update_guest_session_name(text,text) from public;
revoke all on function private.create_guest_message(uuid,text,text,text,uuid,text) from public;
revoke all on function private.create_guest_reaction(uuid,text,text,text) from public;
revoke all on function private.submit_guest_report(uuid,text,text,text) from public;
grant execute on function private.create_guest_session(text) to anon,authenticated;
grant execute on function private.resume_guest_session(text) to anon,authenticated;
grant execute on function private.update_guest_session_name(text,text) to anon,authenticated;
grant execute on function private.create_guest_message(uuid,text,text,text,uuid,text) to anon,authenticated;
grant execute on function private.create_guest_reaction(uuid,text,text,text) to anon,authenticated;
grant execute on function private.submit_guest_report(uuid,text,text,text) to anon,authenticated;

revoke all on function public.create_guest_session(text) from public;
revoke all on function public.resume_guest_session(text) from public;
revoke all on function public.update_guest_session_name(text,text) from public;
revoke all on function public.create_guest_message(uuid,text,text,text,uuid,text) from public;
revoke all on function public.create_guest_reaction(uuid,text,text,text) from public;
revoke all on function public.submit_guest_report(uuid,text,text,text) from public;
grant execute on function public.create_guest_session(text) to anon,authenticated;
grant execute on function public.resume_guest_session(text) to anon,authenticated;
grant execute on function public.update_guest_session_name(text,text) to anon,authenticated;
grant execute on function public.create_guest_message(uuid,text,text,text,uuid,text) to anon,authenticated;
grant execute on function public.create_guest_reaction(uuid,text,text,text) to anon,authenticated;
grant execute on function public.submit_guest_report(uuid,text,text,text) to anon,authenticated;

create or replace function private.enforce_chat_api_rate_limit()
returns void language plpgsql security definer set search_path=pg_catalog,private,public as $$
declare
  req_method text := current_setting('request.method',true);
  req_path text := current_setting('request.path',true);
  req_headers jsonb := nullif(current_setting('request.headers',true),'')::jsonb;
  v_ip_text text;
  req_ip inet;
  recent_count integer;
begin
  if req_method is null or req_method in ('GET','HEAD','OPTIONS') then return; end if;
  if not (
    req_path ~ '(^|/)chat_guest_(messages|reactions|rooms)(/|$)'
    or req_path ~ '(^|/)chat_rooms(/|$)'
    or req_path ~ '(^|/)rpc/(create_guest_session|resume_guest_session|update_guest_session_name|create_guest_message|create_guest_reaction|delete_guest_reaction|edit_guest_message|delete_guest_message|submit_guest_report)$'
  ) then return; end if;
  v_ip_text:=nullif(btrim(req_headers->>'cf-connecting-ip'),'');
  begin req_ip:=coalesce(v_ip_text::inet,'0.0.0.0'::inet);
  exception when invalid_text_representation then req_ip:='0.0.0.0'::inet;
  end;
  perform pg_advisory_xact_lock(hashtext(req_ip::text));
  select count(*) into recent_count from private.chat_guest_rate_limits
   where client_ip=req_ip and requested_at>now()-interval '5 minutes';
  if recent_count>=100 then
    raise sqlstate 'PGRST' using
      message=json_build_object('message','Commonroom is receiving too many requests from this network. Please wait a few minutes.')::text,
      detail=json_build_object('status',429,'status_text','Too Many Requests')::text;
  end if;
  insert into private.chat_guest_rate_limits(client_ip,request_path) values(req_ip,coalesce(req_path,'unknown'));
  delete from private.chat_guest_rate_limits where client_ip=req_ip and requested_at<now()-interval '1 day';
end;
$$;
revoke all on function private.enforce_chat_api_rate_limit() from public;
grant execute on function private.enforce_chat_api_rate_limit() to anon,authenticated;

notify pgrst, 'reload schema';
