-- Mirrors the production migration applied on 2026-11-01.
alter table public.chat_guest_reactions add column if not exists reaction_token_hash text;

drop policy if exists "Guests can remove their own chat reactions" on public.chat_guest_reactions;
drop policy if exists "Guests can add their own chat reactions" on public.chat_guest_reactions;
create policy "Guests can add token-owned chat reactions" on public.chat_guest_reactions for insert to anon, authenticated with check (reaction_token_hash ~ '^[a-f0-9]{64}$');

create or replace function public.delete_guest_reaction(p_reaction_id uuid, p_token text) returns boolean language plpgsql security definer set search_path = pg_catalog, public as $$
declare changed integer;
begin
  if p_token is null or length(p_token) < 32 then return false; end if;
  delete from public.chat_guest_reactions where id = p_reaction_id and reaction_token_hash = encode(sha256(convert_to(p_token, 'UTF8')), 'hex');
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

create or replace function public.enforce_guest_room_creation_limits() returns trigger language plpgsql set search_path = pg_catalog, public as $$
declare recent_count integer;
declare total_count integer;
begin
  perform pg_advisory_xact_lock(73190517);
  select count(*) into total_count from public.chat_rooms;
  if total_count >= 100 then raise exception 'This community has reached its room limit.' using errcode = 'P0001'; end if;
  select count(*) into recent_count from public.chat_rooms where created_at > now() - interval '1 minute';
  if recent_count >= 5 then raise exception 'Too many rooms were created recently. Please try again shortly.' using errcode = 'P0001'; end if;
  new.created_at := now();
  return new;
end;
$$;
revoke all on function public.enforce_guest_room_creation_limits() from public;
drop trigger if exists chat_guest_room_creation_limit on public.chat_rooms;
create trigger chat_guest_room_creation_limit before insert on public.chat_rooms for each row execute function public.enforce_guest_room_creation_limits();