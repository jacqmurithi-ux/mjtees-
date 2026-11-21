-- Apparel & merchandise variants. Variant balances reuse stock_items and stock_movements.
-- Extend the existing movement type constraint without changing prior ledger semantics.
alter table public.stock_movements drop constraint if exists stock_movements_movement_type_check;
alter table public.stock_movements add constraint stock_movements_movement_type_check
 check (movement_type in ('opening','purchase','job_issue','transfer_in','transfer_out','adjustment','offcut_return','vinyl_sticker_sale','apparel_sale'));


create table if not exists public.catalogue_item_variants (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  catalogue_item_id uuid not null,
  stock_item_id uuid not null,
  sku text not null,
  size text,
  colour text,
  style text,
  capacity text,
  attributes jsonb not null default '{}'::jsonb check (jsonb_typeof(attributes)='object'),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  constraint catalogue_item_variants_business_sku_key unique (business_id, sku),
  constraint catalogue_item_variants_stock_item_key unique (stock_item_id),
  constraint catalogue_item_variants_business_id_id_key unique (business_id,id),
  constraint catalogue_item_variants_catalogue_item_fkey
    foreign key (catalogue_item_id) references public.catalogue_items(id),
  constraint catalogue_item_variants_stock_item_fkey
    foreign key (business_id,stock_item_id) references public.stock_items(business_id,id)
);
create index if not exists catalogue_item_variants_catalogue_idx
  on public.catalogue_item_variants(business_id,catalogue_item_id,active);
alter table public.catalogue_item_variants enable row level security;
drop policy if exists catalogue_item_variants_owner_read on public.catalogue_item_variants;
create policy catalogue_item_variants_owner_read on public.catalogue_item_variants
 for select to authenticated using (exists (
  select 1 from public.business_memberships bm
  where bm.business_id=catalogue_item_variants.business_id
    and bm.user_id=(select auth.uid()) and bm.role='owner'
 ));
revoke all on public.catalogue_item_variants from anon,authenticated;
grant select on public.catalogue_item_variants to authenticated;

create table if not exists public.apparel_variant_reservations (
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null references public.businesses(id) on delete cascade,
 variant_id uuid not null,
 job_id uuid not null,
 quantity numeric(14,3) not null check(quantity>0),
 issued_quantity numeric(14,3) not null default 0 check(issued_quantity>=0 and issued_quantity<=quantity),
 status text not null default 'reserved' check(status in('reserved','partially_issued','issued','released')),
 created_by uuid not null references auth.users(id),
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 constraint apparel_reservations_variant_fkey foreign key (business_id,variant_id)
   references public.catalogue_item_variants(business_id,id),
 constraint apparel_reservations_job_fkey foreign key (business_id,job_id)
   references public.production_jobs(business_id,id)
);
create index if not exists apparel_reservations_job_idx
 on public.apparel_variant_reservations(business_id,job_id,status);
create index if not exists apparel_reservations_variant_idx
 on public.apparel_variant_reservations(business_id,variant_id,status);
alter table public.apparel_variant_reservations enable row level security;
drop policy if exists apparel_variant_reservations_owner_read on public.apparel_variant_reservations;
create policy apparel_variant_reservations_owner_read on public.apparel_variant_reservations
 for select to authenticated using (exists (
  select 1 from public.business_memberships bm
  where bm.business_id=apparel_variant_reservations.business_id
   and bm.user_id=(select auth.uid()) and bm.role='owner'
 ));
revoke all on public.apparel_variant_reservations from anon,authenticated;
grant select on public.apparel_variant_reservations to authenticated;

create or replace function public.owner_create_apparel_variant(
 p_catalogue_item_id uuid,p_sku text,p_size text default null,p_colour text default null,
 p_style text default null,p_capacity text default null,p_location_code text default 'shop_1',
 p_opening_quantity numeric default 0,p_reorder_level numeric default 0,p_unit_cost numeric default 0
) returns uuid
language plpgsql security definer
set search_path=public,private,pg_temp
as $fn$
declare v_business uuid; v_item public.catalogue_items%rowtype; v_location uuid;
 v_stock uuid; v_variant uuid; v_name text; v_attrs jsonb; v_item_name text; v_category text;
