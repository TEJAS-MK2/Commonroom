-- Use the trusted Cloudflare client IP for admin PIN throttling and remove
-- the duplicate unique index on public.chat_guest_reports.
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
revoke all on function private.chat_admin_login(text) from public;
grant execute on function private.chat_admin_login(text) to anon,authenticated;

drop index if exists public.chat_guest_reports_message_reporter_uidx;
