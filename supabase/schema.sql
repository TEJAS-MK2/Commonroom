-- Chat application schema. All objects use chat_ prefixes to avoid
-- colliding with existing tables in this Supabase project.

create table if not exists public.chat_profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null check (char_length(display_name) between 1 and 32),
  avatar_url text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.chat_rooms (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique check (slug ~ '^[a-z0-9][a-z0-9-]{1,39}$'),
  name text not null check (char_length(name) between 2 and 40),
  description text not null default '',
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);

create table if not exists public.chat_messages (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.chat_rooms(id) on delete cascade,
  sender_id uuid not null references public.chat_profiles(id) on delete cascade,
  body text not null check (char_length(body) between 1 and 2000),
  created_at timestamptz not null default now()
);

create index if not exists chat_messages_room_created_idx
  on public.chat_messages (room_id, created_at desc);
create index if not exists chat_messages_sender_idx
  on public.chat_messages (sender_id);
create index if not exists chat_rooms_created_by_idx
  on public.chat_rooms (created_by);

alter table public.chat_profiles enable row level security;
alter table public.chat_rooms enable row level security;
alter table public.chat_messages enable row level security;

drop policy if exists "Profiles are visible to signed-in users" on public.chat_profiles;
create policy "Profiles are visible to signed-in users"
  on public.chat_profiles for select to authenticated using (true);

drop policy if exists "Users create their own profile" on public.chat_profiles;
create policy "Users create their own profile"
  on public.chat_profiles for insert to authenticated
  with check ((select auth.uid()) = id);

drop policy if exists "Users update their own profile" on public.chat_profiles;
create policy "Users update their own profile"
  on public.chat_profiles for update to authenticated
  using ((select auth.uid()) = id)
  with check ((select auth.uid()) = id);

drop policy if exists "Signed-in users can read rooms" on public.chat_rooms;
create policy "Signed-in users can read rooms"
  on public.chat_rooms for select to authenticated using (true);

drop policy if exists "Signed-in users can create rooms" on public.chat_rooms;
create policy "Signed-in users can create rooms"
  on public.chat_rooms for insert to authenticated
  with check ((select auth.uid()) = created_by);

drop policy if exists "Room creators can update rooms" on public.chat_rooms;
create policy "Room creators can update rooms"
  on public.chat_rooms for update to authenticated
  using ((select auth.uid()) = created_by)
  with check ((select auth.uid()) = created_by);

drop policy if exists "Signed-in users can read messages" on public.chat_messages;
create policy "Signed-in users can read messages"
  on public.chat_messages for select to authenticated using (true);

drop policy if exists "Users can send messages as themselves" on public.chat_messages;
create policy "Users can send messages as themselves"
  on public.chat_messages for insert to authenticated
  with check ((select auth.uid()) = sender_id);

drop policy if exists "Users can delete their own messages" on public.chat_messages;
create policy "Users can delete their own messages"
  on public.chat_messages for delete to authenticated
  using ((select auth.uid()) = sender_id);

grant select, insert, update on public.chat_profiles to authenticated;
grant select, insert, update on public.chat_rooms to authenticated;
grant select, insert, delete on public.chat_messages to authenticated;

insert into public.chat_rooms (slug, name, description)
values
  ('general', 'general', 'A place for everyday conversations.'),
  ('coding', 'coding', 'Share what you are building, learning, and debugging.'),
  ('random', 'random', 'Anything that does not fit anywhere else.')
on conflict (slug) do nothing;

-- Realtime streams new chat messages to connected clients.
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'chat_messages'
  ) then
    alter publication supabase_realtime add table public.chat_messages;
  end if;
end $$;

-- Keep transient chat broadcasts private to authenticated chat clients.
drop policy if exists "Chat clients can receive chat broadcasts" on realtime.messages;
create policy "Chat clients can receive chat broadcasts"
  on realtime.messages for select to authenticated
  using (realtime.topic() like 'chat-room:%' or realtime.topic() = 'chat-presence');

drop policy if exists "Chat clients can send chat broadcasts" on realtime.messages;
create policy "Chat clients can send chat broadcasts"
  on realtime.messages for insert to authenticated
  with check (realtime.topic() like 'chat-room:%' or realtime.topic() = 'chat-presence');


