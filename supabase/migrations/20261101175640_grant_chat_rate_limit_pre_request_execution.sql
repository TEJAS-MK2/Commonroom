-- PostgREST invokes the configured pre-request function after selecting the request role.
grant execute on function public.enforce_chat_api_rate_limit() to anon, authenticated, authenticator;