begin
 if auth.uid() is null then raise exception 'Authentication required'; end if;
 select business_id into v_business from public.business_memberships
 where user_id=auth.uid() and role='owner' order by created_at limit 1;
 if v_business is null then raise exception 'Owner workspace required'; end if;
 select * into v_item from public.catalogue_items
 where id=p_catalogue_item_id and business_id=v_business and is_active for share;
 if not found then raise exception 'Active catalogue item not found'; end if;
 if v_item.item_type<>'product' then raise exception 'Variants can only be created for catalogue products, not services'; end if;
 if length(btrim(coalesce(p_sku,'')))<2 or p_location_code not in('shop_1','shop_2')
   or coalesce(p_opening_quantity,-1)<0 or coalesce(p_reorder_level,-1)<0 or coalesce(p_unit_cost,-1)<0
 then raise exception 'Enter a SKU, valid location and non-negative stock values'; end if;
 v_item_name:=lower(coalesce(v_item.name,''));
 v_category:=lower(coalesce(v_item.category,''));
 if (v_item_name ~ '(t[ -]?shirts?|polos?|hoodies?)' or v_category='apparel')
    and v_item_name !~ '(reflective)' then
  if nullif(btrim(coalesce(p_size,'')),'') is null or nullif(btrim(coalesce(p_colour,'')),'') is null then
   raise exception 'This apparel variant requires both size and colour';
  end if;
 elsif v_item_name ~ '(caps?|headwear)' or v_category='headwear' then
  if nullif(btrim(coalesce(p_colour,'')),'') is null or nullif(btrim(coalesce(p_style,'')),'') is null then
   raise exception 'A cap variant requires colour and style (for example adjustable or fitted)';
  end if;
 elsif v_item_name ~ '(mugs?|tumblers?|drinkware)' or v_category='drinkware' then
  if nullif(btrim(coalesce(p_colour,'')),'') is null or nullif(btrim(coalesce(p_capacity,'')),'') is null then
   raise exception 'A drinkware variant requires colour and capacity/type';
  end if;
 elsif v_item_name ~ 'reflective.*(jackets?|vests?)|((jackets?|vests?).*reflective)' then
  if nullif(btrim(coalesce(p_size,'')),'') is null or nullif(btrim(coalesce(p_colour,'')),'') is null
     or nullif(btrim(coalesce(p_style,'')),'') is null then
   raise exception 'A reflective garment variant requires size, colour and reflective style';
  end if;
 elsif nullif(btrim(coalesce(p_size,'')),'') is null
  and nullif(btrim(coalesce(p_colour,'')),'') is null
  and nullif(btrim(coalesce(p_style,'')),'') is null
  and nullif(btrim(coalesce(p_capacity,'')),'') is null then
  raise exception 'At least one variant attribute (size, colour, style or capacity) is required';
 end if;
 select id into v_location from public.inventory_locations
 where business_id=v_business and location_code=p_location_code;
 if v_location is null then raise exception 'Inventory location not found'; end if;
 v_name:=v_item.name||' · '||concat_ws(' / ',nullif(btrim(p_size),''),nullif(btrim(p_colour),''),nullif(btrim(p_style),''),nullif(btrim(p_capacity),''));
 v_attrs:=jsonb_strip_nulls(jsonb_build_object('size',nullif(btrim(p_size),''),'colour',nullif(btrim(p_colour),''),'style',nullif(btrim(p_style),''),'capacity',nullif(btrim(p_capacity),'')));
 insert into public.stock_items(business_id,location_id,sku,item_name,category,unit,quantity_on_hand,reorder_level,average_unit_cost)
 values(v_business,v_location,btrim(p_sku),v_name,'Apparel & merchandise','piece',0,p_reorder_level,p_unit_cost)
 returning id into v_stock;
 if p_opening_quantity>0 then
  perform private.apply_stock_movement(v_business,v_stock,p_opening_quantity,p_unit_cost,'opening');
 end if;
 insert into public.catalogue_item_variants(business_id,catalogue_item_id,stock_item_id,sku,size,colour,style,capacity,attributes)
 values(v_business,v_item.id,v_stock,btrim(p_sku),nullif(btrim(p_size),''),nullif(btrim(p_colour),''),nullif(btrim(p_style),''),nullif(btrim(p_capacity),''),v_attrs)
 returning id into v_variant;
 insert into public.audit_events(business_id,actor_user_id,event_type,entity_type,entity_id,details)
 values(v_business,auth.uid(),'inventory.apparel_variant_created','catalogue_item_variant',v_variant,
  jsonb_build_object('catalogue_item_id',v_item.id,'stock_item_id',v_stock,'sku',btrim(p_sku),'attributes',v_attrs,'opening_quantity',p_opening_quantity));
 return v_variant;
