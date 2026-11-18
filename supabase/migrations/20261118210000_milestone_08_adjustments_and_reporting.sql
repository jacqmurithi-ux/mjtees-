-- Milestone 08 follow-up: immutable corrections, cash movement retry safety and complete dashboard balances.

create table public.daily_closing_adjustments (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id),
  daily_closing_id uuid not null references public.daily_closings(id),
  adjustment_type text not null check (adjustment_type in ('cash_in','cash_out')),
  amount bigint not null check (amount>0),
  reason text not null check (length(btrim(reason)) between 1 and 2000),
  created_by uuid not null references auth.users(id),
  request_id uuid not null,
  created_at timestamptz not null default now(),
  unique (business_id,request_id)
);
create index daily_closing_adjustments_closing_idx on public.daily_closing_adjustments(business_id,daily_closing_id,created_at);

create table public.daily_payment_reconciliation_adjustments (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id),
  reconciliation_id uuid not null references public.daily_payment_reconciliations(id),
  bucket text not null check (bucket in ('system_receipt','system_refund','statement_receipt','statement_refund')),
  direction text not null check (direction in ('add','subtract')),
  amount bigint not null check (amount>0),
  reason text not null check (length(btrim(reason)) between 1 and 2000),
  created_by uuid not null references auth.users(id),
  request_id uuid not null,
  created_at timestamptz not null default now(),
  unique (business_id,request_id)
);
create index daily_payment_reconciliation_adjustments_idx on public.daily_payment_reconciliation_adjustments(business_id,reconciliation_id,created_at);

alter table public.daily_closing_adjustments enable row level security;
alter table public.daily_payment_reconciliation_adjustments enable row level security;
create policy daily_closing_adjustments_owner_read on public.daily_closing_adjustments
 for select to authenticated using (private.is_active_owner(business_id));
create policy daily_reconciliation_adjustments_owner_read on public.daily_payment_reconciliation_adjustments
 for select to authenticated using (private.is_active_owner(business_id));
revoke insert,update,delete on public.daily_closing_adjustments,public.daily_payment_reconciliation_adjustments from anon,authenticated;
grant select on public.daily_closing_adjustments,public.daily_payment_reconciliation_adjustments to authenticated;

create index cash_movements_created_by_idx on public.cash_movements(created_by);
create index daily_closings_prepared_by_idx on public.daily_closings(prepared_by);
create index daily_closings_closed_by_idx on public.daily_closings(closed_by);
create index daily_payment_reconciliations_prepared_by_idx on public.daily_payment_reconciliations(prepared_by);
create index daily_payment_reconciliations_confirmed_by_idx on public.daily_payment_reconciliations(confirmed_by);

