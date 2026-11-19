-- Operational transaction layer for MJ Printing & Branding.
-- All writes are owner-scoped, transactional RPCs. Auth users are not modified.
alter table public.quotations
  add column if not exists below_floor_exception_reason text,
  add column if not exists below_floor_approved_by uuid references auth.users(id);
alter table public.production_jobs
  add column if not exists actual_direct_cost numeric(14,2) not null default 0 check(actual_direct_cost>=0);
alter table public.purchase_order_lines
  add column if not exists stock_item_id uuid references public.stock_items(id);

create table if not exists public.production_job_materials(
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null references public.businesses(id) on delete cascade,
 job_id uuid not null references public.production_jobs(id) on delete cascade,
 stock_item_id uuid not null references public.stock_items(id),
 planned_quantity numeric(14,3) not null check(planned_quantity>0),
 issued_quantity numeric(14,3) not null default 0 check(issued_quantity>=0 and issued_quantity<=planned_quantity),
 created_at timestamptz not null default now()
);
alter table public.production_job_materials enable row level security;
create policy production_job_materials_owner_read on public.production_job_materials for select to authenticated
 using(business_id in(select business_id from public.business_memberships where user_id=(select auth.uid()) and role='owner'));
create policy production_job_materials_owner_insert on public.production_job_materials for insert to authenticated
 with check(business_id in(select business_id from public.business_memberships where user_id=(select auth.uid()) and role='owner'));
create policy production_job_materials_owner_update on public.production_job_materials for update to authenticated
 using(business_id in(select business_id from public.business_memberships where user_id=(select auth.uid()) and role='owner'))
 with check(business_id in(select business_id from public.business_memberships where user_id=(select auth.uid()) and role='owner'));

-- Operational tables remain owner-write; read access is still restricted to the same business.
do $$
declare t text;
begin
 foreach t in array array[
 'suppliers','refunds'
 ] loop
  execute format(
   'create policy %I on public.%I for all to authenticated using(business_id in(select business_id from public.business_memberships where user_id=(select auth.uid()) and role=''owner'')) with check(business_id in(select business_id from public.business_memberships where user_id=(select auth.uid()) and role=''owner''))',
   t||'_owner_write'
  );
 end loop;
end $;

-- Costing profiles are versioned and immutable; only the active pointer can be changed privately.
drop policy if exists costing_profiles_owner_access on public.costing_profiles;
create policy costing_profiles_owner_read on public.costing_profiles for select to authenticated
 using(business_id in(select business_id from public.business_memberships where user_id=(select auth.uid()) and role='owner'));
create policy costing_profiles_owner_insert on public.costing_profiles for insert to authenticated
 with check(business_id in(select business_id from public.business_memberships where user_id=(select auth.uid()) and role='owner'));
revoke update,delete on public.costing_profiles from authenticated;
grant select,insert on public.costing_profiles to authenticated;

-- Ledger rows are append-only. Inventory quantities can only change through the private stock movement helper.
drop policy if exists stock_items_owner_access on public.stock_items;
create policy stock_items_owner_insert on public.stock_items for insert to authenticated
 with check(business_id in(select business_id from public.business_memberships where user_id=(select auth.uid()) and role='owner') and quantity_on_hand=0 and average_unit_cost=0);
create policy quotations_owner_insert on public.quotations for insert to authenticated
 with check(business_id in(select business_id from public.business_memberships where user_id=(select auth.uid()) and role='owner'));
create policy quotations_owner_status_update on public.quotations for update to authenticated
 using(business_id in(select business_id from public.business_memberships where user_id=(select auth.uid()) and role='owner'))
 with check(business_id in(select business_id from public.business_memberships where user_id=(select auth.uid()) and role='owner'));
create policy quotation_lines_owner_insert on public.quotation_lines for insert to authenticated
 with check(business_id in(select business_id from public.business_memberships where user_id=(select auth.uid()) and role='owner'));
create policy sales_invoices_owner_insert on public.sales_invoices for insert to authenticated
 with check(business_id in(select business_id from public.business_memberships where user_id=(select auth.uid()) and role='owner'));
create policy sales_invoice_items_owner_insert on public.sales_invoice_items for insert to authenticated
 with check(business_id in(select business_id from public.business_memberships where user_id=(select auth.uid()) and role='owner'));
create policy production_jobs_owner_insert on public.production_jobs for insert to authenticated
 with check(business_id in(select business_id from public.business_memberships where user_id=(select auth.uid()) and role='owner'));
create policy purchase_orders_owner_insert on public.purchase_orders for insert to authenticated
 with check(business_id in(select business_id from public.business_memberships where user_id=(select auth.uid()) and role='owner'));
