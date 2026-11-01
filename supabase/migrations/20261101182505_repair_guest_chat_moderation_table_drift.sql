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
