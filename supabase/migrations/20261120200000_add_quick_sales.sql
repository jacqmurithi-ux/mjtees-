-- Direct Quick Sales: create an invoice and optional payment without creating a quotation.
-- All ledger writes remain inside owner-authorised database functions. No stock is issued here.

create or replace function public.owner_create_quick_sale(
 p_customer_id uuid,
 p_invoice_number text,
 p_due_date date,
 p_catalogue_item_id uuid,
 p_production_method text,
 p_quantity numeric,
 p_unit_price numeric,
 p_supply_arrangement text,
 p_other_direct_costs numeric default 0,
 p_price_reason text default null,
 p_allow_below_floor boolean default false,
 p_exception_reason text default null,
 p_payment_number text default null,
 p_payment_method text default null,
 p_payment_amount numeric default 0,
 p_payment_reference text default null
) returns jsonb
language plpgsql
security definer
set search_path=public,pg_temp
as $fn$
declare
 v_user uuid:=auth.uid();
 v_business uuid;
 v_customer uuid;
 v_invoice uuid;
 v_payment uuid;
 v_item public.catalogue_items%rowtype;
 v_method text;
 v_profile uuid;
 v_profile_name text;
 v_profile_version integer;
 v_components jsonb;
 v_component jsonb;
 v_category text;
 v_basis text;
 v_component_cost numeric(14,2);
 v_cost numeric(14,2):=0;
 v_breakdown jsonb:='[]'::jsonb;
 v_snapshot jsonb;
 v_margin numeric(7,2);
 v_max_price numeric(14,2);
 v_unit_price numeric(14,2);
 v_quantity numeric(14,3);
 v_line_total numeric(14,2);
 v_payment_amount numeric(14,2):=coalesce(p_payment_amount,0);
 v_item_type text;
 v_description text;
