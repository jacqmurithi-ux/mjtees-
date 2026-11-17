begin;
create extension if not exists pgtap with schema extensions;
select plan(3);

select ok(
  not (select prosecdef from pg_proc where oid='public.accept_quotation(text,uuid)'::regprocedure),
  'Public quote acceptance RPC is SECURITY INVOKER'
);
select ok(
  has_function_privilege('anon','private.accept_quotation_token(text,uuid)','EXECUTE'),
  'Anonymous quote acceptance reaches the private token-checked implementation'
);
select ok(
  not has_function_privilege('anon','public.rls_auto_enable()','EXECUTE')
  and not has_function_privilege('authenticated','public.rls_auto_enable()','EXECUTE'),
  'RLS event trigger handler is not executable through API roles'
);

select * from finish();
rollback;