create policy purchase_order_lines_owner_insert on public.purchase_order_lines for insert to authenticated
 with check(business_id in(select business_id from public.business_memberships where user_id=(select auth.uid()) and role='owner'));
create policy expenses_owner_insert on public.expenses for insert to authenticated
 with check(business_id in(select business_id from public.business_memberships where user_id=(select auth.uid()) and role='owner'));
create policy payments_owner_insert on public.payments for insert to authenticated
 with check(business_id in(select business_id from public.business_memberships where user_id=(select auth.uid()) and role='owner'));
create policy payment_allocations_owner_insert on public.payment_allocations for insert to authenticated
 with check(business_id in(select business_id from public.business_memberships where user_id=(select auth.uid()) and role='owner'));
create policy audit_events_owner_insert on public.audit_events for insert to authenticated
 with check(business_id in(select business_id from public.business_memberships where user_id=(select auth.uid()) and role='owner'));
revoke update,delete on public.quotations,public.quotation_lines,public.sales_invoices,public.sales_invoice_items,public.production_jobs,public.purchase_orders,public.purchase_order_lines,public.expenses from authenticated;
grant select,insert on public.quotations,public.quotation_lines,public.sales_invoices,public.sales_invoice_items,public.production_jobs,public.purchase_orders,public.purchase_order_lines,public.expenses to authenticated;
revoke update,delete on public.stock_items from authenticated;
grant select,insert on public.stock_items to authenticated;
revoke update,delete on public.quotations from authenticated;
grant update(status) on public.quotations to authenticated;
revoke insert,update,delete on public.stock_movements from authenticated;
grant select on public.stock_movements to authenticated;
revoke update,delete on public.payments,public.payment_allocations,public.audit_events from authenticated;
grant select,insert on public.payments,public.payment_allocations,public.audit_events to authenticated;
revoke update,delete on public.production_job_materials from authenticated;
grant select,insert on public.production_job_materials to authenticated;

create or replace function private.apply_stock_movement(
 p_business_id uuid,p_stock_item_id uuid,p_quantity numeric,p_unit_cost numeric,p_movement_type text
) returns void language plpgsql security definer set search_path=public,pg_temp as $
declare s public.stock_items%rowtype; v_new_qty numeric(14,3); v_new_cost numeric(14,2);
begin
 if auth.uid() is null or not exists(select 1 from public.business_memberships where business_id=p_business_id and user_id=auth.uid() and role='owner') then
  raise exception 'Owner authorization required';
 end if;
 if p_quantity=0 or p_unit_cost<0 or p_movement_type not in('opening','purchase','job_issue','transfer_in','transfer_out','adjustment','offcut_return') then raise exception 'Invalid stock movement'; end if;
 select * into s from public.stock_items where id=p_stock_item_id and business_id=p_business_id for update;
 if not found then raise exception 'Stock item not found'; end if;
 v_new_qty:=s.quantity_on_hand+p_quantity;
 if v_new_qty<0 then raise exception 'Insufficient stock'; end if;
 v_new_cost:=s.average_unit_cost;
 if p_quantity>0 then
  v_new_cost:=case when v_new_qty>0 then ((s.quantity_on_hand*s.average_unit_cost)+(p_quantity*p_unit_cost))/v_new_qty else p_unit_cost end;
 end if;
 update public.stock_items set quantity_on_hand=v_new_qty,average_unit_cost=v_new_cost where id=s.id;
 insert into public.stock_movements(business_id,stock_item_id,movement_type,quantity,unit_cost,created_by)
 values(p_business_id,p_stock_item_id,p_movement_type,p_quantity,p_unit_cost,auth.uid());
end $;
revoke all on function private.apply_stock_movement(uuid,uuid,numeric,numeric,text) from public,anon;
grant usage on schema private to authenticated;
grant execute on function private.apply_stock_movement(uuid,uuid,numeric,numeric,text) to authenticated;

create or replace function private.activate_costing_profile(p_business_id uuid,p_profile_id uuid)
returns void language plpgsql security definer set search_path=public,pg_temp as $
declare v_name text;
begin
 if auth.uid() is null or not exists(select 1 from public.business_memberships where business_id=p_business_id and user_id=auth.uid() and role='owner') then raise exception 'Owner authorization required'; end if;
 select profile_name into v_name from public.costing_profiles where id=p_profile_id and business_id=p_business_id;
 if v_name is null then raise exception 'Costing profile not found'; end if;
 update public.costing_profiles set is_active=false where business_id=p_business_id and profile_name=v_name and is_active;
 update public.costing_profiles set is_active=true where id=p_profile_id and business_id=p_business_id;
end $;
revoke all on function private.activate_costing_profile(uuid,uuid) from public,anon;
grant execute on function private.activate_costing_profile(uuid,uuid) to authenticated;

