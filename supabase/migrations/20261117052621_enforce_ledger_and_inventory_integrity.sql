-- MJ Tees — ledger, stock and production integrity controls.
-- Generated filename by Supabase CLI 3.2.0. Not applied to hosted Supabase.
begin;

-- The anonymous catalogue contract is a narrow projection, not base-table access.
revoke all on public.catalogue_items, public.service_categories from anon;
drop view if exists public.public_catalogue;
create view public.public_catalogue
with (security_barrier = true)
as
select c.id, c.business_id, c.name, c.slug, c.item_type, c.description,
       c.public_starting_price, c.display_order,
       s.name as category_name, s.slug as category_slug
from public.catalogue_items c
join public.businesses b on b.id=c.business_id and b.is_active=true
left join public.service_categories s
  on s.business_id=c.business_id and s.id=c.category_id
where c.is_published=true and c.is_active=true
  and (s.id is null or s.is_active=true);
revoke all on public.public_catalogue from public, anon, authenticated;
grant select on public.public_catalogue to anon, authenticated;

-- Production methods are shared reference data, readable only by signed-in owners.
alter table public.production_methods enable row level security;
revoke all on public.production_methods from anon, authenticated;
grant select on public.production_methods to authenticated;
create policy production_methods_owner_select on public.production_methods
for select to authenticated
using (exists (
  select 1 from public.business_memberships m
  where m.user_id=(select auth.uid()) and m.role='owner' and m.status='active'
));

insert into public.production_methods(code,name) values
 ('vinyl_cut','Vinyl cutting'),
 ('sticker_cut','Sticker cutting'),
 ('sublimation','Sublimation'),
 ('screen_printing','Screen printing'),
 ('no_cut_printing','No-cut printing'),
 ('dtf_outsourced','Outsourced DTF')
on conflict (code) do nothing;

-- Pair integrity: exactly one out and one in movement with identical quantity/cost/item.
create unique index if not exists stock_transfer_one_movement_per_type
on public.stock_movements(business_id,stock_transfer_id,movement_type)
where stock_transfer_id is not null;

alter table public.stock_movements
  add constraint stock_movement_transfer_type_check
  check (
    (stock_transfer_id is null and movement_type not in ('transfer_in','transfer_out'))
    or (stock_transfer_id is not null and movement_type in ('transfer_in','transfer_out'))
  );

create or replace function private.assert_stock_transfer_pair()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare v_transfer public.stock_transfers%rowtype; v_out public.stock_movements%rowtype; v_in public.stock_movements%rowtype;
begin
  select * into v_transfer from public.stock_transfers where business_id=new.business_id and id=new.id;
  select * into v_out from public.stock_movements where business_id=new.business_id and stock_transfer_id=new.id and movement_type='transfer_out';
  select * into v_in from public.stock_movements where business_id=new.business_id and stock_transfer_id=new.id and movement_type='transfer_in';
  if v_out.id is null or v_in.id is null then
    raise exception using errcode='23514',message='A stock transfer must have exactly one outbound and one inbound movement';
  end if;
  if v_out.stock_item_id<>v_transfer.stock_item_id or v_in.stock_item_id<>v_transfer.stock_item_id
     or v_out.location_id<>v_transfer.source_location_id or v_in.location_id<>v_transfer.destination_location_id
     or v_out.quantity<>-v_transfer.quantity or v_in.quantity<>v_transfer.quantity
     or v_out.unit_cost_snapshot<>v_transfer.unit_cost_snapshot or v_in.unit_cost_snapshot<>v_transfer.unit_cost_snapshot then
    raise exception using errcode='23514',message='Stock transfer movement pair does not reconcile to transfer header';
  end if;
  return null;
end;
$$;
create constraint trigger stock_transfer_pair_deferred
after insert on public.stock_transfers
deferrable initially deferred
for each row execute function private.assert_stock_transfer_pair();

-- A production issue must be the negative stock movement it references.
create or replace function private.assert_production_issue_movement()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare v_movement public.stock_movements%rowtype;
begin
  select * into v_movement from public.stock_movements
  where business_id=new.business_id and id=new.stock_movement_id;
  if not found or v_movement.movement_type<>'issue'
     or v_movement.stock_item_id<>new.stock_item_id
     or v_movement.location_id<>new.location_id
     or v_movement.quantity<>-new.quantity_issued
     or v_movement.unit_cost_snapshot<>new.unit_cost_snapshot then
    raise exception using errcode='23514',message='Production issue must match its stock issue movement';
  end if;
  return new;
end;
$$;
create trigger production_issue_movement_guard
before insert on public.production_material_issues
for each row execute function private.assert_production_issue_movement();

-- Waste/offcut records must belong to the same job as their source issue and share
-- one issued-quantity capacity. Waste does not create another movement.
create or replace function private.assert_issue_reconciliation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare v_issue public.production_material_issues%rowtype; v_total numeric(12,3);
begin
  select * into v_issue from public.production_material_issues
  where business_id=new.business_id and id=new.issue_id for update;
  if not found or v_issue.job_id<>new.job_id then
    raise exception using errcode='23514',message='Waste/offcut must reference an issue from the same production job';
  end if;
  select
    coalesce((select sum(w.quantity) from public.production_waste w
      where w.business_id=new.business_id and w.issue_id=new.issue_id),0)
    + coalesce((select sum(o.quantity) from public.production_offcut_returns o
      where o.business_id=new.business_id and o.issue_id=new.issue_id),0)
  into v_total;
  if v_total>v_issue.quantity_issued then
    raise exception using errcode='23514',message='Waste plus reusable offcuts cannot exceed issued quantity';
  end if;
  if tg_table_name='production_offcut_returns' then
    if new.condition<>'usable' then
      raise exception using errcode='23514',message='Only usable offcuts may be returned to stock; classify damaged offcuts as waste';
    end if;
    if not exists (
      select 1 from public.stock_movements m
      where m.business_id=new.business_id and m.id=new.stock_movement_id
        and m.movement_type='return' and m.stock_item_id=v_issue.stock_item_id
        and m.location_id=new.destination_location_id and m.quantity=new.quantity
        and m.unit_cost_snapshot=v_issue.unit_cost_snapshot
    ) then
      raise exception using errcode='23514',message='Offcut return requires one matching positive stock movement';
    end if;
  end if;
  return new;
end;
$$;
create trigger production_waste_issue_guard
after insert on public.production_waste
for each row execute function private.assert_issue_reconciliation();
create trigger production_offcut_issue_guard
after insert on public.production_offcut_returns
for each row execute function private.assert_issue_reconciliation();