end
$fn$;

create or replace function public.owner_reserve_apparel_variant(
 p_job_id uuid,p_variant_id uuid,p_quantity numeric
) returns uuid
language plpgsql security definer
set search_path=public,pg_temp
as $fn$
declare v_business uuid; v_job public.production_jobs%rowtype; v_variant public.catalogue_item_variants%rowtype;
 v_stock public.stock_items%rowtype; v_reserved numeric; v_id uuid;
begin
 if auth.uid() is null or p_quantity is null or p_quantity<=0 then raise exception 'Authentication and a positive reservation quantity are required'; end if;
 select business_id into v_business from public.business_memberships
 where user_id=auth.uid() and role='owner' order by created_at limit 1;
 select * into v_job from public.production_jobs where id=p_job_id and business_id=v_business for update;
 if not found or v_job.production_status in('cancelled','delivered') then raise exception 'Open production job not found'; end if;
 if coalesce(v_job.customer_supplied_items,false) then raise exception 'Customer-supplied items cannot reserve MJ stock'; end if;
 select * into v_variant from public.catalogue_item_variants
 where id=p_variant_id and business_id=v_business and active for share;
 if not found then raise exception 'Active apparel variant not found'; end if;
 select * into v_stock from public.stock_items where id=v_variant.stock_item_id and business_id=v_business and active for update;
 if not found then raise exception 'Variant stock item is inactive'; end if;
 select coalesce(sum(quantity-issued_quantity),0) into v_reserved
 from public.apparel_variant_reservations
 where business_id=v_business and variant_id=p_variant_id and status in('reserved','partially_issued');
 if v_stock.quantity_on_hand-v_reserved<p_quantity then
  raise exception 'Insufficient available stock. On hand %, already reserved %, requested %',v_stock.quantity_on_hand,v_reserved,p_quantity;
 end if;
 insert into public.apparel_variant_reservations(business_id,variant_id,job_id,quantity,created_by)
 values(v_business,p_variant_id,p_quantity,auth.uid()) returning id into v_id;
 insert into public.audit_events(business_id,actor_user_id,event_type,entity_type,entity_id,details)
 values(v_business,auth.uid(),'inventory.apparel_variant_reserved','apparel_variant_reservation',v_id,
  jsonb_build_object('job_id',p_job_id,'variant_id',p_variant_id,'quantity',p_quantity));
 return v_id;
end
$fn$;

create or replace function public.owner_issue_apparel_variant_reservation(
 p_reservation_id uuid,p_quantity numeric
) returns void
language plpgsql security definer
set search_path=public,private,pg_temp
as $fn$
declare v_res public.apparel_variant_reservations%rowtype; v_variant public.catalogue_item_variants%rowtype;
 v_stock public.stock_items%rowtype; v_job public.production_jobs%rowtype; v_remaining numeric;
