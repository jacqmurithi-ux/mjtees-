-- Restore the Production material workflow on installations where the original
-- operational-workflows migration was not applied. Idempotent for clean replays.
alter table public.production_jobs
  add column if not exists actual_direct_cost numeric(14,2) not null default 0
  check (actual_direct_cost >= 0);

create unique index if not exists production_jobs_business_id_id_uidx
  on public.production_jobs(business_id,id);
create unique index if not exists stock_items_business_id_id_uidx
  on public.stock_items(business_id,id);

create table if not exists public.production_job_materials (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  job_id uuid not null,
  stock_item_id uuid not null,
  planned_quantity numeric(14,3) not null check (planned_quantity > 0),
  issued_quantity numeric(14,3) not null default 0
    check (issued_quantity >= 0 and issued_quantity <= planned_quantity),
  created_at timestamptz not null default now()
);

create index if not exists production_job_materials_business_job_idx
  on public.production_job_materials(business_id,job_id);
create index if not exists production_job_materials_business_stock_idx
  on public.production_job_materials(business_id,stock_item_id);

do $migration$
begin
  if not exists (select 1 from pg_constraint where conrelid='public.production_job_materials'::regclass and conname='production_job_materials_business_job_fkey') then
    alter table public.production_job_materials
      add constraint production_job_materials_business_job_fkey
      foreign key (business_id,job_id)
      references public.production_jobs(business_id,id) on delete cascade;
  end if;
  if not exists (select 1 from pg_constraint where conrelid='public.production_job_materials'::regclass and conname='production_job_materials_business_stock_fkey') then
    alter table public.production_job_materials
      add constraint production_job_materials_business_stock_fkey
      foreign key (business_id,stock_item_id)
      references public.stock_items(business_id,id);
  end if;
end
$migration$;

alter table public.production_job_materials enable row level security;
drop policy if exists production_job_materials_owner_insert on public.production_job_materials;
drop policy if exists production_job_materials_owner_update on public.production_job_materials;
drop policy if exists production_job_materials_owner_read on public.production_job_materials;
create policy production_job_materials_owner_read
  on public.production_job_materials for select to authenticated
  using (exists (
    select 1 from public.business_memberships bm
    where bm.business_id=production_job_materials.business_id
      and bm.user_id=(select auth.uid()) and bm.role='owner'
  ));
revoke all on public.production_job_materials from anon,authenticated;
grant select on public.production_job_materials to authenticated;

-- This helper is the only path that changes stock quantities and appends a
-- stock_movements ledger row. Callers below run with an authenticated owner.
create or replace function private.apply_stock_movement(
  p_business_id uuid,
  p_stock_item_id uuid,
  p_quantity numeric,
  p_unit_cost numeric,
  p_movement_type text
) returns void
language plpgsql
security definer
set search_path=public,pg_temp
as $function$
declare
  v_stock public.stock_items%rowtype;
  v_new_quantity numeric(14,3);
  v_new_cost numeric(14,2);
begin
  if auth.uid() is null or not exists (
    select 1 from public.business_memberships
    where business_id=p_business_id and user_id=auth.uid() and role='owner'
  ) then
    raise exception 'Owner authorization required';
  end if;
  if p_quantity is null or p_quantity=0 or p_unit_cost is null or p_unit_cost<0
     or p_movement_type not in ('opening','purchase','job_issue','transfer_in','transfer_out','adjustment','offcut_return') then
    raise exception 'Invalid stock movement';
  end if;

  select * into v_stock
  from public.stock_items
  where id=p_stock_item_id and business_id=p_business_id
  for update;
  if not found then raise exception 'Stock item not found'; end if;

  v_new_quantity:=v_stock.quantity_on_hand+p_quantity;
  if v_new_quantity<0 then raise exception 'Insufficient stock'; end if;

  v_new_cost:=v_stock.average_unit_cost;
  if p_quantity>0 then
    v_new_cost:=case
      when v_new_quantity>0 then
        ((v_stock.quantity_on_hand*v_stock.average_unit_cost)+(p_quantity*p_unit_cost))/v_new_quantity
      else p_unit_cost
    end;
  end if;

  update public.stock_items
    set quantity_on_hand=v_new_quantity,average_unit_cost=v_new_cost
    where id=v_stock.id and business_id=p_business_id;

  insert into public.stock_movements(
    business_id,stock_item_id,movement_type,quantity,unit_cost,created_by
  ) values (
    p_business_id,p_stock_item_id,p_movement_type,p_quantity,p_unit_cost,auth.uid()
  );
end
$function$;

revoke all on function private.apply_stock_movement(uuid,uuid,numeric,numeric,text) from public,anon,authenticated;

