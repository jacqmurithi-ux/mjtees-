-- Milestone 08: daily close, cash movements, reconciliation and delivery attempt history.
-- Additive only. Existing payment, expense, stock and order ledgers remain authoritative.

create table public.cash_movements (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id),
  business_date date not null,
  movement_type text not null check (movement_type in ('till_top_up','bank_deposit','owner_withdrawal','other_cash_in','other_cash_out')),
  direction text not null check (direction in ('in','out')),
  amount bigint not null check (amount > 0),
  source_account text,
  destination_account text,
  reference text,
  notes text not null,
  created_by uuid not null references auth.users(id),
  request_id uuid not null,
  created_at timestamptz not null default now(),
  unique (business_id, request_id),
  check (
    (movement_type in ('till_top_up','other_cash_in') and direction='in')
    or (movement_type in ('bank_deposit','owner_withdrawal','other_cash_out') and direction='out')
  ),
  check (length(btrim(notes)) between 1 and 2000)
);
create index cash_movements_business_date_idx on public.cash_movements(business_id,business_date,created_at);

create table public.daily_closings (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id),
  business_date date not null,
  status text not null default 'draft' check (status in ('draft','closed')),
  opening_float bigint not null check (opening_float >= 0),
  posted_cash_receipts bigint not null default 0 check (posted_cash_receipts >= 0),
  posted_cash_refunds bigint not null default 0 check (posted_cash_refunds >= 0),
  cash_expenses bigint not null default 0 check (cash_expenses >= 0),
  cash_top_ups bigint not null default 0 check (cash_top_ups >= 0),
  cash_bank_deposits bigint not null default 0 check (cash_bank_deposits >= 0),
  cash_owner_withdrawals bigint not null default 0 check (cash_owner_withdrawals >= 0),
  other_cash_in bigint not null default 0 check (other_cash_in >= 0),
  other_cash_out bigint not null default 0 check (other_cash_out >= 0),
  expected_cash bigint not null default 0,
  actual_cash bigint check (actual_cash >= 0),
  difference bigint,
  notes text,
  variance_reason text,
  prepared_by uuid not null references auth.users(id),
  prepared_at timestamptz not null default now(),
  closed_by uuid references auth.users(id),
  closed_at timestamptz,
  created_at timestamptz not null default now(),
  unique (business_id,business_date),
  check ((status='draft' and closed_at is null and closed_by is null) or (status='closed' and closed_at is not null and closed_by is not null and actual_cash is not null and difference is not null))
);
create index daily_closings_business_date_idx on public.daily_closings(business_id,business_date desc);

create table public.daily_payment_reconciliations (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id),
  business_date date not null,
  method text not null check (method in ('mpesa','bank','card')),
  system_receipts bigint not null default 0 check (system_receipts >= 0),
  system_refunds bigint not null default 0 check (system_refunds >= 0),
  statement_receipts bigint not null check (statement_receipts >= 0),
  statement_refunds bigint not null default 0 check (statement_refunds >= 0),
  net_system bigint not null,
  net_statement bigint not null,
  difference bigint not null,
  statement_reference text,
  notes text,
  variance_reason text,
  status text not null default 'draft' check (status in ('draft','confirmed')),
  prepared_by uuid not null references auth.users(id),
  prepared_at timestamptz not null default now(),
  confirmed_by uuid references auth.users(id),
  confirmed_at timestamptz,
  created_at timestamptz not null default now(),
  unique (business_id,business_date,method),
  check ((status='draft' and confirmed_at is null and confirmed_by is null) or (status='confirmed' and confirmed_at is not null and confirmed_by is not null))
);
create index daily_payment_reconciliations_business_date_idx on public.daily_payment_reconciliations(business_id,business_date desc);

alter table public.deliveries
  add column attempt_status text not null default 'prepared'
    check (attempt_status in ('prepared','dispatched','handed_over','failed','cancelled')),
  add column failed_at timestamptz,
  add column failure_reason text,
  add column updated_at timestamptz not null default now();

