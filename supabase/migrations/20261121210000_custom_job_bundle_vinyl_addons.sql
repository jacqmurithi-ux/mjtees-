-- Extend the custom-job bundle so vinyl add-ons use the canonical vinyl
-- pricing/stock RPC while retaining one customer invoice and one payment.
-- Every nested RPC and stock movement runs in this outer transaction.
create or replace function public.owner_create_custom_job_bundle_quick_sale(
 p_customer_id uuid,
 p_invoice_number text,
 p_due_date date,
 p_description text,
 p_dimensions text,
 p_production_method text,
 p_costing_profile_id uuid,
 p_quantity numeric,
 p_agreed_price numeric,
 p_supply_arrangement text,
 p_other_direct_costs numeric default 0,
 p_allow_below_floor boolean default false,
 p_exception_reason text default null,
 p_catalogue_lines jsonb default '[]'::jsonb,
 p_payment_number text default null,
 p_payment_method text default null,
 p_payment_amount numeric default 0,
 p_payment_reference text default null
) returns jsonb
language plpgsql
security definer
set search_path=public,private,pg_temp
as $fn$
declare
 v_user uuid:=auth.uid();
 v_business uuid;
 v_customer uuid;
 v_invoice uuid;
 v_temp_invoice uuid;
 v_addon jsonb;
 v_addon_result jsonb;
 v_result jsonb;
 v_payment uuid;
 v_total numeric(14,2);
 v_paid numeric(14,2):=coalesce(p_payment_amount,0);
 v_items jsonb;
 v_line_count integer:=0;
 v_catalogue_item uuid;
 v_catalogue_name text;
 v_catalogue_price numeric(14,2);
 v_quantity numeric;
 v_unit_price numeric;
 v_supply text;
 v_length numeric;
 v_width numeric;
 v_roll_width numeric;
 v_area numeric;
 v_labour numeric;
 v_tape numeric;
 v_application numeric;
 v_other_costs numeric;
 v_material_cost numeric;
 v_direct_cost numeric;
 v_stock_consumption numeric(14,6);
 v_stock public.stock_items%rowtype;
 v_breakdown jsonb;
 v_pricing_details jsonb;
