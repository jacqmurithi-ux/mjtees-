-- Extend the owner-managed catalogue with categories and explicit order minimums.
-- Seed names only: prices and costing profiles remain unapproved/unassigned.
alter table public.catalogue_items
 add column if not exists category text not null default 'Other',
 add column if not exists minimum_quantity numeric(14,3)
  check (minimum_quantity is null or minimum_quantity > 0);

comment on column public.catalogue_items.category is
 'Owner-managed catalogue category used for grouping and filtering.';
comment on column public.catalogue_items.minimum_quantity is
 'Optional minimum order quantity. This is distinct from the customer-supplied bulk-pricing consideration threshold.';

create or replace function public.owner_save_catalogue_item_v2(
 p_item_id uuid,
 p_item_code text,
 p_name text,
 p_description text,
 p_item_type text,
 p_category text,
 p_shop_location text,
 p_selling_method text,
 p_standard_unit_price numeric,
 p_price_unit text,
 p_minimum_quantity numeric,
 p_quantity_rules jsonb,
 p_is_active boolean,
 p_methods jsonb
) returns uuid
language plpgsql
security definer
set search_path=public,pg_temp
as $fn$
declare
 v_business uuid;
 v_item uuid;
 v_method jsonb;
 v_profile uuid;
begin
 if auth.uid() is null then raise exception 'Authentication required'; end if;
 select business_id into v_business from public.business_memberships
 where user_id=auth.uid() and role='owner' limit 1;
 if v_business is null then raise exception 'Owner workspace required'; end if;
 if length(btrim(coalesce(p_name,'')))=0 then raise exception 'Catalogue item name is required'; end if;
 if length(btrim(coalesce(p_category,'')))=0 then raise exception 'Catalogue category is required'; end if;
 if p_item_type not in ('product','service') then raise exception 'Invalid catalogue item type'; end if;
 if p_selling_method not in ('fixed_price','job_costed','quantity_tier') then raise exception 'Invalid selling method'; end if;
 if p_standard_unit_price is not null and p_standard_unit_price<=0 then raise exception 'Approved selling price must be greater than zero'; end if;
 if p_minimum_quantity is not null and p_minimum_quantity<=0 then raise exception 'Minimum quantity must be greater than zero'; end if;
 if p_quantity_rules is null or jsonb_typeof(p_quantity_rules)<>'object' then raise exception 'Quantity rules must be an object'; end if;
 if p_methods is null or jsonb_typeof(p_methods)<>'array' then raise exception 'Production methods must be an array'; end if;
 if p_shop_location is not null and p_shop_location not in ('shop_1','shop_2') then raise exception 'Invalid shop location'; end if;
 if p_item_id is null then
  insert into public.catalogue_items(business_id,item_code,name,description,item_type,category,shop_location,
   selling_method,standard_unit_price,price_unit,minimum_quantity,quantity_rules,is_active)
  values(v_business,nullif(btrim(coalesce(p_item_code,'')),''),btrim(p_name),coalesce(p_description,''),
   p_item_type,btrim(p_category),p_shop_location,p_selling_method,p_standard_unit_price,
   coalesce(nullif(btrim(p_price_unit),''),'item'),p_minimum_quantity,p_quantity_rules,coalesce(p_is_active,true))
  returning id into v_item;
 else
  update public.catalogue_items set
   item_code=nullif(btrim(coalesce(p_item_code,'')),''),
   name=btrim(p_name),description=coalesce(p_description,''),item_type=p_item_type,
   category=btrim(p_category),shop_location=p_shop_location,selling_method=p_selling_method,
   standard_unit_price=p_standard_unit_price,price_unit=coalesce(nullif(btrim(p_price_unit),''),'item'),
   minimum_quantity=p_minimum_quantity,quantity_rules=p_quantity_rules,
   is_active=coalesce(p_is_active,true),updated_at=now()
  where id=p_item_id and business_id=v_business returning id into v_item;
  if v_item is null then raise exception 'Catalogue item not found'; end if;
 end if;
 delete from public.catalogue_item_methods where business_id=v_business and catalogue_item_id=v_item;
 for v_method in select value from jsonb_array_elements(p_methods) loop
  if coalesce(v_method->>'production_method','') not in
   ('sublimation','dtf','screen_printing','embroidery','vinyl_cutting','other') then
   raise exception 'Unsupported production method';
  end if;
  v_profile:=nullif(v_method->>'costing_profile_id','')::uuid;
  if v_profile is not null and not exists(select 1 from public.costing_profiles
    where id=v_profile and business_id=v_business and is_active) then
   raise exception 'Costing profile must be active and belong to this business';
  end if;
  insert into public.catalogue_item_methods(business_id,catalogue_item_id,production_method,
   costing_profile_id,is_preferred,is_active,suitability_notes)
  values(v_business,v_item,v_method->>'production_method',v_profile,
   coalesce((v_method->>'is_preferred')::boolean,false),
   coalesce((v_method->>'is_active')::boolean,true),
   coalesce(v_method->>'suitability_notes',''));
 end loop;
 insert into public.audit_events(business_id,actor_user_id,event_type,entity_type,entity_id,details)
 values(v_business,auth.uid(),'catalogue.item_saved','catalogue_item',v_item,
  jsonb_build_object('item_type',p_item_type,'category',p_category,'selling_method',p_selling_method,
   'standard_unit_price',p_standard_unit_price,'minimum_quantity',p_minimum_quantity,
   'is_active',coalesce(p_is_active,true),'method_count',jsonb_array_length(p_methods)));
 return v_item;