-- These owner RPCs must execute with the trusted database role because the
-- stock movement helper is deliberately not directly callable by browser clients.
create or replace function public.owner_create_stock_item(
  p_location_code text,
  p_item_name text,
  p_category text,
  p_unit text default 'piece',
  p_opening_quantity numeric default 0,
  p_reorder_level numeric default 0,
  p_unit_cost numeric default 0,
  p_sku text default null
) returns uuid
language plpgsql
security definer
set search_path=public,private,pg_temp
as $function$
declare
  v_business_id uuid;
  v_location_id uuid;
  v_stock_item_id uuid;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  select business_id into v_business_id
  from public.business_memberships
  where user_id=auth.uid() and role='owner'
  order by created_at
  limit 1;
  if v_business_id is null then raise exception 'Owner workspace required'; end if;
  if p_location_code not in ('shop_1','shop_2')
     or length(btrim(coalesce(p_item_name,'')))=0
     or length(btrim(coalesce(p_category,'')))=0
     or p_opening_quantity is null or p_opening_quantity<0
     or p_reorder_level is null or p_reorder_level<0
     or p_unit_cost is null or p_unit_cost<0 then
    raise exception 'Invalid stock details';
  end if;

  select id into v_location_id
  from public.inventory_locations
  where business_id=v_business_id and location_code=p_location_code;
  if v_location_id is null then raise exception 'Inventory location not found'; end if;

  insert into public.stock_items(
    business_id,location_id,sku,item_name,category,unit,
    quantity_on_hand,reorder_level,average_unit_cost
  ) values (
    v_business_id,v_location_id,nullif(btrim(p_sku),''),
    btrim(p_item_name),btrim(p_category),
    coalesce(nullif(btrim(p_unit),''),'piece'),0,p_reorder_level,p_unit_cost
  ) returning id into v_stock_item_id;

  if p_opening_quantity>0 then
    perform private.apply_stock_movement(
      v_business_id,v_stock_item_id,p_opening_quantity,p_unit_cost,'opening'
    );
  end if;

  insert into public.audit_events(
    business_id,actor_user_id,event_type,entity_type,entity_id,details
  ) values (
    v_business_id,auth.uid(),'inventory.stock_item_created','stock_item',
    v_stock_item_id,jsonb_build_object(
      'location_code',p_location_code,'opening_quantity',p_opening_quantity,
      'unit_cost',p_unit_cost
    )
  );
  return v_stock_item_id;
end
$function$;

create or replace function public.owner_receive_purchase_order_line(
  p_line_id uuid,
  p_received_quantity numeric
) returns void
language plpgsql
security definer
set search_path=public,private,pg_temp
as $function$
declare
  v_line public.purchase_order_lines%rowtype;
  v_order public.purchase_orders%rowtype;
  v_stock public.stock_items%rowtype;
  v_landed_unit_cost numeric(14,4);
  v_total_received numeric(14,3);
  v_total_ordered numeric(14,3);
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  select * into v_line from public.purchase_order_lines
  where id=p_line_id for update;
  if not found or not exists (
    select 1 from public.business_memberships
    where business_id=v_line.business_id and user_id=auth.uid() and role='owner'
  ) then raise exception 'Purchase line not found'; end if;

  select * into v_order from public.purchase_orders
  where id=v_line.purchase_order_id and business_id=v_line.business_id
  for update;
  if not found then raise exception 'Purchase order not found'; end if;
  if v_order.status in ('cancelled','received')
     or p_received_quantity is null or p_received_quantity<=0
     or v_line.received_quantity+p_received_quantity>v_line.quantity then
    raise exception 'Invalid or excess goods receipt';
  end if;

  select * into v_stock from public.stock_items
  where id=v_line.stock_item_id and business_id=v_line.business_id
  for update;
  if not found or not v_stock.active then raise exception 'Active stock item not found'; end if;

  v_landed_unit_cost:=v_line.unit_cost+
    case when v_order.total>0
      then (v_order.transport_cost*(v_line.quantity*v_line.unit_cost/v_order.total))/v_line.quantity
      else 0
    end;

  perform private.apply_stock_movement(
    v_line.business_id,v_stock.id,p_received_quantity,v_landed_unit_cost,'purchase'
  );

  update public.purchase_order_lines
    set received_quantity=received_quantity+p_received_quantity
    where id=v_line.id and business_id=v_line.business_id;

  select coalesce(sum(received_quantity),0),coalesce(sum(quantity),0)
    into v_total_received,v_total_ordered
    from public.purchase_order_lines
    where purchase_order_id=v_order.id and business_id=v_order.business_id;

  update public.purchase_orders
    set status=case when v_total_received>=v_total_ordered then 'received' else 'part_received' end
    where id=v_order.id and business_id=v_order.business_id;

  insert into public.audit_events(
    business_id,actor_user_id,event_type,entity_type,entity_id,details
  ) values (
    v_line.business_id,auth.uid(),'purchasing.goods_received','purchase_order_line',
    v_line.id,jsonb_build_object(
      'purchase_order_id',v_order.id,'stock_item_id',v_stock.id,
      'received_quantity',p_received_quantity,'landed_unit_cost',v_landed_unit_cost
    )
  );