create or replace function public.owner_create_costing_profile(
 p_profile_name text,p_components jsonb,p_direct_cost numeric,p_activate boolean default true
) returns uuid language plpgsql security invoker set search_path=public,pg_temp as $
declare v_business uuid; v_version integer; v_id uuid;
begin
 select business_id into v_business from public.business_memberships where user_id=auth.uid() and role='owner' limit 1;
 if v_business is null or length(btrim(coalesce(p_profile_name,'')))<2 then raise exception 'Valid costing profile and owner workspace required'; end if;
 if jsonb_typeof(p_components)<>'array' or jsonb_array_length(p_components)=0 or p_direct_cost<0 then raise exception 'Costing profile requires components and a non-negative direct cost'; end if;
 select coalesce(max(version),0)+1 into v_version from public.costing_profiles where business_id=v_business and profile_name=btrim(p_profile_name);
 insert into public.costing_profiles(business_id,profile_name,version,is_active,components,direct_cost)
 values(v_business,btrim(p_profile_name),v_version,false,p_components,p_direct_cost) returning id into v_id;
 if p_activate then perform private.activate_costing_profile(v_business,v_id); end if;
 return v_id;
end $;

create or replace function public.owner_activate_costing_profile(p_profile_id uuid)
returns void language plpgsql security invoker set search_path=public,pg_temp as $
declare v_business uuid;
begin
 select business_id into v_business from public.costing_profiles where id=p_profile_id;
 if v_business is null then raise exception 'Costing profile not found'; end if;
 perform private.activate_costing_profile(v_business,p_profile_id);
end $;

create or replace function private.update_invoice_balance(p_business_id uuid,p_invoice_id uuid,p_amount numeric)
returns void language plpgsql security definer set search_path=public,pg_temp as $
declare i public.sales_invoices%rowtype;
begin
 if auth.uid() is null or not exists(select 1 from public.business_memberships where business_id=p_business_id and user_id=auth.uid() and role='owner') then raise exception 'Owner authorization required'; end if;
 select * into i from public.sales_invoices where id=p_invoice_id and business_id=p_business_id for update;
 if not found or p_amount<=0 or p_amount>i.balance then raise exception 'Invalid invoice payment allocation'; end if;
 perform private.update_invoice_balance(i.business_id,i.id,p_amount);
end $;

create or replace function private.update_job_material_issue(p_business_id uuid,p_material_id uuid,p_quantity numeric,p_cost numeric)
returns void language plpgsql security definer set search_path=public,pg_temp as $
declare m public.production_job_materials%rowtype;
begin
 if auth.uid() is null or not exists(select 1 from public.business_memberships where business_id=p_business_id and user_id=auth.uid() and role='owner') then raise exception 'Owner authorization required'; end if;
 select * into m from public.production_job_materials where id=p_material_id and business_id=p_business_id for update;
 if not found or p_quantity<=0 or m.issued_quantity+p_quantity>m.planned_quantity then raise exception 'Invalid job material issue'; end if;
 update public.production_job_materials set issued_quantity=issued_quantity+p_quantity where id=m.id;
 update public.production_jobs set actual_direct_cost=actual_direct_cost+p_cost where id=m.job_id and business_id=p_business_id;
end $;

create or replace function private.update_job_stage(p_business_id uuid,p_job_id uuid,p_stage text)
returns void language plpgsql security definer set search_path=public,pg_temp as $
declare v_old text;
begin
 if auth.uid() is null or not exists(select 1 from public.business_memberships where business_id=p_business_id and user_id=auth.uid() and role='owner') then raise exception 'Owner authorization required'; end if;
 select stage into v_old from public.production_jobs where id=p_job_id and business_id=p_business_id for update;
 if not found or v_old in('delivered','cancelled') then raise exception 'Production job not found or already closed'; end if;
 update public.production_jobs set stage=p_stage,delivered_at=case when p_stage='delivered' then now() else delivered_at end where id=p_job_id and business_id=p_business_id;
end $;

create or replace function private.update_purchase_receipt(p_business_id uuid,p_line_id uuid,p_received_quantity numeric)
returns void language plpgsql security definer set search_path=public,pg_temp as $
declare l public.purchase_order_lines%rowtype; po public.purchase_orders%rowtype; v_received numeric(14,3);
begin
 if auth.uid() is null or not exists(select 1 from public.business_memberships where business_id=p_business_id and user_id=auth.uid() and role='owner') then raise exception 'Owner authorization required'; end if;
 select * into l from public.purchase_order_lines where id=p_line_id and business_id=p_business_id for update;
 if not found then raise exception 'Purchase line not found'; end if;
 select * into po from public.purchase_orders where id=l.purchase_order_id and business_id=p_business_id for update;
 if po.status in('cancelled','received') or p_received_quantity<=0 or l.received_quantity+p_received_quantity>l.quantity then raise exception 'Invalid or excess goods receipt'; end if;
 update public.purchase_order_lines set received_quantity=received_quantity+p_received_quantity where id=l.id;
 select coalesce(sum(received_quantity),0) into v_received from public.purchase_order_lines where purchase_order_id=po.id;
 update public.purchase_orders set status=case when v_received>=(select sum(quantity) from public.purchase_order_lines where purchase_order_id=po.id) then 'received' else 'part_received' end where id=po.id;
