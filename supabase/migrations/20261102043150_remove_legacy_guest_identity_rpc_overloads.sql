-- Retire legacy RPC overloads that accepted client-selected sender/reporter UUIDs.
-- New browser clients use server-issued guest session tokens.
drop function if exists public.create_guest_message(uuid,uuid,text,text,uuid,text);
drop function if exists private.create_guest_message(uuid,uuid,text,text,uuid,text);
drop function if exists public.create_guest_reaction(uuid,uuid,text,text);
drop function if exists private.create_guest_reaction(uuid,uuid,text,text);
drop function if exists public.submit_guest_report(uuid,uuid,text,text);
drop function if exists private.submit_guest_report(uuid,uuid,text,text);

notify pgrst, 'reload schema';