end
$function$;

revoke all on function public.owner_create_stock_item(text,text,text,text,numeric,numeric,numeric,text) from public,anon;
revoke all on function public.owner_receive_purchase_order_line(uuid,numeric) from public,anon;
grant execute on function public.owner_create_stock_item(text,text,text,text,numeric,numeric,numeric,text) to authenticated;
grant execute on function public.owner_receive_purchase_order_line(uuid,numeric) to authenticated;

do $permissions$
begin
  if to_regprocedure('private.update_job_material_issue(uuid,uuid,numeric,numeric)') is not null then
    execute 'revoke all on function private.update_job_material_issue(uuid,uuid,numeric,numeric) from public,anon,authenticated';
  end if;
  if to_regprocedure('private.update_job_stage(uuid,uuid,text)') is not null then
    execute 'revoke all on function private.update_job_stage(uuid,uuid,text) from public,anon,authenticated';
  end if;
  if to_regprocedure('private.update_purchase_receipt(uuid,uuid,numeric)') is not null then
    execute 'revoke all on function private.update_purchase_receipt(uuid,uuid,numeric) from public,anon,authenticated';
  end if;
end
$permissions$;

create or replace function public.owner_add_job_material(
  p_job_id uuid,
  p_stock_item_id uuid,
  p_planned_quantity numeric
) returns uuid
language plpgsql
security definer
set search_path=public,pg_temp
as $function$
declare
  v_business_id uuid;
  v_job_stage text;
  v_material_id uuid;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;

  select business_id,stage into v_business_id,v_job_stage
  from public.production_jobs where id=p_job_id for update;
  if v_business_id is null or not exists (
    select 1 from public.business_memberships
    where business_id=v_business_id and user_id=auth.uid() and role='owner'
  ) then
    raise exception 'Production job not found';
  end if;
  if v_job_stage in ('delivered','cancelled') then
    raise exception 'Cannot plan material for a closed production job';
  end if;
  if p_planned_quantity is null or p_planned_quantity<=0 then
    raise exception 'Planned quantity must be greater than zero';
  end if;
  if not exists (
    select 1 from public.stock_items
    where id=p_stock_item_id and business_id=v_business_id and active
  ) then
    raise exception 'Active stock item not found in this business';
  end if;

  insert into public.production_job_materials(
    business_id,job_id,stock_item_id,planned_quantity
  ) values (
    v_business_id,p_job_id,p_stock_item_id,p_planned_quantity
  ) returning id into v_material_id;

  insert into public.audit_events(
    business_id,actor_user_id,event_type,entity_type,entity_id,details
  ) values (
    v_business_id,auth.uid(),'production.material_planned','production_job_material',
    v_material_id,jsonb_build_object(
      'job_id',p_job_id,'stock_item_id',p_stock_item_id,
      'planned_quantity',p_planned_quantity
    )
  );
  return v_material_id;
end
$function$;