end $;

revoke all on function private.update_invoice_balance(uuid,uuid,numeric) from public,anon;
revoke all on function private.update_job_material_issue(uuid,uuid,numeric,numeric) from public,anon;
revoke all on function private.update_job_stage(uuid,uuid,text) from public,anon;
revoke all on function private.update_purchase_receipt(uuid,uuid,numeric) from public,anon;
grant execute on function private.update_invoice_balance(uuid,uuid,numeric) to authenticated;
grant execute on function private.update_job_material_issue(uuid,uuid,numeric,numeric) to authenticated;
grant execute on function private.update_job_stage(uuid,uuid,text) to authenticated;
grant execute on function private.update_purchase_receipt(uuid,uuid,numeric) to authenticated;

create or replace function public.owner_create_stock_item(
 p_location_code text,p_item_name text,p_category text,p_unit text default 'piece',
 p_opening_quantity numeric default 0,p_reorder_level numeric default 0,p_unit_cost numeric default 0,p_sku text default null
) returns uuid language plpgsql security invoker set search_path=public,pg_temp as $$
declare v_business uuid; v_location uuid; v_item uuid; v_user uuid;
begin
 v_user:=auth.uid();
 select business_id into v_business from public.business_memberships where user_id=v_user and role='owner' limit 1;
 if v_business is null then raise exception 'Owner workspace required'; end if;
 if p_location_code not in('shop_1','shop_2') or p_opening_quantity<0 or p_reorder_level<0 or p_unit_cost<0 then raise exception 'Invalid stock details'; end if;
 select id into v_location from public.inventory_locations where business_id=v_business and location_code=p_location_code;
 if v_location is null then raise exception 'Inventory location not found'; end if;
 insert into public.stock_items(business_id,location_id,sku,item_name,category,unit,quantity_on_hand,reorder_level,average_unit_cost)
 values(v_business,v_location,nullif(btrim(p_sku),''),btrim(p_item_name),btrim(p_category),coalesce(nullif(btrim(p_unit),''),'piece'),0,p_reorder_level,p_unit_cost)
 returning id into v_item;
 if p_opening_quantity>0 then
  perform private.apply_stock_movement(v_business,v_item,p_opening_quantity,p_unit_cost,'opening');
 end if;
 return v_item;
end $$;

create or replace function public.owner_create_quotation(
 p_customer_id uuid,p_costing_profile_id uuid,p_quote_number text,p_valid_until date,p_lines jsonb,
 p_allow_below_floor boolean default false,p_exception_reason text default null
) returns uuid language plpgsql security invoker set search_path=public,pg_temp as $$
declare v_business uuid; v_user uuid; v_quote uuid; v_profile uuid; v_profile_direct_cost numeric(14,2); v_total numeric(14,2):=0; v_cost numeric(14,2):=0;
 v_line jsonb; v_qty numeric; v_price numeric; v_cost_line numeric; v_desc text;