-- Idempotent retries must return the original result even if the business date has since been closed.
create or replace function private.owner_record_cash_movement(
  p_business_id uuid,p_business_date date,p_movement_type text,p_amount bigint,
  p_source_account text,p_destination_account text,p_reference text,p_notes text,p_request_id uuid
) returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_actor uuid; v_cached jsonb; v_payload jsonb; v_id uuid; v_direction text; v_result jsonb;
begin
  v_actor:=private.assert_active_owner(p_business_id);
  if p_business_date is null or p_business_date>(now() at time zone 'Africa/Nairobi')::date
    or p_movement_type not in ('till_top_up','bank_deposit','owner_withdrawal','other_cash_in','other_cash_out')
    or p_amount is null or p_amount<=0 or length(btrim(coalesce(p_notes,''))) not between 1 and 2000
    or p_request_id is null then
    raise exception using errcode='22023',message='Invalid cash movement details';
  end if;
  v_direction:=case when p_movement_type in ('till_top_up','other_cash_in') then 'in' else 'out' end;
  v_payload:=jsonb_build_object('business_date',p_business_date,'movement_type',p_movement_type,'amount',p_amount,
    'source_account',p_source_account,'destination_account',p_destination_account,'reference',p_reference,'notes',p_notes);
  v_cached:=private.begin_idempotent_request(p_business_id,'record_cash_movement',p_request_id,v_payload);
  if v_cached is not null then return v_cached; end if;
  if exists(select 1 from public.daily_closings where business_id=p_business_id and business_date=p_business_date and status='closed') then
    raise exception using errcode='55000',message='This cash day is closed; record a separate closing adjustment';
  end if;
  insert into public.cash_movements(business_id,business_date,movement_type,direction,amount,source_account,destination_account,reference,notes,created_by,request_id)
  values(p_business_id,p_business_date,p_movement_type,v_direction,p_amount,nullif(btrim(p_source_account),''),nullif(btrim(p_destination_account),''),
    nullif(btrim(p_reference),''),btrim(p_notes),v_actor,p_request_id)
  returning id into v_id;
  v_result:=jsonb_build_object('cash_movement_id',v_id,'direction',v_direction,'amount',p_amount);
  perform private.finish_idempotent_request(p_business_id,'record_cash_movement',p_request_id,v_result);
  perform private.write_audit(p_business_id,v_actor,'cash_movement.recorded','cash_movement',v_id,p_request_id,v_result);
  return v_result;
end;
$$;

create or replace function private.owner_record_daily_closing_adjustment(
  p_daily_closing_id uuid,p_adjustment_type text,p_amount bigint,p_reason text,p_request_id uuid
) returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_close public.daily_closings%rowtype; v_actor uuid; v_cached jsonb; v_payload jsonb; v_id uuid; v_result jsonb;
begin
  select * into v_close from public.daily_closings where id=p_daily_closing_id;
  if not found then raise exception using errcode='P0002',message='Daily closing not found'; end if;
  v_actor:=private.assert_active_owner(v_close.business_id);
  if v_close.status<>'closed' or p_adjustment_type not in ('cash_in','cash_out') or p_amount is null or p_amount<=0
    or length(btrim(coalesce(p_reason,''))) not between 1 and 2000 or p_request_id is null then
    raise exception using errcode='22023',message='A closed date, positive adjustment and reason are required';
  end if;
  v_payload:=jsonb_build_object('daily_closing_id',p_daily_closing_id,'adjustment_type',p_adjustment_type,'amount',p_amount,'reason',p_reason);
  v_cached:=private.begin_idempotent_request(v_close.business_id,'daily_closing_adjustment',p_request_id,v_payload);
  if v_cached is not null then return v_cached; end if;
  insert into public.daily_closing_adjustments(business_id,daily_closing_id,adjustment_type,amount,reason,created_by,request_id)
  values(v_close.business_id,p_daily_closing_id,p_adjustment_type,p_amount,btrim(p_reason),v_actor,p_request_id) returning id into v_id;
  v_result:=jsonb_build_object('adjustment_id',v_id,'daily_closing_id',p_daily_closing_id,'adjustment_type',p_adjustment_type,'amount',p_amount);
  perform private.finish_idempotent_request(v_close.business_id,'daily_closing_adjustment',p_request_id,v_result);
  perform private.write_audit(v_close.business_id,v_actor,'daily_closing.adjusted','daily_closing',p_daily_closing_id,p_request_id,v_result||jsonb_build_object('reason',p_reason));
  return v_result;
end;
$$;
create or replace function public.owner_record_daily_closing_adjustment(p_daily_closing_id uuid,p_adjustment_type text,p_amount bigint,p_reason text,p_request_id uuid)
returns jsonb language sql set search_path=''
as $$ select private.owner_record_daily_closing_adjustment($1,$2,$3,$4,$5); $$;
revoke all on function public.owner_record_daily_closing_adjustment(uuid,text,bigint,text,uuid) from public,anon;
grant execute on function public.owner_record_daily_closing_adjustment(uuid,text,bigint,text,uuid) to authenticated;