create or replace function public.owner_issue_job_material(
  p_job_material_id uuid,
  p_quantity numeric
) returns void
language plpgsql
security definer
set search_path=public,pg_temp
as $function$
declare
  v_material public.production_job_materials%rowtype;
  v_stock public.stock_items%rowtype;
  v_job_stage text;
  v_cost numeric(14,2);
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if p_quantity is null or p_quantity<=0 then
    raise exception 'Issue quantity must be greater than zero';
  end if;

  select * into v_material
  from public.production_job_materials
  where id=p_job_material_id
  for update;
  if not found or not exists (
    select 1 from public.business_memberships
    where business_id=v_material.business_id and user_id=auth.uid() and role='owner'
  ) then
    raise exception 'Job material not found';
  end if;

  select stage into v_job_stage
  from public.production_jobs
  where id=v_material.job_id and business_id=v_material.business_id
  for update;
  if not found or v_job_stage in ('delivered','cancelled') then
    raise exception 'Cannot issue material for a closed production job';
  end if;

  if v_material.issued_quantity+p_quantity>v_material.planned_quantity then
    raise exception 'Issue quantity exceeds planned balance';
  end if;

  select * into v_stock
  from public.stock_items
  where id=v_material.stock_item_id and business_id=v_material.business_id
  for update;
  if not found or not v_stock.active then raise exception 'Active stock item not found'; end if;
  if v_stock.quantity_on_hand<p_quantity then raise exception 'Insufficient stock'; end if;

  v_cost:=round(p_quantity*v_stock.average_unit_cost,2);
  perform private.apply_stock_movement(
    v_material.business_id,v_stock.id,-p_quantity,v_stock.average_unit_cost,'job_issue'
  );

  update public.production_job_materials
    set issued_quantity=issued_quantity+p_quantity
    where id=v_material.id and business_id=v_material.business_id;
  update public.production_jobs
    set actual_direct_cost=actual_direct_cost+v_cost
    where id=v_material.job_id and business_id=v_material.business_id;

  insert into public.audit_events(
    business_id,actor_user_id,event_type,entity_type,entity_id,details
  ) values (
    v_material.business_id,auth.uid(),'production.material_issued','production_job_material',
    v_material.id,jsonb_build_object(
      'job_id',v_material.job_id,'stock_item_id',v_material.stock_item_id,
      'quantity',p_quantity,'unit_cost',v_stock.average_unit_cost,'direct_cost',v_cost
    )
  );
end
$function$;

create or replace function public.owner_set_production_stage(
  p_job_id uuid,
  p_stage text
) returns void
language plpgsql
security definer
set search_path=public,pg_temp
as $function$
declare
  v_business_id uuid;
  v_old_stage text;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  select business_id,stage into v_business_id,v_old_stage
  from public.production_jobs where id=p_job_id for update;
  if v_business_id is null or not exists (
    select 1 from public.business_memberships
    where business_id=v_business_id and user_id=auth.uid() and role='owner'
  ) then
    raise exception 'Production job not found';
  end if;

  if not (
    (v_old_stage='awaiting_artwork' and p_stage in ('artwork_proof','cancelled')) or
    (v_old_stage='artwork_proof' and p_stage in ('screens_prepared','cancelled')) or
    (v_old_stage='screens_prepared' and p_stage in ('printing','cancelled')) or
    (v_old_stage='printing' and p_stage in ('finishing','cancelled')) or
    (v_old_stage='finishing' and p_stage in ('quality_check','cancelled')) or
    (v_old_stage='quality_check' and p_stage in ('ready','printing','cancelled')) or
    (v_old_stage='ready' and p_stage in ('delivered','finishing','cancelled'))
  ) then
    raise exception 'Invalid production stage transition';
  end if;

  update public.production_jobs
    set stage=p_stage,
        delivered_at=case when p_stage='delivered' then now() else delivered_at end
    where id=p_job_id and business_id=v_business_id;

  insert into public.audit_events(
    business_id,actor_user_id,event_type,entity_type,entity_id,details
  ) values (
    v_business_id,auth.uid(),'production.stage_changed','production_job',p_job_id,
    jsonb_build_object('from',v_old_stage,'to',p_stage)
  );
end
$function$;

revoke all on function public.owner_add_job_material(uuid,uuid,numeric) from public,anon;
revoke all on function public.owner_issue_job_material(uuid,numeric) from public,anon;
revoke all on function public.owner_set_production_stage(uuid,text) from public,anon;
grant execute on function public.owner_add_job_material(uuid,uuid,numeric) to authenticated;
grant execute on function public.owner_issue_job_material(uuid,numeric) to authenticated;
grant execute on function public.owner_set_production_stage(uuid,text) to authenticated;

-- Restore the public PostgREST entry point for quotation creation.
-- The implementation remains private and SECURITY DEFINER; this invoker wrapper
-- preserves the established owner authorization and server-side pricing rules.
create or replace function public.owner_create_quotation(
 p_customer_id uuid,
 p_costing_profile_id uuid,
 p_quote_number text,
 p_valid_until date,
 p_lines jsonb,
 p_allow_below_floor boolean default false,
 p_exception_reason text default null
) returns uuid
language sql
security invoker
set search_path=public,private,pg_temp
as $function$
 select private.owner_create_quotation_impl(
  p_customer_id,p_costing_profile_id,p_quote_number,p_valid_until,p_lines,
  p_allow_below_floor,p_exception_reason
 );
$function$;

revoke all on function public.owner_create_quotation(uuid,uuid,text,date,jsonb,boolean,text) from public,anon;
grant execute on function public.owner_create_quotation(uuid,uuid,text,date,jsonb,boolean,text) to authenticated;

-- Ensure PostgREST notices the restored RPC without requiring a manual dashboard refresh.
notify pgrst, 'reload schema';