begin
 v_user:=auth.uid();
 select business_id into v_business from public.business_memberships where user_id=v_user and role='owner' limit 1;
 if v_business is null then raise exception 'Owner workspace required'; end if;
 if not exists(select 1 from public.customers where id=p_customer_id and business_id=v_business) then raise exception 'Customer not found in this workspace'; end if;
 select id,direct_cost into v_profile,v_profile_direct_cost from public.costing_profiles where id=p_costing_profile_id and business_id=v_business and is_active;
 if v_profile is null then raise exception 'An active versioned costing profile is required before pricing this quotation'; end if;
 if jsonb_typeof(p_lines)<>'array' or jsonb_array_length(p_lines)<>1 then raise exception 'This costing profile prices one production line per quotation'; end if;
 v_cost:=v_profile_direct_cost;
 for v_line in select value from jsonb_array_elements(p_lines) loop
  v_qty:=(v_line->>'quantity')::numeric; v_price:=(v_line->>'unit_price')::numeric;
  v_cost_line:=0; v_desc:=btrim(v_line->>'description');
  if v_qty<=0 or v_price<0 or coalesce(v_desc,'')='' then raise exception 'Invalid quotation line'; end if;
  v_total:=v_total+(v_qty*v_price);
 end loop;
 if v_total<=0 then raise exception 'Quotation total must be greater than zero'; end if;
 if ((v_total-v_cost)/v_total)*100 < 30 then
  if not coalesce(p_allow_below_floor,false) or length(btrim(coalesce(p_exception_reason,'')))<8 then
   raise exception 'Quotation is below the 30% gross-margin floor. An authorised exception and reason are required.';
  end if;
 end if;
 insert into public.quotations(business_id,customer_id,costing_profile_id,quote_number,valid_until,total,created_by,below_floor_exception_reason,below_floor_approved_by)
 values(v_business,p_customer_id,v_profile,btrim(p_quote_number),p_valid_until,v_total,v_user,
  case when ((v_total-v_cost)/v_total)*100<30 then btrim(p_exception_reason) end,
  case when ((v_total-v_cost)/v_total)*100<30 then v_user end)
 returning id into v_quote;
 for v_line in select value from jsonb_array_elements(p_lines) loop
  v_qty:=(v_line->>'quantity')::numeric; v_price:=(v_line->>'unit_price')::numeric;
  insert into public.quotation_lines(business_id,quotation_id,description,quantity,unit_price,direct_cost,line_total,details)
  values(v_business,v_quote,btrim(v_line->>'description'),v_qty,v_price,v_cost,v_qty*v_price,coalesce(v_line->'details','{}'::jsonb));
 end loop;
 insert into public.audit_events(business_id,actor_user_id,event_type,entity_type,entity_id,details)
 values(v_business,v_user,'quotation.created','quotation',v_quote,jsonb_build_object('total',v_total,'direct_cost',v_cost,'gross_margin_percent',round(((v_total-v_cost)/v_total)*100,2)));
 return v_quote;
end $$;

create or replace function public.owner_set_quotation_status(p_quote_id uuid,p_status text)
returns void language plpgsql security invoker set search_path=public,pg_temp as $$
declare v_business uuid; v_old text;
begin
 select business_id,status into v_business,v_old from public.quotations where id=p_quote_id for update;
 if v_business is null or not exists(select 1 from public.business_memberships where business_id=v_business and user_id=auth.uid() and role='owner') then raise exception 'Quotation not found'; end if;
 if p_status not in('sent','accepted','declined','expired') then raise exception 'Unsupported quotation status'; end if;
 if not ((v_old='draft' and p_status='sent') or (v_old='sent' and p_status in('accepted','declined','expired'))) then raise exception 'Invalid quotation status transition'; end if;
 update public.quotations set status=p_status where id=p_quote_id;
end $$;

create or replace function public.owner_convert_quote_to_invoice(
 p_quote_id uuid,p_invoice_number text,p_job_number text,p_due_date date
) returns jsonb language plpgsql security invoker set search_path=public,pg_temp as $$
declare q public.quotations%rowtype; v_invoice uuid; v_job uuid; v_user uuid; v_customer_supplied boolean; v_job_name text;
begin
 v_user:=auth.uid();
 select * into q from public.quotations where id=p_quote_id for update;
 if not found or not exists(select 1 from public.business_memberships where business_id=q.business_id and user_id=v_user and role='owner') then raise exception 'Quotation not found'; end if;
 if q.status<>'accepted' then raise exception 'Only accepted quotations can be invoiced'; end if;
 insert into public.sales_invoices(business_id,customer_id,invoice_number,status,due_date,total,amount_paid,balance,created_by)
 values(q.business_id,q.customer_id,btrim(p_invoice_number),'sent',p_due_date,q.total,0,q.total,v_user)
 returning id into v_invoice;
 insert into public.sales_invoice_items(business_id,invoice_id,description,quantity,unit_price,line_total,item_type)
 select q.business_id,v_invoice,l.description,l.quantity,l.unit_price,l.line_total,
  case when l.details->>'item_type' in('blank_product','printing_service','custom_production','other') then l.details->>'item_type' else 'other' end
 from public.quotation_lines l where l.quotation_id=q.id and l.business_id=q.business_id;
 select coalesce(bool_or(coalesce((details->>'customer_supplied_items')::boolean,false)),false)
 into v_customer_supplied from public.quotation_lines where quotation_id=q.id and business_id=q.business_id;
 v_job_name:='Production for '||q.quote_number;
 insert into public.production_jobs(business_id,invoice_id,quotation_id,customer_id,job_number,job_name,customer_supplied_items,actual_direct_cost)
 values(q.business_id,v_invoice,q.id,q.customer_id,btrim(p_job_number),v_job_name,v_customer_supplied,0)
 returning id into v_job;
 update public.quotations set status='converted' where id=q.id;
 insert into public.audit_events(business_id,actor_user_id,event_type,entity_type,entity_id,details)
 values(q.business_id,v_user,'quotation.converted','quotation',q.id,jsonb_build_object('invoice_id',v_invoice,'job_id',v_job));
 return jsonb_build_object('invoice_id',v_invoice,'job_id',v_job);