-- Financial ledger integrity at database boundary, including privileged server writes.
create or replace function private.guard_payment_allocation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare v_payment public.payments%rowtype; v_order public.orders%rowtype; v_allocated bigint; v_balance jsonb;
begin
  select * into v_payment from public.payments
  where business_id=new.business_id and id=new.payment_id for update;
  if not found or v_payment.status<>'posted' then
    raise exception using errcode='23514',message='Only posted payments can be allocated';
  end if;
  select * into v_order from public.orders
  where business_id=new.business_id and id=new.order_id for update;
  if not found or v_order.status in ('cancelled','completed') then
    raise exception using errcode='23514',message='Allocation order is not receivable';
  end if;
  select coalesce(sum(amount),0) into v_allocated from public.payment_allocations
  where business_id=new.business_id and payment_id=new.payment_id;
  if v_allocated+new.amount>v_payment.amount then
    raise exception using errcode='23514',message='Payment allocations exceed posted payment amount';
  end if;
  v_balance:=private.owner_order_balance(new.order_id);
  if new.amount>(v_balance->>'balance_due')::bigint then
    raise exception using errcode='23514',message='Payment allocation exceeds outstanding order balance';
  end if;
  return new;
end;
$$;
create trigger payment_allocation_guard
before insert on public.payment_allocations
for each row execute function private.guard_payment_allocation();

create or replace function private.guard_allocation_reversal()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare v_allocation public.payment_allocations%rowtype; v_used bigint;
begin
  select * into v_allocation from public.payment_allocations
  where business_id=new.business_id and id=new.allocation_id;
  if not found then raise exception using errcode='23503',message='Allocation not found'; end if;
  perform 1 from public.payments where business_id=new.business_id and id=v_allocation.payment_id for update;
  select coalesce(sum(amount),0) into v_used from (
    select amount from public.allocation_reversals where business_id=new.business_id and allocation_id=new.allocation_id
    union all
    select amount from public.payment_refunds where business_id=new.business_id and allocation_id=new.allocation_id and status in ('pending','posted')
  ) q;
  if v_used+new.amount>v_allocation.amount then
    raise exception using errcode='23514',message='Allocation reversal/refund shared capacity exceeded';
  end if;
  return new;
end;
$$;
create trigger allocation_reversal_capacity_guard
before insert on public.allocation_reversals
for each row execute function private.guard_allocation_reversal();

create or replace function private.guard_payment_refund()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare v_payment public.payments%rowtype; v_allocation public.payment_allocations%rowtype; v_used bigint; v_available bigint;
begin
  if tg_op='UPDATE' then
    if old.status<>'pending' or new.status not in ('posted','cancelled')
       or (to_jsonb(old)-'status'-'posted_by'-'posted_at')<>(to_jsonb(new)-'status'-'posted_by'-'posted_at') then
      raise exception using errcode='23514',message='Refunds are immutable except pending to posted/cancelled';
    end if;
    return new;
  end if;
  select * into v_payment from public.payments
  where business_id=new.business_id and id=new.payment_id for update;
  if not found or v_payment.status<>'posted' then
    raise exception using errcode='23514',message='Refund source payment must be posted';
  end if;
  if new.source_bucket='allocated' then
    select * into v_allocation from public.payment_allocations
    where business_id=new.business_id and id=new.allocation_id and payment_id=new.payment_id and order_id=new.order_id for update;
    if not found then raise exception using errcode='23514',message='Refund allocation must match its payment and order'; end if;
    select coalesce(sum(amount),0) into v_used from (
      select amount from public.allocation_reversals where business_id=new.business_id and allocation_id=new.allocation_id
      union all
      select amount from public.payment_refunds where business_id=new.business_id and allocation_id=new.allocation_id and status in ('pending','posted')
    ) q;
    if v_used+new.amount>v_allocation.amount then
      raise exception using errcode='23514',message='Refund/reversal shared allocation capacity exceeded';
    end if;
  else
    if new.allocation_id is not null or new.order_id is not null then
      raise exception using errcode='23514',message='Unallocated refund cannot reference an order allocation';
    end if;
    select coalesce(sum(a.amount),0) into v_used from public.payment_allocations a
      where a.business_id=new.business_id and a.payment_id=new.payment_id;
    select v_used - coalesce(sum(r.amount),0) into v_used from public.allocation_reversals r
      join public.payment_allocations a on a.business_id=r.business_id and a.id=r.allocation_id
      where a.business_id=new.business_id and a.payment_id=new.payment_id;
    select coalesce(sum(f.amount),0) into v_available from public.payment_refunds f
      where f.business_id=new.business_id and f.payment_id=new.payment_id
        and f.source_bucket='unallocated' and f.status in ('pending','posted');
    if new.amount>v_payment.amount-v_used-v_available then
      raise exception using errcode='23514',message='Unallocated refund exceeds unallocated payment balance';
    end if;
  end if;
  return new;
end;
$$;
create trigger payment_refund_capacity_guard
before insert or update on public.payment_refunds
for each row execute function private.guard_payment_refund();

-- Immutable ledger/event records. Corrections use compensating records.
create or replace function private.reject_ledger_mutation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  raise exception using errcode='55000',message='This record is append-only; create a compensating event instead';
end;
$$;

do $do$
declare t text;
begin
  foreach t in array array[
    'audit_events','payment_allocations','allocation_reversals','payment_events','receipts',
    'order_events','quotation_events','stock_movements','production_material_issues',
    'production_waste','production_offcut_returns','production_cost_entries','quality_checks'
  ] loop
    execute format('create trigger %I_immutable before update or delete on public.%I for each row execute function private.reject_ledger_mutation()',t,t);
  end loop;
end $do$;

create or replace function private.guard_payment_update()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (to_jsonb(old)-'status'-'verified_by'-'verified_at')<>(to_jsonb(new)-'status'-'verified_by'-'verified_at')
     or old.status not in ('pending_verification')
     or new.status not in ('posted','rejected')
     or new.verified_by is null or new.verified_at is null then
    raise exception using errcode='55000',message='Payment evidence is immutable; only pending verification may transition to posted or rejected';
  end if;
  return new;
end;
$$;
create trigger payment_update_guard
before update on public.payments
for each row execute function private.guard_payment_update();

-- Stable UUIDs for paired stock movements and idempotency.
create or replace function private.derived_request_uuid(p_request_id uuid,p_suffix text)
returns uuid
language sql immutable
set search_path = ''
as $$
  select (substr(md5(p_request_id::text||':'||p_suffix),1,8)||'-'||
          substr(md5(p_request_id::text||':'||p_suffix),9,4)||'-'||
          substr(md5(p_request_id::text||':'||p_suffix),13,4)||'-'||
          substr(md5(p_request_id::text||':'||p_suffix),17,4)||'-'||
          substr(md5(p_request_id::text||':'||p_suffix),21,12))::uuid;
$$;

create or replace function private.owner_adjust_stock(
  p_stock_item_id uuid,p_location_id uuid,p_quantity numeric,p_adjustment_type text,p_reason text,p_request_id uuid
) returns jsonb
language plpgsql security definer set search_path=''
as $$
declare v_item public.stock_items%rowtype; v_actor uuid; v_cached jsonb; v_payload jsonb;
  v_on_hand numeric; v_delta numeric; v_movement uuid; v_result jsonb;
