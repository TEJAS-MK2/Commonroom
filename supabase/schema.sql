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