end $$;

create or replace function public.owner_add_job_material(p_job_id uuid,p_stock_item_id uuid,p_planned_quantity numeric)
returns uuid language plpgsql security invoker set search_path=public,pg_temp as $$
declare v_business uuid; v_id uuid;
begin
 select business_id into v_business from public.production_jobs where id=p_job_id;
 if v_business is null or not exists(select 1 from public.business_memberships where business_id=v_business and user_id=auth.uid() and role='owner') then raise exception 'Production job not found'; end if;
 if p_planned_quantity<=0 or not exists(select 1 from public.stock_items where id=p_stock_item_id and business_id=v_business and active) then raise exception 'Invalid material or quantity'; end if;
 insert into public.production_job_materials(business_id,job_id,stock_item_id,planned_quantity)
 values(v_business,p_job_id,p_stock_item_id,p_planned_quantity) returning id into v_id;
 return v_id;
end $$;

create or replace function public.owner_issue_job_material(p_job_material_id uuid,p_quantity numeric)
returns void language plpgsql security invoker set search_path=public,pg_temp as $$
declare m public.production_job_materials%rowtype; s public.stock_items%rowtype; v_user uuid;
begin
 v_user:=auth.uid();
 select * into m from public.production_job_materials where id=p_job_material_id;
 if not found or not exists(select 1 from public.business_memberships where business_id=m.business_id and user_id=v_user and role='owner') then raise exception 'Job material not found'; end if;
 if p_quantity<=0 or m.issued_quantity+p_quantity>m.planned_quantity then raise exception 'Issue quantity exceeds planned balance'; end if;
 select * into s from public.stock_items where id=m.stock_item_id and business_id=m.business_id;
 if s.quantity_on_hand<p_quantity then raise exception 'Insufficient stock'; end if;
 perform private.apply_stock_movement(m.business_id,s.id,-p_quantity,s.average_unit_cost,'job_issue');
 perform private.update_job_material_issue(m.business_id,m.id,p_quantity,p_quantity*s.average_unit_cost);
end $$;

create or replace function public.owner_set_production_stage(p_job_id uuid,p_stage text)
returns void language plpgsql security invoker set search_path=public,pg_temp as $$
declare v_business uuid; v_old text;
begin
 select business_id,stage into v_business,v_old from public.production_jobs where id=p_job_id;
 if v_business is null or not exists(select 1 from public.business_memberships where business_id=v_business and user_id=auth.uid() and role='owner') then raise exception 'Production job not found'; end if;
 if p_stage not in('awaiting_artwork','artwork_proof','screens_prepared','printing','finishing','quality_check','ready','delivered','cancelled') then raise exception 'Invalid production stage'; end if;
 if v_old in('delivered','cancelled') then raise exception 'Closed jobs cannot be changed'; end if;
 perform private.update_job_stage(v_business,p_job_id,p_stage);
end $$;

create or replace function public.owner_record_payment(
 p_invoice_id uuid,p_payment_number text,p_method text,p_amount numeric,p_reference_code text default null
) returns uuid language plpgsql security invoker set search_path=public,pg_temp as $$
declare i public.sales_invoices%rowtype; v_payment uuid; v_user uuid;
begin
 v_user:=auth.uid();
 select * into i from public.sales_invoices where id=p_invoice_id;
 if not found or not exists(select 1 from public.business_memberships where business_id=i.business_id and user_id=v_user and role='owner') then raise exception 'Invoice not found'; end if;
 if p_method not in('cash','mpesa_paybill') or p_amount<=0 or p_amount>i.balance then raise exception 'Invalid payment method or amount exceeds invoice balance'; end if;
 insert into public.payments(business_id,customer_id,payment_number,method,amount,reference_code,received_by)
 values(i.business_id,i.customer_id,btrim(p_payment_number),p_method,p_amount,nullif(btrim(p_reference_code),''),v_user)
 returning id into v_payment;
 insert into public.payment_allocations(business_id,payment_id,invoice_id,amount)
 values(i.business_id,v_payment,i.id,p_amount);
 update public.sales_invoices set amount_paid=amount_paid+p_amount,balance=balance-p_amount,
 status=case when balance-p_amount=0 then 'paid' else 'partially_paid' end where id=i.id;
 insert into public.audit_events(business_id,actor_user_id,event_type,entity_type,entity_id,details)
 values(i.business_id,v_user,'payment.received','payment',v_payment,jsonb_build_object('invoice_id',i.id,'amount',p_amount,'method',p_method));
 return v_payment;
