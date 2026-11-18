begin;
select plan(16);

select ok(to_regclass('public.cash_movements') is not null, 'cash movement ledger exists');
select ok(to_regclass('public.daily_closings') is not null, 'daily closing snapshots exist');
select ok(to_regclass('public.daily_payment_reconciliations') is not null, 'payment reconciliation snapshots exist');
select ok((select relrowsecurity from pg_class where oid='public.cash_movements'::regclass), 'cash movements RLS enabled');
select ok((select relrowsecurity from pg_class where oid='public.daily_closings'::regclass), 'daily closings RLS enabled');
select ok((select relrowsecurity from pg_class where oid='public.daily_payment_reconciliations'::regclass), 'reconciliation RLS enabled');
select ok(exists(select 1 from pg_policies where schemaname='public' and tablename='cash_movements' and cmd='SELECT'), 'cash movement owner read policy exists');
select ok(exists(select 1 from pg_policies where schemaname='public' and tablename='daily_closings' and cmd='SELECT'), 'daily closing owner read policy exists');
select ok(exists(select 1 from pg_policies where schemaname='public' and tablename='daily_payment_reconciliations' and cmd='SELECT'), 'reconciliation owner read policy exists');
select ok(exists(select 1 from information_schema.columns where table_schema='public' and table_name='deliveries' and column_name='attempt_status'), 'delivery attempt status exists');
select ok(exists(select 1 from information_schema.columns where table_schema='public' and table_name='deliveries' and column_name='failed_at'), 'delivery failure timestamp exists');
select ok(to_regprocedure('public.owner_record_cash_movement(uuid,date,text,bigint,text,text,text,text,uuid)') is not null, 'cash movement RPC exists');
select ok(to_regprocedure('public.owner_save_daily_closing(uuid,date,bigint,bigint,text,text,boolean,uuid)') is not null, 'daily closing RPC exists');
select ok(to_regprocedure('public.owner_save_payment_reconciliation(uuid,date,text,bigint,bigint,text,text,text,boolean,uuid)') is not null, 'payment reconciliation RPC exists');
select ok(to_regprocedure('public.owner_mark_delivery_failed(uuid,text,uuid)') is not null, 'delivery failure RPC exists');
select ok(not (select prosecdef from pg_proc where oid='public.owner_get_daily_operations_summary(uuid,date)'::regprocedure), 'dashboard aggregate RPC runs as invoker');

select * from finish();
rollback;