begin
 if v_user is null then raise exception 'Authentication required'; end if;
 select business_id into v_business
 from public.business_memberships
 where user_id=v_user and role='owner'
 order by created_at limit 1;
 if v_business is null then raise exception 'Owner workspace required'; end if;

 -- Serialise walk-in customer creation and invoice numbering within this business.
 perform 1 from public.businesses where id=v_business for update;

 if p_customer_id is null then
  select id into v_customer from public.customers
  where business_id=v_business and lower(customer_name)='walk-in customer'
  order by created_at limit 1;
  if v_customer is null then
   insert into public.customers(business_id,customer_name,customer_type,created_by)
   values(v_business,'Walk-in Customer','individual',v_user)
   returning id into v_customer;
  end if;
 else
  select id into v_customer from public.customers
  where id=p_customer_id and business_id=v_business;
  if v_customer is null then raise exception 'Customer not found in this workspace'; end if;
 end if;

 if nullif(btrim(p_invoice_number),'') is null then raise exception 'Invoice number is required'; end if;
 if p_catalogue_item_id is null then raise exception 'Select an active catalogue item'; end if;
 if p_quantity is null or p_quantity<=0 then raise exception 'Quantity must be greater than zero'; end if;
 if p_unit_price is null or p_unit_price<=0 then raise exception 'Selling price must be greater than zero'; end if;
 if p_supply_arrangement not in('mj_supplies','customer_supplies') then raise exception 'Invalid supply arrangement'; end if;
 if coalesce(p_other_direct_costs,0)<0 then raise exception 'Other direct costs cannot be negative'; end if;
 if v_payment_amount<0 then raise exception 'Payment amount cannot be negative'; end if;

 select * into v_item from public.catalogue_items
 where id=p_catalogue_item_id and business_id=v_business and is_active for share;
 if not found then raise exception 'Catalogue item is inactive or does not belong to this workspace'; end if;
 if v_item.standard_unit_price is null then raise exception 'This catalogue item has no owner-approved standard price'; end if;
 if v_item.selling_method='quantity_tier' then raise exception 'Quantity-tier pricing is unavailable until approved quantity rules are configured'; end if;
 if v_item.selling_method not in('fixed_price','job_costed') then raise exception 'Unsupported catalogue selling method'; end if;

 select max_unit_selling_price into v_max_price
 from public.business_settings where business_id=v_business;
 v_unit_price:=round(p_unit_price,2);
 if v_max_price is not null and v_unit_price>v_max_price then
  raise exception 'Selling price exceeds the owner-set maximum price of KSh %',v_max_price;
 end if;
 if v_unit_price<v_item.standard_unit_price and length(btrim(coalesce(p_price_reason,'')))<3 then
  raise exception 'A reason is required when the actual selling price is below the catalogue-approved price';
 end if;

 select cm.production_method,cm.costing_profile_id
 into v_method,v_profile
 from public.catalogue_item_methods cm
 where cm.business_id=v_business and cm.catalogue_item_id=v_item.id
  and cm.is_active
  and (p_production_method is null or cm.production_method=p_production_method)
 order by cm.is_preferred desc,cm.production_method
 limit 1;
 if p_production_method is not null and v_method is null then
  raise exception 'Selected production method is not active for this catalogue item';
 end if;
 if p_production_method is null and exists(
  select 1 from public.catalogue_item_methods cm
  where cm.business_id=v_business and cm.catalogue_item_id=v_item.id and cm.is_active
 ) then
  if (select count(*) from public.catalogue_item_methods cm where cm.business_id=v_business and cm.catalogue_item_id=v_item.id and cm.is_active)>1
     and (select count(*) from public.catalogue_item_methods cm where cm.business_id=v_business and cm.catalogue_item_id=v_item.id and cm.is_active and cm.is_preferred)<>1 then
   raise exception 'Select a production method for this catalogue item';
  end if;
 end if;
 if v_item.selling_method='job_costed' and (v_method is null or v_profile is null) then
  raise exception 'This catalogue item requires an active production method linked to a costing profile';
 end if;

 v_quantity:=p_quantity;
 v_line_total:=round(v_unit_price*v_quantity,2);
 if v_profile is not null then
  select profile_name,version,components into v_profile_name,v_profile_version,v_components
  from public.costing_profiles
  where id=v_profile and business_id=v_business and is_active for share;
  if v_profile_name is null then raise exception 'The linked costing profile is not active'; end if;
  if jsonb_typeof(v_components)<>'array' then raise exception 'Costing profile components are invalid'; end if;
  for v_component in select value from jsonb_array_elements(v_components) loop
   v_category:=coalesce(v_component->>'category','production');
   v_basis:=coalesce(v_component->>'basis','per_piece');
   v_component_cost:=coalesce(nullif(v_component->>'cost','')::numeric,0);
   if v_component_cost<0 or v_basis not in('per_piece','per_job') then raise exception 'Invalid costing component'; end if;
   if v_category='blank_item' and p_supply_arrangement='customer_supplies' then continue; end if;
   if v_category not in('blank_item','production') then raise exception 'Invalid costing category'; end if;
   v_cost:=v_cost+case when v_basis='per_job' then v_component_cost else v_component_cost*v_quantity end;
   v_breakdown:=v_breakdown||jsonb_build_array(jsonb_build_object(
    'name',v_component->>'name','category',v_category,'basis',v_basis,
    'unit_cost',v_component_cost,'quantity',case when v_basis='per_job' then 1 else v_quantity end,
    'total_cost',case when v_basis='per_job' then v_component_cost else v_component_cost*v_quantity end
   ));
  end loop;
 elsif v_item.selling_method<>'fixed_price' then
  raise exception 'A costing profile is required for this catalogue item';
 end if;
 v_cost:=v_cost+coalesce(p_other_direct_costs,0);
 if coalesce(p_other_direct_costs,0)>0 then
  v_breakdown:=v_breakdown||jsonb_build_array(jsonb_build_object(
   'name','Other direct costs','basis','per_job','unit_cost',p_other_direct_costs,
   'quantity',1,'total_cost',p_other_direct_costs
  ));
 end if;
 v_margin:=case when v_line_total>0 then round(((v_line_total-v_cost)/v_line_total)*100,2) else 0 end;
 if v_cost>0 and v_margin<30 then
  if not coalesce(p_allow_below_floor,false) or length(btrim(coalesce(p_exception_reason,'')))<8 then
   raise exception 'Sale is below the 30%% gross-margin floor. An authorised exception and reason are required.';
  end if;
 end if;

 if v_payment_amount>v_line_total then raise exception 'Payment cannot exceed the invoice total'; end if;
 if v_payment_amount>0 and (
  nullif(btrim(coalesce(p_payment_number,'')),'') is null
  or p_payment_method not in('cash','mpesa_paybill')
 ) then raise exception 'A payment number and valid payment method are required for money received'; end if;

 v_snapshot:=jsonb_build_object(
  'profile_id',v_profile,'profile_name',v_profile_name,'profile_version',v_profile_version,
  'quantity',v_quantity,'supply_arrangement',p_supply_arrangement,
  'components',v_breakdown,'direct_cost_total',round(v_cost,2),
  'gross_margin_percent',v_margin,'catalogue_item_id',v_item.id,
  'catalogue_item_name',v_item.name,'selling_method',v_item.selling_method,
  'production_method',v_method,'catalogue_standard_price',v_item.standard_unit_price,
  'actual_unit_price',v_unit_price,'price_reason',nullif(btrim(p_price_reason),'')
 );
 v_description:=v_item.name||case when v_method is null then '' else ' · '||replace(v_method,'_',' ') end;
 v_item_type:=case when v_item.item_type in('blank_product','printing_service','custom_production','other') then v_item.item_type else 'other' end;

 insert into public.sales_invoices(
  business_id,customer_id,quotation_id,invoice_number,status,due_date,total,amount_paid,balance,created_by
 ) values(
  v_business,v_customer,null,btrim(p_invoice_number),
  case when v_payment_amount=v_line_total then 'paid' when v_payment_amount>0 then 'partially_paid' else 'sent' end,
  p_due_date,v_line_total,v_payment_amount,v_line_total-v_payment_amount,v_user
 ) returning id into v_invoice;

 insert into public.sales_invoice_items(
  business_id,invoice_id,description,quantity,unit_price,line_total,direct_cost,cost_snapshot,item_type
 ) values(
  v_business,v_invoice,v_description,v_quantity,v_unit_price,v_line_total,round(v_cost,2),v_snapshot,v_item_type
 );

 if v_payment_amount>0 then
  insert into public.payments(
   business_id,customer_id,payment_number,method,amount,reference_code,received_by
  ) values(
   v_business,v_customer,btrim(p_payment_number),p_payment_method,v_payment_amount,
   nullif(btrim(p_payment_reference),''),v_user
  ) returning id into v_payment;
  insert into public.payment_allocations(business_id,payment_id,invoice_id,amount)
  values(v_business,v_payment,v_invoice,v_payment_amount);
 end if;

 insert into public.audit_events(business_id,actor_user_id,event_type,entity_type,entity_id,details)
 values(v_business,v_user,'quick_sale.created','sales_invoice',v_invoice,jsonb_build_object(
  'invoice_number',p_invoice_number,'customer_id',v_customer,'catalogue_item_id',v_item.id,
  'quantity',v_quantity,'total',v_line_total,'direct_cost',round(v_cost,2),
  'gross_margin_percent',v_margin,'amount_received',v_payment_amount,'payment_id',v_payment,
  'price_reason',nullif(btrim(p_price_reason),''),'below_floor_exception_reason',
  case when v_cost>0 and v_margin<30 then btrim(p_exception_reason) end
 ));

 return jsonb_build_object(
  'invoice_id',v_invoice,'payment_id',v_payment,'invoice_number',p_invoice_number,
  'payment_number',case when v_payment is null then null else p_payment_number end,
  'customer_name',(select customer_name from public.customers where id=v_customer),
  'description',v_description,'quantity',v_quantity,'unit_price',v_unit_price,
  'total',v_line_total,'amount_paid',v_payment_amount,'balance',v_line_total-v_payment_amount,
  'payment_method',case when v_payment is null then null else p_payment_method end,
  'payment_reference',nullif(btrim(p_payment_reference),'')
 );