-- Private one-to-one conversations.
create table if not exists public.chat_conversations (
  id uuid primary key default gen_random_uuid(),
  participant_a uuid not null references public.chat_profiles(id) on delete cascade,
  participant_b uuid not null references public.chat_profiles(id) on delete cascade,
  created_by uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  constraint chat_conversations_distinct_participants check (participant_a <> participant_b),
  constraint chat_conversations_creator_is_participant check (created_by = participant_a)
);

create unique index if not exists chat_conversations_pair_uidx
  on public.chat_conversations (least(participant_a, participant_b), greatest(participant_a, participant_b));

create table if not exists public.chat_conversation_members (
  conversation_id uuid not null references public.chat_conversations(id) on delete cascade,
  user_id uuid not null references public.chat_profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (conversation_id, user_id)
);

create table if not exists public.chat_direct_messages (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.chat_conversations(id) on delete cascade,
  sender_id uuid not null references public.chat_profiles(id) on delete cascade,
  body text,
  attachment_path text,
  created_at timestamptz not null default now(),
  constraint chat_direct_messages_content_check check (
    (body is not null and char_length(body) between 1 and 2000) or attachment_path is not null
  )
);

create index if not exists chat_direct_messages_conversation_created_idx
  on public.chat_direct_messages (conversation_id, created_at desc);

alter table public.chat_conversations enable row level security;
alter table public.chat_conversation_members enable row level security;
alter table public.chat_direct_messages enable row level security;

drop policy if exists "Conversation participants can read conversations" on public.chat_conversations;
create policy "Conversation participants can read conversations"
  on public.chat_conversations for select to authenticated
  using (
    created_by = (select auth.uid())
    or exists (
      select 1 from public.chat_conversation_members m
      where m.conversation_id = id and m.user_id = (select auth.uid())
    )
  );

drop policy if exists "Users create conversations as participant A" on public.chat_conversations;
create policy "Users create conversations as participant A"
  on public.chat_conversations for insert to authenticated
  with check (
    created_by = (select auth.uid())
    and participant_a = (select auth.uid())
    and participant_b <> (select auth.uid())
  );

drop policy if exists "Users can read their own conversation membership" on public.chat_conversation_members;
create policy "Users can read their own conversation membership"
  on public.chat_conversation_members for select to authenticated
  using (user_id = (select auth.uid()));

drop policy if exists "Conversation creator adds only its two participants" on public.chat_conversation_members;
create policy "Conversation creator adds only its two participants"
  on public.chat_conversation_members for insert to authenticated
  with check (
    exists (
      select 1 from public.chat_conversations c
      where c.id = conversation_id
        and c.created_by = (select auth.uid())
        and user_id in (c.participant_a, c.participant_b)
    )
  );

drop policy if exists "Participants can read direct messages" on public.chat_direct_messages;
create policy "Participants can read direct messages"
  on public.chat_direct_messages for select to authenticated
  using (
    exists (
      select 1 from public.chat_conversation_members m
      where m.conversation_id = chat_direct_messages.conversation_id
        and m.user_id = (select auth.uid())
    )
  );

drop policy if exists "Participants send direct messages as themselves" on public.chat_direct_messages;
create policy "Participants send direct messages as themselves"
  on public.chat_direct_messages for insert to authenticated
  with check (
    sender_id = (select auth.uid())
    and exists (
      select 1 from public.chat_conversation_members m
      where m.conversation_id = chat_direct_messages.conversation_id
        and m.user_id = (select auth.uid())
    )
  );

grant select, insert on public.chat_conversations to authenticated;
grant select, insert on public.chat_conversation_members to authenticated;
grant select, insert on public.chat_direct_messages to authenticated;

-- Private file bucket: each object is stored under conversation-id/user-id/.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'chat-attachments',
  'chat-attachments',
  false,
  10485760,
  array['image/jpeg','image/png','image/webp','application/pdf','text/plain']
)
on conflict (id) do nothing;

drop policy if exists "Conversation members can view chat attachments" on storage.objects;
create policy "Conversation members can view chat attachments"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'chat-attachments'
    and exists (
      select 1 from public.chat_conversation_members m
      where m.conversation_id::text = (storage.foldername(name))[1]
        and m.user_id = (select auth.uid())
    )
  );