update public.deliveries
set attempt_status = case
  when handed_over_at is not null then 'handed_over'
  when dispatched_at is not null then 'dispatched'
  else 'prepared'
end;

create index deliveries_outstanding_idx on public.deliveries(business_id,order_id,attempt_status,created_at desc);

alter table public.cash_movements enable row level security;
alter table public.daily_closings enable row level security;
alter table public.daily_payment_reconciliations enable row level security;

create policy cash_movements_owner_read on public.cash_movements
  for select to authenticated
  using (exists (select 1 from public.business_memberships m where m.business_id=cash_movements.business_id and m.user_id=(select auth.uid()) and m.role='owner' and m.status='active'));
create policy daily_closings_owner_read on public.daily_closings
  for select to authenticated
  using (exists (select 1 from public.business_memberships m where m.business_id=daily_closings.business_id and m.user_id=(select auth.uid()) and m.role='owner' and m.status='active'));
create policy daily_reconciliations_owner_read on public.daily_payment_reconciliations
  for select to authenticated
  using (exists (select 1 from public.business_memberships m where m.business_id=daily_payment_reconciliations.business_id and m.user_id=(select auth.uid()) and m.role='owner' and m.status='active'));

revoke insert, update, delete on public.cash_movements, public.daily_closings, public.daily_payment_reconciliations from anon, authenticated;
grant select on public.cash_movements, public.daily_closings, public.daily_payment_reconciliations to authenticated;

create or replace function private.guard_delivery_attempt_history()
returns trigger language plpgsql security definer set search_path=''
as $$
begin
  if tg_op='DELETE' then
    raise exception using errcode='55000',message='Delivery attempt history cannot be deleted';
  end if;
  if tg_op='INSERT' then
    if new.failed_at is not null then new.attempt_status:='failed';
    elsif new.handed_over_at is not null then new.attempt_status:='handed_over';
    elsif new.dispatched_at is not null then new.attempt_status:='dispatched';
    else new.attempt_status:='prepared'; end if;
    new.updated_at:=now();
    return new;
  end if;
  if old.attempt_status in ('failed','handed_over','cancelled') then
    raise exception using errcode='55000',message='A terminal delivery attempt is immutable; create a new attempt';
  end if;
  if new.failed_at is not null then
    new.attempt_status:='failed';
  elsif new.handed_over_at is not null then
    new.attempt_status:='handed_over';
  elsif new.dispatched_at is not null then
    new.attempt_status:='dispatched';
  else
    new.attempt_status:='prepared';
  end if;
  new.updated_at:=now();
  return new;
end;
$$;
create trigger deliveries_guard_attempt_history
before insert or update or delete on public.deliveries
for each row execute function private.guard_delivery_attempt_history();

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

create or replace function public.owner_record_cash_movement(
  p_business_id uuid,p_business_date date,p_movement_type text,p_amount bigint,
  p_source_account text,p_destination_account text,p_reference text,p_notes text,p_request_id uuid
) returns jsonb language sql set search_path=''
as $$ select private.owner_record_cash_movement($1,$2,$3,$4,$5,$6,$7,$8,$9); $$;
revoke all on function public.owner_record_cash_movement(uuid,date,text,bigint,text,text,text,text,uuid) from public,anon;
grant execute on function public.owner_record_cash_movement(uuid,date,text,bigint,text,text,text,text,uuid) to authenticated;

create or replace function private.owner_save_daily_closing(
  p_business_id uuid,p_business_date date,p_opening_float bigint,p_actual_cash bigint,
  p_notes text,p_variance_reason text,p_close boolean,p_request_id uuid
) returns jsonb language plpgsql security definer set search_path=''
as $$
declare
  v_actor uuid; v_cached jsonb; v_payload jsonb; v_existing public.daily_closings%rowtype; v_has_existing boolean:=false;
  v_opening bigint; v_previous bigint; v_receipts bigint; v_refunds bigint; v_expenses bigint;
  v_topups bigint; v_deposits bigint; v_withdrawals bigint; v_other_in bigint; v_other_out bigint;
  v_expected bigint; v_difference bigint; v_id uuid; v_result jsonb;
