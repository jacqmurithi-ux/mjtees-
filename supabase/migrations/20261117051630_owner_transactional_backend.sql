-- MJ Tees — transactional owner backend (financial core and handover)
-- Supabase CLI generated: 2026-11-17. Apply only after separate explicit approval.
begin;

create table private.rpc_idempotency (
  business_id uuid not null references public.businesses(id) on delete restrict,
  operation text not null,
  request_id uuid not null,
  request_payload jsonb not null,
  result jsonb,
  created_at timestamptz not null default now(),
  primary key (business_id, operation, request_id)
);
alter table private.rpc_idempotency enable row level security;
revoke all on private.rpc_idempotency from public, anon, authenticated;

create index if not exists business_memberships_owner_lookup
  on public.business_memberships(user_id,business_id,status,role);
create index if not exists payment_allocations_payment_idx
  on public.payment_allocations(business_id,payment_id);
create index if not exists payment_allocations_order_idx
  on public.payment_allocations(business_id,order_id);
create index if not exists allocation_reversals_allocation_idx
  on public.allocation_reversals(business_id,allocation_id);
create index if not exists payment_refunds_allocation_idx
  on public.payment_refunds(business_id,allocation_id,status);
create index if not exists payment_refunds_payment_idx
  on public.payment_refunds(business_id,payment_id,status);