begin
  select * into v_item from public.stock_items where id=p_stock_item_id;
  if not found then raise exception using errcode='P0002',message='Stock item not found'; end if;
  v_actor:=private.assert_active_owner(v_item.business_id);
  if p_quantity is null or p_quantity<=0 or p_adjustment_type is null or p_adjustment_type not in ('count_gain','count_loss','opening_balance')
     or length(btrim(coalesce(p_reason,'')))=0 then
    raise exception using errcode='22023',message='Positive quantity, valid adjustment type and reason are required';
  end if;
  v_payload:=jsonb_build_object('stock_item_id',p_stock_item_id,'location_id',p_location_id,'quantity',p_quantity,
    'adjustment_type',p_adjustment_type,'reason',p_reason);
  v_cached:=private.begin_idempotent_request(v_item.business_id,'adjust_stock',p_request_id,v_payload);
  if v_cached is not null then return v_cached; end if;
  perform pg_advisory_xact_lock(hashtextextended(v_item.business_id::text||p_stock_item_id::text||p_location_id::text,0));
  if not exists(select 1 from public.inventory_locations where business_id=v_item.business_id and id=p_location_id and is_active) then
    raise exception using errcode='22023',message='Inventory location is invalid or inactive';
  end if;
  select coalesce(sum(quantity),0) into v_on_hand from public.stock_movements
  where business_id=v_item.business_id and stock_item_id=p_stock_item_id and location_id=p_location_id;
  if p_adjustment_type='opening_balance' then
    if exists(select 1 from public.stock_movements where business_id=v_item.business_id and stock_item_id=p_stock_item_id and location_id=p_location_id) then
      raise exception using errcode='22023',message='Opening balance can only be recorded before other movements';
    end if;
    v_delta:=p_quantity;
  elsif p_adjustment_type='count_gain' then v_delta:=p_quantity;
  else v_delta:=-p_quantity;
  end if;
  if v_on_hand+v_delta<0 then raise exception using errcode='22023',message='Adjustment would make stock negative'; end if;
  insert into public.stock_movements(business_id,stock_item_id,location_id,movement_type,quantity,unit_cost_snapshot,
    source_type,source_id,reason,actor_user_id,request_id)
  values(v_item.business_id,p_stock_item_id,p_location_id,
    case when p_adjustment_type='opening_balance' then 'opening' else 'adjustment' end,
    v_delta,v_item.current_average_unit_cost,'owner_adjustment',null,btrim(p_reason),v_actor,p_request_id)
  returning id into v_movement;
  v_result:=jsonb_build_object('movement_id',v_movement,'on_hand',v_on_hand+v_delta,'quantity_delta',v_delta);
  perform private.finish_idempotent_request(v_item.business_id,'adjust_stock',p_request_id,v_result);
  perform private.write_audit(v_item.business_id,v_actor,'stock.adjusted','stock_item',p_stock_item_id,p_request_id,
    jsonb_build_object('quantity_delta',v_delta,'reason',p_reason));
  return v_result;
end;
$$;

create or replace function private.owner_transfer_stock(
  p_stock_item_id uuid,p_source_location_id uuid,p_destination_location_id uuid,
  p_quantity numeric,p_reason text,p_request_id uuid
) returns jsonb
language plpgsql security definer set search_path=''
as $$
declare v_item public.stock_items%rowtype; v_actor uuid; v_cached jsonb; v_payload jsonb;
  v_on_hand numeric; v_reserved numeric; v_transfer uuid; v_cost bigint; v_out uuid; v_in uuid; v_result jsonb;
begin
  select * into v_item from public.stock_items where id=p_stock_item_id;
  if not found then raise exception using errcode='P0002',message='Stock item not found'; end if;
  v_actor:=private.assert_active_owner(v_item.business_id);
  if p_quantity is null or p_quantity<=0 or p_source_location_id=p_destination_location_id
     or length(btrim(coalesce(p_reason,'')))=0 then
    raise exception using errcode='22023',message='Valid locations, positive quantity and reason are required';
  end if;
  v_payload:=jsonb_build_object('stock_item_id',p_stock_item_id,'source',p_source_location_id,
    'destination',p_destination_location_id,'quantity',p_quantity,'reason',p_reason);
  v_cached:=private.begin_idempotent_request(v_item.business_id,'transfer_stock',p_request_id,v_payload);
  if v_cached is not null then return v_cached; end if;
  perform pg_advisory_xact_lock(hashtextextended(v_item.business_id::text||p_stock_item_id::text||p_source_location_id::text,0));
  if not exists(select 1 from public.inventory_locations where business_id=v_item.business_id and id in (p_source_location_id,p_destination_location_id) and is_active group by business_id having count(*)=2) then
    raise exception using errcode='22023',message='Both transfer locations must be active in this business';
  end if;
  select coalesce(sum(quantity),0) into v_on_hand from public.stock_movements
    where business_id=v_item.business_id and stock_item_id=p_stock_item_id and location_id=p_source_location_id;
  select coalesce(sum(reserved_quantity-released_quantity),0) into v_reserved from public.stock_reservations
    where business_id=v_item.business_id and stock_item_id=p_stock_item_id and location_id=p_source_location_id and status='active';
  if p_quantity>v_on_hand-v_reserved then raise exception using errcode='22023',message='Transfer exceeds available unreserved stock'; end if;
  v_cost:=v_item.current_average_unit_cost;
  insert into public.stock_transfers(business_id,stock_item_id,source_location_id,destination_location_id,quantity,
    unit_cost_snapshot,request_id,actor_user_id)
  values(v_item.business_id,p_stock_item_id,p_source_location_id,p_destination_location_id,p_quantity,v_cost,p_request_id,v_actor)
  returning id into v_transfer;
  insert into public.stock_movements(business_id,stock_item_id,location_id,movement_type,quantity,unit_cost_snapshot,
    source_type,source_id,stock_transfer_id,reason,actor_user_id,request_id)
  values(v_item.business_id,p_stock_item_id,p_source_location_id,'transfer_out',-p_quantity,v_cost,
    'stock_transfer',v_transfer,v_transfer,btrim(p_reason),v_actor,private.derived_request_uuid(p_request_id,'out'))
  returning id into v_out;
  insert into public.stock_movements(business_id,stock_item_id,location_id,movement_type,quantity,unit_cost_snapshot,
    source_type,source_id,stock_transfer_id,reason,actor_user_id,request_id)
  values(v_item.business_id,p_stock_item_id,p_destination_location_id,'transfer_in',p_quantity,v_cost,
    'stock_transfer',v_transfer,v_transfer,btrim(p_reason),v_actor,private.derived_request_uuid(p_request_id,'in'))
  returning id into v_in;
  v_result:=jsonb_build_object('transfer_id',v_transfer,'out_movement_id',v_out,'in_movement_id',v_in,'quantity',p_quantity);
  perform private.finish_idempotent_request(v_item.business_id,'transfer_stock',p_request_id,v_result);
  perform private.write_audit(v_item.business_id,v_actor,'stock.transferred','stock_transfer',v_transfer,p_request_id,
    jsonb_build_object('quantity',p_quantity,'from',p_source_location_id,'to',p_destination_location_id));
  return v_result;
end;
$$;

create or replace function private.owner_start_production_job(
  p_order_item_id uuid,p_method_code text,p_plan jsonb,p_request_id uuid
) returns jsonb
language plpgsql security definer set search_path=''
as $$
declare v_item public.order_items%rowtype; v_actor uuid; v_cached jsonb; v_payload jsonb;
  v_method uuid; v_job uuid; v_result jsonb; v_due timestamptz;