begin
  v_actor:=private.assert_active_owner(p_business_id);
  if p_business_date is null or p_business_date>(now() at time zone 'Africa/Nairobi')::date
    or p_request_id is null or (p_opening_float is not null and p_opening_float<0)
    or (p_actual_cash is not null and p_actual_cash<0) or length(coalesce(p_notes,''))>4000
    or length(coalesce(p_variance_reason,''))>2000 then
    raise exception using errcode='22023',message='Invalid daily closing details';
  end if;
  v_payload:=jsonb_build_object('business_date',p_business_date,'opening_float',p_opening_float,'actual_cash',p_actual_cash,
    'notes',p_notes,'variance_reason',p_variance_reason,'close',p_close);
  v_cached:=private.begin_idempotent_request(p_business_id,'save_daily_closing',p_request_id,v_payload);
  if v_cached is not null then return v_cached; end if;
  select * into v_existing from public.daily_closings
  where business_id=p_business_id and business_date=p_business_date for update;
  v_has_existing:=found;
  if v_has_existing and v_existing.status='closed' then
    raise exception using errcode='55000',message='This business date is already closed; record an adjustment instead';
  end if;
  select actual_cash into v_previous from public.daily_closings
  where business_id=p_business_id and status='closed' and business_date<p_business_date
  order by business_date desc limit 1;
  v_opening:=coalesce(p_opening_float,v_existing.opening_float,v_previous);
  if v_opening is null then
    raise exception using errcode='22023',message='Enter the opening cash float for the first business day';
  end if;
  select coalesce(sum(amount),0)::bigint into v_receipts from public.payments
  where business_id=p_business_id and status='posted' and method='cash'
    and received_at>=p_business_date::timestamp at time zone 'Africa/Nairobi'
    and received_at<(p_business_date+1)::timestamp at time zone 'Africa/Nairobi';
  select coalesce(sum(amount),0)::bigint into v_refunds from public.payment_refunds
  where business_id=p_business_id and status='posted' and refund_method='cash'
    and posted_at>=p_business_date::timestamp at time zone 'Africa/Nairobi'
    and posted_at<(p_business_date+1)::timestamp at time zone 'Africa/Nairobi';
  select coalesce(sum(amount),0)::bigint into v_expenses from public.expenses
  where business_id=p_business_id and payment_method='cash' and expense_date=p_business_date;
  select coalesce(sum(amount) filter(where movement_type='till_top_up'),0)::bigint,
         coalesce(sum(amount) filter(where movement_type='bank_deposit'),0)::bigint,
         coalesce(sum(amount) filter(where movement_type='owner_withdrawal'),0)::bigint,
         coalesce(sum(amount) filter(where movement_type='other_cash_in'),0)::bigint,
         coalesce(sum(amount) filter(where movement_type='other_cash_out'),0)::bigint
  into v_topups,v_deposits,v_withdrawals,v_other_in,v_other_out
  from public.cash_movements where business_id=p_business_id and business_date=p_business_date;
  v_expected:=v_opening+v_receipts-v_refunds-v_expenses+v_topups-v_deposits-v_withdrawals+v_other_in-v_other_out;
  v_difference:=case when p_actual_cash is null then null else p_actual_cash-v_expected end;
  if p_close and p_actual_cash is null then
    raise exception using errcode='22023',message='Enter the physical cash count before closing';
  end if;
  if p_close and v_difference<>0 and length(btrim(coalesce(p_variance_reason,'')))=0 then
    raise exception using errcode='22023',message='Explain the cash shortage or excess before closing';
  end if;
  if v_has_existing then
    update public.daily_closings set opening_float=v_opening,posted_cash_receipts=v_receipts,posted_cash_refunds=v_refunds,
      cash_expenses=v_expenses,cash_top_ups=v_topups,cash_bank_deposits=v_deposits,cash_owner_withdrawals=v_withdrawals,
      other_cash_in=v_other_in,other_cash_out=v_other_out,expected_cash=v_expected,actual_cash=p_actual_cash,
      difference=v_difference,notes=p_notes,variance_reason=nullif(btrim(p_variance_reason),''),
      status=case when p_close then 'closed' else 'draft' end,
      closed_by=case when p_close then v_actor else null end,closed_at=case when p_close then now() else null end,
      prepared_by=v_actor,prepared_at=now()
    where business_id=p_business_id and business_date=p_business_date returning id into v_id;
  else
    insert into public.daily_closings(business_id,business_date,status,opening_float,posted_cash_receipts,posted_cash_refunds,
      cash_expenses,cash_top_ups,cash_bank_deposits,cash_owner_withdrawals,other_cash_in,other_cash_out,expected_cash,
      actual_cash,difference,notes,variance_reason,prepared_by,closed_by,closed_at)
    values(p_business_id,p_business_date,case when p_close then 'closed' else 'draft' end,v_opening,v_receipts,v_refunds,
      v_expenses,v_topups,v_deposits,v_withdrawals,v_other_in,v_other_out,v_expected,p_actual_cash,v_difference,p_notes,
      nullif(btrim(p_variance_reason),''),v_actor,case when p_close then v_actor else null end,case when p_close then now() else null end)
    returning id into v_id;
  end if;
  v_result:=jsonb_build_object('daily_closing_id',v_id,'business_date',p_business_date,'status',case when p_close then 'closed' else 'draft' end,
    'opening_float',v_opening,'expected_cash',v_expected,'actual_cash',p_actual_cash,'difference',v_difference);
  perform private.finish_idempotent_request(p_business_id,'save_daily_closing',p_request_id,v_result);
  perform private.write_audit(p_business_id,v_actor,case when p_close then 'daily_closing.closed' else 'daily_closing.saved' end,
    'daily_closing',v_id,p_request_id,v_result);
  return v_result;
