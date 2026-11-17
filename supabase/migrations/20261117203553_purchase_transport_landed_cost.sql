-- Allocate purchase-order transport as landed inventory cost while preserving supplier prices.
alter table public.purchase_orders
  add column if not exists transport_cost bigint not null default 0 check (transport_cost >= 0);
alter table public.purchase_order_items
  add column if not exists transport_cost_allocated bigint not null default 0 check (transport_cost_allocated >= 0);
alter table public.goods_receipt_items
  add column if not exists transport_cost_allocated bigint not null default 0 check (transport_cost_allocated >= 0),
  add column if not exists landed_unit_cost numeric(18,4) not null default 0 check (landed_unit_cost >= 0);

create or replace function private.capture_purchase_transport_cost()
returns trigger language plpgsql security definer set search_path=''
as $$
begin
  new.transport_cost := coalesce(substring(coalesce(new.notes,'') from '(?m)^Transport cost \\(KES\\): ([0-9]+)$')::bigint,new.transport_cost,0);
  return new;
end; $$;
drop trigger if exists purchase_orders_capture_transport_cost on public.purchase_orders;
create trigger purchase_orders_capture_transport_cost before insert or update of notes on public.purchase_orders
for each row execute function private.capture_purchase_transport_cost();

create or replace function private.allocate_purchase_line_transport()
returns trigger language plpgsql security definer set search_path=''
as $$
declare v_total bigint; v_transport bigint;
begin
  select coalesce(sum(poi.line_total),0),max(po.transport_cost) into v_total,v_transport
  from public.purchase_order_items poi join public.purchase_orders po on po.id=poi.purchase_order_id and po.business_id=poi.business_id
  where poi.business_id=new.business_id and poi.purchase_order_id=new.purchase_order_id;
  with ranked as (
    select id,line_total,row_number() over(order by created_at,id) rn,count(*) over() cnt
    from public.purchase_order_items where business_id=new.business_id and purchase_order_id=new.purchase_order_id
  ), shares as (
    select id,case when rn=cnt then v_transport-coalesce(sum(case when v_total>0 then floor(v_transport*line_total::numeric/v_total)::bigint else 0 end) over(order by rn rows between unbounded preceding and 1 preceding),0)
      when v_total>0 then floor(v_transport*line_total::numeric/v_total)::bigint else 0 end share from ranked
  )
  update public.purchase_order_items poi set transport_cost_allocated=shares.share
  from shares where poi.id=shares.id and poi.business_id=new.business_id;
  return new;
end; $$;
drop trigger if exists purchase_order_items_allocate_transport on public.purchase_order_items;
create trigger purchase_order_items_allocate_transport after insert on public.purchase_order_items
for each row execute function private.allocate_purchase_line_transport();

create or replace function private.allocate_receipt_transport_before()
returns trigger language plpgsql security definer set search_path=''
as $$
declare v_ordered numeric; v_line_transport bigint; v_prior_accepted numeric; v_prior_transport bigint; v_target bigint;
begin
  select ordered_quantity,transport_cost_allocated into v_ordered,v_line_transport
  from public.purchase_order_items where business_id=new.business_id and id=new.purchase_order_item_id;
  select coalesce(sum(accepted_quantity),0),coalesce(sum(transport_cost_allocated),0)
  into v_prior_accepted,v_prior_transport from public.goods_receipt_items
  where business_id=new.business_id and purchase_order_item_id=new.purchase_order_item_id;
  if new.accepted_quantity>0 then
    v_target:=round(v_line_transport*(v_prior_accepted+new.accepted_quantity)/nullif(v_ordered,0))::bigint;
    new.transport_cost_allocated:=greatest(0,v_target-v_prior_transport);
    new.landed_unit_cost:=new.actual_unit_cost+new.transport_cost_allocated::numeric/new.accepted_quantity;
  else
    new.transport_cost_allocated:=0; new.landed_unit_cost:=new.actual_unit_cost;
  end if;
  return new;
end; $$;

create or replace function private.apply_receipt_transport_to_inventory()
returns trigger language plpgsql security definer set search_path=''
as $$
declare v_movement public.stock_movements%rowtype; v_factor numeric; v_base_qty numeric; v_new_base_cost bigint; v_on_hand numeric;
begin
  if new.accepted_quantity<=0 or new.stock_movement_id is null then return new; end if;
  select * into v_movement from public.stock_movements where business_id=new.business_id and id=new.stock_movement_id for update;
  select purchase_to_base_factor into v_factor from public.purchase_order_items where business_id=new.business_id and id=new.purchase_order_item_id;
  v_base_qty:=new.accepted_quantity*v_factor;
  v_new_base_cost:=round(new.landed_unit_cost/nullif(v_factor,0))::bigint;
  select coalesce(sum(quantity),0) into v_on_hand from public.stock_movements where business_id=new.business_id and stock_item_id=new.stock_item_id;
  update public.stock_movements set unit_cost_snapshot=v_new_base_cost where business_id=new.business_id and id=new.stock_movement_id;
  if v_on_hand>0 then
    update public.stock_items set current_average_unit_cost=greatest(0,round(
      (current_average_unit_cost::numeric*v_on_hand+v_base_qty*(v_new_base_cost-v_movement.unit_cost_snapshot))/v_on_hand
    ))::bigint,updated_at=now()
    where business_id=new.business_id and id=new.stock_item_id;
  end if;
  return new;
end; $$;

drop trigger if exists goods_receipt_items_transport_before on public.goods_receipt_items;
create trigger goods_receipt_items_transport_before before insert on public.goods_receipt_items
for each row execute function private.allocate_receipt_transport_before();
drop trigger if exists goods_receipt_items_transport_after on public.goods_receipt_items;
create trigger goods_receipt_items_transport_after after insert on public.goods_receipt_items
for each row execute function private.apply_receipt_transport_to_inventory();

-- Backfill the transport already entered in purchase-order notes, including existing drafts.
update public.purchase_orders set transport_cost=coalesce(
  substring(coalesce(notes,'') from '(?m)^Transport cost \\(KES\\): ([0-9]+)$')::bigint,0
) where transport_cost=0 and notes ~ '(?m)^Transport cost \\(KES\\): [0-9]+$';

with totals as (
  select poi.purchase_order_id,poi.business_id,sum(poi.line_total)::numeric subtotal,max(po.transport_cost)::bigint transport
  from public.purchase_order_items poi join public.purchase_orders po on po.business_id=poi.business_id and po.id=poi.purchase_order_id
  group by poi.purchase_order_id,poi.business_id
), ranked as (
  select poi.id,poi.business_id,poi.purchase_order_id,poi.line_total,t.transport,t.subtotal,
    row_number() over(partition by poi.business_id,poi.purchase_order_id order by poi.created_at,poi.id) rn,
    count(*) over(partition by poi.business_id,poi.purchase_order_id) cnt
  from public.purchase_order_items poi join totals t on t.business_id=poi.business_id and t.purchase_order_id=poi.purchase_order_id
), shares as (
  select id,business_id,case when rn=cnt then transport-coalesce(sum(
    case when subtotal>0 then floor(transport*line_total::numeric/subtotal)::bigint else 0 end
  ) over(partition by business_id,purchase_order_id order by rn rows between unbounded preceding and 1 preceding),0)
  when subtotal>0 then floor(transport*line_total::numeric/subtotal)::bigint else 0 end allocated
  from ranked
)
update public.purchase_order_items poi set transport_cost_allocated=shares.allocated
from shares where poi.id=shares.id and poi.business_id=shares.business_id;