create or replace function private.owner_record_reconciliation_adjustment(
  p_reconciliation_id uuid,p_bucket text,p_direction text,p_amount bigint,p_reason text,p_request_id uuid
) returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_rec public.daily_payment_reconciliations%rowtype; v_actor uuid; v_cached jsonb; v_payload jsonb; v_id uuid; v_result jsonb;
begin
  select * into v_rec from public.daily_payment_reconciliations where id=p_reconciliation_id;
  if not found then raise exception using errcode='P0002',message='Payment reconciliation not found'; end if;
  v_actor:=private.assert_active_owner(v_rec.business_id);
  if v_rec.status<>'confirmed' or p_bucket not in ('system_receipt','system_refund','statement_receipt','statement_refund')
    or p_direction not in ('add','subtract') or p_amount is null or p_amount<=0
    or length(btrim(coalesce(p_reason,''))) not between 1 and 2000 or p_request_id is null then
    raise exception using errcode='22023',message='A confirmed reconciliation, positive adjustment and reason are required';
  end if;
  v_payload:=jsonb_build_object('reconciliation_id',p_reconciliation_id,'bucket',p_bucket,'direction',p_direction,'amount',p_amount,'reason',p_reason);
  v_cached:=private.begin_idempotent_request(v_rec.business_id,'reconciliation_adjustment',p_request_id,v_payload);
  if v_cached is not null then return v_cached; end if;
  insert into public.daily_payment_reconciliation_adjustments(business_id,reconciliation_id,bucket,direction,amount,reason,created_by,request_id)
  values(v_rec.business_id,p_reconciliation_id,p_bucket,p_direction,p_amount,btrim(p_reason),v_actor,p_request_id) returning id into v_id;
  v_result:=jsonb_build_object('adjustment_id',v_id,'reconciliation_id',p_reconciliation_id,'bucket',p_bucket,'direction',p_direction,'amount',p_amount);
  perform private.finish_idempotent_request(v_rec.business_id,'reconciliation_adjustment',p_request_id,v_result);
  perform private.write_audit(v_rec.business_id,v_actor,'payment_reconciliation.adjusted','daily_payment_reconciliation',p_reconciliation_id,p_request_id,v_result||jsonb_build_object('reason',p_reason));
  return v_result;
end;
$$;
create or replace function public.owner_record_reconciliation_adjustment(p_reconciliation_id uuid,p_bucket text,p_direction text,p_amount bigint,p_reason text,p_request_id uuid)
returns jsonb language sql set search_path=''
as $$ select private.owner_record_reconciliation_adjustment($1,$2,$3,$4,$5,$6); $$;
revoke all on function public.owner_record_reconciliation_adjustment(uuid,text,text,bigint,text,uuid) from public,anon;
grant execute on function public.owner_record_reconciliation_adjustment(uuid,text,text,bigint,text,uuid) to authenticated;

create or replace function private.guard_milestone08_adjustment_append_only()
returns trigger language plpgsql security definer set search_path=''
as $$ begin raise exception using errcode='55000',message='Financial adjustments are append-only'; end; $$;
create trigger daily_closing_adjustments_append_only before update or delete on public.daily_closing_adjustments
for each row execute function private.guard_milestone08_adjustment_append_only();
create trigger daily_reconciliation_adjustments_append_only before update or delete on public.daily_payment_reconciliation_adjustments
for each row execute function private.guard_milestone08_adjustment_append_only();