drop policy if exists "Users upload their own chat attachments" on storage.objects;
create policy "Users upload their own chat attachments"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'chat-attachments'
    and (storage.foldername(name))[2] = (select auth.uid())::text
    and exists (
      select 1 from public.chat_conversation_members m
      where m.conversation_id::text = (storage.foldername(name))[1]
        and m.user_id = (select auth.uid())
    )
  );

drop policy if exists "Users delete their own chat attachments" on storage.objects;
create policy "Users delete their own chat attachments"
  on storage.objects for delete to authenticated
  using (
    bucket_id = 'chat-attachments'
    and (storage.foldername(name))[2] = (select auth.uid())::text
    and exists (
      select 1 from public.chat_conversation_members m
      where m.conversation_id::text = (storage.foldername(name))[1]
        and m.user_id = (select auth.uid())
    )
  );

-- Private DM typing channels share the same authenticated authorization model.
drop policy if exists "Chat clients can receive chat broadcasts" on realtime.messages;
create policy "Chat clients can receive chat broadcasts"
  on realtime.messages for select to authenticated
  using (
    realtime.topic() like 'chat-room:%'
    or realtime.topic() = 'chat-presence'
    or (
      realtime.topic() like 'chat-dm:%'
      and exists (
        select 1 from public.chat_conversation_members m
        where m.conversation_id::text = split_part(realtime.topic(), ':', 2)
          and m.user_id = (select auth.uid())
      )
    )
  );

drop policy if exists "Chat clients can send chat broadcasts" on realtime.messages;
create policy "Chat clients can send chat broadcasts"
  on realtime.messages for insert to authenticated
  with check (
    realtime.topic() like 'chat-room:%'
    or realtime.topic() = 'chat-presence'
    or (
      realtime.topic() like 'chat-dm:%'
      and exists (
        select 1 from public.chat_conversation_members m
        where m.conversation_id::text = split_part(realtime.topic(), ':', 2)
          and m.user_id = (select auth.uid())
      )
    )
  );


-- Cover the foreign keys used by participant and membership lookups.
create index if not exists chat_conversation_members_user_idx
  on public.chat_conversation_members (user_id);
create index if not exists chat_conversations_created_by_idx
  on public.chat_conversations (created_by);
create index if not exists chat_conversations_participant_a_idx
  on public.chat_conversations (participant_a);
create index if not exists chat_conversations_participant_b_idx
  on public.chat_conversations (participant_b);
create index if not exists chat_direct_messages_sender_idx
  on public.chat_direct_messages (sender_id);
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'chat_direct_messages'
  ) then
    alter publication supabase_realtime add table public.chat_direct_messages;
  end if;
end $$;


-- Anonymous public chat support. Existing authenticated tables are retained.
-- Public messages intentionally have no verified user identity.
create table if not exists public.chat_guest_messages (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.chat_rooms(id) on delete cascade,
  sender_key uuid not null,
  sender_name text not null check (char_length(sender_name) between 2 and 32),
  body text not null check (char_length(body) between 1 and 2000),
  created_at timestamptz not null default now()
);
create index if not exists chat_guest_messages_room_created_idx
  on public.chat_guest_messages (room_id, created_at desc);
alter table public.chat_guest_messages enable row level security;

drop policy if exists "Anyone can read public guest messages" on public.chat_guest_messages;
create policy "Anyone can read public guest messages"
  on public.chat_guest_messages for select to anon, authenticated using (true);
drop policy if exists "Anyone can post public guest messages" on public.chat_guest_messages;
create policy "Anyone can post public guest messages"
  on public.chat_guest_messages for insert to anon, authenticated
  with check (char_length(sender_name) between 2 and 32 and char_length(body) between 1 and 2000);

grant select, insert on public.chat_guest_messages to anon, authenticated;
grant select on public.chat_rooms to anon;
grant insert on public.chat_rooms to anon;

drop policy if exists "Anyone can read public chat rooms" on public.chat_rooms;
create policy "Anyone can read public chat rooms"
  on public.chat_rooms for select to anon using (true);
drop policy if exists "Anyone can create public chat rooms" on public.chat_rooms;
create policy "Anyone can create public chat rooms"
  on public.chat_rooms for insert to anon with check (created_by is null);

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'chat_guest_messages'
  ) then
    alter publication supabase_realtime add table public.chat_guest_messages;
  end if;
