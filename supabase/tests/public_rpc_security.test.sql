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
  to_regprocedure('public.rls_auto_enable()') is null,
  'Obsolete RLS event trigger handler is not installed in the public API schema'
);

select * from finish();
rollback;