begin
  select * into v_item from public.order_items where id=p_order_item_id;
  if not found then raise exception using errcode='P0002',message='Order item not found'; end if;
  v_actor:=private.assert_active_owner(v_item.business_id);
  if v_item.sale_mode<>'value_added' or v_item.customer_supplies_item is null then
    raise exception using errcode='22023',message='Only value-added order items can start a production job';
  end if;
  select id into v_method from public.production_methods where code=p_method_code and is_active;
  if v_method is null or (v_item.production_method_id is not null and v_item.production_method_id<>v_method) then
    raise exception using errcode='22023',message='Production method does not match the accepted order line';
  end if;
  v_payload:=jsonb_build_object('order_item_id',p_order_item_id,'method_code',p_method_code,'plan',coalesce(p_plan,'{}'::jsonb));
  v_cached:=private.begin_idempotent_request(v_item.business_id,'start_production_job',p_request_id,v_payload);
  if v_cached is not null then return v_cached; end if;
  perform 1 from public.order_items where business_id=v_item.business_id and id=p_order_item_id for update;
  if exists(select 1 from public.production_jobs where business_id=v_item.business_id and order_item_id=p_order_item_id and status not in ('cancelled')) then
    raise exception using errcode='23505',message='A production job already exists for this order line';
  end if;
  if jsonb_typeof(coalesce(p_plan,'{}'::jsonb))<>'object'
     or (p_plan ? 'due_at' and (p_plan->>'due_at')::timestamptz is null) then
    raise exception using errcode='22023',message='Invalid production plan';
  end if;
  v_due:=nullif(p_plan->>'due_at','')::timestamptz;
  insert into public.production_jobs(business_id,order_item_id,production_method_id,status,planned_quantity,due_at,
    estimated_cost_total,calculation_version,notes)
  values(v_item.business_id,p_order_item_id,v_method,'planned',v_item.quantity,v_due,
    null,'mj-costing-v1',nullif(p_plan->>'notes',''))
  returning id into v_job;
  update public.orders set status='in_production',updated_at=now()
    where business_id=v_item.business_id and id=v_item.order_id and status='confirmed';
  insert into public.order_events(business_id,order_id,event_type,from_status,to_status,actor_user_id,reason)
  values(v_item.business_id,v_item.order_id,'production_started','confirmed','in_production',v_actor,'Production job created');
  v_result:=jsonb_build_object('job_id',v_job,'status','planned','planned_quantity',v_item.quantity);
  perform private.finish_idempotent_request(v_item.business_id,'start_production_job',p_request_id,v_result);
  perform private.write_audit(v_item.business_id,v_actor,'production.job_started','production_job',v_job,p_request_id,
    jsonb_build_object('order_item_id',p_order_item_id,'method',p_method_code));
  return v_result;
end;
$$;

create or replace function private.owner_issue_job_material(
  p_job_id uuid,p_stock_item_id uuid,p_location_id uuid,p_quantity numeric,p_reason text,p_request_id uuid
) returns jsonb
language plpgsql security definer set search_path=''
as $$
declare v_job public.production_jobs%rowtype; v_item public.stock_items%rowtype; v_actor uuid;
  v_cached jsonb; v_payload jsonb; v_on_hand numeric; v_reserved numeric; v_own_reserved numeric;
  v_cost bigint; v_movement uuid; v_issue uuid; v_result jsonb;
begin
  select * into v_job from public.production_jobs where id=p_job_id;
  if not found then raise exception using errcode='P0002',message='Production job not found'; end if;
  v_actor:=private.assert_active_owner(v_job.business_id);
  if p_quantity is null or p_quantity<=0 or length(btrim(coalesce(p_reason,'')))=0 then
    raise exception using errcode='22023',message='Positive issue quantity and reason are required';
  end if;
  select * into v_item from public.stock_items where business_id=v_job.business_id and id=p_stock_item_id and is_active;
  if not found then raise exception using errcode='P0002',message='Active stock item not found'; end if;
  v_payload:=jsonb_build_object('job_id',p_job_id,'stock_item_id',p_stock_item_id,'location_id',p_location_id,'quantity',p_quantity,'reason',p_reason);
  v_cached:=private.begin_idempotent_request(v_job.business_id,'issue_job_material',p_request_id,v_payload);
  if v_cached is not null then return v_cached; end if;
  select * into v_job from public.production_jobs where business_id=v_job.business_id and id=p_job_id for update;
  if v_job.status not in ('planned','in_progress','rework') then raise exception using errcode='22023',message='Job is locked against new material issues'; end if;
  perform pg_advisory_xact_lock(hashtextextended(v_job.business_id::text||p_stock_item_id::text||p_location_id::text,0));
  select coalesce(sum(quantity),0) into v_on_hand from public.stock_movements
    where business_id=v_job.business_id and stock_item_id=p_stock_item_id and location_id=p_location_id;
  select coalesce(sum(reserved_quantity-released_quantity),0) into v_reserved from public.stock_reservations
    where business_id=v_job.business_id and stock_item_id=p_stock_item_id and location_id=p_location_id and status='active';
  select coalesce(sum(reserved_quantity-released_quantity),0) into v_own_reserved from public.stock_reservations
    where business_id=v_job.business_id and order_item_id=v_job.order_item_id and stock_item_id=p_stock_item_id
      and location_id=p_location_id and status='active';
  if p_quantity>v_on_hand-v_reserved+v_own_reserved then
    raise exception using errcode='22023',message='Issue exceeds on-hand stock available after other reservations';
  end if;
  if not exists(select 1 from public.inventory_locations where business_id=v_job.business_id and id=p_location_id and is_active) then
    raise exception using errcode='22023',message='Inventory location is invalid or inactive';
  end if;
  v_cost:=v_item.current_average_unit_cost;
  insert into public.stock_movements(business_id,stock_item_id,location_id,movement_type,quantity,unit_cost_snapshot,
    source_type,source_id,reason,actor_user_id,request_id)
  values(v_job.business_id,p_stock_item_id,p_location_id,'issue',-p_quantity,v_cost,'production_job',p_job_id,
    btrim(p_reason),v_actor,p_request_id)
  returning id into v_movement;
  insert into public.production_material_issues(business_id,job_id,stock_item_id,location_id,quantity_issued,
    unit_cost_snapshot,extended_cost,stock_movement_id,actor_user_id)
  values(v_job.business_id,p_job_id,p_stock_item_id,p_location_id,p_quantity,v_cost,round(p_quantity*v_cost)::bigint,v_movement,v_actor)
  returning id into v_issue;
  with reservations as (
    select r.id,r.reserved_quantity,r.released_quantity,
      r.reserved_quantity-r.released_quantity as remaining,
      coalesce(sum(r.reserved_quantity-r.released_quantity) over(order by r.created_at,r.id
        rows between unbounded preceding and 1 preceding),0) as prior_remaining
    from public.stock_reservations r
    where r.business_id=v_job.business_id and r.order_item_id=v_job.order_item_id
      and r.stock_item_id=p_stock_item_id and r.location_id=p_location_id
      and r.status='active' and r.released_quantity<r.reserved_quantity
  )
  update public.stock_reservations r set
    released_quantity=r.released_quantity+greatest(0,least(reservations.remaining,p_quantity-reservations.prior_remaining)),
    status=case when r.released_quantity+greatest(0,least(reservations.remaining,p_quantity-reservations.prior_remaining))>=r.reserved_quantity then 'consumed' else 'active' end,
    released_at=case when r.released_quantity+greatest(0,least(reservations.remaining,p_quantity-reservations.prior_remaining))>=r.reserved_quantity then now() else null end
  from reservations
  where r.id=reservations.id and greatest(0,least(reservations.remaining,p_quantity-reservations.prior_remaining))>0;
  update public.production_jobs set status='in_progress',started_at=coalesce(started_at,now())
  where business_id=v_job.business_id and id=p_job_id and status='planned';
  v_result:=jsonb_build_object('issue_id',v_issue,'stock_movement_id',v_movement,'quantity_issued',p_quantity,
    'unit_cost_snapshot',v_cost,'extended_cost',round(p_quantity*v_cost)::bigint);
  perform private.finish_idempotent_request(v_job.business_id,'issue_job_material',p_request_id,v_result);
  perform private.write_audit(v_job.business_id,v_actor,'production.material_issued','production_job',p_job_id,p_request_id,
    jsonb_build_object('stock_item_id',p_stock_item_id,'quantity',p_quantity,'unit_cost',v_cost));
  return v_result;