end $$;

-- Persistent reactions for anonymous public chat messages.
create table if not exists public.chat_guest_reactions (
  id uuid primary key default gen_random_uuid(),
  message_id uuid not null references public.chat_guest_messages(id) on delete cascade,
  sender_key uuid not null,
  emoji text not null check (emoji in ('👍','❤️','😂','🎉','🔥','👀','🙌','🤔')),
  created_at timestamptz not null default now(),
  constraint chat_guest_reactions_unique unique (message_id, sender_key, emoji)
);
create index if not exists chat_guest_reactions_message_idx
  on public.chat_guest_reactions (message_id);
alter table public.chat_guest_reactions enable row level security;
drop policy if exists "Anyone can read public chat reactions" on public.chat_guest_reactions;
create policy "Anyone can read public chat reactions"
  on public.chat_guest_reactions for select to anon, authenticated using (true);
drop policy if exists "Guests can add their own chat reactions" on public.chat_guest_reactions;
create policy "Guests can add their own chat reactions"
  on public.chat_guest_reactions for insert to anon, authenticated with check (true);
drop policy if exists "Guests can remove their own chat reactions" on public.chat_guest_reactions;
create policy "Guests can remove their own chat reactions"
  on public.chat_guest_reactions for delete to anon, authenticated using (true);
grant select, insert, delete on public.chat_guest_reactions to anon, authenticated;
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'chat_guest_reactions'
  ) then
    alter publication supabase_realtime add table public.chat_guest_reactions;
  end if;
end $$;

-- Message replies and client-held owner tokens.
alter table public.chat_guest_messages
  add column if not exists reply_to uuid references public.chat_guest_messages(id) on delete set null,
  add column if not exists edited_at timestamptz,
  add column if not exists edit_token_hash text;

create or replace function public.edit_guest_message(p_message_id uuid, p_token text, p_body text)
returns boolean language plpgsql security definer set search_path = pg_catalog, public as $$
declare changed integer;
begin
  if p_token is null or length(p_token) < 32 or p_body is null or length(btrim(p_body)) < 1 or length(p_body) > 2000 then return false; end if;
  update public.chat_guest_messages set body = btrim(p_body), edited_at = now()
  where id = p_message_id and edit_token_hash = encode(sha256(convert_to(p_token, 'UTF8')), 'hex');
  get diagnostics changed = row_count;
  return changed = 1;
end;
$$;
create or replace function public.delete_guest_message(p_message_id uuid, p_token text)
returns boolean language plpgsql security definer set search_path = pg_catalog, public as $$
declare changed integer;
begin
  if p_token is null or length(p_token) < 32 then return false; end if;
  delete from public.chat_guest_messages where id = p_message_id
  and edit_token_hash = encode(sha256(convert_to(p_token, 'UTF8')), 'hex');
  get diagnostics changed = row_count;
  return changed = 1;
end;
$$;
revoke all on function public.edit_guest_message(uuid,text,text) from public;
revoke all on function public.delete_guest_message(uuid,text) from public;
grant execute on function public.edit_guest_message(uuid,text,text) to anon, authenticated;
grant execute on function public.delete_guest_message(uuid,text) to anon, authenticated;

create or replace function public.enforce_guest_chat_limits()
returns trigger language plpgsql set search_path = pg_catalog, public as $$
declare recent_count integer;
begin
  new.created_at := now();
  perform pg_advisory_xact_lock(hashtext(new.sender_key::text));
  select count(*) into recent_count from public.chat_guest_messages
    where sender_key = new.sender_key and created_at > now() - interval '15 seconds';
  if recent_count >= 5 then
    raise exception 'You are sending messages too quickly. Please wait a moment.' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.chat_guest_messages
    where sender_key = new.sender_key and lower(btrim(body)) = lower(btrim(new.body))
      and created_at > now() - interval '60 seconds') then
    raise exception 'Please avoid sending the same message repeatedly.' using errcode = 'P0001';
  end if;
  return new;