end;
$$;

create or replace function public.owner_save_daily_closing(
  p_business_id uuid,p_business_date date,p_opening_float bigint,p_actual_cash bigint,
  p_notes text,p_variance_reason text,p_close boolean,p_request_id uuid
) returns jsonb language sql set search_path=''
as $$ select private.owner_save_daily_closing($1,$2,$3,$4,$5,$6,$7,$8); $$;
revoke all on function public.owner_save_daily_closing(uuid,date,bigint,bigint,text,text,boolean,uuid) from public,anon;
grant execute on function public.owner_save_daily_closing(uuid,date,bigint,bigint,text,text,boolean,uuid) to authenticated;

create or replace function private.owner_save_payment_reconciliation(
  p_business_id uuid,p_business_date date,p_method text,p_statement_receipts bigint,p_statement_refunds bigint,
  p_statement_reference text,p_notes text,p_variance_reason text,p_confirm boolean,p_request_id uuid
) returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_actor uuid; v_cached jsonb; v_payload jsonb; v_receipts bigint; v_refunds bigint; v_id uuid;
  v_net_system bigint; v_net_statement bigint; v_difference bigint; v_existing public.daily_payment_reconciliations%rowtype; v_result jsonb; v_has_existing boolean:=false;
begin
  v_actor:=private.assert_active_owner(p_business_id);
  if p_business_date is null or p_business_date>(now() at time zone 'Africa/Nairobi')::date
    or p_method not in ('mpesa','bank','card') or p_statement_receipts is null or p_statement_receipts<0
    or p_statement_refunds is null or p_statement_refunds<0 or p_request_id is null
    or length(coalesce(p_statement_reference,''))>160 or length(coalesce(p_notes,''))>4000
    or length(coalesce(p_variance_reason,''))>2000 then
    raise exception using errcode='22023',message='Invalid payment reconciliation details';
  end if;
  v_payload:=jsonb_build_object('business_date',p_business_date,'method',p_method,'statement_receipts',p_statement_receipts,
    'statement_refunds',p_statement_refunds,'statement_reference',p_statement_reference,'notes',p_notes,
    'variance_reason',p_variance_reason,'confirm',p_confirm);
  v_cached:=private.begin_idempotent_request(p_business_id,'save_payment_reconciliation',p_request_id,v_payload);
  if v_cached is not null then return v_cached; end if;
  select * into v_existing from public.daily_payment_reconciliations
  where business_id=p_business_id and business_date=p_business_date and method=p_method for update;
  v_has_existing:=found;
  if v_has_existing and v_existing.status='confirmed' then
    raise exception using errcode='55000',message='This reconciliation is confirmed and immutable';
  end if;
  if p_method='mpesa' then
    if p_confirm and exists(select 1 from public.payments where business_id=p_business_id and method='mpesa_manual'
      and status='pending_verification' and received_at>=p_business_date::timestamp at time zone 'Africa/Nairobi'
      and received_at<(p_business_date+1)::timestamp at time zone 'Africa/Nairobi') then
      raise exception using errcode='22023',message='Verify or reject all M-Pesa evidence for this date before confirming reconciliation';
    end if;
    select coalesce(sum(amount),0)::bigint into v_receipts from public.payments
    where business_id=p_business_id and status='posted' and method='mpesa_manual'
      and received_at>=p_business_date::timestamp at time zone 'Africa/Nairobi'
      and received_at<(p_business_date+1)::timestamp at time zone 'Africa/Nairobi';
    select coalesce(sum(amount),0)::bigint into v_refunds from public.payment_refunds
    where business_id=p_business_id and status='posted' and refund_method='mpesa'
      and posted_at>=p_business_date::timestamp at time zone 'Africa/Nairobi'
      and posted_at<(p_business_date+1)::timestamp at time zone 'Africa/Nairobi';
  else
    v_receipts:=0; v_refunds:=0;
  end if;
  v_net_system:=v_receipts-v_refunds; v_net_statement:=p_statement_receipts-p_statement_refunds;
  v_difference:=v_net_statement-v_net_system;
  if p_confirm and v_difference<>0 and length(btrim(coalesce(p_variance_reason,'')))=0 then
    raise exception using errcode='22023',message='Explain the statement variance before confirming';
  end if;
  if v_has_existing then
    update public.daily_payment_reconciliations set system_receipts=v_receipts,system_refunds=v_refunds,
      statement_receipts=p_statement_receipts,statement_refunds=p_statement_refunds,net_system=v_net_system,
      net_statement=v_net_statement,difference=v_difference,statement_reference=nullif(btrim(p_statement_reference),''),
      notes=p_notes,variance_reason=nullif(btrim(p_variance_reason),''),
      status=case when p_confirm then 'confirmed' else 'draft' end,confirmed_by=case when p_confirm then v_actor else null end,
      confirmed_at=case when p_confirm then now() else null end,prepared_by=v_actor,prepared_at=now()
    where business_id=p_business_id and business_date=p_business_date and method=p_method returning id into v_id;
  else
    insert into public.daily_payment_reconciliations(business_id,business_date,method,system_receipts,system_refunds,
      statement_receipts,statement_refunds,net_system,net_statement,difference,statement_reference,notes,variance_reason,
      status,prepared_by,confirmed_by,confirmed_at)
    values(p_business_id,p_business_date,p_method,v_receipts,v_refunds,p_statement_receipts,p_statement_refunds,
      v_net_system,v_net_statement,v_difference,nullif(btrim(p_statement_reference),''),p_notes,
      nullif(btrim(p_variance_reason),''),case when p_confirm then 'confirmed' else 'draft' end,v_actor,
      case when p_confirm then v_actor else null end,case when p_confirm then now() else null end)
    returning id into v_id;
  end if;
  v_result:=jsonb_build_object('reconciliation_id',v_id,'method',p_method,'net_system',v_net_system,
    'net_statement',v_net_statement,'difference',v_difference,'status',case when p_confirm then 'confirmed' else 'draft' end);
  perform private.finish_idempotent_request(p_business_id,'save_payment_reconciliation',p_request_id,v_result);
  perform private.write_audit(p_business_id,v_actor,case when p_confirm then 'payment_reconciliation.confirmed' else 'payment_reconciliation.saved' end,
    'daily_payment_reconciliation',v_id,p_request_id,v_result);
  return v_result;