end
$fn$;

revoke all on function public.owner_create_quick_sale(uuid,text,date,uuid,text,numeric,numeric,text,numeric,text,boolean,text,text,text,numeric,text) from public,anon;
grant execute on function public.owner_create_quick_sale(uuid,text,date,uuid,text,numeric,numeric,text,numeric,text,boolean,text,text,text,numeric,text) to authenticated;

create or replace function public.owner_create_production_job_from_invoice(
 p_invoice_id uuid,p_job_number text,p_due_date date default null
) returns jsonb
language plpgsql
security definer
set search_path=public,pg_temp
as $fn$
declare
 i public.sales_invoices%rowtype;
 v_user uuid:=auth.uid();
 v_job_id uuid;
 v_customer_supplied boolean;
 v_job public.production_jobs%rowtype;
 v_job_name text;
begin
 if v_user is null then raise exception 'Authentication required'; end if;
 select * into i from public.sales_invoices where id=p_invoice_id for update;
 if not found or not exists(
  select 1 from public.business_memberships
  where business_id=i.business_id and user_id=v_user and role='owner'
 ) then raise exception 'Invoice not found'; end if;
 select * into v_job from public.production_jobs where invoice_id=i.id and business_id=i.business_id for update;
 if found then return jsonb_build_object('job_id',v_job.id,'invoice_id',i.id,'already_created',true); end if;
 if nullif(btrim(p_job_number),'') is null then raise exception 'Production job number is required'; end if;
 select coalesce(bool_or(coalesce(cost_snapshot->>'supply_arrangement','mj_supplies')='customer_supplies'),false),
        string_agg(description,', ' order by id)
 into v_customer_supplied,v_job_name
 from public.sales_invoice_items where invoice_id=i.id and business_id=i.business_id;
 if v_job_name is null then raise exception 'Invoice has no sale lines'; end if;
 insert into public.production_jobs(
  business_id,invoice_id,quotation_id,customer_id,job_number,job_name,
  customer_supplied_items,actual_direct_cost,due_at
 ) values(
  i.business_id,i.id,i.quotation_id,i.customer_id,btrim(p_job_number),
  'Production for '||v_job_name,v_customer_supplied,
  coalesce((select sum(direct_cost) from public.sales_invoice_items where invoice_id=i.id and business_id=i.business_id),0),
  case when p_due_date is null then null else (p_due_date::timestamp at time zone 'Africa/Nairobi') end
 ) returning id into v_job_id;
 insert into public.audit_events(business_id,actor_user_id,event_type,entity_type,entity_id,details)
 values(i.business_id,v_user,'production_job.created','production_job',v_job_id,
  jsonb_build_object('invoice_id',i.id,'quotation_id',i.quotation_id,'source','quick_sale_or_direct_invoice'));
 return jsonb_build_object('job_id',v_job_id,'invoice_id',i.id,'already_created',false);
end
$fn$;

revoke all on function public.owner_create_production_job_from_invoice(uuid,text,date) from public,anon;
grant execute on function public.owner_create_production_job_from_invoice(uuid,text,date) to authenticated;

notify pgrst,'reload schema';
