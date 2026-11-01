-- Harden anonymous chat writes and keep ownership hashes out of the exposed public schema.
create table if not exists private.chat_guest_message_tokens (
  message_id uuid primary key references public.chat_guest_messages(id) on delete cascade,
  token_hash text not null check (token_hash ~ '^[a-f0-9]{64}$'),
  created_at timestamptz not null default now()
);
create table if not exists private.chat_guest_reaction_tokens (
  reaction_id uuid primary key references public.chat_guest_reactions(id) on delete cascade,
  token_hash text not null check (token_hash ~ '^[a-f0-9]{64}$'),
  created_at timestamptz not null default now()
);
alter table private.chat_guest_message_tokens enable row level security;
alter table private.chat_guest_reaction_tokens enable row level security;
revoke all on private.chat_guest_message_tokens, private.chat_guest_reaction_tokens from public, anon, authenticated;
insert into private.chat_guest_message_tokens(message_id, token_hash)
select id, edit_token_hash from public.chat_guest_messages
where edit_token_hash ~ '^[a-f0-9]{64}$' on conflict (message_id) do nothing;
insert into private.chat_guest_reaction_tokens(reaction_id, token_hash)
select id, reaction_token_hash from public.chat_guest_reactions
where reaction_token_hash ~ '^[a-f0-9]{64}$' on conflict (reaction_id) do nothing;

create or replace function private.create_guest_message(
  p_room_id uuid,p_sender_key uuid,p_sender_name text,p_body text,p_reply_to uuid,p_token_hash text
) returns uuid language plpgsql security definer set search_path = pg_catalog, public, private as $$
declare v_message_id uuid;
begin
  if p_room_id is null or p_sender_key is null or p_sender_name is null
     or char_length(btrim(p_sender_name)) not between 2 and 32
     or p_body is null or char_length(btrim(p_body)) not between 1 and 2000
     or p_token_hash is null or p_token_hash !~ '^[a-f0-9]{64}$' then
    raise exception 'Invalid message payload.' using errcode = '22023';
  end if;
  if p_reply_to is not null and not exists (
    select 1 from public.chat_guest_messages where id=p_reply_to and room_id=p_room_id
  ) then
    raise exception 'Replies must point to a message in the same room.' using errcode = '23503';
  end if;
  insert into public.chat_guest_messages(room_id,sender_key,sender_name,body,reply_to)
  values (p_room_id,p_sender_key,btrim(p_sender_name),btrim(p_body),p_reply_to)
  returning id into v_message_id;
  insert into private.chat_guest_message_tokens(message_id,token_hash) values(v_message_id,p_token_hash);
  return v_message_id;
end;
$$;

create or replace function private.create_guest_reaction(
  p_message_id uuid,p_sender_key uuid,p_emoji text,p_token_hash text
) returns uuid language plpgsql security definer set search_path = pg_catalog, public, private as $$
declare v_reaction_id uuid;
begin
  if p_message_id is null or p_sender_key is null
     or p_emoji not in ('👍','❤️','😂','🎉','🔥','👀','🙌','🤔')
     or p_token_hash is null or p_token_hash !~ '^[a-f0-9]{64}$' then
    raise exception 'Invalid reaction payload.' using errcode = '22023';
  end if;
  insert into public.chat_guest_reactions(message_id,sender_key,emoji)
  values(p_message_id,p_sender_key,p_emoji) returning id into v_reaction_id;
  insert into private.chat_guest_reaction_tokens(reaction_id,token_hash) values(v_reaction_id,p_token_hash);
  return v_reaction_id;
end;
$$;

create or replace function private.edit_guest_message(p_message_id uuid,p_token text,p_body text)
returns boolean language plpgsql security definer set search_path = pg_catalog, public, private as $$
declare changed integer;
begin
  if p_token is null or length(p_token)<32 or p_body is null
     or length(btrim(p_body))<1 or length(p_body)>2000 then return false; end if;
  update public.chat_guest_messages m set body=btrim(p_body),edited_at=now()
   where m.id=p_message_id and exists (
     select 1 from private.chat_guest_message_tokens t
      where t.message_id=m.id and t.token_hash=encode(sha256(convert_to(p_token,'UTF8')),'hex')
   );
  get diagnostics changed=row_count;
  return changed=1;
end;
$$;

create or replace function private.delete_guest_message(p_message_id uuid,p_token text)
returns boolean language plpgsql security definer set search_path = pg_catalog, public, private as $$
declare changed integer;
begin
  if p_token is null or length(p_token)<32 then return false; end if;
  delete from public.chat_guest_messages m where m.id=p_message_id and exists (
    select 1 from private.chat_guest_message_tokens t
     where t.message_id=m.id and t.token_hash=encode(sha256(convert_to(p_token,'UTF8')),'hex')
  );
  get diagnostics changed=row_count;
  return changed=1;