end;
$$;
revoke all on function public.enforce_guest_chat_limits() from public;
drop trigger if exists chat_guest_message_rate_limit on public.chat_guest_messages;
create trigger chat_guest_message_rate_limit before insert on public.chat_guest_messages
for each row execute function public.enforce_guest_chat_limits();

create or replace function public.enforce_guest_reaction_limits()
returns trigger language plpgsql set search_path = pg_catalog, public as $$
declare recent_count integer;
begin
  new.created_at := now();
  perform pg_advisory_xact_lock(hashtext(new.sender_key::text));
  select count(*) into recent_count from public.chat_guest_reactions
    where sender_key = new.sender_key and created_at > now() - interval '15 seconds';
  if recent_count >= 20 then
    raise exception 'You are reacting too quickly. Please wait a moment.' using errcode = 'P0001';
  end if;
  return new;
end;
$$;
revoke all on function public.enforce_guest_reaction_limits() from public;
drop trigger if exists chat_guest_reaction_rate_limit on public.chat_guest_reactions;
create trigger chat_guest_reaction_rate_limit before insert on public.chat_guest_reactions
for each row execute function public.enforce_guest_reaction_limits();

-- Current deployed anti-abuse hardening.
create index if not exists chat_guest_messages_reply_to_idx on public.chat_guest_messages(reply_to);

-- Private moderation reports. This table intentionally has no public policies or grants.
create table if not exists public.chat_guest_reports (
  id uuid primary key default gen_random_uuid(),
  message_id uuid not null references public.chat_guest_messages(id) on delete cascade,
  reporter_key uuid not null,
  reason text not null check (reason in ('spam','harassment','hate','personal-info','other')),
  details text not null default '',
  status text not null default 'open' check (status in ('open','reviewed','dismissed')),
  created_at timestamptz not null default now()
);
create index if not exists chat_guest_reports_status_created_idx
  on public.chat_guest_reports(status, created_at desc);
alter table public.chat_guest_reports enable row level security;

-- Public mutation hardening: reactions require a private owner token hash.
alter table public.chat_guest_reactions add column if not exists reaction_token_hash text;
drop policy if exists "Guests can remove their own chat reactions" on public.chat_guest_reactions;
drop policy if exists "Guests can add their own chat reactions" on public.chat_guest_reactions;
create policy "Guests can add token-owned chat reactions"
  on public.chat_guest_reactions for insert to anon, authenticated
  with check (reaction_token_hash ~ '^[a-f0-9]{64}$');
create or replace function public.delete_guest_reaction(p_reaction_id uuid, p_token text)
returns boolean language plpgsql security definer set search_path = pg_catalog, public as $$
declare changed integer;
begin
  if p_token is null or length(p_token) < 32 then return false; end if;
  delete from public.chat_guest_reactions where id = p_reaction_id
    and reaction_token_hash = encode(sha256(convert_to(p_token, 'UTF8')), 'hex');
  get diagnostics changed = row_count;
  return changed = 1;
end;
$$;
revoke all on function public.delete_guest_reaction(uuid,text) from public;
grant execute on function public.delete_guest_reaction(uuid,text) to anon, authenticated;

revoke all on public.chat_guest_messages, public.chat_guest_reactions, public.chat_rooms from anon, authenticated;
grant select, insert on public.chat_guest_messages to anon, authenticated;
grant select, insert on public.chat_guest_reactions to anon, authenticated;
grant select, insert on public.chat_rooms to anon, authenticated;

create or replace function public.enforce_guest_room_creation_limits()
returns trigger language plpgsql set search_path = pg_catalog, public as $$
declare recent_count integer;
declare total_count integer;
begin
  perform pg_advisory_xact_lock(73190517);
  select count(*) into total_count from public.chat_rooms;
  if total_count >= 100 then raise exception 'This community has reached its room limit.' using errcode = 'P0001'; end if;
  select count(*) into recent_count from public.chat_rooms
   where created_at > now() - interval '1 minute';
  if recent_count >= 5 then raise exception 'Too many rooms were created recently. Please try again shortly.' using errcode = 'P0001'; end if;
  new.created_at := now();
  return new;
end;
$$;
revoke all on function public.enforce_guest_room_creation_limits() from public;
drop trigger if exists chat_guest_room_creation_limit on public.chat_rooms;
create trigger chat_guest_room_creation_limit before insert on public.chat_rooms
for each row execute function public.enforce_guest_room_creation_limits();


