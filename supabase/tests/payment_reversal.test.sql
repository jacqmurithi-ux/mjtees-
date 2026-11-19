begin;
create extension if not exists pgtap with schema extensions;
select plan(2);

select is(
 (select count(*)::integer from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='owner_reverse_payment'),
 0,'Public payment reversal RPC is not available');

select is(
 (select count(*)::integer from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='private' and p.proname='owner_reverse_payment'),
 0,'Private payment reversal implementation is not available');

select * from finish();
rollback;