end
$fn$;

revoke all on function public.owner_save_catalogue_item_v2(uuid,text,text,text,text,text,text,text,numeric,text,numeric,jsonb,boolean,jsonb) from public,anon;
grant execute on function public.owner_save_catalogue_item_v2(uuid,text,text,text,text,text,text,text,numeric,text,numeric,jsonb,boolean,jsonb) to authenticated;

-- The 10-piece threshold is for considering bulk pricing on customer-supplied items,
-- not a mandatory order minimum. No automatic discount is created.
with owner_businesses as (
 select distinct business_id from public.business_memberships where role='owner'
), seed(item_code,name,description,item_type,category,shop_location,selling_method,price_unit,methods) as (
 values
 ('APP-TSHIRT','T-shirts','Blank and decorated T-shirts; customer-supplied garments are also supported.','product','Apparel','shop_1','job_costed','piece',array['dtf','screen_printing','sublimation','embroidery']),
 ('APP-HOODIE','Hoodies','Blank and decorated hoodies.','product','Apparel','shop_1','job_costed','piece',array['dtf','screen_printing','embroidery']),
 ('APP-CAP','Caps','Blank and branded caps.','product','Headwear','shop_1','job_costed','piece',array['embroidery','dtf','screen_printing']),
 ('PRD-STICKER','Stickers','Printed and plotter-cut stickers.','product','Stickers','shop_1','job_costed','piece',array['vinyl_cutting','dtf','other']),
 ('PRD-VINYL','Self-adhesive vinyl','Coloured and printable self-adhesive vinyl products.','product','Vinyl','shop_1','job_costed','metre',array['vinyl_cutting','other']),
 ('SVC-SCREEN','Screen printing','Screen printing service.','service','Printing services','shop_2','job_costed','print',array['screen_printing']),
 ('SVC-SUBLIMATION','Sublimation','Sublimation printing service.','service','Printing services','shop_2','job_costed','print',array['sublimation']),
 ('SVC-VINYL','Vinyl cutting','Plotter-cut vinyl lettering, decals and graphics.','service','Printing services','shop_1','job_costed','metre',array['vinyl_cutting']),
 ('SVC-BRANDING','Branding','General product, garment and promotional branding service.','service','Branding','shop_1','job_costed','job',array['dtf','screen_printing','sublimation','embroidery','vinyl_cutting','other']),
 ('SVC-OTHER','Other printing services','Other approved printing and finishing services.','service','Printing services','shop_2','job_costed','job',array['other'])
), inserted as (
 insert into public.catalogue_items(
  business_id,item_code,name,description,item_type,category,shop_location,selling_method,
  standard_unit_price,price_unit,minimum_quantity,quantity_rules,is_active
 )
 select b.business_id,s.item_code,s.name,s.description,s.item_type,s.category,s.shop_location,s.selling_method,
  null,s.price_unit,null,
  jsonb_build_object('customer_supplied_bulk_pricing_minimum',10,'bulk_discount_automatic',false),
  true
 from owner_businesses b cross join seed s
 on conflict (business_id,item_code) do nothing
 returning business_id,id,item_code
)
insert into public.catalogue_item_methods(
 business_id,catalogue_item_id,production_method,is_preferred,is_active,suitability_notes
)
select ci.business_id,ci.id,m.method,
 row_number() over(partition by ci.id order by m.ordinality)=1,true,''
from inserted ci
join seed s on s.item_code=ci.item_code
cross join lateral unnest(s.methods) with ordinality as m(method,ordinality)
where ci.item_code like 'APP-%' or ci.item_code like 'PRD-%' or ci.item_code like 'SVC-%'
on conflict (business_id,catalogue_item_id,production_method) do nothing;

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
 if p_supply_arrangement is null or p_supply_arrangement not in('mj_supplies','customer_supplies') then raise exception 'Invalid supply arrangement'; end if;
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
 if v_item.minimum_quantity is not null and v_quantity<v_item.minimum_quantity then
  raise exception 'Minimum order quantity for % is % %',v_item.name,v_item.minimum_quantity,v_item.price_unit;
 end if;
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


notify pgrst,'reload schema';