end;
$$;

create or replace function private.delete_guest_reaction(p_reaction_id uuid,p_token text)
returns boolean language plpgsql security definer set search_path = pg_catalog, public, private as $$
declare changed integer;
begin
  if p_token is null or length(p_token)<32 then return false; end if;
  delete from public.chat_guest_reactions r where r.id=p_reaction_id and exists (
    select 1 from private.chat_guest_reaction_tokens t
     where t.reaction_id=r.id and t.token_hash=encode(sha256(convert_to(p_token,'UTF8')),'hex')
  );
  get diagnostics changed=row_count;
  return changed=1;
end;
$$;

revoke all on function private.create_guest_message(uuid,uuid,text,text,uuid,text) from public;
revoke all on function private.create_guest_reaction(uuid,uuid,text,text) from public;
revoke all on function private.edit_guest_message(uuid,text,text) from public;
revoke all on function private.delete_guest_message(uuid,text) from public;
revoke all on function private.delete_guest_reaction(uuid,text) from public;
grant execute on function private.create_guest_message(uuid,uuid,text,text,uuid,text) to anon,authenticated;
grant execute on function private.create_guest_reaction(uuid,uuid,text,text) to anon,authenticated;
grant execute on function private.edit_guest_message(uuid,text,text) to anon,authenticated;
grant execute on function private.delete_guest_message(uuid,text) to anon,authenticated;
grant execute on function private.delete_guest_reaction(uuid,text) to anon,authenticated;

create or replace function public.create_guest_message(
  p_room_id uuid,p_sender_key uuid,p_sender_name text,p_body text,p_reply_to uuid,p_token_hash text
) returns uuid language sql security invoker set search_path = pg_catalog,public
as $$ select private.create_guest_message(p_room_id,p_sender_key,p_sender_name,p_body,p_reply_to,p_token_hash); $$;
create or replace function public.create_guest_reaction(
  p_message_id uuid,p_sender_key uuid,p_emoji text,p_token_hash text
) returns uuid language sql security invoker set search_path = pg_catalog,public
as $$ select private.create_guest_reaction(p_message_id,p_sender_key,p_emoji,p_token_hash); $$;
create or replace function public.edit_guest_message(p_message_id uuid,p_token text,p_body text)
returns boolean language sql security invoker set search_path = pg_catalog,public
as $$ select private.edit_guest_message(p_message_id,p_token,p_body); $$;
create or replace function public.delete_guest_message(p_message_id uuid,p_token text)
returns boolean language sql security invoker set search_path = pg_catalog,public
as $$ select private.delete_guest_message(p_message_id,p_token); $$;
create or replace function public.delete_guest_reaction(p_reaction_id uuid,p_token text)
returns boolean language sql security invoker set search_path = pg_catalog,public
as $$ select private.delete_guest_reaction(p_reaction_id,p_token); $$;

revoke all on function public.create_guest_message(uuid,uuid,text,text,uuid,text) from public;
revoke all on function public.create_guest_reaction(uuid,uuid,text,text) from public;
revoke all on function public.edit_guest_message(uuid,text,text) from public;
revoke all on function public.delete_guest_message(uuid,text) from public;
revoke all on function public.delete_guest_reaction(uuid,text) from public;
grant execute on function public.create_guest_message(uuid,uuid,text,text,uuid,text) to anon,authenticated;
grant execute on function public.create_guest_reaction(uuid,uuid,text,text) to anon,authenticated;
grant execute on function public.edit_guest_message(uuid,text,text) to anon,authenticated;
grant execute on function public.delete_guest_message(uuid,text) to anon,authenticated;
grant execute on function public.delete_guest_reaction(uuid,text) to anon,authenticated;

drop policy if exists "Anyone can post public guest messages" on public.chat_guest_messages;
drop policy if exists "Guests can add token-owned chat reactions" on public.chat_guest_reactions;
drop policy if exists "Guests can add their own chat reactions" on public.chat_guest_reactions;
drop policy if exists "Guests can remove their own chat reactions" on public.chat_guest_reactions;
revoke insert,update,delete on public.chat_guest_messages from public,anon,authenticated;
revoke insert,update,delete on public.chat_guest_reactions from public,anon,authenticated;
grant select on public.chat_guest_messages,public.chat_guest_reactions to anon,authenticated;
alter table public.chat_guest_messages drop column if exists edit_token_hash;
alter table public.chat_guest_reactions drop column if exists reaction_token_hash;

