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
from public.catalogue_items ci
join owner_businesses b on b.business_id=ci.business_id
join seed s on s.item_code=ci.item_code
cross join lateral unnest(s.methods) with ordinality as m(method,ordinality)
where ci.item_code like 'APP-%' or ci.item_code like 'PRD-%' or ci.item_code like 'SVC-%'
on conflict (business_id,catalogue_item_id,production_method) do nothing;

notify pgrst,'reload schema';