create or replace function private.assert_active_owner(p_business_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare v_user uuid;
begin
  v_user := auth.uid();
  if v_user is null then
    raise exception using errcode = '42501', message = 'Authentication required';
  end if;
  if not exists (
    select 1 from public.businesses b
    join public.business_memberships m on m.business_id = b.id
    where b.id = p_business_id and b.is_active
      and m.user_id = v_user and m.role = 'owner' and m.status = 'active'
  ) then
    raise exception using errcode = '42501', message = 'Active owner access required';
  end if;
  return v_user;
end;
$$;

create or replace function private.begin_idempotent_request(
  p_business_id uuid, p_operation text, p_request_id uuid, p_payload jsonb
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v_existing private.rpc_idempotency%rowtype;
begin
  if p_request_id is null then
    raise exception using errcode = '22023', message = 'request_id is required';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(
    p_business_id::text || ':' || p_operation || ':' || p_request_id::text, 0
  ));
  select * into v_existing from private.rpc_idempotency
  where business_id = p_business_id and operation = p_operation and request_id = p_request_id;
  if found then
    if v_existing.request_payload is distinct from p_payload then
      raise exception using errcode = '22023', message = 'request_id reused with different payload';
    end if;
    if v_existing.result is null then
      raise exception using errcode = '40001', message = 'Request is already being processed';
    end if;
    return v_existing.result;
  end if;
  insert into private.rpc_idempotency(business_id,operation,request_id,request_payload)
  values (p_business_id,p_operation,p_request_id,p_payload);
  return null;
end;
$$;

create or replace function private.finish_idempotent_request(
  p_business_id uuid, p_operation text, p_request_id uuid, p_result jsonb
) returns void
language sql
security definer
set search_path = ''
as $$
  update private.rpc_idempotency
  set result = p_result
  where business_id = p_business_id and operation = p_operation and request_id = p_request_id;
$$;

create or replace function private.next_document_number(p_business_id uuid,p_type text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare v_prefix text; v_number bigint;
begin
  insert into public.document_counters(business_id,document_type,next_value,prefix)
  values (p_business_id,p_type,2,upper(left(p_type,1)))
  on conflict (business_id,document_type)
  do update set next_value = public.document_counters.next_value + 1,
                updated_at = now()
  returning prefix,next_value - 1 into v_prefix,v_number;
  return v_prefix || '-' || to_char(current_date,'YYYY') || '-' || lpad(v_number::text,6,'0');
end;
$$;

create or replace function private.write_audit(
  p_business_id uuid,p_actor uuid,p_action text,p_entity_type text,p_entity_id uuid,
  p_request_id uuid,p_metadata jsonb default '{}'::jsonb
) returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.audit_events(business_id,actor_user_id,action,entity_type,entity_id,request_id,metadata)
  values (p_business_id,p_actor,p_action,p_entity_type,p_entity_id,p_request_id,coalesce(p_metadata,'{}'::jsonb));
$$;

-- Owner customer create/update.
create or replace function private.owner_upsert_customer(
  p_business_id uuid,p_customer_id uuid,p_display_name text,p_business_name text,
  p_phone text,p_email text,p_notes text,p_request_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v_actor uuid; v_cached jsonb; v_id uuid; v_created boolean; v_payload jsonb; v_result jsonb;
begin
  v_actor := private.assert_active_owner(p_business_id);
  if length(btrim(coalesce(p_display_name,''))) not between 1 and 180
     or length(coalesce(p_business_name,'')) > 180
     or length(coalesce(p_phone,'')) > 40
     or length(coalesce(p_email,'')) > 254
     or length(coalesce(p_notes,'')) > 4000 then
    raise exception using errcode='22023',message='Customer fields exceed allowed limits';
  end if;
  if p_email is not null and p_email !~* '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then
    raise exception using errcode='22023',message='Invalid email address';
  end if;
  v_payload := jsonb_build_object('customer_id',p_customer_id,'display_name',p_display_name,
    'business_name',p_business_name,'phone',p_phone,'email',p_email,'notes',p_notes);
  v_cached := private.begin_idempotent_request(p_business_id,'upsert_customer',p_request_id,v_payload);
  if v_cached is not null then return v_cached; end if;

  if p_customer_id is null then
    insert into public.customers(business_id,display_name,business_name,phone,phone_normalized,email,notes,created_by)
    values(p_business_id,btrim(p_display_name),nullif(btrim(p_business_name),''),nullif(btrim(p_phone),''),
      nullif(regexp_replace(coalesce(p_phone,''),'[^0-9+]','','g'),''),nullif(lower(btrim(p_email)),''),p_notes,v_actor)
    returning id into v_id;
    v_created := true;
  else
    update public.customers set display_name=btrim(p_display_name),
      business_name=nullif(btrim(p_business_name),''),phone=nullif(btrim(p_phone),''),
      phone_normalized=nullif(regexp_replace(coalesce(p_phone,''),'[^0-9+]','','g'),''),email=nullif(lower(btrim(p_email)),''),
      notes=p_notes,updated_at=now()
    where business_id=p_business_id and id=p_customer_id and archived_at is null
    returning id into v_id;
    if v_id is null then raise exception using errcode='P0002',message='Customer not found or archived'; end if;
    v_created := false;
  end if;
  v_result := jsonb_build_object('customer_id',v_id,'created',v_created);
  perform private.finish_idempotent_request(p_business_id,'upsert_customer',p_request_id,v_result);
  perform private.write_audit(p_business_id,v_actor,case when v_created then 'customer.created' else 'customer.updated' end,
    'customer',v_id,p_request_id,'{}'::jsonb);
  return v_result;
end;
$$;

-- Derived order balance. Refunds and allocation reversals share allocation capacity.
create or replace function private.owner_order_balance(p_order_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v_order public.orders%rowtype; v_actor uuid; v_paid bigint; v_due bigint; v_overpaid bigint;
begin
  select * into v_order from public.orders where id=p_order_id;
  if not found then raise exception using errcode='P0002',message='Order not found'; end if;
  v_actor := private.assert_active_owner(v_order.business_id);
  select coalesce(sum(a.amount
      - coalesce((select sum(r.amount) from public.allocation_reversals r where r.business_id=a.business_id and r.allocation_id=a.id),0)
      - coalesce((select sum(f.amount) from public.payment_refunds f where f.business_id=a.business_id and f.allocation_id=a.id and f.status='posted'),0)
    ),0)::bigint
  into v_paid
  from public.payment_allocations a
  join public.payments p on p.business_id=a.business_id and p.id=a.payment_id
  where a.business_id=v_order.business_id and a.order_id=p_order_id and p.status='posted';
  v_due := greatest(v_order.total_amount-v_paid,0);
  v_overpaid := greatest(v_paid-v_order.total_amount,0);
  return jsonb_build_object('order_id',p_order_id,'order_total',v_order.total_amount,
    'net_paid',v_paid,'balance_due',v_due,'overpaid',v_overpaid,'currency_code','KES');
end;
$$;

create or replace function private.owner_record_payment(
  p_business_id uuid,p_order_id uuid,p_method text,p_amount bigint,p_received_at timestamptz,
  p_payer_name text,p_payer_phone text,p_mpesa_reference text,p_notes text,p_request_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v_actor uuid; v_cached jsonb; v_order public.orders%rowtype; v_balance jsonb;
  v_payment uuid; v_number text; v_status text; v_receipt text; v_payload jsonb; v_result jsonb;
  v_reference text;
begin
  v_actor := private.assert_active_owner(p_business_id);
  if p_amount is null or p_amount <= 0 or p_method not in ('cash','mpesa_manual') then
    raise exception using errcode='22023',message='Invalid payment method or amount';
  end if;
  if p_method='cash' and nullif(btrim(p_mpesa_reference),'') is not null then
    raise exception using errcode='22023',message='Cash payment cannot have an M-Pesa reference';
  end if;
  if p_method='mpesa_manual' and length(btrim(coalesce(p_mpesa_reference,''))) not between 6 and 32 then
    raise exception using errcode='22023',message='Valid M-Pesa reference is required';
  end if;
  if p_received_at is null or p_received_at > now() + interval '5 minutes' then
    raise exception using errcode='22023',message='Invalid received timestamp';
  end if;
  v_payload:=jsonb_build_object('order_id',p_order_id,'method',p_method,'amount',p_amount,'received_at',p_received_at,
    'payer_name',p_payer_name,'payer_phone',p_payer_phone,'mpesa_reference',upper(btrim(coalesce(p_mpesa_reference,''))),'notes',p_notes);
  v_cached:=private.begin_idempotent_request(p_business_id,'record_payment',p_request_id,v_payload);
  if v_cached is not null then return v_cached; end if;
  select * into v_order from public.orders where business_id=p_business_id and id=p_order_id for update;
  if not found then raise exception using errcode='P0002',message='Order not found'; end if;
  if v_order.status in ('cancelled','completed') then raise exception using errcode='22023',message='Order cannot receive payment'; end if;
  v_number:=private.next_document_number(p_business_id,'payment');
  v_status:=case when p_method='cash' then 'posted' else 'pending_verification' end;
  v_reference:=case when p_method='mpesa_manual' then upper(regexp_replace(btrim(p_mpesa_reference),'[^A-Za-z0-9]','','g')) else null end;
  insert into public.payments(business_id,payment_number,method,status,amount,received_at,payer_name,payer_phone,
    mpesa_reference,mpesa_reference_normalized,intended_order_id,idempotency_key,received_by,notes)
  values(p_business_id,v_number,p_method,v_status,p_amount,p_received_at,nullif(btrim(p_payer_name),''),
    nullif(btrim(p_payer_phone),''),nullif(btrim(p_mpesa_reference),''),v_reference,p_order_id,p_request_id,v_actor,p_notes)
  returning id into v_payment;
  insert into public.payment_events(business_id,payment_id,event_type,actor_user_id,metadata)
  values(p_business_id,v_payment,'created',v_actor,jsonb_build_object('method',p_method,'status',v_status));
  if p_method='cash' then
    v_balance:=private.owner_order_balance(p_order_id);
    if p_amount > (v_balance->>'balance_due')::bigint then
      raise exception using errcode='22023',message='Payment exceeds outstanding order balance';
    end if;
    insert into public.payment_allocations(business_id,payment_id,order_id,amount,created_by)
    values(p_business_id,v_payment,p_order_id,p_amount,v_actor);
    v_receipt:=private.next_document_number(p_business_id,'receipt');
    insert into public.receipts(business_id,receipt_number,payment_id,customer_name_snapshot,amount,issued_by)
    values(p_business_id,v_receipt,v_payment,
      (select c.display_name from public.customers c where c.business_id=p_business_id and c.id=v_order.customer_id),p_amount,v_actor);
    insert into public.payment_events(business_id,payment_id,event_type,actor_user_id)
    values(p_business_id,v_payment,'verified',v_actor);
  end if;
  v_result:=jsonb_build_object('payment_id',v_payment,'payment_number',v_number,'status',v_status,
    'allocated_amount',case when p_method='cash' then p_amount else 0 end,'receipt_number',v_receipt,
    'balance_due',(private.owner_order_balance(p_order_id)->>'balance_due')::bigint);
  perform private.finish_idempotent_request(p_business_id,'record_payment',p_request_id,v_result);
  perform private.write_audit(p_business_id,v_actor,'payment.recorded','payment',v_payment,p_request_id,
    jsonb_build_object('method',p_method,'amount',p_amount,'status',v_status));
  return v_result;
end;
$$;

create or replace function private.owner_verify_mpesa_payment(
  p_payment_id uuid,p_outcome text,p_reason text,p_request_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v_payment public.payments%rowtype; v_actor uuid; v_order public.orders%rowtype;
  v_cached jsonb; v_payload jsonb; v_balance jsonb; v_receipt text; v_result jsonb;
begin
  select * into v_payment from public.payments where id=p_payment_id;
  if not found then raise exception using errcode='P0002',message='Payment not found'; end if;
  v_actor:=private.assert_active_owner(v_payment.business_id);
  v_payload:=jsonb_build_object('payment_id',p_payment_id,'outcome',p_outcome,'reason',p_reason);
  v_cached:=private.begin_idempotent_request(v_payment.business_id,'verify_mpesa',p_request_id,v_payload);
  if v_cached is not null then return v_cached; end if;
  select * into v_payment from public.payments where business_id=v_payment.business_id and id=p_payment_id for update;
  if v_payment.method<>'mpesa_manual' or v_payment.status<>'pending_verification' then
    raise exception using errcode='22023',message='Only pending M-Pesa evidence can be verified';
  end if;
  if p_outcome not in ('verified','rejected') then raise exception using errcode='22023',message='Invalid verification outcome'; end if;
  select * into v_order from public.orders where business_id=v_payment.business_id and id=v_payment.intended_order_id for update;
  if not found then raise exception using errcode='22023',message='Original intended order no longer exists'; end if;
  if p_outcome='verified' then
    if v_order.status in ('cancelled','completed') then raise exception using errcode='22023',message='Intended order cannot receive payment'; end if;
    v_balance:=private.owner_order_balance(v_order.id);
    if v_payment.amount > (v_balance->>'balance_due')::bigint then
      raise exception using errcode='22023',message='Verified payment exceeds outstanding balance; reject and record correct evidence';
    end if;
    update public.payments set status='posted',verified_by=v_actor,verified_at=now()
    where business_id=v_payment.business_id and id=p_payment_id;
    insert into public.payment_allocations(business_id,payment_id,order_id,amount,created_by)
    values(v_payment.business_id,p_payment.id,v_order.id,v_payment.amount,v_actor);
    v_receipt:=private.next_document_number(v_payment.business_id,'receipt');
    insert into public.receipts(business_id,receipt_number,payment_id,customer_name_snapshot,amount,issued_by)
    values(v_payment.business_id,v_receipt,p_payment_id,
      (select c.display_name from public.customers c where c.business_id=v_order.business_id and c.id=v_order.customer_id),
      v_payment.amount,v_actor);
    insert into public.payment_events(business_id,payment_id,event_type,actor_user_id,reason)
    values(v_payment.business_id,p_payment_id,'verified',v_actor,p_reason);
  else
    update public.payments set status='rejected',verified_by=v_actor,verified_at=now()
    where business_id=v_payment.business_id and id=p_payment_id;
    insert into public.payment_events(business_id,payment_id,event_type,actor_user_id,reason)
    values(v_payment.business_id,p_payment_id,'rejected',v_actor,p_reason);
  end if;
  v_result:=jsonb_build_object('payment_id',p_payment_id,'status',case when p_outcome='verified' then 'posted' else 'rejected' end,
    'receipt_number',v_receipt,'balance_due',(private.owner_order_balance(v_order.id)->>'balance_due')::bigint);
  perform private.finish_idempotent_request(v_payment.business_id,'verify_mpesa',p_request_id,v_result);
  perform private.write_audit(v_payment.business_id,v_actor,'payment.mpesa_'||p_outcome,'payment',p_payment_id,p_request_id,
    jsonb_build_object('reason',p_reason));
  return v_result;
end;
$$;

create or replace function private.owner_reverse_payment_allocation(
  p_allocation_id uuid,p_amount bigint,p_reason text,p_request_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v_allocation public.payment_allocations%rowtype; v_actor uuid; v_cached jsonb;
  v_payload jsonb; v_used bigint; v_result jsonb;
begin
  select * into v_allocation from public.payment_allocations where id=p_allocation_id;
  if not found then raise exception using errcode='P0002',message='Allocation not found'; end if;
  v_actor:=private.assert_active_owner(v_allocation.business_id);
  if p_amount is null or p_amount<=0 or length(btrim(coalesce(p_reason,'')))=0 then
    raise exception using errcode='22023',message='Positive amount and reason are required';
  end if;
  v_payload:=jsonb_build_object('allocation_id',p_allocation_id,'amount',p_amount,'reason',p_reason);
  v_cached:=private.begin_idempotent_request(v_allocation.business_id,'reverse_allocation',p_request_id,v_payload);
  if v_cached is not null then return v_cached; end if;
  perform 1 from public.payments where business_id=v_allocation.business_id and id=v_allocation.payment_id for update;
  perform 1 from public.payment_allocations where business_id=v_allocation.business_id and id=p_allocation_id for update;
  select coalesce(sum(amount),0) into v_used from (
    select amount from public.allocation_reversals where business_id=v_allocation.business_id and allocation_id=p_allocation_id
    union all
    select amount from public.payment_refunds where business_id=v_allocation.business_id and allocation_id=p_allocation_id and status in ('pending','posted')
  ) x;
  if p_amount > v_allocation.amount-v_used then raise exception using errcode='22023',message='Reversal exceeds remaining allocation capacity'; end if;
  insert into public.allocation_reversals(business_id,allocation_id,amount,reason,reversed_by)
  values(v_allocation.business_id,p_allocation_id,p_amount,btrim(p_reason),v_actor);
  insert into public.payment_events(business_id,payment_id,event_type,actor_user_id,reason)
  values(v_allocation.business_id,v_allocation.payment_id,'allocation_reversed',v_actor,p_reason);
  v_result:=jsonb_build_object('allocation_id',p_allocation_id,'reversed_amount',p_amount,
    'order_balance',private.owner_order_balance(v_allocation.order_id));
  perform private.finish_idempotent_request(v_allocation.business_id,'reverse_allocation',p_request_id,v_result);
  perform private.write_audit(v_allocation.business_id,v_actor,'payment.allocation_reversed','payment_allocation',p_allocation_id,p_request_id,
    jsonb_build_object('amount',p_amount,'reason',p_reason));
  return v_result;
end;
$$;

create or replace function private.owner_record_refund(
  p_payment_id uuid,p_allocation_id uuid,p_source_bucket text,p_amount bigint,p_reason text,
  p_refund_method text,p_external_reference text,p_request_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v_payment public.payments%rowtype; v_allocation public.payment_allocations%rowtype;
  v_actor uuid; v_cached jsonb; v_payload jsonb; v_order uuid; v_used bigint; v_result jsonb; v_refund uuid;
begin
  select * into v_payment from public.payments where id=p_payment_id;
  if not found then raise exception using errcode='P0002',message='Payment not found'; end if;
  v_actor:=private.assert_active_owner(v_payment.business_id);
  if p_amount is null or p_amount<=0 or length(btrim(coalesce(p_reason,'')))=0
     or p_refund_method not in ('cash','mpesa') or p_source_bucket not in ('allocated','unallocated') then
    raise exception using errcode='22023',message='Invalid refund details';
  end if;
  v_payload:=jsonb_build_object('payment_id',p_payment_id,'allocation_id',p_allocation_id,'source_bucket',p_source_bucket,
    'amount',p_amount,'reason',p_reason,'refund_method',p_refund_method,'external_reference',p_external_reference);
  v_cached:=private.begin_idempotent_request(v_payment.business_id,'record_refund',p_request_id,v_payload);
  if v_cached is not null then return v_cached; end if;
  perform 1 from public.payments where business_id=v_payment.business_id and id=p_payment_id for update;
  if v_payment.status<>'posted' then raise exception using errcode='22023',message='Only posted payments can be refunded'; end if;
  if p_source_bucket='allocated' then
    if p_allocation_id is null then raise exception using errcode='22023',message='Allocation is required'; end if;
    select * into v_allocation from public.payment_allocations
      where business_id=v_payment.business_id and id=p_allocation_id and payment_id=p_payment_id for update;
    if not found then raise exception using errcode='22023',message='Allocation does not belong to payment'; end if;
    v_order:=v_allocation.order_id;
    select coalesce(sum(amount),0) into v_used from (
      select amount from public.allocation_reversals where business_id=v_payment.business_id and allocation_id=p_allocation_id
      union all
      select amount from public.payment_refunds where business_id=v_payment.business_id and allocation_id=p_allocation_id and status in ('pending','posted')
    ) x;
    if p_amount>v_allocation.amount-v_used then raise exception using errcode='22023',message='Refund exceeds remaining allocation capacity'; end if;
  else
    if p_allocation_id is not null then raise exception using errcode='22023',message='Unallocated refund cannot reference allocation'; end if;
    select coalesce(sum(amount),0) into v_used from (
      select a.amount * -1 as amount from public.payment_allocations a
        where a.business_id=v_payment.business_id and a.payment_id=p_payment_id
      union all
      select r.amount from public.allocation_reversals r
        join public.payment_allocations a on a.business_id=r.business_id and a.id=r.allocation_id
        where a.business_id=v_payment.business_id and a.payment_id=p_payment_id
      union all
      select f.amount from public.payment_refunds f where f.business_id=v_payment.business_id
        and f.payment_id=p_payment_id and f.source_bucket='unallocated' and f.status in ('pending','posted')
    ) x;
    if p_amount>v_payment.amount+v_used then raise exception using errcode='22023',message='Refund exceeds unallocated payment balance'; end if;
  end if;
  insert into public.payment_refunds(business_id,payment_id,order_id,allocation_id,source_bucket,amount,status,reason,
    refund_method,external_reference,created_by)
  values(v_payment.business_id,p_payment_id,v_order,p_allocation_id,p_source_bucket,p_amount,'pending',btrim(p_reason),
    p_refund_method,nullif(btrim(p_external_reference),''),v_actor)
  returning id into v_refund;
  v_result:=jsonb_build_object('refund_id',v_refund,'status','pending');
  perform private.finish_idempotent_request(v_payment.business_id,'record_refund',p_request_id,v_result);
  perform private.write_audit(v_payment.business_id,v_actor,'payment.refund_requested','payment_refund',v_refund,p_request_id,
    jsonb_build_object('amount',p_amount,'source_bucket',p_source_bucket,'reason',p_reason));
  return v_result;
end;
$$;

create or replace function private.owner_post_refund(p_refund_id uuid,p_request_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v_refund public.payment_refunds%rowtype; v_actor uuid; v_payment public.payments%rowtype;
  v_cached jsonb; v_payload jsonb; v_result jsonb; v_balance jsonb;
begin
  select * into v_refund from public.payment_refunds where id=p_refund_id;
  if not found then raise exception using errcode='P0002',message='Refund not found'; end if;
  v_actor:=private.assert_active_owner(v_refund.business_id);
  v_payload:=jsonb_build_object('refund_id',p_refund_id);
  v_cached:=private.begin_idempotent_request(v_refund.business_id,'post_refund',p_request_id,v_payload);
  if v_cached is not null then return v_cached; end if;
  select * into v_payment from public.payments where business_id=v_refund.business_id and id=v_refund.payment_id for update;
  select * into v_refund from public.payment_refunds where business_id=v_refund.business_id and id=p_refund_id for update;
  if v_refund.status<>'pending' or v_payment.status<>'posted' then
    raise exception using errcode='22023',message='Only pending refunds on posted payments can be posted';
  end if;
  update public.payment_refunds set status='posted',posted_by=v_actor,posted_at=now()
  where business_id=v_refund.business_id and id=p_refund_id;
  insert into public.payment_events(business_id,payment_id,event_type,actor_user_id,reason,metadata)
  values(v_refund.business_id,v_refund.payment_id,'refund_posted',v_actor,v_refund.reason,
    jsonb_build_object('refund_id',p_refund_id,'amount',v_refund.amount));
  if v_refund.order_id is not null then v_balance:=private.owner_order_balance(v_refund.order_id); end if;
  v_result:=jsonb_build_object('refund_id',p_refund_id,'status','posted','order_balance',v_balance);
  perform private.finish_idempotent_request(v_refund.business_id,'post_refund',p_request_id,v_result);
  perform private.write_audit(v_refund.business_id,v_actor,'payment.refund_posted','payment_refund',p_refund_id,p_request_id,
    jsonb_build_object('amount',v_refund.amount,'payment_id',v_refund.payment_id));
  return v_result;
end;
$$;

create or replace function private.owner_handover_order(
  p_order_id uuid,p_method text,p_recipient_name text,p_tracking_reference text,
  p_payment_exception_reason text,p_request_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v_order public.orders%rowtype; v_actor uuid; v_cached jsonb; v_payload jsonb; v_balance jsonb; v_delivery uuid; v_result jsonb;
begin
  select * into v_order from public.orders where id=p_order_id;
  if not found then raise exception using errcode='P0002',message='Order not found'; end if;
  v_actor:=private.assert_active_owner(v_order.business_id);
  if p_method not in ('collection','courier') or length(btrim(coalesce(p_recipient_name,'')))=0 then
    raise exception using errcode='22023',message='Handover method and recipient are required';
  end if;
  v_payload:=jsonb_build_object('order_id',p_order_id,'method',p_method,'recipient_name',p_recipient_name,
    'tracking_reference',p_tracking_reference,'payment_exception_reason',p_payment_exception_reason);
  v_cached:=private.begin_idempotent_request(v_order.business_id,'handover_order',p_request_id,v_payload);
  if v_cached is not null then return v_cached; end if;
  select * into v_order from public.orders where business_id=v_order.business_id and id=p_order_id for update;
  if v_order.status not in ('ready','completed') then raise exception using errcode='22023',message='Order must pass production and QC before handover'; end if;
  v_balance:=private.owner_order_balance(p_order_id);
  if (v_balance->>'balance_due')::bigint>0 then
    if length(btrim(coalesce(p_payment_exception_reason,'')))=0 then
      raise exception using errcode='22023',message='Full payment is required before handover';
    end if;
    insert into public.owner_approvals(business_id,approval_type,entity_type,entity_id,reason,approved_by,request_id)
    values(v_order.business_id,'payment_exception','order',p_order_id,btrim(p_payment_exception_reason),v_actor,p_request_id);
  end if;
  insert into public.deliveries(business_id,order_id,method,tracking_reference,recipient_name,handed_over_at)
  values(v_order.business_id,p_order_id,p_method,nullif(btrim(p_tracking_reference),''),btrim(p_recipient_name),now())
  returning id into v_delivery;
  update public.orders set status='completed',updated_at=now()
  where business_id=v_order.business_id and id=p_order_id;
  insert into public.order_events(business_id,order_id,event_type,from_status,to_status,actor_user_id,reason)
  values(v_order.business_id,p_order_id,'handed_over',v_order.status,'completed',v_actor,
    case when (v_balance->>'balance_due')::bigint>0 then p_payment_exception_reason else null end);
  v_result:=jsonb_build_object('order_id',p_order_id,'delivery_id',v_delivery,'status','completed','balance',v_balance);
  perform private.finish_idempotent_request(v_order.business_id,'handover_order',p_request_id,v_result);
  perform private.write_audit(v_order.business_id,v_actor,'order.handed_over','order',p_order_id,p_request_id,
    jsonb_build_object('method',p_method,'recipient_name',p_recipient_name,'payment_exception',p_payment_exception_reason is not null));
  return v_result;
end;
$$;

-- Thin PostgREST wrappers. Internal definer functions are not exposed directly by the API.
create or replace function public.owner_upsert_customer(
  p_business_id uuid,p_customer_id uuid,p_display_name text,p_business_name text,
  p_phone text,p_email text,p_notes text,p_request_id uuid
) returns jsonb language sql security invoker set search_path = '' as
$$ select private.owner_upsert_customer($1,$2,$3,$4,$5,$6,$7,$8); $$;

create or replace function public.owner_record_payment(
  p_business_id uuid,p_order_id uuid,p_method text,p_amount bigint,p_received_at timestamptz,
  p_payer_name text,p_payer_phone text,p_mpesa_reference text,p_notes text,p_request_id uuid
) returns jsonb language sql security invoker set search_path = '' as
$$ select private.owner_record_payment($1,$2,$3,$4,$5,$6,$7,$8,$9,$10); $$;

create or replace function public.owner_verify_mpesa_payment(
  p_payment_id uuid,p_outcome text,p_reason text,p_request_id uuid
) returns jsonb language sql security invoker set search_path = '' as
$$ select private.owner_verify_mpesa_payment($1,$2,$3,$4); $$;

create or replace function public.owner_reverse_payment_allocation(
  p_allocation_id uuid,p_amount bigint,p_reason text,p_request_id uuid
) returns jsonb language sql security invoker set search_path = '' as
$$ select private.owner_reverse_payment_allocation($1,$2,$3,$4); $$;

create or replace function public.owner_record_refund(
  p_payment_id uuid,p_allocation_id uuid,p_source_bucket text,p_amount bigint,p_reason text,
  p_refund_method text,p_external_reference text,p_request_id uuid
) returns jsonb language sql security invoker set search_path = '' as
$$ select private.owner_record_refund($1,$2,$3,$4,$5,$6,$7,$8); $$;

create or replace function public.owner_post_refund(p_refund_id uuid,p_request_id uuid)
returns jsonb language sql security invoker set search_path = '' as
$$ select private.owner_post_refund($1,$2); $$;

create or replace function public.owner_get_order_balance(p_order_id uuid)
returns jsonb language sql security invoker set search_path = '' as
$$ select private.owner_order_balance($1); $$;

create or replace function public.owner_handover_order(
  p_order_id uuid,p_method text,p_recipient_name text,p_tracking_reference text,
  p_payment_exception_reason text,p_request_id uuid
) returns jsonb language sql security invoker set search_path = '' as
$$ select private.owner_handover_order($1,$2,$3,$4,$5,$6); $$;

-- Private functions are not in an exposed schema. Authenticated can execute only
-- the named operations; each function validates auth.uid() and owner membership.
revoke all on all functions in schema private from public, anon, authenticated;
grant usage on schema private to authenticated;
grant execute on function private.assert_active_owner(uuid),
  private.begin_idempotent_request(uuid,text,uuid,jsonb),
  private.finish_idempotent_request(uuid,text,uuid,jsonb),
  private.next_document_number(uuid,text),
  private.write_audit(uuid,uuid,text,text,uuid,uuid,jsonb),
  private.owner_upsert_customer(uuid,uuid,text,text,text,text,text,uuid),
  private.owner_order_balance(uuid),
  private.owner_record_payment(uuid,uuid,text,bigint,timestamptz,text,text,text,text,uuid),
  private.owner_verify_mpesa_payment(uuid,text,text,uuid),
  private.owner_reverse_payment_allocation(uuid,bigint,text,uuid),
  private.owner_record_refund(uuid,uuid,text,bigint,text,text,text,uuid),
  private.owner_post_refund(uuid,uuid),
  private.owner_handover_order(uuid,text,text,text,text,uuid)
to authenticated;

revoke all on function public.owner_upsert_customer(uuid,uuid,text,text,text,text,text,uuid),
  public.owner_record_payment(uuid,uuid,text,bigint,timestamptz,text,text,text,text,uuid),
  public.owner_verify_mpesa_payment(uuid,text,text,uuid),
  public.owner_reverse_payment_allocation(uuid,bigint,text,uuid),
  public.owner_record_refund(uuid,uuid,text,bigint,text,text,text,uuid),
  public.owner_post_refund(uuid,uuid),
  public.owner_get_order_balance(uuid),
  public.owner_handover_order(uuid,text,text,text,text,uuid)
from public, anon;
grant execute on function public.owner_upsert_customer(uuid,uuid,text,text,text,text,text,uuid),
  public.owner_record_payment(uuid,uuid,text,bigint,timestamptz,text,text,text,text,uuid),
  public.owner_verify_mpesa_payment(uuid,text,text,uuid),
  public.owner_reverse_payment_allocation(uuid,bigint,text,uuid),
  public.owner_record_refund(uuid,uuid,text,bigint,text,text,text,uuid),
  public.owner_post_refund(uuid,uuid),
  public.owner_get_order_balance(uuid),
  public.owner_handover_order(uuid,text,text,text,text,uuid)
to authenticated;

commit;