end;
$$;

create or replace function public.owner_save_payment_reconciliation(
  p_business_id uuid,p_business_date date,p_method text,p_statement_receipts bigint,p_statement_refunds bigint,
  p_statement_reference text,p_notes text,p_variance_reason text,p_confirm boolean,p_request_id uuid
) returns jsonb language sql set search_path=''
as $$ select private.owner_save_payment_reconciliation($1,$2,$3,$4,$5,$6,$7,$8,$9,$10); $$;
revoke all on function public.owner_save_payment_reconciliation(uuid,date,text,bigint,bigint,text,text,text,boolean,uuid) from public,anon;
grant execute on function public.owner_save_payment_reconciliation(uuid,date,text,bigint,bigint,text,text,text,boolean,uuid) to authenticated;

create or replace function private.owner_mark_delivery_failed(p_delivery_id uuid,p_reason text,p_request_id uuid)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_delivery public.deliveries%rowtype; v_actor uuid; v_cached jsonb; v_payload jsonb; v_result jsonb;
begin
  select * into v_delivery from public.deliveries where id=p_delivery_id;
  if not found then raise exception using errcode='P0002',message='Delivery attempt not found'; end if;
  v_actor:=private.assert_active_owner(v_delivery.business_id);
  if length(btrim(coalesce(p_reason,''))) not between 1 and 2000 or p_request_id is null then
    raise exception using errcode='22023',message='A failure reason and request id are required';
  end if;
  v_payload:=jsonb_build_object('delivery_id',p_delivery_id,'reason',p_reason);
  v_cached:=private.begin_idempotent_request(v_delivery.business_id,'mark_delivery_failed',p_request_id,v_payload);
  if v_cached is not null then return v_cached; end if;
  update public.deliveries set failed_at=now(),failure_reason=btrim(p_reason),attempt_status='failed',updated_at=now()
  where business_id=v_delivery.business_id and id=p_delivery_id and handed_over_at is null and failed_at is null;
  if not found then raise exception using errcode='55000',message='Only an outstanding attempt can be marked failed'; end if;
  v_result:=jsonb_build_object('delivery_id',p_delivery_id,'attempt_status','failed');
  perform private.finish_idempotent_request(v_delivery.business_id,'mark_delivery_failed',p_request_id,v_result);
  perform private.write_audit(v_delivery.business_id,v_actor,'delivery.attempt_failed','delivery',p_delivery_id,p_request_id,v_result||jsonb_build_object('reason',p_reason));
  return v_result;