-- Mirrors production migration 20261101175421_rate_limit_public_chat_by_ip.sql.
-- Per-IP request guard for public Commonroom mutations. The hook is scoped to
-- chat REST/RPC paths so other applications sharing this Supabase project are unaffected.
create schema if not exists private;
revoke all on schema private from public, anon, authenticated;
create table if not exists private.chat_guest_rate_limits (
  id bigint generated always as identity primary key,
  client_ip inet not null,
  requested_at timestamptz not null default now(),
  request_path text not null
);
create index if not exists chat_guest_rate_limits_ip_time_idx
  on private.chat_guest_rate_limits(client_ip, requested_at desc);
alter table private.chat_guest_rate_limits enable row level security;
revoke all on private.chat_guest_rate_limits from public, anon, authenticated;

create or replace function public.enforce_chat_api_rate_limit()
returns void language plpgsql security definer
set search_path = pg_catalog, private, public as $$
declare
  req_method text := current_setting('request.method', true);
  req_path text := current_setting('request.path', true);
  req_headers jsonb := nullif(current_setting('request.headers', true), '')::jsonb;
  req_ip inet;
  recent_count integer;
begin
  if req_method is null or req_method in ('GET', 'HEAD', 'OPTIONS') then return; end if;
  if not (
    req_path ~ '(^|/)chat_guest_(messages|reactions|rooms)(/|$)'
    or req_path ~ '(^|/)chat_rooms(/|$)'
    or req_path ~ '(^|/)rpc/(delete_guest_reaction|edit_guest_message|delete_guest_message)$'
  ) then return; end if;
  req_ip := nullif(split_part(coalesce(req_headers->>'x-forwarded-for', ''), ',', 1), '')::inet;
  if req_ip is null then return; end if;
  perform pg_advisory_xact_lock(hashtext(req_ip::text));
  select count(*) into recent_count from private.chat_guest_rate_limits
   where client_ip = req_ip and requested_at > now() - interval '5 minutes';
  if recent_count >= 100 then
    raise sqlstate 'PGRST' using
      message = json_build_object('message', 'Commonroom is receiving too many requests from this network. Please wait a few minutes.')::text,
      detail = json_build_object('status', 429, 'status_text', 'Too Many Requests')::text;
  end if;
  insert into private.chat_guest_rate_limits(client_ip, request_path)
  values (req_ip, coalesce(req_path, 'unknown'));
  delete from private.chat_guest_rate_limits
   where client_ip = req_ip and requested_at < now() - interval '1 day';
end;
$$;
revoke all on function public.enforce_chat_api_rate_limit() from public, anon, authenticated;
grant execute on function public.enforce_chat_api_rate_limit() to authenticator;
alter role authenticator set pgrst.db_pre_request = 'public.enforce_chat_api_rate_limit';
notify pgrst, 'reload config';


-- The pre-request hook runs after the request role is selected by PostgREST.
grant execute on function public.enforce_chat_api_rate_limit() to anon, authenticated, authenticator;


-- Keep the scoped PostgREST pre-request hook in a non-exposed schema.
create or replace function private.enforce_chat_api_rate_limit()
returns void language plpgsql security definer
set search_path = pg_catalog, private, public as $$
declare
  req_method text := current_setting('request.method', true);
  req_path text := current_setting('request.path', true);
  req_headers jsonb := nullif(current_setting('request.headers', true), '')::jsonb;
  req_ip inet;
  recent_count integer;
begin
  if req_method is null or req_method in ('GET', 'HEAD', 'OPTIONS') then return; end if;
  if not (
    req_path ~ '(^|/)chat_guest_(messages|reactions|rooms)(/|$)'
    or req_path ~ '(^|/)chat_rooms(/|$)'
    or req_path ~ '(^|/)rpc/(delete_guest_reaction|edit_guest_message|delete_guest_message)$'
  ) then return; end if;
  req_ip := nullif(split_part(coalesce(req_headers->>'x-forwarded-for', ''), ',', 1), '')::inet;
  if req_ip is null then return; end if;
  perform pg_advisory_xact_lock(hashtext(req_ip::text));
  select count(*) into recent_count from private.chat_guest_rate_limits
   where client_ip = req_ip and requested_at > now() - interval '5 minutes';
  if recent_count >= 100 then
    raise sqlstate 'PGRST' using
      message = json_build_object('message', 'Commonroom is receiving too many requests from this network. Please wait a few minutes.')::text,
      detail = json_build_object('status', 429, 'status_text', 'Too Many Requests')::text;
  end if;
  insert into private.chat_guest_rate_limits(client_ip, request_path)
  values (req_ip, coalesce(req_path, 'unknown'));
  delete from private.chat_guest_rate_limits where requested_at < now() - interval '1 day';