end $$;

create or replace function public.owner_record_expense(
 p_category text,p_description text,p_amount numeric,p_payment_method text,p_expense_date date default current_date
) returns uuid language plpgsql security invoker set search_path=public,pg_temp as $$
declare v_business uuid; v_id uuid; v_user uuid;
begin
 v_user:=auth.uid();
 select business_id into v_business from public.business_memberships where user_id=v_user and role='owner' limit 1;
 if v_business is null then raise exception 'Owner workspace required'; end if;
 if p_amount<=0 or p_payment_method not in('cash','mpesa_paybill') or length(btrim(p_description))=0 then raise exception 'Invalid expense'; end if;
 insert into public.expenses(business_id,expense_date,category,description,amount,payment_method,created_by)
 values(v_business,p_expense_date,btrim(p_category),btrim(p_description),p_amount,p_payment_method,v_user) returning id into v_id;
 return v_id;
end $$;

create or replace function public.owner_operational_report()
returns jsonb language plpgsql stable security invoker set search_path=public,pg_temp as $$
declare v_business uuid; v_result jsonb;
begin
 select business_id into v_business from public.business_memberships where user_id=auth.uid() and role='owner' limit 1;
 if v_business is null then raise exception 'Owner workspace required'; end if;
 select jsonb_build_object(
  'invoiced_sales',coalesce((select sum(total) from public.sales_invoices where business_id=v_business and status not in('draft','void')),0),
  'payments_received',coalesce((select sum(amount) from public.payments where business_id=v_business),0),
  'outstanding_receivables',coalesce((select sum(balance) from public.sales_invoices where business_id=v_business and status not in('draft','void')),0),
  'active_jobs',(select count(*) from public.production_jobs where business_id=v_business and stage not in('delivered','cancelled')),
  'delivered_jobs',(select count(*) from public.production_jobs where business_id=v_business and stage='delivered'),
  'stock_items',(select count(*) from public.stock_items where business_id=v_business and active),
  'low_stock_items',(select count(*) from public.stock_items where business_id=v_business and active and quantity_on_hand<=reorder_level),
  'expenses',coalesce((select sum(amount) from public.expenses where business_id=v_business),0),
  'cash_received',coalesce((select sum(amount) from public.payments where business_id=v_business and method='cash'),0),
  'mpesa_received',coalesce((select sum(amount) from public.payments where business_id=v_business and method='mpesa_paybill'),0)
 ) into v_result;
 return v_result;
end $$;

revoke all on function public.owner_create_stock_item(text,text,text,text,numeric,numeric,numeric,text) from public,anon;
revoke all on function public.owner_create_costing_profile(text,jsonb,numeric,boolean) from public,anon;
revoke all on function public.owner_activate_costing_profile(uuid) from public,anon;
revoke all on function public.owner_create_quotation(uuid,uuid,text,date,jsonb,boolean,text) from public,anon;
revoke all on function public.owner_set_quotation_status(uuid,text) from public,anon;
revoke all on function public.owner_convert_quote_to_invoice(uuid,text,text,date) from public,anon;
revoke all on function public.owner_add_job_material(uuid,uuid,numeric) from public,anon;
revoke all on function public.owner_issue_job_material(uuid,numeric) from public,anon;
revoke all on function public.owner_set_production_stage(uuid,text) from public,anon;
revoke all on function public.owner_record_payment(uuid,text,text,numeric,text) from public,anon;
revoke all on function public.owner_record_expense(text,text,numeric,text,date) from public,anon;
revoke all on function public.owner_operational_report() from public,anon;
grant execute on function public.owner_create_stock_item(text,text,text,text,numeric,numeric,numeric,text) to authenticated;
grant execute on function public.owner_create_costing_profile(text,jsonb,numeric,boolean) to authenticated;
grant execute on function public.owner_activate_costing_profile(uuid) to authenticated;
grant execute on function public.owner_create_quotation(uuid,uuid,text,date,jsonb,boolean,text) to authenticated;
grant execute on function public.owner_set_quotation_status(uuid,text) to authenticated;
grant execute on function public.owner_convert_quote_to_invoice(uuid,text,text,date) to authenticated;
grant execute on function public.owner_add_job_material(uuid,uuid,numeric) to authenticated;
grant execute on function public.owner_issue_job_material(uuid,numeric) to authenticated;
grant execute on function public.owner_set_production_stage(uuid,text) to authenticated;
grant execute on function public.owner_record_payment(uuid,text,text,numeric,text) to authenticated;
grant execute on function public.owner_record_expense(text,text,numeric,text,date) to authenticated;
grant execute on function public.owner_operational_report() to authenticated;