begin
 if auth.uid() is null or p_quantity is null or p_quantity<=0 then raise exception 'Authentication and a positive issue quantity are required'; end if;
 select * into v_res from public.apparel_variant_reservations where id=p_reservation_id for update;
 if not found or not exists(select 1 from public.business_memberships where business_id=v_res.business_id and user_id=auth.uid() and role='owner') then raise exception 'Reservation not found'; end if;
 if v_res.status not in('reserved','partially_issued') then raise exception 'Reservation is no longer active'; end if;
 v_remaining:=v_res.quantity-v_res.issued_quantity;
 if p_quantity>v_remaining then raise exception 'Issue quantity exceeds remaining reserved quantity'; end if;
 select * into v_job from public.production_jobs where id=v_res.job_id and business_id=v_res.business_id for update;
 if not found or v_job.production_status in('cancelled','delivered') then raise exception 'Cannot issue stock to a closed production job'; end if;
 select * into v_variant from public.catalogue_item_variants where id=v_res.variant_id and business_id=v_res.business_id;
 select * into v_stock from public.stock_items where id=v_variant.stock_item_id and business_id=v_res.business_id for update;
 if not found or not v_stock.active or v_stock.quantity_on_hand<p_quantity then raise exception 'Insufficient stock or inactive variant'; end if;
 perform private.apply_stock_movement(v_res.business_id,v_stock.id,-p_quantity,v_stock.average_unit_cost,'job_issue');
 update public.apparel_variant_reservations set issued_quantity=issued_quantity+p_quantity,
  status=case when issued_quantity+p_quantity>=quantity then 'issued' else 'partially_issued' end,updated_at=now()
 where id=v_res.id;
 -- Replace the estimated blank-item component from the linked invoice with actual
 -- issued garment cost. Preserve all other direct costs and count partial issues once.
 select coalesce(sum(i.quantity),0),
        coalesce(sum(case when jsonb_typeof(i.cost_snapshot->'components')='array' then
          (select coalesce(sum(nullif(c.value->>'total_cost','')::numeric),0)
           from jsonb_array_elements(i.cost_snapshot->'components') c(value)
           where c.value->>'category'='blank_item')
         else 0 end),0)
 into v_invoice_quantity,v_blank_estimate_total
 from public.sales_invoice_items i
 where i.business_id=v_res.business_id
  and i.invoice_id=v_job.invoice_id
  and i.cost_snapshot->>'catalogue_item_id'=v_variant.catalogue_item_id::text;
 select greatest(coalesce(sum(r.issued_quantity),0)-p_quantity,0) into v_previously_issued
 from public.apparel_variant_reservations r
 join public.catalogue_item_variants cv on cv.id=r.variant_id and cv.business_id=r.business_id
 where r.business_id=v_res.business_id and r.job_id=v_res.job_id
  and cv.catalogue_item_id=v_variant.catalogue_item_id;
 if v_invoice_quantity>0 and v_blank_estimate_total>0 then
  v_blank_estimate_to_replace:=round(
   (v_blank_estimate_total/v_invoice_quantity)
   *least(p_quantity,greatest(v_invoice_quantity-v_previously_issued,0)),2);
 end if;
 select greatest(0,coalesce(actual_direct_cost,0)-v_blank_estimate_to_replace)
   +round(p_quantity*v_stock.average_unit_cost,2)
 into v_actual_job_cost
 from public.production_jobs where id=v_res.job_id and business_id=v_res.business_id;
 update public.production_jobs set actual_direct_cost=v_actual_job_cost
 where id=v_res.job_id and business_id=v_res.business_id;
 insert into public.audit_events(business_id,actor_user_id,event_type,entity_type,entity_id,details)
 values(v_res.business_id,auth.uid(),'inventory.apparel_variant_issued','apparel_variant_reservation',v_res.id,
  jsonb_build_object('job_id',v_res.job_id,'variant_id',v_res.variant_id,'stock_item_id',v_stock.id,'quantity',p_quantity,'unit_cost',v_stock.average_unit_cost));
end
$fn$;