end;
$$;
revoke all on function private.enforce_chat_api_rate_limit() from public;
grant execute on function private.enforce_chat_api_rate_limit() to anon, authenticated, authenticator;
drop function if exists public.enforce_chat_api_rate_limit();
alter role authenticator set pgrst.db_pre_request = 'private.enforce_chat_api_rate_limit';
notify pgrst, 'reload config';


-- Keep owner-token SECURITY DEFINER implementations outside the exposed API schema.
grant usage on schema private to anon, authenticated;

create or replace function private.edit_guest_message(p_message_id uuid, p_token text, p_body text)
returns boolean language plpgsql security definer set search_path = pg_catalog, public as $$
declare changed integer;
begin
  if p_token is null or length(p_token) < 32 or p_body is null or length(btrim(p_body)) < 1 or length(p_body) > 2000 then return false; end if;
  update public.chat_guest_messages set body = btrim(p_body), edited_at = now()
   where id = p_message_id and edit_token_hash = encode(sha256(convert_to(p_token, 'UTF8')), 'hex');
  get diagnostics changed = row_count;
  return changed = 1;
end;
$$;

create or replace function private.delete_guest_message(p_message_id uuid, p_token text)
returns boolean language plpgsql security definer set search_path = pg_catalog, public as $$
declare changed integer;
begin
  if p_token is null or length(p_token) < 32 then return false; end if;
  delete from public.chat_guest_messages where id = p_message_id
   and edit_token_hash = encode(sha256(convert_to(p_token, 'UTF8')), 'hex');
  get diagnostics changed = row_count;
  return changed = 1;
end;
$$;

create or replace function private.delete_guest_reaction(p_reaction_id uuid, p_token text)
returns boolean language plpgsql security definer set search_path = pg_catalog, public as $$
declare changed integer;
begin
  if p_token is null or length(p_token) < 32 then return false; end if;
  delete from public.chat_guest_reactions where id = p_reaction_id
   and reaction_token_hash = encode(sha256(convert_to(p_token, 'UTF8')), 'hex');
  get diagnostics changed = row_count;
  return changed = 1;
end;
$$;

revoke all on function private.edit_guest_message(uuid,text,text) from public;
revoke all on function private.delete_guest_message(uuid,text) from public;
revoke all on function private.delete_guest_reaction(uuid,text) from public;
grant execute on function private.edit_guest_message(uuid,text,text) to anon, authenticated;
grant execute on function private.delete_guest_message(uuid,text) to anon, authenticated;
grant execute on function private.delete_guest_reaction(uuid,text) to anon, authenticated;

create or replace function public.edit_guest_message(p_message_id uuid, p_token text, p_body text)
returns boolean language sql security invoker set search_path = pg_catalog, public as $$
  select private.edit_guest_message(p_message_id, p_token, p_body);
$$;
create or replace function public.delete_guest_message(p_message_id uuid, p_token text)
returns boolean language sql security invoker set search_path = pg_catalog, public as $$
  select private.delete_guest_message(p_message_id, p_token);
$$;
create or replace function public.delete_guest_reaction(p_reaction_id uuid, p_token text)
returns boolean language sql security invoker set search_path = pg_catalog, public as $$
  select private.delete_guest_reaction(p_reaction_id, p_token);
$$;
revoke all on function public.edit_guest_message(uuid,text,text) from public;
revoke all on function public.delete_guest_message(uuid,text) from public;
revoke all on function public.delete_guest_reaction(uuid,text) from public;
grant execute on function public.edit_guest_message(uuid,text,text) to anon, authenticated;
grant execute on function public.delete_guest_message(uuid,text) to anon, authenticated;
grant execute on function public.delete_guest_reaction(uuid,text) to anon, authenticated;

