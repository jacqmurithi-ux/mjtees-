-- Catalogue foundation for MJ Printing & Branding.
-- Prices and discounts are intentionally nullable/configurable: no unapproved rates are seeded.
create table if not exists public.catalogue_items (
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null references public.businesses(id) on delete cascade,
 item_code text,
 name text not null check (length(btrim(name)) > 0),
 description text not null default '',
 item_type text not null check (item_type in ('product','service')),
 shop_location text check (shop_location is null or shop_location in ('shop_1','shop_2')),
 selling_method text not null check (selling_method in ('fixed_price','job_costed','quantity_tier')),
 standard_unit_price numeric(14,2) check (standard_unit_price is null or standard_unit_price >= 0),
 price_unit text not null default 'item',
 quantity_rules jsonb not null default '{}'::jsonb check (jsonb_typeof(quantity_rules)='object'),
 is_active boolean not null default true,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 unique (business_id,item_code),
 unique (business_id,id)
);
comment on table public.catalogue_items is
 'Owner-managed product and service catalogue. Prices are not seeded; only owner-approved prices are stored.';
comment on column public.catalogue_items.quantity_rules is
 'Configurable quantity and bulk-eligibility rules. No discount percentages or rates are assumed.';
comment on column public.catalogue_items.standard_unit_price is
 'Owner-approved standard selling price. NULL means not yet priced/approved.';

create table if not exists public.catalogue_item_methods (
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null references public.businesses(id) on delete cascade,
 catalogue_item_id uuid not null,
 production_method text not null check (production_method in ('sublimation','dtf','screen_printing','embroidery','vinyl_cutting','other')),
 costing_profile_id uuid,
 is_preferred boolean not null default false,
 is_active boolean not null default true,
 suitability_notes text not null default '',
 created_at timestamptz not null default now(),
 unique (business_id,catalogue_item_id,production_method),
 foreign key (business_id,catalogue_item_id)
  references public.catalogue_items(business_id,id) on delete cascade,
 foreign key (costing_profile_id) references public.costing_profiles(id) on delete restrict
);
comment on table public.catalogue_item_methods is
 'Production methods available for each catalogue item, each optionally linked to its own costing profile.';

create index if not exists catalogue_items_business_active_idx
 on public.catalogue_items(business_id,is_active,name);
create index if not exists catalogue_item_methods_item_idx
 on public.catalogue_item_methods(business_id,catalogue_item_id,is_active);

alter table public.catalogue_items enable row level security;
alter table public.catalogue_item_methods enable row level security;

drop policy if exists catalogue_items_owner_read on public.catalogue_items;
create policy catalogue_items_owner_read on public.catalogue_items
 for select to authenticated using (
  exists(select 1 from public.business_memberships bm
   where bm.business_id=catalogue_items.business_id
    and bm.user_id=auth.uid() and bm.role='owner')
 );
drop policy if exists catalogue_item_methods_owner_read on public.catalogue_item_methods;
create policy catalogue_item_methods_owner_read on public.catalogue_item_methods
 for select to authenticated using (
  exists(select 1 from public.business_memberships bm
   where bm.business_id=catalogue_item_methods.business_id
    and bm.user_id=auth.uid() and bm.role='owner')
 );

revoke all on public.catalogue_items,public.catalogue_item_methods from anon,authenticated;
grant select on public.catalogue_items,public.catalogue_item_methods to authenticated;

create or replace function public.owner_save_catalogue_item(
 p_item_id uuid,
 p_item_code text,
 p_name text,
 p_description text,
 p_item_type text,
 p_shop_location text,
 p_selling_method text,
 p_standard_unit_price numeric,
 p_price_unit text,
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
 if p_item_type not in ('product','service') then raise exception 'Invalid catalogue item type'; end if;
 if p_selling_method not in ('fixed_price','job_costed','quantity_tier') then raise exception 'Invalid selling method'; end if;
 if p_standard_unit_price is not null and p_standard_unit_price<0 then raise exception 'Price cannot be negative'; end if;
 if p_quantity_rules is null or jsonb_typeof(p_quantity_rules)<>'object' then raise exception 'Quantity rules must be an object'; end if;
 if p_methods is null or jsonb_typeof(p_methods)<>'array' then raise exception 'Production methods must be an array'; end if;
 if p_shop_location is not null and p_shop_location not in ('shop_1','shop_2') then raise exception 'Invalid shop location'; end if;
 if p_item_id is null then
  insert into public.catalogue_items(business_id,item_code,name,description,item_type,shop_location,
   selling_method,standard_unit_price,price_unit,quantity_rules,is_active)
  values(v_business,nullif(btrim(coalesce(p_item_code,'')),''),btrim(p_name),coalesce(p_description,''),
   p_item_type,p_shop_location,p_selling_method,p_standard_unit_price,
   coalesce(nullif(btrim(p_price_unit),''),'item'),p_quantity_rules,coalesce(p_is_active,true))
  returning id into v_item;
 else
  update public.catalogue_items set
   item_code=nullif(btrim(coalesce(p_item_code,'')),''),
   name=btrim(p_name),description=coalesce(p_description,''),item_type=p_item_type,
   shop_location=p_shop_location,selling_method=p_selling_method,
   standard_unit_price=p_standard_unit_price,price_unit=coalesce(nullif(btrim(p_price_unit),''),'item'),
   quantity_rules=p_quantity_rules,is_active=coalesce(p_is_active,true),updated_at=now()
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
    where id=v_profile and business_id=v_business) then
   raise exception 'Costing profile must belong to this business';
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
  jsonb_build_object('item_type',p_item_type,'selling_method',p_selling_method,
   'standard_unit_price',p_standard_unit_price,'is_active',coalesce(p_is_active,true),
   'method_count',jsonb_array_length(p_methods)));
 return v_item;
end
$fn$;

revoke all on function public.owner_save_catalogue_item(uuid,text,text,text,text,text,text,numeric,text,jsonb,boolean,jsonb) from public,anon;
grant execute on function public.owner_save_catalogue_item(uuid,text,text,text,text,text,text,numeric,text,jsonb,boolean,jsonb) to authenticated;

notify pgrst,'reload schema';
