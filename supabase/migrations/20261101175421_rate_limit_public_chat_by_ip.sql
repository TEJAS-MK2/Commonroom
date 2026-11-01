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