end;
$$;
create or replace function public.owner_mark_delivery_failed(p_delivery_id uuid,p_reason text,p_request_id uuid)
returns jsonb language sql set search_path=''
as $$ select private.owner_mark_delivery_failed($1,$2,$3); $$;
revoke all on function public.owner_mark_delivery_failed(uuid,text,uuid) from public,anon;
grant execute on function public.owner_mark_delivery_failed(uuid,text,uuid) to authenticated;

create or replace function public.owner_get_daily_operations_summary(p_business_id uuid,p_business_date date)
returns jsonb language plpgsql security definer set search_path=''
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
    'ready_awaiting_collection',(select count(*) from public.orders o where o.business_id=p_business_id and o.status='ready' and not exists(select 1 from public.deliveries d where d.business_id=o.business_id and d.order_id=o.id and d.handed_over_at is not null)),
    'courier_outstanding',(select count(*) from public.deliveries d where d.business_id=p_business_id and d.method='courier' and d.attempt_status='dispatched'),
    'failed_delivery_attempts',(select count(*) from public.deliveries d where d.business_id=p_business_id and d.attempt_status='failed'),
    'overdue_orders',(select count(*) from public.orders o where o.business_id=p_business_id and o.required_by<p_business_date and o.status not in ('completed','cancelled')),
    'pending_mpesa',(select count(*) from public.payments p where p.business_id=p_business_id and p.method='mpesa_manual' and p.status='pending_verification'),
    'order_value',(select coalesce(sum(o.total_amount),0) from public.orders o where o.business_id=p_business_id and o.received_at>=v_start and o.received_at<v_end and o.status<>'cancelled'),
    'posted_receipts',(select coalesce(sum(p.amount),0) from public.payments p where p.business_id=p_business_id and p.status='posted' and p.received_at>=v_start and p.received_at<v_end),
    'posted_refunds',(select coalesce(sum(f.amount),0) from public.payment_refunds f where f.business_id=p_business_id and f.status='posted' and f.posted_at>=v_start and f.posted_at<v_end),
    'expenses',(select coalesce(sum(e.amount),0) from public.expenses e where e.business_id=p_business_id and e.expense_date=p_business_date),
    'cash_expenses',(select coalesce(sum(e.amount),0) from public.expenses e where e.business_id=p_business_id and e.expense_date=p_business_date and e.payment_method='cash'),
    'production_costs',(select coalesce(sum(c.amount),0) from public.production_cost_entries c where c.business_id=p_business_id and c.occurred_at>=v_start and c.occurred_at<v_end),
    'daily_closing',(select to_jsonb(dc) from public.daily_closings dc where dc.business_id=p_business_id and dc.business_date=p_business_date),
    'mpesa_reconciliation',(select to_jsonb(r) from public.daily_payment_reconciliations r where r.business_id=p_business_id and r.business_date=p_business_date and r.method='mpesa')
  ) into v_result;
  return v_result;