begin
 if v_user is null then raise exception 'Authentication required'; end if;
 select business_id into v_business
 from public.business_memberships
 where user_id=v_user and role='owner'
 order by created_at limit 1;
 if v_business is null then raise exception 'Owner workspace required'; end if;
 if p_catalogue_lines is null or jsonb_typeof(p_catalogue_lines)<>'array' then
  raise exception 'Catalogue add-ons must be supplied as a JSON array';
 end if;
 if jsonb_array_length(p_catalogue_lines)>20 then
  raise exception 'A custom sale can contain no more than 20 catalogue add-on lines';
 end if;
 if v_paid<0 then raise exception 'Payment amount cannot be negative'; end if;

 -- Create the primary custom-job invoice without payment. The existing
 -- canonical custom-job RPC retains owner, profile, costing and margin checks.
 v_result:=public.owner_create_custom_job_quick_sale(
  p_customer_id=>p_customer_id,p_invoice_number=>p_invoice_number,p_due_date=>p_due_date,
  p_description=>p_description,p_dimensions=>p_dimensions,p_production_method=>p_production_method,
  p_costing_profile_id=>p_costing_profile_id,p_quantity=>p_quantity,p_agreed_price=>p_agreed_price,
  p_supply_arrangement=>p_supply_arrangement,p_other_direct_costs=>coalesce(p_other_direct_costs,0),
  p_allow_below_floor=>coalesce(p_allow_below_floor,false),p_exception_reason=>p_exception_reason,
  p_payment_number=>null,p_payment_method=>null,p_payment_amount=>0,p_payment_reference=>null
 );
 v_invoice:=(v_result->>'invoice_id')::uuid;
 select customer_id into v_customer from public.sales_invoices
 where id=v_invoice and business_id=v_business for update;
 if v_customer is null then raise exception 'Could not resolve the customer for the custom-job invoice'; end if;

 for v_addon in select value from jsonb_array_elements(p_catalogue_lines) loop
  v_catalogue_item:=nullif(v_addon->>'catalogue_item_id','')::uuid;
  v_supply:=coalesce(nullif(v_addon->>'supply_arrangement',''),'mj_supplies');

  if coalesce(nullif(v_addon->>'production_method',''),'')='vinyl_cutting' then
   -- Validate the catalogue identity and active production method independently;
   -- the vinyl RPC is the authority for pricing/stock, not catalogue metadata.
   select name,standard_unit_price into v_catalogue_name,v_catalogue_price
   from public.catalogue_items
   where id=v_catalogue_item and business_id=v_business and is_active=true
   for share;
   if not found then raise exception 'Vinyl add-on catalogue item is missing or inactive'; end if;
   if exists(select 1 from public.catalogue_item_methods
      where business_id=v_business and catalogue_item_id=v_catalogue_item and is_active=true)
      and not exists(select 1 from public.catalogue_item_methods
      where business_id=v_business and catalogue_item_id=v_catalogue_item
       and production_method='vinyl_cutting' and is_active=true) then
    raise exception 'Vinyl cutting is not an active method for catalogue add-on %',v_catalogue_name;
   end if;

   v_quantity:=nullif(v_addon->>'quantity','')::numeric;
   v_unit_price:=nullif(v_addon->>'unit_price','')::numeric;
   if v_quantity is null or v_quantity<=0 or v_quantity<>trunc(v_quantity) then
    raise exception 'Vinyl add-on quantity must be a whole number greater than zero';
   end if;
   if v_unit_price is null or v_unit_price<=0 then raise exception 'Vinyl add-on price must be greater than zero'; end if;
   if v_catalogue_price is not null and v_unit_price<v_catalogue_price
      and length(btrim(coalesce(v_addon->>'price_reason','')))<3 then
    raise exception 'A reason is required when a vinyl add-on price is below its catalogue-approved price';
   end if;
   if v_supply not in('mj_supplies','customer_supplies') then raise exception 'Invalid vinyl add-on supply arrangement'; end if;

   v_length:=nullif(v_addon->>'vinyl_length_inches','')::numeric;
   v_width:=nullif(v_addon->>'vinyl_width_inches','')::numeric;
   v_roll_width:=nullif(v_addon->>'vinyl_roll_width_inches','')::numeric;
   v_labour:=coalesce(nullif(v_addon->>'vinyl_direct_labour','')::numeric,0);
   v_tape:=coalesce(nullif(v_addon->>'vinyl_transfer_tape_cost','')::numeric,0);
   v_application:=coalesce(nullif(v_addon->>'vinyl_application_cost','')::numeric,0);
   v_other_costs:=coalesce(nullif(v_addon->>'other_direct_costs','')::numeric,0);
   if v_length is null or v_length<=0 or v_width is null or v_width<=0
      or v_roll_width is null or v_roll_width<=0 then
    raise exception 'Vinyl add-on requires positive sticker dimensions and roll width';
   end if;
   if v_labour<0 or v_tape<0 or v_application<0 or v_other_costs<0 then
    raise exception 'Vinyl add-on direct costs cannot be negative';
   end if;
   v_area:=v_length*v_width;
   v_material_cost:=0;
   v_stock_consumption:=0;
   v_stock:=null;

   if v_supply='mj_supplies' then
    select * into v_stock from public.stock_items
    where id=nullif(v_addon->>'vinyl_stock_item_id','')::uuid
      and business_id=v_business and active=true
      and category='Vinyl sticker material' and unit='metre'
    for update;
    if not found then raise exception 'Selected active vinyl stock item was not found'; end if;
    v_stock_consumption:=ceil(((v_area*v_quantity)/(v_roll_width*39.37))*1000000)/1000000;
    if v_stock_consumption<=0 then raise exception 'Calculated vinyl consumption must be greater than zero'; end if;
    if v_stock.quantity_on_hand<v_stock_consumption then
     raise exception using message='Insufficient vinyl stock. Required: '||v_stock_consumption||' metre; available: '||v_stock.quantity_on_hand||' metre';
    end if;
    -- The current average inventory cost is read under the same row lock used
    -- by the stock movement. The browser cannot submit or override material cost.
    v_material_cost:=(v_area/(v_roll_width*39.37))*v_stock.average_unit_cost;
   end if;

   v_direct_cost:=round(v_material_cost+v_labour+v_tape+v_application+v_other_costs,2);
   v_breakdown:=jsonb_build_array(
    jsonb_build_object('name','Vinyl material by area','category','material','basis','per_piece','unit_cost',round(v_material_cost,2),'total_cost',round(v_material_cost,2)),
    jsonb_build_object('name','Cutting / weeding labour','category','labour','basis','per_piece','unit_cost',round(v_labour,2),'total_cost',round(v_labour,2)),
    jsonb_build_object('name','Transfer tape','category','material','basis','per_piece','unit_cost',round(v_tape,2),'total_cost',round(v_tape,2)),
    jsonb_build_object('name','Application labour','category','labour','basis','per_piece','unit_cost',round(v_application,2),'total_cost',round(v_application,2)),
    jsonb_build_object('name','Other direct job costs','category','job_expense','basis','per_piece','unit_cost',round(v_other_costs,2),'total_cost',round(v_other_costs,2))
   );
   v_pricing_details:=jsonb_build_object(
    'unit','inch','length',v_length,'width',v_width,'area_square_inches',v_area,
    'stock_length_inches',39.37,'stock_width_inches',v_roll_width,
    'inventory_stock_item_id',case when v_supply='mj_supplies' then v_stock.id else null end,
    'inventory_stock_item_name',case when v_supply='mj_supplies' then v_stock.item_name else null end,
    'inventory_average_unit_cost',case when v_supply='mj_supplies' then v_stock.average_unit_cost else 0 end,
    'inventory_quantity_on_hand',case when v_supply='mj_supplies' then v_stock.quantity_on_hand else null end,
    'material_cost_per_piece',round(v_material_cost,2),
    'direct_cost_total_per_piece',v_direct_cost,
    'quantity',v_quantity,'catalogue_item_id',v_catalogue_item,
    'catalogue_item_name',v_catalogue_name,
    'catalogue_standard_price',v_catalogue_price,
    'supply_arrangement',v_supply
   );

   v_addon_result:=public.owner_create_vinyl_sticker_quick_sale(
    p_customer_id=>v_customer,p_invoice_number=>'__BUNDLE__'||replace(gen_random_uuid()::text,'-',''),
    p_due_date=>p_due_date,p_description=>v_catalogue_name,
    p_dimensions=>v_length||' × '||v_width||' inches',
    p_quantity=>v_quantity,p_agreed_price=>v_unit_price,p_supply_arrangement=>v_supply,
    p_direct_cost_total=>v_direct_cost,p_direct_cost_breakdown=>v_breakdown,
    p_pricing_details=>v_pricing_details,
    p_allow_below_floor=>coalesce((v_addon->>'allow_below_floor')::boolean,false),
    p_exception_reason=>nullif(v_addon->>'exception_reason',''),
    p_payment_number=>null,p_payment_method=>null,p_payment_amount=>0,p_payment_reference=>null
   );
   v_temp_invoice:=(v_addon_result->>'invoice_id')::uuid;

   update public.sales_invoice_items
   set invoice_id=v_invoice,
       cost_snapshot=coalesce(cost_snapshot,'{}'::jsonb)||jsonb_build_object(
        'catalogue_item_id',v_catalogue_item,'catalogue_item_name',v_catalogue_name,
        'catalogue_standard_price',v_catalogue_price,
        'bundle_source','custom_job_catalogue_addon','bundle_addon_index',v_line_count+1
       )
   where business_id=v_business and invoice_id=v_temp_invoice;
   if not found then raise exception 'Could not attach the vinyl add-on to the custom-job invoice'; end if;

   -- Keep every vinyl pricing and stock audit event, but make the final invoice
   -- the canonical entity. The temporary invoice is removed before commit.
   update public.audit_events
   set entity_id=v_invoice,
       details=coalesce(details,'{}'::jsonb)||jsonb_build_object(
        'bundle_addon_index',v_line_count+1,
        'bundle_addon_catalogue_item_id',v_catalogue_item,
        'bundle_addon_catalogue_item_name',v_catalogue_name,
        'bundle_temp_invoice_id',v_temp_invoice
       )
   where business_id=v_business and entity_type='sales_invoice' and entity_id=v_temp_invoice;
   delete from public.sales_invoices where business_id=v_business and id=v_temp_invoice;
   if not found then raise exception 'Could not remove the temporary vinyl add-on invoice'; end if;
  else
   -- Non-vinyl catalogue lines retain the existing canonical catalogue RPC.
   v_addon_result:=public.owner_create_quick_sale(
    p_customer_id=>v_customer,
    p_invoice_number=>'__BUNDLE__'||replace(gen_random_uuid()::text,'-',''),
    p_due_date=>p_due_date,
    p_catalogue_item_id=>v_catalogue_item,
    p_production_method=>nullif(v_addon->>'production_method',''),
    p_quantity=>nullif(v_addon->>'quantity','')::numeric,
    p_unit_price=>nullif(v_addon->>'unit_price','')::numeric,
    p_supply_arrangement=>v_supply,
    p_other_direct_costs=>coalesce(nullif(v_addon->>'other_direct_costs','')::numeric,0),
    p_price_reason=>nullif(v_addon->>'price_reason',''),
    p_allow_below_floor=>coalesce((v_addon->>'allow_below_floor')::boolean,false),
    p_exception_reason=>nullif(v_addon->>'exception_reason',''),
    p_payment_number=>null,p_payment_method=>null,p_payment_amount=>0,p_payment_reference=>null
   );
   v_temp_invoice:=(v_addon_result->>'invoice_id')::uuid;
   update public.sales_invoice_items set invoice_id=v_invoice
   where business_id=v_business and invoice_id=v_temp_invoice;
   if not found then raise exception 'Could not attach a catalogue add-on to the custom-job invoice'; end if;
   delete from public.audit_events
   where business_id=v_business and entity_type='sales_invoice'
    and entity_id=v_temp_invoice and event_type='quick_sale.created';
   delete from public.sales_invoices where business_id=v_business and id=v_temp_invoice;
   if not found then raise exception 'Could not remove the temporary add-on invoice'; end if;
  end if;
  v_line_count:=v_line_count+1;
 end loop;

 select round(coalesce(sum(line_total),0),2),
        coalesce(jsonb_agg(jsonb_build_object(
         'description',description,'quantity',quantity,'unit_price',unit_price,
         'line_total',line_total,'item_type',item_type
        ) order by id),'[]'::jsonb)
 into v_total,v_items
 from public.sales_invoice_items
 where business_id=v_business and invoice_id=v_invoice;
 if v_total<=0 then raise exception 'The combined invoice total must be greater than zero'; end if;
 if v_paid>v_total then raise exception 'Payment cannot exceed the combined invoice total'; end if;
 if v_paid>0 and (nullif(btrim(coalesce(p_payment_number,'')),'') is null
   or p_payment_method not in('cash','mpesa_paybill')) then
  raise exception 'A payment number and valid payment method are required for money received';
 end if;

 -- Exactly one combined payment and allocation, after every add-on succeeds.
 if v_paid>0 then
  insert into public.payments(business_id,customer_id,payment_number,method,amount,reference_code,received_by)
  values(v_business,v_customer,btrim(p_payment_number),p_payment_method,v_paid,
   nullif(btrim(p_payment_reference),''),v_user) returning id into v_payment;
  insert into public.payment_allocations(business_id,payment_id,invoice_id,amount)
  values(v_business,v_payment,v_invoice,v_paid);
 end if;

 update public.sales_invoices
 set total=v_total,amount_paid=v_paid,balance=v_total-v_paid,
  status=case when v_paid=v_total then 'paid' when v_paid>0 then 'partially_paid' else 'sent' end
 where business_id=v_business and id=v_invoice;

 insert into public.audit_events(business_id,actor_user_id,event_type,entity_type,entity_id,details)
 values(v_business,v_user,'custom_job_bundle_quick_sale.created','sales_invoice',v_invoice,
  jsonb_build_object('source','custom_job_with_catalogue_addons','catalogue_addon_count',v_line_count,
   'invoice_total',v_total,'amount_received',v_paid,'payment_id',v_payment,
   'catalogue_lines',p_catalogue_lines));

 return v_result||jsonb_build_object('total',v_total,'amount_paid',v_paid,'balance',v_total-v_paid,
  'payment_id',v_payment,'payment_number',case when v_payment is null then null else p_payment_number end,
  'payment_method',case when v_payment is null then null else p_payment_method end,
  'payment_reference',case when v_payment is null then null else nullif(btrim(p_payment_reference),'') end,
  'items',v_items);
end
$fn$;

revoke all on function public.owner_create_custom_job_bundle_quick_sale(uuid,text,date,text,text,text,uuid,numeric,numeric,text,numeric,boolean,text,jsonb,text,text,numeric,text) from public,anon;
grant execute on function public.owner_create_custom_job_bundle_quick_sale(uuid,text,date,text,text,text,uuid,numeric,numeric,text,numeric,boolean,text,jsonb,text,text,numeric,text) to authenticated;

notify pgrst,'reload schema';