create or replace function public.owner_release_apparel_variant_reservation(
 p_reservation_id uuid,p_reason text
) returns void
language plpgsql security definer
set search_path=public,pg_temp
as $fn$
declare v_res public.apparel_variant_reservations%rowtype;
begin
 if auth.uid() is null or length(btrim(coalesce(p_reason,'')))<3 then raise exception 'Authentication and a release reason are required'; end if;
 select * into v_res from public.apparel_variant_reservations where id=p_reservation_id for update;
 if not found or not exists(select 1 from public.business_memberships where business_id=v_res.business_id and user_id=auth.uid() and role='owner') then raise exception 'Reservation not found'; end if;
 if v_res.status not in('reserved','partially_issued') then raise exception 'Reservation is already closed'; end if;
 update public.apparel_variant_reservations set status='released',updated_at=now() where id=v_res.id;
 insert into public.audit_events(business_id,actor_user_id,event_type,entity_type,entity_id,details)
 values(v_res.business_id,auth.uid(),'inventory.apparel_variant_released','apparel_variant_reservation',v_res.id,
  jsonb_build_object('job_id',v_res.job_id,'variant_id',v_res.variant_id,'unissued_quantity',v_res.quantity-v_res.issued_quantity,'issued_quantity_kept_consumed',v_res.issued_quantity,'reason',btrim(p_reason)));
end
$fn$;

-- Atomic direct blank-item sale: preserve canonical invoice, payment, costing and margin validation.
-- Extend the canonical stock ledger movement vocabulary for confirmed blank-item sales.
create or replace function private.apply_stock_movement(
 p_business_id uuid,p_stock_item_id uuid,p_quantity numeric,p_unit_cost numeric,p_movement_type text
) returns void
language plpgsql security definer
set search_path=public,pg_temp
as $function$
declare v_stock public.stock_items%rowtype; v_new_quantity numeric(14,6); v_new_cost numeric(14,2);
begin
 if auth.uid() is null or not exists(select 1 from public.business_memberships
  where business_id=p_business_id and user_id=auth.uid() and role='owner') then
  raise exception 'Owner authorization required';
 end if;
 if p_quantity is null or p_quantity=0 or p_unit_cost is null or p_unit_cost<0
  or p_movement_type not in('opening','purchase','job_issue','transfer_in','transfer_out','adjustment','offcut_return','vinyl_sticker_sale','apparel_sale') then
  raise exception 'Invalid stock movement';
 end if;
 select * into v_stock from public.stock_items where id=p_stock_item_id and business_id=p_business_id for update;
 if not found then raise exception 'Stock item not found'; end if;
 v_new_quantity:=v_stock.quantity_on_hand+p_quantity;
 if v_new_quantity<0 then raise exception 'Insufficient stock'; end if;
 v_new_cost:=v_stock.average_unit_cost;
 if p_quantity>0 then
  v_new_cost:=case when v_new_quantity>0 then
   ((v_stock.quantity_on_hand*v_stock.average_unit_cost)+(p_quantity*p_unit_cost))/v_new_quantity
   else p_unit_cost end;
 end if;
 update public.stock_items set quantity_on_hand=v_new_quantity,average_unit_cost=v_new_cost
 where id=v_stock.id and business_id=p_business_id;
 insert into public.stock_movements(business_id,stock_item_id,movement_type,quantity,unit_cost,created_by)
 values(p_business_id,p_stock_item_id,p_movement_type,p_quantity,p_unit_cost,auth.uid());
end
$function$;
revoke all on function private.apply_stock_movement(uuid,uuid,numeric,numeric,text) from public,anon,authenticated;

-- Cancellation releases only unissued reservations. Issued quantities remain consumed.
create or replace function private.release_apparel_reservations_on_job_cancel()
returns trigger language plpgsql security definer
set search_path=public,pg_temp
as $trigger$
begin
 if new.production_status='cancelled' and old.production_status is distinct from new.production_status then
  with released as (
   update public.apparel_variant_reservations
    set status='released',updated_at=now()
    where business_id=new.business_id and job_id=new.id and status in('reserved','partially_issued')
    returning id,quantity,issued_quantity
  )
  insert into public.audit_events(business_id,actor_user_id,event_type,entity_type,entity_id,details)
  select new.business_id,auth.uid(),'inventory.apparel_reservation_released_on_cancel',
   'apparel_variant_reservation',r.id,
   jsonb_build_object('job_id',new.id,'unissued_quantity',r.quantity-r.issued_quantity,'issued_quantity_kept_consumed',r.issued_quantity)
  from released r;
 end if;
 return new;