create or replace function public.owner_create_supplier(p_supplier_name text,p_phone text default null,p_email text default null)
returns uuid language plpgsql security invoker set search_path=public,pg_temp as $$
declare v_business uuid; v_id uuid;
begin
 select business_id into v_business from public.business_memberships where user_id=auth.uid() and role='owner' limit 1;
 if v_business is null or length(btrim(coalesce(p_supplier_name,'')))<2 then raise exception 'Valid supplier and owner workspace required'; end if;
 insert into public.suppliers(business_id,supplier_name,phone,email)
 values(v_business,btrim(p_supplier_name),nullif(btrim(p_phone),''),nullif(btrim(p_email),'')) returning id into v_id;
 return v_id;
end $$;

create or replace function public.owner_create_purchase_order(
 p_supplier_id uuid,p_po_number text,p_transport_cost numeric,p_lines jsonb
) returns uuid language plpgsql security invoker set search_path=public,pg_temp as $$
declare v_business uuid; v_total numeric(14,2):=0; v_line jsonb; v_stock uuid; v_qty numeric; v_cost numeric; v_po uuid;
begin
 select business_id into v_business from public.business_memberships where user_id=auth.uid() and role='owner' limit 1;
 if v_business is null or not exists(select 1 from public.suppliers where id=p_supplier_id and business_id=v_business) then raise exception 'Supplier not found'; end if;
 if p_transport_cost<0 or jsonb_typeof(p_lines)<>'array' or jsonb_array_length(p_lines)=0 then raise exception 'Invalid purchase order'; end if;
 for v_line in select value from jsonb_array_elements(p_lines) loop
  v_stock:=(v_line->>'stock_item_id')::uuid; v_qty:=(v_line->>'quantity')::numeric; v_cost:=(v_line->>'unit_cost')::numeric;
  if v_qty<=0 or v_cost<0 or not exists(select 1 from public.stock_items where id=v_stock and business_id=v_business and active) then raise exception 'Invalid purchase line'; end if;
  v_total:=v_total+(v_qty*v_cost);
 end loop;
 insert into public.purchase_orders(business_id,supplier_id,po_number,status,total,transport_cost)
 values(v_business,p_supplier_id,btrim(p_po_number),'sent',v_total,p_transport_cost) returning id into v_po;
 for v_line in select value from jsonb_array_elements(p_lines) loop
  v_stock:=(v_line->>'stock_item_id')::uuid; v_qty:=(v_line->>'quantity')::numeric; v_cost:=(v_line->>'unit_cost')::numeric;
  insert into public.purchase_order_lines(business_id,purchase_order_id,stock_item_id,item_description,quantity,unit_cost)
  select v_business,v_po,s.id,s.item_name,v_qty,v_cost from public.stock_items s where s.id=v_stock and s.business_id=v_business;
 end loop;
 return v_po;
end $$;

create or replace function public.owner_receive_purchase_order_line(p_line_id uuid,p_received_quantity numeric)
returns void language plpgsql security invoker set search_path=public,pg_temp as $$
declare l public.purchase_order_lines%rowtype; po public.purchase_orders%rowtype; s public.stock_items%rowtype;
 v_landed numeric(14,4); v_new_qty numeric(14,3); v_received numeric(14,3);
begin
 select * into l from public.purchase_order_lines where id=p_line_id;
 if not found or not exists(select 1 from public.business_memberships where business_id=l.business_id and user_id=auth.uid() and role='owner') then raise exception 'Purchase line not found'; end if;
 select * into po from public.purchase_orders where id=l.purchase_order_id;
 if po.status in('cancelled','received') or p_received_quantity<=0 or l.received_quantity+p_received_quantity>l.quantity then raise exception 'Invalid or excess goods receipt'; end if;
 select * into s from public.stock_items where id=l.stock_item_id and business_id=l.business_id;
 if not found then raise exception 'Stock item not found'; end if;
 v_landed:=l.unit_cost+case when po.total>0 then (po.transport_cost*(l.quantity*l.unit_cost/po.total))/l.quantity else 0 end;
 perform private.apply_stock_movement(l.business_id,s.id,p_received_quantity,v_landed,'purchase');
 perform private.update_purchase_receipt(l.business_id,l.id,p_received_quantity);
end $$;

revoke all on function public.owner_create_supplier(text,text,text) from public,anon;
revoke all on function public.owner_create_purchase_order(uuid,text,numeric,jsonb) from public,anon;
revoke all on function public.owner_receive_purchase_order_line(uuid,numeric) from public,anon;
grant execute on function public.owner_create_supplier(text,text,text) to authenticated;
grant execute on function public.owner_create_purchase_order(uuid,text,numeric,jsonb) to authenticated;
grant execute on function public.owner_receive_purchase_order_line(uuid,numeric) to authenticated;