create or replace function public.owner_get_daily_operations_summary(p_business_id uuid,p_business_date date)
returns jsonb language plpgsql security invoker set search_path=''
as $$
declare v_actor uuid; v_result jsonb; v_start timestamptz; v_end timestamptz;
begin
  v_actor:=private.assert_active_owner(p_business_id);
  if p_business_date is null then raise exception using errcode='22023',message='Business date is required'; end if;
  v_start:=p_business_date::timestamp at time zone 'Africa/Nairobi';
  v_end:=(p_business_date+1)::timestamp at time zone 'Africa/Nairobi';
  select jsonb_build_object(
    'business_date',p_business_date,
    'orders_in_progress',(select count(*) from public.orders o where o.business_id=p_business_id and o.status in ('confirmed','in_production','quality_check')),
    'ready_awaiting_collection',(select count(*) from public.orders o where o.business_id=p_business_id and o.status='ready'
      and not exists(select 1 from public.deliveries d where d.business_id=o.business_id and d.order_id=o.id and d.handed_over_at is not null)
      and not exists(select 1 from public.deliveries d where d.business_id=o.business_id and d.order_id=o.id and d.method='courier' and d.attempt_status='dispatched')),
    'courier_outstanding',(select count(*) from public.deliveries d where d.business_id=p_business_id and d.method='courier' and d.attempt_status='dispatched'),
    'failed_delivery_attempts',(select count(*) from public.deliveries d where d.business_id=p_business_id and d.attempt_status='failed'),
    'overdue_orders',(select count(*) from public.orders o where o.business_id=p_business_id and o.required_by<p_business_date and o.status not in ('completed','cancelled')),
    'pending_mpesa',(select count(*) from public.payments p where p.business_id=p_business_id and p.method='mpesa_manual' and p.status='pending_verification'),
    'outstanding_balances',(select coalesce(sum((private.owner_order_balance(o.id)->>'balance_due')::bigint),0) from public.orders o where o.business_id=p_business_id and o.status not in ('completed','cancelled')),
    'order_value',(select coalesce(sum(o.total_amount),0) from public.orders o where o.business_id=p_business_id and o.received_at>=v_start and o.received_at<v_end and o.status<>'cancelled'),
    'posted_receipts',(select coalesce(sum(p.amount),0) from public.payments p where p.business_id=p_business_id and p.status='posted' and p.received_at>=v_start and p.received_at<v_end),
    'posted_refunds',(select coalesce(sum(f.amount),0) from public.payment_refunds f where f.business_id=p_business_id and f.status='posted' and f.posted_at>=v_start and f.posted_at<v_end),
    'expenses',(select coalesce(sum(e.amount),0) from public.expenses e where e.business_id=p_business_id and e.expense_date=p_business_date),
    'cash_expenses',(select coalesce(sum(e.amount),0) from public.expenses e where e.business_id=p_business_id and e.expense_date=p_business_date and e.payment_method='cash'),
    'production_costs',(select coalesce(sum(c.amount),0) from public.production_cost_entries c where c.business_id=p_business_id and c.occurred_at>=v_start and c.occurred_at<v_end),
    'daily_closing',(select to_jsonb(dc) from public.daily_closings dc where dc.business_id=p_business_id and dc.business_date=p_business_date),
    'daily_closing_adjustments',(select coalesce(jsonb_agg(to_jsonb(a) order by a.created_at), '[]'::jsonb) from public.daily_closing_adjustments a join public.daily_closings dc on dc.id=a.daily_closing_id where a.business_id=p_business_id and dc.business_date=p_business_date),
    'mpesa_reconciliation',(select to_jsonb(r) from public.daily_payment_reconciliations r where r.business_id=p_business_id and r.business_date=p_business_date and r.method='mpesa'),
    'reconciliation_adjustments',(select coalesce(jsonb_agg(to_jsonb(a) order by a.created_at), '[]'::jsonb) from public.daily_payment_reconciliation_adjustments a join public.daily_payment_reconciliations r on r.id=a.reconciliation_id where a.business_id=p_business_id and r.business_date=p_business_date and r.method='mpesa')
  ) into v_result;
  return v_result;
end;
$$;
revoke all on function public.owner_get_daily_operations_summary(uuid,date) from public,anon;
grant execute on function public.owner_get_daily_operations_summary(uuid,date) to authenticated;
