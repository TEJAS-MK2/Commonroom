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
