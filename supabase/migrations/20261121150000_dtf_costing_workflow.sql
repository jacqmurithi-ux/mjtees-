-- DTF workflow RPCs. This file is pending review; it has NOT been applied to production.
create or replace function public.owner_create_dtf_quotation(
 p_customer_id uuid,p_quote_number text,p_valid_until date,p_quantity numeric,p_unit_price numeric,
 p_direct_cost_per_piece numeric,p_details jsonb,p_allow_below_floor boolean default false,p_exception_reason text default null
) returns uuid language plpgsql security definer set search_path=public,private,pg_temp as $$
declare v_user uuid:=auth.uid(); v_business uuid; v_profile uuid; v_quote uuid;
begin
 if v_user is null then raise exception 'Authentication required'; end if;
 select business_id into v_business from public.business_memberships where user_id=v_user and role='owner' order by created_at limit 1;
 if v_business is null then raise exception 'Owner workspace required'; end if;
 if not exists(select 1 from public.customers where id=p_customer_id and business_id=v_business) then raise exception 'Customer not found in this workspace'; end if;
 if p_quantity is null or p_quantity<=0 or p_quantity<>trunc(p_quantity) then raise exception 'Quantity must be a whole number greater than zero'; end if;
 if p_unit_price is null or p_unit_price<=0 or p_direct_cost_per_piece is null or p_direct_cost_per_piece<0 then raise exception 'Invalid DTF price or direct cost'; end if;
 if jsonb_typeof(p_details)<>'object' or p_details->>'module'<>'dtf_costing' then raise exception 'DTF costing details are required'; end if;
 insert into public.costing_profiles(business_id,profile_name,version,is_active,components,direct_cost,margin_floor,full_cost_target)
 values(v_business,'DTF quotation '||left(replace(gen_random_uuid()::text,'-',''),12),1,true,
  jsonb_build_array(jsonb_build_object('name','DTF direct production costs','category','production','basis','per_piece','cost',round(p_direct_cost_per_piece,2))),
  round(p_direct_cost_per_piece,2),30,1.8) returning id into v_profile;
 v_quote:=public.owner_create_quotation(p_customer_id,v_profile,p_quote_number,p_valid_until,
  jsonb_build_array(jsonb_build_object('description','DTF printing and garment decoration','quantity',p_quantity,'unit_price',p_unit_price,
   'details',jsonb_build_object('customer_supplied_items',coalesce((p_details->'garments') @> '[{"supply_source":"customer_supplies"}]'::jsonb,false),
    'item_type','custom_production'))),
  coalesce(p_allow_below_floor,false),p_exception_reason);
 update public.quotation_lines set details=coalesce(details,'{}'::jsonb)||jsonb_build_object('cost_snapshot',
  coalesce(details->'cost_snapshot','{}'::jsonb)||jsonb_build_object('pricing_source','dtf_costing','dtf_details',p_details))
 where quotation_id=v_quote and business_id=v_business;
 update public.costing_profiles set is_active=false where id=v_profile and business_id=v_business;
 insert into public.audit_events(business_id,actor_user_id,event_type,entity_type,entity_id,details)
 values(v_business,v_user,'dtf.quotation_created','quotation',v_quote,jsonb_build_object('pricing_source','dtf_costing','dtf_details',p_details));
 return v_quote;
end $$;