end;
$$;
revoke all on function public.owner_get_daily_operations_summary(uuid,date) from public,anon;
grant execute on function public.owner_get_daily_operations_summary(uuid,date) to authenticated;


-- Terminal snapshots and cash movements are append-only.
create or replace function private.guard_milestone08_immutable_rows()
returns trigger language plpgsql security definer set search_path=''
as $$
begin
  if tg_table_name='cash_movements' then
    raise exception using errcode='55000',message='Cash movements are append-only; record a correcting movement';
  end if;
  if tg_op='DELETE' then
    if (tg_table_name='daily_closings' and old.status='closed')
      or (tg_table_name='daily_payment_reconciliations' and old.status='confirmed') then
      raise exception using errcode='55000',message='Confirmed financial snapshots cannot be deleted';
    end if;
    return old;
  end if;
  if tg_table_name='daily_closings' and old.status='closed' then
    raise exception using errcode='55000',message='A closed daily snapshot is immutable';
  end if;
  if tg_table_name='daily_payment_reconciliations' and old.status='confirmed' then
    raise exception using errcode='55000',message='A confirmed reconciliation is immutable';
  end if;
  return new;
end;
$$;
create trigger cash_movements_immutable before update or delete on public.cash_movements
for each row execute function private.guard_milestone08_immutable_rows();
create trigger daily_closings_immutable before update or delete on public.daily_closings
for each row execute function private.guard_milestone08_immutable_rows();
create trigger daily_payment_reconciliations_immutable before update or delete on public.daily_payment_reconciliations
for each row execute function private.guard_milestone08_immutable_rows();