create index if not exists chat_guest_rate_limits_requested_at_idx
  on private.chat_guest_rate_limits(requested_at);


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

-- Defense in depth for the private PIN verifier and serialized login throttling.
alter table private.chat_admin_config enable row level security;
create or replace function private.chat_admin_login(p_pin text)
returns jsonb language plpgsql security definer set search_path=pg_catalog,private as $$
declare
  request_headers jsonb := nullif(current_setting('request.headers',true),'')::jsonb;
  v_ip_text text;
  v_client_ip inet;
  failed_attempts integer;
  global_attempts integer;
  config_row private.chat_admin_config%rowtype;
  session_token text;
begin
  -- Trust only the proxy-provided Cloudflare client address, matching the
  -- database pre-request rate limiter. Never trust caller-supplied X-Forwarded-For.
  v_ip_text := nullif(btrim(request_headers->>'cf-connecting-ip'),'');
  begin
    v_client_ip := v_ip_text::inet;
  exception when invalid_text_representation then
    return jsonb_build_object('ok',false,'error','Unable to verify this connection.');
  end;
  if v_client_ip is null then
    return jsonb_build_object('ok',false,'error','Unable to verify this connection.');
  end if;

  perform pg_advisory_xact_lock(hashtext('commonroom-admin:'||v_client_ip::text));
  perform pg_advisory_xact_lock(hashtext('commonroom-admin-global'));
  delete from private.chat_admin_login_attempts a where a.attempted_at<now()-interval '1 day';
  select count(*) into failed_attempts from private.chat_admin_login_attempts a
    where a.client_ip=v_client_ip and a.attempted_at>now()-interval '15 minutes';
  select count(*) into global_attempts from private.chat_admin_login_attempts a
    where a.attempted_at>now()-interval '15 minutes';
  if failed_attempts>=5 or global_attempts>=30 then
    return jsonb_build_object('ok',false,'error','Too many incorrect attempts. Try again in 15 minutes.');
  end if;
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
  insert into private.chat_admin_sessions(token_hash,expires_at)
    values(encode(sha256(convert_to(session_token,'UTF8')),'hex'),now()+interval '30 minutes');
  insert into private.chat_admin_audit(action,details)
    values('admin_login',jsonb_build_object('source','control_room'));
  return jsonb_build_object('ok',true,'token',session_token,'expires_at',now()+interval '30 minutes');
end;
$$;

-- Mirrors migration 20261101182323_harden_guest_chat_tokens_realtime_and_limits.sql
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


-- Mirrors migration 20261101182505_repair_guest_chat_moderation_table_drift.sql
-- Restore the deployed moderation check without exposing a moderation table in the Data API.
create table if not exists private.chat_guest_moderation_blocks (
  sender_key uuid primary key,
  reason text not null default 'community moderation',
  created_at timestamptz not null default now(),
  expires_at timestamptz
);
alter table private.chat_guest_moderation_blocks enable row level security;
revoke all on private.chat_guest_moderation_blocks from public,anon,authenticated;

create or replace function public.enforce_guest_chat_limits()
returns trigger language plpgsql security definer
set search_path = pg_catalog,public,private as $$
declare recent_count integer;
begin
  perform pg_advisory_xact_lock(hashtext(new.sender_key::text));
  if exists (
    select 1 from private.chat_guest_moderation_blocks
     where sender_key=new.sender_key and (expires_at is null or expires_at>now())
  ) then
    raise exception 'This guest is restricted from posting in this community.' using errcode='42501';
  end if;
  select count(*) into recent_count from public.chat_guest_messages
   where sender_key=new.sender_key and created_at>now()-interval '15 seconds';
  if recent_count>=5 then
    raise exception 'You are sending messages too quickly. Please wait a moment.' using errcode='P0001';
  end if;
  if exists (
    select 1 from public.chat_guest_messages
     where sender_key=new.sender_key and lower(btrim(body))=lower(btrim(new.body))
       and created_at>now()-interval '60 seconds'
  ) then
    raise exception 'Please avoid sending the same message repeatedly.' using errcode='P0001';
  end if;
  return new;
end;
$$;
revoke all on function public.enforce_guest_chat_limits() from public,anon,authenticated;