create or replace function public.owner_create_dtf_quick_sale(
 p_customer_id uuid,p_invoice_number text,p_due_date date,p_description text,p_quantity numeric,p_agreed_price numeric,
 p_direct_cost_per_piece numeric,p_details jsonb,p_stock_lines jsonb default '[]'::jsonb,
 p_allow_below_floor boolean default false,p_exception_reason text default null,
 p_payment_number text default null,p_payment_method text default null,p_payment_amount numeric default 0,p_payment_reference text default null
) returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
declare v_user uuid:=auth.uid(); v_business uuid; v_profile uuid; v_result jsonb; v_invoice uuid; v_stock record; v_line jsonb; v_qty numeric;
begin
 if v_user is null then raise exception 'Authentication required'; end if;
 select business_id into v_business from public.business_memberships where user_id=v_user and role='owner' order by created_at limit 1;
 if v_business is null then raise exception 'Owner workspace required'; end if;
 if p_quantity is null or p_quantity<=0 or p_quantity<>trunc(p_quantity) then raise exception 'Quantity must be a whole number greater than zero'; end if;
 if p_agreed_price is null or p_agreed_price<=0 or p_direct_cost_per_piece is null or p_direct_cost_per_piece<0 then raise exception 'Invalid DTF price or direct cost'; end if;
 if jsonb_typeof(p_details)<>'object' or p_details->>'module'<>'dtf_costing' then raise exception 'DTF costing details are required'; end if;
 if jsonb_typeof(coalesce(p_stock_lines,'[]'::jsonb))<>'array' then raise exception 'Stock lines must be an array'; end if;
 if coalesce(p_payment_amount,0)<0 or p_payment_amount>p_quantity*p_agreed_price then raise exception 'Invalid payment amount'; end if;
 if coalesce(p_allow_below_floor,false) and length(btrim(coalesce(p_exception_reason,'')))<8 then raise exception 'A below-floor exception reason must contain at least 8 characters'; end if;
 insert into public.costing_profiles(business_id,profile_name,version,is_active,components,direct_cost,margin_floor,full_cost_target)
 values(v_business,'__dtf_sale_'||replace(gen_random_uuid()::text,'-',''),1,true,
  jsonb_build_array(jsonb_build_object('name','DTF direct production costs','category','production','basis','per_piece','cost',round(p_direct_cost_per_piece,2))),
  round(p_direct_cost_per_piece,2),30,1.8) returning id into v_profile;
 v_result:=public.owner_create_custom_job_quick_sale(
  p_customer_id=>p_customer_id,p_invoice_number=>p_invoice_number,p_due_date=>p_due_date,
  p_description=>coalesce(nullif(btrim(p_description),''),'DTF printing and garment decoration'),
  p_dimensions=>'Mixed custom DTF dimensions and garment items',p_production_method=>'dtf',
  p_costing_profile_id=>v_profile,p_quantity=>p_quantity,p_agreed_price=>p_agreed_price,
  p_supply_arrangement=>'customer_supplies',p_other_direct_costs=>0,
  p_allow_below_floor=>coalesce(p_allow_below_floor,false),p_exception_reason=>p_exception_reason,
  p_payment_number=>p_payment_number,p_payment_method=>p_payment_method,p_payment_amount=>coalesce(p_payment_amount,0),p_payment_reference=>p_payment_reference);
 v_invoice:=(v_result->>'invoice_id')::uuid;
 update public.sales_invoice_items set direct_cost=round(p_direct_cost_per_piece*p_quantity,2),
  cost_snapshot=coalesce(cost_snapshot,'{}'::jsonb)||jsonb_build_object('pricing_source','dtf_costing','dtf_details',p_details,
   'direct_cost_per_piece',round(p_direct_cost_per_piece,2),'direct_cost_total',round(p_direct_cost_per_piece*p_quantity,2))
 where business_id=v_business and invoice_id=v_invoice;
 update public.production_jobs set actual_direct_cost=round(p_direct_cost_per_piece*p_quantity,2),
  notes=concat_ws(E'\\n',nullif(notes,''),'DTF production details: '||p_details::text),
  customer_supplied_items=coalesce(p_details->'garments' @> '[{"supply_source":"customer_supplies"}]'::jsonb,false)
 where business_id=v_business and invoice_id=v_invoice;
 for v_line in select value from jsonb_array_elements(coalesce(p_stock_lines,'[]'::jsonb)) loop
  begin v_qty:=(v_line->>'quantity')::numeric;
  exception when others then raise exception 'Invalid MJ stock quantity'; end;
  if v_qty<=0 or v_qty<>trunc(v_qty) then raise exception 'MJ-stocked item quantities must be whole numbers greater than zero'; end if;
  select * into v_stock from public.stock_items where id=(v_line->>'stock_item_id')::uuid and business_id=v_business and active for update;
  if not found then raise exception 'Selected MJ inventory item is not active or does not belong to this business'; end if;
  if v_stock.quantity_on_hand<v_qty then raise exception 'Insufficient stock for %: required %, available %',v_stock.item_name,v_qty,v_stock.quantity_on_hand; end if;
  perform private.apply_stock_movement(v_business,v_stock.id,-v_qty,v_stock.average_unit_cost,'job_issue');
  insert into public.audit_events(business_id,actor_user_id,event_type,entity_type,entity_id,details)
  values(v_business,v_user,'inventory.dtf_garment_stock_consumed','sales_invoice',v_invoice,
   jsonb_build_object('stock_item_id',v_stock.id,'item_name',v_stock.item_name,'quantity',v_qty,'unit',v_stock.unit,'movement_type','job_issue'));
 end loop;
 delete from public.costing_profiles where id=v_profile and business_id=v_business;
 insert into public.audit_events(business_id,actor_user_id,event_type,entity_type,entity_id,details)
 values(v_business,v_user,'dtf.quick_sale_created','sales_invoice',v_invoice,jsonb_build_object('pricing_source','dtf_costing','dtf_details',p_details));
 return v_result||jsonb_build_object('pricing_source','dtf_costing','direct_cost_total',round(p_direct_cost_per_piece*p_quantity,2));
