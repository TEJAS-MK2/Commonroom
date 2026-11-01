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