create or replace function public.enforce_guest_reply_room_scope()
returns trigger language plpgsql set search_path = pg_catalog,public as $$
begin
  if new.reply_to is not null and not exists (
    select 1 from public.chat_guest_messages parent
     where parent.id=new.reply_to and parent.room_id=new.room_id
  ) then
    raise exception 'Replies must point to a message in the same room.' using errcode='23503';
  end if;
  return new;
end;
$$;
revoke all on function public.enforce_guest_reply_room_scope() from public,anon,authenticated;
drop trigger if exists chat_guest_reply_room_scope on public.chat_guest_messages;
create trigger chat_guest_reply_room_scope before insert or update of reply_to,room_id
on public.chat_guest_messages for each row execute function public.enforce_guest_reply_room_scope();

do $$
begin
  if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='chat_rooms') then
    alter publication supabase_realtime add table public.chat_rooms;
  end if;
end;
$$;

create table if not exists private.chat_guest_room_creations (
  id bigint generated always as identity primary key,
  client_ip inet not null,
  created_at timestamptz not null default now()
);
create index if not exists chat_guest_room_creations_ip_time_idx on private.chat_guest_room_creations(client_ip,created_at desc);
alter table private.chat_guest_room_creations enable row level security;
revoke all on private.chat_guest_room_creations from public,anon,authenticated;

create or replace function private.enforce_guest_room_creation_ip_limit()
returns trigger language plpgsql security definer set search_path = pg_catalog,public,private as $$
declare
  v_headers jsonb := nullif(current_setting('request.headers',true),'')::jsonb;
  v_ip_text text;
  v_ip inet;
  v_recent integer;
begin
  v_ip_text := nullif(btrim(v_headers->>'cf-connecting-ip'),'');
  begin v_ip := coalesce(v_ip_text::inet,'0.0.0.0'::inet);
  exception when invalid_text_representation then v_ip := '0.0.0.0'::inet; end;
  perform pg_advisory_xact_lock(hashtext('commonroom-room-create:'||v_ip::text));
  delete from private.chat_guest_room_creations where client_ip=v_ip and created_at<now()-interval '1 day';
  select count(*) into v_recent from private.chat_guest_room_creations
   where client_ip=v_ip and created_at>now()-interval '1 hour';
  if v_recent>=5 then
    raise exception 'This network has created the maximum number of rooms for this hour.' using errcode='P0001';
  end if;
  return new;
end;
$$;

create or replace function private.record_guest_room_creation_ip()
returns trigger language plpgsql security definer set search_path = pg_catalog,public,private as $$
declare
  v_headers jsonb := nullif(current_setting('request.headers',true),'')::jsonb;
  v_ip_text text;
  v_ip inet;
begin
  v_ip_text := nullif(btrim(v_headers->>'cf-connecting-ip'),'');
  begin v_ip := coalesce(v_ip_text::inet,'0.0.0.0'::inet);
  exception when invalid_text_representation then v_ip := '0.0.0.0'::inet; end;
  insert into private.chat_guest_room_creations(client_ip) values(v_ip);
  return new;
end;
$$;
revoke all on function private.enforce_guest_room_creation_ip_limit() from public;
revoke all on function private.record_guest_room_creation_ip() from public;
drop trigger if exists chat_guest_room_creation_ip_limit on public.chat_rooms;
create trigger chat_guest_room_creation_ip_limit before insert on public.chat_rooms
for each row execute function private.enforce_guest_room_creation_ip_limit();
drop trigger if exists chat_guest_room_creation_ip_record on public.chat_rooms;
create trigger chat_guest_room_creation_ip_record after insert on public.chat_rooms
for each row execute function private.record_guest_room_creation_ip();

create or replace function private.enforce_chat_api_rate_limit()
returns void language plpgsql security definer set search_path = pg_catalog,private,public as $$
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
    or req_path ~ '(^|/)rpc/(create_guest_message|create_guest_reaction|delete_guest_reaction|edit_guest_message|delete_guest_message|submit_guest_report)$'
  ) then return; end if;
  v_ip_text := nullif(btrim(req_headers->>'cf-connecting-ip'),'');
  begin req_ip := coalesce(v_ip_text::inet,'0.0.0.0'::inet);
  exception when invalid_text_representation then req_ip := '0.0.0.0'::inet; end;
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
grant execute on function private.enforce_chat_api_rate_limit() to anon,authenticated,authenticator;
alter role authenticator set pgrst.db_pre_request='private.enforce_chat_api_rate_limit';
notify pgrst,'reload config';