end $$;

-- Carry DTF quote metadata into production and consume MJ garments only when
-- the accepted quotation is converted into a production job.
create or replace function private.apply_dtf_quote_production_details()
returns trigger language plpgsql security definer set search_path=public,private,pg_temp as $
declare v_line public.quotation_lines%rowtype; v_details jsonb; v_garment jsonb; v_stock public.stock_items%rowtype; v_qty numeric;
begin
 if new.quotation_id is null then return new; end if;
 select * into v_line from public.quotation_lines
 where quotation_id=new.quotation_id and business_id=new.business_id
  and details->'cost_snapshot'->>'pricing_source'='dtf_costing'
 order by line_number nulls first,id limit 1;
 if not found then return new; end if;
 v_details:=v_line.details->'cost_snapshot'->'dtf_details';
 update public.production_jobs set
  notes=concat_ws(E'\\n',nullif(notes,''),'DTF production details: '||v_details::text),
  actual_direct_cost=v_line.direct_cost,
  customer_supplied_items=coalesce(v_details->'garments' @> '[{"supply_source":"customer_supplies"}]'::jsonb,false)
 where id=new.id and business_id=new.business_id;
 for v_garment in select value from jsonb_array_elements(coalesce(v_details->'garments','[]'::jsonb)) loop
  if v_garment->>'supply_source'='mj_supplies' and nullif(v_garment->>'inventory_stock_item_id','') is not null then
   v_qty:=(v_garment->>'quantity')::numeric;
   if v_qty<=0 or v_qty<>trunc(v_qty) then raise exception 'DTF garment inventory quantities must be whole numbers greater than zero'; end if;
   select * into v_stock from public.stock_items
   where id=(v_garment->>'inventory_stock_item_id')::uuid and business_id=new.business_id and active for update;
   if not found then raise exception 'DTF garment stock item is inactive or unavailable'; end if;
   if v_stock.quantity_on_hand<v_qty then raise exception 'Insufficient stock for %: required %, available %',v_stock.item_name,v_qty,v_stock.quantity_on_hand; end if;
   perform private.apply_stock_movement(new.business_id,v_stock.id,-v_qty,v_stock.average_unit_cost,'job_issue');
   insert into public.audit_events(business_id,actor_user_id,event_type,entity_type,entity_id,details)
   values(new.business_id,auth.uid(),'inventory.dtf_garment_stock_consumed','production_job',new.id,
    jsonb_build_object('stock_item_id',v_stock.id,'item_name',v_stock.item_name,'quantity',v_qty,'unit',v_stock.unit,'movement_type','job_issue'));
  end if;
 end loop;
 return new;
end $;

drop trigger if exists trg_apply_dtf_quote_production_details on public.production_jobs;
create trigger trg_apply_dtf_quote_production_details
after insert on public.production_jobs
for each row execute function private.apply_dtf_quote_production_details();

revoke all on function private.apply_dtf_quote_production_details() from public,anon;
grant execute on function private.apply_dtf_quote_production_details() to authenticated;

revoke all on function public.owner_create_dtf_quotation(uuid,text,date,numeric,numeric,numeric,jsonb,boolean,text) from public,anon;
grant execute on function public.owner_create_dtf_quotation(uuid,text,date,numeric,numeric,numeric,jsonb,boolean,text) to authenticated;
revoke all on function public.owner_create_dtf_quick_sale(uuid,text,date,text,numeric,numeric,numeric,jsonb,jsonb,boolean,text,text,text,numeric,text) from public,anon;
grant execute on function public.owner_create_dtf_quick_sale(uuid,text,date,text,numeric,numeric,numeric,jsonb,jsonb,boolean,text,text,text,numeric,text) to authenticated;
