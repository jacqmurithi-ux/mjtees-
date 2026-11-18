-- Harden public RPC wrappers: keep privileged token handling in private schema.
begin;

create or replace function public.accept_quotation(p_token text,p_request_id uuid)
returns jsonb
language sql
security invoker
set search_path=''
as $function$
  select private.accept_quotation_token($1,$2);
$function$;

-- The private implementation remains SECURITY DEFINER because it must create an
-- order from a single-use, expiring customer token without an owner session.
-- It is callable only through the intentionally exposed invoker wrapper.
revoke all on function private.accept_quotation_token(text,uuid) from public,anon,authenticated;
grant usage on schema private to anon,authenticated;
grant execute on function private.accept_quotation_token(text,uuid) to anon,authenticated;

revoke all on function public.accept_quotation(text,uuid) from public;
grant execute on function public.accept_quotation(text,uuid) to anon,authenticated;

-- Event-trigger handlers are invoked by PostgreSQL, not through the Data API.
-- Guard the optional helper so a clean local database can apply this migration
-- whether or not the automatic-RLS event trigger has been installed.
do $block$
begin
  if to_regprocedure('public.rls_auto_enable()') is not null then
    execute 'revoke all on function public.rls_auto_enable() from public, anon, authenticated';
  end if;
end;
$block$;

commit;