end
$trigger$;
drop trigger if exists production_job_release_apparel_reservations on public.production_jobs;
create trigger production_job_release_apparel_reservations
 after update of production_status on public.production_jobs
 for each row execute function private.release_apparel_reservations_on_job_cancel();

create or replace function public.owner_create_apparel_quick_sale(
 p_sale_args jsonb,p_variant_id uuid
) returns jsonb
language plpgsql security definer
set search_path=public,private,pg_temp
as $fn$
declare
 v_business uuid; v_variant public.catalogue_item_variants%rowtype; v_stock public.stock_items%rowtype;
 v_result jsonb; v_qty numeric; v_supply text; v_item_id uuid; v_invoice uuid; v_reserved numeric:=0;
 v_invoice_total numeric(14,2); v_existing_cost numeric(14,2); v_blank_estimate numeric(14,2);
 v_other_cost numeric(14,2); v_actual_cost numeric(14,2); v_margin numeric(7,2);
 v_snapshot jsonb; v_exception boolean; v_exception_reason text;
begin
 if auth.uid() is null or jsonb_typeof(p_sale_args)<>'object' or p_variant_id is null then raise exception 'Invalid apparel sale request'; end if;
 select business_id into v_business from public.business_memberships
 where user_id=auth.uid() and role='owner' order by created_at limit 1;
 perform 1 from public.businesses where id=v_business for update;
 select * into v_variant from public.catalogue_item_variants
 where id=p_variant_id and business_id=v_business and active for share;
 if not found then raise exception 'Active apparel variant not found'; end if;
 v_qty:=(p_sale_args->>'p_quantity')::numeric;
 v_supply:=p_sale_args->>'p_supply_arrangement';
 v_item_id:=(p_sale_args->>'p_catalogue_item_id')::uuid;
 if v_item_id<>v_variant.catalogue_item_id then raise exception 'Selected variant does not belong to the selected catalogue product'; end if;
 if v_supply<>'mj_supplies' then raise exception 'Customer-supplied items must use the standard sale workflow without MJ stock'; end if;
 if v_qty is null or v_qty<=0 or v_qty<>trunc(v_qty) then raise exception 'Apparel quantity must be a whole number greater than zero'; end if;
 select * into v_stock from public.stock_items where id=v_variant.stock_item_id and business_id=v_business and active for update;
 if not found then raise exception 'Apparel variant stock item is inactive or unavailable'; end if;
 select coalesce(sum(quantity-issued_quantity),0) into v_reserved
 from public.apparel_variant_reservations
 where business_id=v_business and variant_id=p_variant_id
  and status in('reserved','partially_issued');
 if v_stock.quantity_on_hand-v_reserved<v_qty then
  raise exception 'Insufficient available apparel stock after reservations. On hand %, reserved %, requested %',
   v_stock.quantity_on_hand,v_reserved,v_qty;
 end if;
 v_result:=public.owner_create_quick_sale(
  (p_sale_args->>'p_customer_id')::uuid,p_sale_args->>'p_invoice_number',(p_sale_args->>'p_due_date')::date,
  v_item_id,p_sale_args->>'p_production_method',v_qty,(p_sale_args->>'p_unit_price')::numeric,v_supply,
  coalesce((p_sale_args->>'p_other_direct_costs')::numeric,0),p_sale_args->>'p_price_reason',
  coalesce((p_sale_args->>'p_allow_below_floor')::boolean,false),p_sale_args->>'p_exception_reason',
  p_sale_args->>'p_payment_number',p_sale_args->>'p_payment_method',
  coalesce((p_sale_args->>'p_payment_amount')::numeric,0),p_sale_args->>'p_payment_reference'
 );
 v_invoice:=(v_result->>'invoice_id')::uuid;
 select i.total,li.direct_cost,li.cost_snapshot into v_invoice_total,v_existing_cost,v_snapshot
 from public.sales_invoices i join public.sales_invoice_items li on li.invoice_id=i.id and li.business_id=i.business_id
 where i.id=v_invoice and i.business_id=v_business for update of li;
 v_blank_estimate:=case when jsonb_typeof(v_snapshot->'components')='array' then
  (select coalesce(sum(nullif(x.value->>'total_cost','')::numeric),0)
   from jsonb_array_elements(v_snapshot->'components') x(value)
   where x.value->>'category'='blank_item') else 0 end;
 v_other_cost:=greatest(0,coalesce(v_existing_cost,0)-v_blank_estimate);
 v_actual_cost:=round(v_other_cost+(v_stock.average_unit_cost*v_qty),2);
 v_margin:=case when v_invoice_total>0 then round(((v_invoice_total-v_actual_cost)/v_invoice_total)*100,2) else 0 end;
 v_exception:=coalesce((p_sale_args->>'p_allow_below_floor')::boolean,false);
 v_exception_reason:=btrim(coalesce(p_sale_args->>'p_exception_reason',''));
 if v_margin<30 and (not v_exception or length(v_exception_reason)<8) then
  raise exception 'Actual apparel stock cost puts this sale below the 30%% gross-margin floor. An authorised exception and reason are required.';
 end if;
 perform private.apply_stock_movement(v_business,v_stock.id,-v_qty,v_stock.average_unit_cost,'apparel_sale');
 update public.sales_invoice_items set direct_cost=v_actual_cost,
  cost_snapshot=coalesce(v_snapshot,'{}'::jsonb)||jsonb_build_object(
   'apparel_variant_id',v_variant.id,'apparel_sku',v_variant.sku,'apparel_attributes',v_variant.attributes,
   'apparel_stock_item_id',v_stock.id,'apparel_stock_consumed',v_qty,
   'apparel_actual_unit_cost',v_stock.average_unit_cost,'apparel_actual_direct_cost',round(v_stock.average_unit_cost*v_qty,2),
   'direct_cost_total',v_actual_cost,'gross_margin_percent',v_margin
  )
 where invoice_id=v_invoice and business_id=v_business;
 insert into public.audit_events(business_id,actor_user_id,event_type,entity_type,entity_id,details)
 values(v_business,auth.uid(),'sales.apparel_variant_consumed','sales_invoice',v_invoice,
  jsonb_build_object('variant_id',v_variant.id,'sku',v_variant.sku,'stock_item_id',v_stock.id,'quantity',v_qty,
   'unit_cost',v_stock.average_unit_cost,'actual_direct_cost',v_actual_cost,'gross_margin_percent',v_margin,
   'below_floor_exception_reason',case when v_margin<30 then v_exception_reason else null end));
 return v_result||jsonb_build_object('apparel_variant_id',v_variant.id,'apparel_sku',v_variant.sku,'actual_direct_cost',v_actual_cost,'gross_margin_percent',v_margin);
end
$fn$;

revoke all on function public.owner_create_apparel_variant(uuid,text,text,text,text,text,text,numeric,numeric,numeric) from public,anon;
revoke all on function public.owner_reserve_apparel_variant(uuid,uuid,numeric) from public,anon;
revoke all on function public.owner_issue_apparel_variant_reservation(uuid,numeric) from public,anon;
revoke all on function public.owner_release_apparel_variant_reservation(uuid,text) from public,anon;
revoke all on function public.owner_create_apparel_quick_sale(jsonb,uuid) from public,anon;
grant execute on function public.owner_create_apparel_variant(uuid,text,text,text,text,text,text,numeric,numeric,numeric) to authenticated;
grant execute on function public.owner_reserve_apparel_variant(uuid,uuid,numeric) to authenticated;
grant execute on function public.owner_issue_apparel_variant_reservation(uuid,numeric) to authenticated;
grant execute on function public.owner_release_apparel_variant_reservation(uuid,text) to authenticated;
grant execute on function public.owner_create_apparel_quick_sale(jsonb,uuid) to authenticated;