end;
$$;

create or replace function private.owner_record_job_waste(
  p_job_id uuid,p_issue_id uuid,p_quantity numeric,p_waste_type text,p_reason text,p_request_id uuid
) returns jsonb
language plpgsql security definer set search_path=''
as $$
declare v_job public.production_jobs%rowtype; v_issue public.production_material_issues%rowtype; v_actor uuid;
  v_cached jsonb; v_payload jsonb; v_waste uuid; v_result jsonb; v_used numeric;
begin
  select * into v_job from public.production_jobs where id=p_job_id;
  if not found then raise exception using errcode='P0002',message='Production job not found'; end if;
  v_actor:=private.assert_active_owner(v_job.business_id);
  if p_quantity is null or p_quantity<=0 or length(btrim(coalesce(p_reason,'')))=0 or length(btrim(coalesce(p_waste_type,'')))=0 then
    raise exception using errcode='22023',message='Waste quantity, type and reason are required';
  end if;
  v_payload:=jsonb_build_object('job_id',p_job_id,'issue_id',p_issue_id,'quantity',p_quantity,'waste_type',p_waste_type,'reason',p_reason);
  v_cached:=private.begin_idempotent_request(v_job.business_id,'record_job_waste',p_request_id,v_payload);
  if v_cached is not null then return v_cached; end if;
  select * into v_job from public.production_jobs where business_id=v_job.business_id and id=p_job_id for update;
  if v_job.status in ('completed','cancelled') then raise exception using errcode='22023',message='Job is closed to waste classification'; end if;
  select * into v_issue from public.production_material_issues where business_id=v_job.business_id and id=p_issue_id for update;
  if not found or v_issue.job_id<>p_job_id then raise exception using errcode='22023',message='Issue does not belong to job'; end if;
  select coalesce(sum(quantity),0) into v_used from public.production_waste where business_id=v_job.business_id and issue_id=p_issue_id;
  select v_used+coalesce(sum(quantity),0) into v_used from public.production_offcut_returns where business_id=v_job.business_id and issue_id=p_issue_id;
  if v_used+p_quantity>v_issue.quantity_issued then raise exception using errcode='22023',message='Waste exceeds remaining issued quantity'; end if;
  insert into public.production_waste(business_id,job_id,issue_id,quantity,waste_type,reason)
  values(v_job.business_id,p_job_id,p_issue_id,p_quantity,btrim(p_waste_type),btrim(p_reason)) returning id into v_waste;
  v_result:=jsonb_build_object('waste_id',v_waste,'quantity',p_quantity,'stock_deducted_again',false);
  perform private.finish_idempotent_request(v_job.business_id,'record_job_waste',p_request_id,v_result);
  perform private.write_audit(v_job.business_id,v_actor,'production.waste_recorded','production_job',p_job_id,p_request_id,
    jsonb_build_object('issue_id',p_issue_id,'quantity',p_quantity,'waste_type',p_waste_type,'reason',p_reason));
  return v_result;
end;
$$;

create or replace function private.owner_return_job_offcut(
  p_job_id uuid,p_issue_id uuid,p_location_id uuid,p_quantity numeric,p_request_id uuid
) returns jsonb
language plpgsql security definer set search_path=''
as $$
declare v_job public.production_jobs%rowtype; v_issue public.production_material_issues%rowtype; v_actor uuid;
  v_cached jsonb; v_payload jsonb; v_used numeric; v_movement uuid; v_return uuid; v_result jsonb;
begin
  select * into v_job from public.production_jobs where id=p_job_id;
  if not found then raise exception using errcode='P0002',message='Production job not found'; end if;
  v_actor:=private.assert_active_owner(v_job.business_id);
  if p_quantity is null or p_quantity<=0 then raise exception using errcode='22023',message='Positive offcut quantity is required'; end if;
  v_payload:=jsonb_build_object('job_id',p_job_id,'issue_id',p_issue_id,'location_id',p_location_id,'quantity',p_quantity);
  v_cached:=private.begin_idempotent_request(v_job.business_id,'return_job_offcut',p_request_id,v_payload);
  if v_cached is not null then return v_cached; end if;
  select * into v_job from public.production_jobs where business_id=v_job.business_id and id=p_job_id for update;
  if v_job.status in ('completed','cancelled') then raise exception using errcode='22023',message='Job is closed to offcut returns'; end if;
  select * into v_issue from public.production_material_issues where business_id=v_job.business_id and id=p_issue_id for update;
  if not found or v_issue.job_id<>p_job_id then raise exception using errcode='22023',message='Issue does not belong to job'; end if;
  select coalesce(sum(quantity),0) into v_used from public.production_waste where business_id=v_job.business_id and issue_id=p_issue_id;
  select v_used+coalesce(sum(quantity),0) into v_used from public.production_offcut_returns where business_id=v_job.business_id and issue_id=p_issue_id;
  if v_used+p_quantity>v_issue.quantity_issued then raise exception using errcode='22023',message='Offcut return exceeds remaining issued quantity'; end if;
  if not exists(select 1 from public.inventory_locations where business_id=v_job.business_id and id=p_location_id and is_active) then
    raise exception using errcode='22023',message='Destination location is invalid';
  end if;
  insert into public.stock_movements(business_id,stock_item_id,location_id,movement_type,quantity,unit_cost_snapshot,
    source_type,source_id,reason,actor_user_id,request_id)
  values(v_job.business_id,v_issue.stock_item_id,p_location_id,'return',p_quantity,v_issue.unit_cost_snapshot,
    'production_offcut',p_issue_id,'Reusable offcut returned to stock',v_actor,p_request_id)
  returning id into v_movement;
  insert into public.production_offcut_returns(business_id,job_id,issue_id,quantity,destination_location_id,
    stock_movement_id,condition)
  values(v_job.business_id,p_job_id,p_issue_id,p_quantity,p_location_id,v_movement,'usable')
  returning id into v_return;
  v_result:=jsonb_build_object('offcut_return_id',v_return,'stock_movement_id',v_movement,
    'quantity',p_quantity,'cost_credit',round(p_quantity*v_issue.unit_cost_snapshot)::bigint);
  perform private.finish_idempotent_request(v_job.business_id,'return_job_offcut',p_request_id,v_result);
  perform private.write_audit(v_job.business_id,v_actor,'production.offcut_returned','production_job',p_job_id,p_request_id,
    jsonb_build_object('issue_id',p_issue_id,'quantity',p_quantity,'cost_credit',round(p_quantity*v_issue.unit_cost_snapshot)::bigint));
  return v_result;