-- Do not allow cashbook inputs to be backdated into a closed cash day.
create or replace function private.guard_closed_cash_day()
returns trigger language plpgsql security definer set search_path=''
as $$
declare v_date date; v_business uuid; v_is_cash boolean:=false;
begin
  if tg_table_name='payments' then
    v_date:=(new.received_at at time zone 'Africa/Nairobi')::date;
    v_business:=new.business_id;
    v_is_cash:=new.method='cash';
  elsif tg_table_name='expenses' then
    v_date:=new.expense_date;
    v_business:=new.business_id;
    v_is_cash:=new.payment_method='cash';
  end if;
  if v_is_cash and exists(select 1 from public.daily_closings where business_id=v_business and business_date=v_date and status='closed') then
    raise exception using errcode='55000',message='This cash day is already closed; use a current-day correction movement';
  end if;
  return new;
end;
$$;
create trigger payments_guard_closed_cash_day before insert on public.payments
for each row execute function private.guard_closed_cash_day();
create trigger expenses_guard_closed_cash_day before insert on public.expenses
for each row execute function private.guard_closed_cash_day();

-- A failed delivery remains historical. The next recording call creates a fresh attempt.
create or replace function private.owner_record_delivery(
  p_order_id uuid,p_method text,p_carrier text,p_tracking_reference text,
  p_customer_paid_charge bigint,p_recipient_name text,p_request_id uuid
) returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_order public.orders%rowtype; v_actor uuid; v_cached jsonb; v_payload jsonb;
  v_id uuid; v_existing public.deliveries%rowtype; v_result jsonb;
begin
  select * into v_order from public.orders where id=p_order_id;
  if not found then raise exception using errcode='P0002',message='Order not found'; end if;
  v_actor:=private.assert_active_owner(v_order.business_id);
  if v_order.status<>'ready' or p_method is null or p_method not in ('collection','courier')
    or p_customer_paid_charge is null or p_customer_paid_charge<0
    or length(btrim(coalesce(p_recipient_name,''))) not between 1 and 180
    or (p_method='courier' and length(btrim(coalesce(p_carrier,'')))=0) then
    raise exception using errcode='22023',message='Order must be ready and delivery details must be valid';
  end if;
  v_payload:=jsonb_build_object('order_id',p_order_id,'method',p_method,'carrier',p_carrier,
    'tracking_reference',p_tracking_reference,'customer_paid_charge',p_customer_paid_charge,'recipient_name',p_recipient_name);
  v_cached:=private.begin_idempotent_request(v_order.business_id,'record_delivery',p_request_id,v_payload);
  if v_cached is not null then return v_cached; end if;
  select * into v_existing from public.deliveries
  where business_id=v_order.business_id and order_id=p_order_id and handed_over_at is null
    and failed_at is null and attempt_status in ('prepared','dispatched')
  order by created_at desc,id desc limit 1 for update;
  if found then
    if v_existing.method<>p_method then raise exception using errcode='22023',message='An active delivery exists with a different method'; end if;
    update public.deliveries set carrier=nullif(btrim(p_carrier),''),tracking_reference=nullif(btrim(p_tracking_reference),''),
      customer_paid_charge=p_customer_paid_charge,recipient_name=btrim(p_recipient_name),
      dispatched_at=case when p_method='courier' then coalesce(dispatched_at,now()) else null end
    where business_id=v_order.business_id and id=v_existing.id returning id into v_id;
  else
    insert into public.deliveries(business_id,order_id,method,carrier,tracking_reference,customer_paid_charge,recipient_name,dispatched_at)
    values(v_order.business_id,p_order_id,p_method,nullif(btrim(p_carrier),''),nullif(btrim(p_tracking_reference),''),
      p_customer_paid_charge,btrim(p_recipient_name),case when p_method='courier' then now() else null end)
    returning id into v_id;
  end if;
  v_result:=jsonb_build_object('delivery_id',v_id,'method',p_method,'customer_paid_charge',p_customer_paid_charge);
  perform private.finish_idempotent_request(v_order.business_id,'record_delivery',p_request_id,v_result);
  perform private.write_audit(v_order.business_id,v_actor,'delivery.recorded','delivery',v_id,p_request_id,
    jsonb_build_object('customer_paid_charge',p_customer_paid_charge,'method',p_method));
  return v_result;
end;
$$;