end;
$$;

create or replace function private.owner_add_production_cost(
  p_job_id uuid,p_cost_type text,p_description text,p_quantity numeric,p_unit text,p_unit_rate bigint,p_request_id uuid
) returns jsonb
language plpgsql security definer set search_path=''
as $$
declare v_job public.production_jobs%rowtype; v_actor uuid; v_cached jsonb; v_payload jsonb; v_cost uuid; v_amount bigint; v_result jsonb;
begin
  select * into v_job from public.production_jobs where id=p_job_id;
  if not found then raise exception using errcode='P0002',message='Production job not found'; end if;
  v_actor:=private.assert_active_owner(v_job.business_id);
  if v_job.status not in ('planned','in_progress','rework') or p_cost_type not in ('labour','machine','setup','outsourced','other')
    or length(btrim(coalesce(p_description,'')))=0 or p_quantity is null or p_quantity<=0 or p_unit_rate is null or p_unit_rate<0
    or length(btrim(coalesce(p_unit,'')))=0 then
    raise exception using errcode='22023',message='Invalid cost entry or job is locked';
  end if;
  v_payload:=jsonb_build_object('job_id',p_job_id,'cost_type',p_cost_type,'description',p_description,'quantity',p_quantity,'unit',p_unit,'unit_rate',p_unit_rate);
  v_cached:=private.begin_idempotent_request(v_job.business_id,'add_production_cost',p_request_id,v_payload);
  if v_cached is not null then return v_cached; end if;
  select * into v_job from public.production_jobs where business_id=v_job.business_id and id=p_job_id for update;
  if v_job.status not in ('planned','in_progress','rework') then raise exception using errcode='22023',message='Job is locked against additional costs'; end if;
  v_amount:=round(p_quantity*p_unit_rate)::bigint;
  insert into public.production_cost_entries(business_id,job_id,cost_type,description,quantity,unit,unit_rate,amount,actor_user_id)
  values(v_job.business_id,p_job_id,p_cost_type,btrim(p_description),p_quantity,btrim(p_unit),p_unit_rate,v_amount,v_actor)
  returning id into v_cost;
  v_result:=jsonb_build_object('cost_entry_id',v_cost,'amount',v_amount);
  perform private.finish_idempotent_request(v_job.business_id,'add_production_cost',p_request_id,v_result);
  perform private.write_audit(v_job.business_id,v_actor,'production.cost_added','production_job',p_job_id,p_request_id,
    jsonb_build_object('cost_entry_id',v_cost,'amount',v_amount,'cost_type',p_cost_type));
  return v_result;
end;
$$;

create or replace function private.owner_record_quality_check(
  p_job_id uuid,p_result text,p_inspection_mode text,p_inspector_user_id uuid,p_notes text,p_request_id uuid
) returns jsonb
language plpgsql security definer set search_path=''
as $$
declare v_job public.production_jobs%rowtype; v_actor uuid; v_cached jsonb; v_payload jsonb; v_check uuid; v_result jsonb;
begin
  select * into v_job from public.production_jobs where id=p_job_id;
  if not found then raise exception using errcode='P0002',message='Production job not found'; end if;
  v_actor:=private.assert_active_owner(v_job.business_id);
  if p_result not in ('pass','fail') or p_inspection_mode not in ('self','second_person') then
    raise exception using errcode='22023',message='Invalid quality check result or inspection mode';
  end if;
  if p_inspection_mode='self' and p_inspector_user_id is distinct from v_actor then
    raise exception using errcode='22023',message='Self inspection must identify the signed-in owner';
  end if;
  if p_inspection_mode='second_person' and (p_inspector_user_id is null or p_inspector_user_id=v_actor
      or not exists(select 1 from auth.users where id=p_inspector_user_id)) then
    raise exception using errcode='22023',message='Second-person inspection requires a different registered inspector';
  end if;
  v_payload:=jsonb_build_object('job_id',p_job_id,'result',p_result,'inspection_mode',p_inspection_mode,
    'inspector_user_id',p_inspector_user_id,'notes',p_notes);
  v_cached:=private.begin_idempotent_request(v_job.business_id,'record_quality_check',p_request_id,v_payload);
  if v_cached is not null then return v_cached; end if;
  select * into v_job from public.production_jobs where business_id=v_job.business_id and id=p_job_id for update;
  if v_job.status in ('completed','cancelled') then raise exception using errcode='22023',message='Job is closed to new quality checks'; end if;
  insert into public.quality_checks(business_id,job_id,result,inspection_mode,inspector_user_id,checked_at,notes)
  values(v_job.business_id,p_job_id,p_result,p_inspection_mode,p_inspector_user_id,clock_timestamp(),p_notes)
  returning id into v_check;
  update public.production_jobs set status=case when p_result='pass' then 'quality_check' else 'rework' end
  where business_id=v_job.business_id and id=p_job_id;
  v_result:=jsonb_build_object('quality_check_id',v_check,'result',p_result,'inspection_mode',p_inspection_mode);
  perform private.finish_idempotent_request(v_job.business_id,'record_quality_check',p_request_id,v_result);
  perform private.write_audit(v_job.business_id,v_actor,'production.quality_checked','production_job',p_job_id,p_request_id,
    jsonb_build_object('result',p_result,'inspection_mode',p_inspection_mode,'inspector_user_id',p_inspector_user_id));
  return v_result;
end;
$$;

create or replace function private.owner_complete_production_job(p_job_id uuid,p_request_id uuid)
returns jsonb
language plpgsql security definer set search_path=''
as $$
declare v_job public.production_jobs%rowtype; v_actor uuid; v_cached jsonb; v_payload jsonb;
  v_latest text; v_cost bigint; v_result jsonb; v_order_id uuid; v_item_id uuid; v_qty numeric;
begin
  select * into v_job from public.production_jobs where id=p_job_id;
  if not found then raise exception using errcode='P0002',message='Production job not found'; end if;
  v_actor:=private.assert_active_owner(v_job.business_id);
  v_payload:=jsonb_build_object('job_id',p_job_id);
  v_cached:=private.begin_idempotent_request(v_job.business_id,'complete_production_job',p_request_id,v_payload);
  if v_cached is not null then return v_cached; end if;
  select * into v_job from public.production_jobs where business_id=v_job.business_id and id=p_job_id for update;
  if v_job.status not in ('quality_check','in_progress','rework') then
    raise exception using errcode='22023',message='Job must be in production or quality check before completion';
  end if;
  select q.result into v_latest from public.quality_checks q
  where q.business_id=v_job.business_id and q.job_id=p_job_id
  order by q.checked_at desc,q.id desc limit 1;
  if v_latest is distinct from 'pass' then raise exception using errcode='22023',message='A latest passing quality check is required'; end if;
  if exists(
    select 1 from public.quality_checks q
    where q.business_id=v_job.business_id and q.job_id=p_job_id and q.result='fail'
      and not exists(select 1 from public.rework_events r where r.business_id=q.business_id
        and r.quality_check_id=q.id and r.closed_at is not null)
  ) then raise exception using errcode='22023',message='Every failed quality check requires a closed rework event'; end if;
  select coalesce(sum(i.extended_cost),0)
    - coalesce((select sum(round(o.quantity*i2.unit_cost_snapshot)::bigint)
      from public.production_offcut_returns o
      join public.production_material_issues i2 on i2.business_id=o.business_id and i2.id=o.issue_id
      where o.business_id=v_job.business_id and o.job_id=p_job_id),0)
    + coalesce((select sum(c.amount) from public.production_cost_entries c
      where c.business_id=v_job.business_id and c.job_id=p_job_id),0)
  into v_cost
  from public.production_material_issues i where i.business_id=v_job.business_id and i.job_id=p_job_id;
  if v_cost<0 then raise exception using errcode='23514',message='Calculated job cost cannot be negative'; end if;
  update public.production_jobs set status='completed',completed_at=now(),actual_cost_total=v_cost
  where business_id=v_job.business_id and id=p_job_id;
  select oi.order_id,oi.id,oi.quantity into v_order_id,v_item_id,v_qty
  from public.order_items oi where oi.business_id=v_job.business_id and oi.id=v_job.order_item_id;
  update public.order_items set actual_total_cost=v_cost,actual_unit_cost=case when v_qty>0 then round(v_cost/v_qty)::bigint else 0 end
  where business_id=v_job.business_id and id=v_item_id;
  if exists (
    select 1 from public.order_items oi
    where oi.business_id=v_job.business_id and oi.order_id=v_order_id
      and oi.sale_mode='value_added' and oi.production_method_id is not null
      and not exists (select 1 from public.production_jobs pj where pj.business_id=oi.business_id and pj.order_item_id=oi.id and pj.status='completed')
  ) then raise exception using errcode='22023',message='Every value-added production line must have a completed job'; end if;
  if not exists(
    select 1 from public.production_jobs j
    where j.business_id=v_job.business_id and j.order_item_id in (
      select oi.id from public.order_items oi where oi.business_id=v_job.business_id and oi.order_id=v_order_id
    ) and j.status<>'completed'
  ) and exists(select 1 from public.orders where business_id=v_job.business_id and id=v_order_id and status='in_production') then
    update public.orders set status='ready',updated_at=now() where business_id=v_job.business_id and id=v_order_id;
    insert into public.order_events(business_id,order_id,event_type,from_status,to_status,actor_user_id,reason)
    values(v_job.business_id,v_order_id,'production_ready','in_production','ready',v_actor,'All production jobs completed and passed QC');
  end if;
  v_result:=jsonb_build_object('job_id',p_job_id,'status','completed','actual_cost_total',v_cost,'order_id',v_order_id);
  perform private.finish_idempotent_request(v_job.business_id,'complete_production_job',p_request_id,v_result);
  perform private.write_audit(v_job.business_id,v_actor,'production.job_completed','production_job',p_job_id,p_request_id,
    jsonb_build_object('actual_cost_total',v_cost,'order_id',v_order_id));
  return v_result;
end;
$$;

create or replace function private.owner_open_rework_event(
  p_job_id uuid,p_quality_check_id uuid,p_reason text,p_request_id uuid
) returns jsonb
language plpgsql security definer set search_path=''
as $$
declare v_job public.production_jobs%rowtype; v_actor uuid; v_check public.quality_checks%rowtype;
  v_cached jsonb; v_payload jsonb; v_event uuid; v_result jsonb;
begin
  select * into v_job from public.production_jobs where id=p_job_id;
  if not found then raise exception using errcode='P0002',message='Production job not found'; end if;
  v_actor:=private.assert_active_owner(v_job.business_id);
  if length(btrim(coalesce(p_reason,'')))=0 then raise exception using errcode='22023',message='Rework reason is required'; end if;
  v_payload:=jsonb_build_object('job_id',p_job_id,'quality_check_id',p_quality_check_id,'reason',p_reason);
  v_cached:=private.begin_idempotent_request(v_job.business_id,'open_rework',p_request_id,v_payload);
  if v_cached is not null then return v_cached; end if;
  select * into v_job from public.production_jobs where business_id=v_job.business_id and id=p_job_id for update;
  if v_job.status not in ('rework','quality_check','in_progress') then raise exception using errcode='22023',message='Job is not eligible for rework'; end if;
  select * into v_check from public.quality_checks where business_id=v_job.business_id and id=p_quality_check_id;
  if not found or v_check.job_id<>p_job_id or v_check.result<>'fail' then
    raise exception using errcode='22023',message='Rework must reference a failed quality check for this job';
  end if;
  if exists(select 1 from public.rework_events where business_id=v_job.business_id and quality_check_id=p_quality_check_id and closed_at is null) then
    raise exception using errcode='23505',message='An open rework event already exists for this failed check';
  end if;
  insert into public.rework_events(business_id,job_id,quality_check_id,reason)
  values(v_job.business_id,p_job_id,p_quality_check_id,btrim(p_reason))
  returning id into v_event;
  update public.production_jobs set status='rework' where business_id=v_job.business_id and id=p_job_id;
  v_result:=jsonb_build_object('rework_event_id',v_event,'status','open');
  perform private.finish_idempotent_request(v_job.business_id,'open_rework',p_request_id,v_result);
  perform private.write_audit(v_job.business_id,v_actor,'production.rework_opened','rework_event',v_event,p_request_id,
    jsonb_build_object('job_id',p_job_id,'quality_check_id',p_quality_check_id,'reason',p_reason));
  return v_result;
end;
$$;

create or replace function private.owner_close_rework_event(
  p_rework_event_id uuid,p_notes text,p_request_id uuid
) returns jsonb
language plpgsql security definer set search_path=''
as $$
declare v_rework public.rework_events%rowtype; v_actor uuid; v_job public.production_jobs%rowtype;
  v_cached jsonb; v_payload jsonb; v_result jsonb;
begin
  select * into v_rework from public.rework_events where id=p_rework_event_id;
  if not found then raise exception using errcode='P0002',message='Rework event not found'; end if;
  v_actor:=private.assert_active_owner(v_rework.business_id);
  v_payload:=jsonb_build_object('rework_event_id',p_rework_event_id,'notes',p_notes);
  v_cached:=private.begin_idempotent_request(v_rework.business_id,'close_rework',p_request_id,v_payload);
  if v_cached is not null then return v_cached; end if;
  select * into v_job from public.production_jobs where business_id=v_rework.business_id and id=v_rework.job_id for update;
  select * into v_rework from public.rework_events where business_id=v_rework.business_id and id=p_rework_event_id for update;
  if v_rework.closed_at is not null or v_job.status='completed' then
    raise exception using errcode='22023',message='Rework event is already closed or job is completed';
  end if;
  update public.rework_events set closed_at=now(),notes=p_notes
  where business_id=v_rework.business_id and id=p_rework_event_id;
  v_result:=jsonb_build_object('rework_event_id',p_rework_event_id,'status','closed');
  perform private.finish_idempotent_request(v_rework.business_id,'close_rework',p_request_id,v_result);
  perform private.write_audit(v_rework.business_id,v_actor,'production.rework_closed','rework_event',p_rework_event_id,p_request_id,
    jsonb_build_object('job_id',v_rework.job_id,'notes',p_notes));
  return v_result;
end;
$$;

-- Public wrappers are SECURITY INVOKER; all writes happen inside private definer functions.
create or replace function public.owner_adjust_stock(uuid,uuid,numeric,text,text,uuid)
returns jsonb language sql security invoker set search_path='' as $$ select private.owner_adjust_stock($1,$2,$3,$4,$5,$6); $$;
create or replace function public.owner_transfer_stock(uuid,uuid,uuid,numeric,text,uuid)
returns jsonb language sql security invoker set search_path='' as $$ select private.owner_transfer_stock($1,$2,$3,$4,$5,$6); $$;
create or replace function public.owner_start_production_job(uuid,text,jsonb,uuid)
returns jsonb language sql security invoker set search_path='' as $$ select private.owner_start_production_job($1,$2,$3,$4); $$;
create or replace function public.owner_issue_job_material(uuid,uuid,uuid,numeric,text,uuid)
returns jsonb language sql security invoker set search_path='' as $$ select private.owner_issue_job_material($1,$2,$3,$4,$5,$6); $$;
create or replace function public.owner_record_job_waste(uuid,uuid,numeric,text,text,uuid)
returns jsonb language sql security invoker set search_path='' as $$ select private.owner_record_job_waste($1,$2,$3,$4,$5,$6); $$;
create or replace function public.owner_return_job_offcut(uuid,uuid,uuid,numeric,uuid)
returns jsonb language sql security invoker set search_path='' as $$ select private.owner_return_job_offcut($1,$2,$3,$4,$5); $$;
create or replace function public.owner_add_production_cost(uuid,text,text,numeric,text,bigint,uuid)
returns jsonb language sql security invoker set search_path='' as $$ select private.owner_add_production_cost($1,$2,$3,$4,$5,$6,$7); $$;
create or replace function public.owner_record_quality_check(uuid,text,text,uuid,text,uuid)
returns jsonb language sql security invoker set search_path='' as $$ select private.owner_record_quality_check($1,$2,$3,$4,$5,$6); $$;
create or replace function public.owner_complete_production_job(uuid,uuid)
returns jsonb language sql security invoker set search_path='' as $$ select private.owner_complete_production_job($1,$2); $$;
create or replace function public.owner_open_rework_event(uuid,uuid,text,uuid)
returns jsonb language sql security invoker set search_path='' as $$ select private.owner_open_rework_event($1,$2,$3,$4); $$;
create or replace function public.owner_close_rework_event(uuid,text,uuid)
returns jsonb language sql security invoker set search_path='' as $$ select private.owner_close_rework_event($1,$2,$3); $$;


revoke all on all functions in schema private from public,anon,authenticated;
grant usage on schema private to authenticated;
grant execute on function private.is_active_owner(uuid),
 private.owner_adjust_stock(uuid,uuid,numeric,text,text,uuid),
 private.owner_transfer_stock(uuid,uuid,uuid,numeric,text,uuid),
 private.owner_start_production_job(uuid,text,jsonb,uuid),
 private.owner_issue_job_material(uuid,uuid,uuid,numeric,text,uuid),
 private.owner_record_job_waste(uuid,uuid,numeric,text,text,uuid),
 private.owner_return_job_offcut(uuid,uuid,uuid,numeric,uuid),
 private.owner_add_production_cost(uuid,text,text,numeric,text,bigint,uuid),
 private.owner_record_quality_check(uuid,text,text,uuid,text,uuid),
 private.owner_complete_production_job(uuid,uuid),
 private.owner_open_rework_event(uuid,uuid,text,uuid),
 private.owner_close_rework_event(uuid,text,uuid),
 private.owner_upsert_customer(uuid,uuid,text,text,text,text,text,uuid),
 private.owner_order_balance(uuid),
 private.owner_record_payment(uuid,uuid,text,bigint,timestamptz,text,text,text,text,uuid),
 private.owner_verify_mpesa_payment(uuid,text,text,uuid),
 private.owner_reverse_payment_allocation(uuid,bigint,text,uuid),
 private.owner_record_refund(uuid,uuid,text,bigint,text,text,text,uuid),
 private.owner_post_refund(uuid,uuid),
 private.owner_handover_order(uuid,text,text,text,text,uuid)
to authenticated;

revoke all on function public.owner_adjust_stock(uuid,uuid,numeric,text,text,uuid),
 public.owner_transfer_stock(uuid,uuid,uuid,numeric,text,uuid),
 public.owner_start_production_job(uuid,text,jsonb,uuid),
 public.owner_issue_job_material(uuid,uuid,uuid,numeric,text,uuid),
 public.owner_record_job_waste(uuid,uuid,numeric,text,text,uuid),
 public.owner_return_job_offcut(uuid,uuid,uuid,numeric,uuid),
 public.owner_add_production_cost(uuid,text,text,numeric,text,bigint,uuid),
 public.owner_record_quality_check(uuid,text,text,uuid,text,uuid),
 public.owner_complete_production_job(uuid,uuid),
 public.owner_open_rework_event(uuid,uuid,text,uuid),
 public.owner_close_rework_event(uuid,text,uuid)
from public,anon;
grant execute on function public.owner_adjust_stock(uuid,uuid,numeric,text,text,uuid),
 public.owner_transfer_stock(uuid,uuid,uuid,numeric,text,uuid),
 public.owner_start_production_job(uuid,text,jsonb,uuid),
 public.owner_issue_job_material(uuid,uuid,uuid,numeric,text,uuid),
 public.owner_record_job_waste(uuid,uuid,numeric,text,text,uuid),
 public.owner_return_job_offcut(uuid,uuid,uuid,numeric,uuid),
 public.owner_add_production_cost(uuid,text,text,numeric,text,bigint,uuid),
 public.owner_record_quality_check(uuid,text,text,uuid,text,uuid),
 public.owner_complete_production_job(uuid,uuid),
 public.owner_open_rework_event(uuid,uuid,text,uuid),
 public.owner_close_rework_event(uuid,text,uuid)
to authenticated;

commit;
