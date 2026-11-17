-- Public, read-only published catalogue and owner-managed catalogue entries.
begin;

-- Replace the former unscoped view: it could mix published rows across businesses.
drop view if exists public.public_catalogue;

create or replace function private.owner_upsert_catalogue_item(
  p_business_id uuid,
  p_catalogue_item_id uuid,
  p_category_id uuid,
  p_name text,
  p_slug text,
  p_item_type text,
  p_description text,
  p_public_starting_price bigint,
  p_is_published boolean,
  p_display_order integer,
  p_request_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_id uuid;
begin
  if auth.uid() is null or not private.is_active_owner(p_business_id) then
    raise exception 'Active owner membership required' using errcode = '42501';
  end if;
  if length(btrim(coalesce(p_name,''))) not between 1 and 160
     or p_slug !~ '^[a-z0-9]+(?:-[a-z0-9]+)*$'
     or p_item_type not in ('product','service')
     or (p_public_starting_price is not null and p_public_starting_price < 0)
     or p_display_order is null or p_display_order < 0 or p_request_id is null then
    raise exception 'Invalid catalogue item details' using errcode = '22023';
  end if;
  if p_category_id is not null and not exists (
    select 1 from public.service_categories c
    where c.business_id=p_business_id and c.id=p_category_id and c.is_active
  ) then
    raise exception 'Active service category not found for this business' using errcode = '22023';
  end if;
  if p_catalogue_item_id is null then
    insert into public.catalogue_items(
      business_id,category_id,name,slug,item_type,description,public_starting_price,
      is_published,is_active,display_order
    ) values (
      p_business_id,p_category_id,btrim(p_name),p_slug,p_item_type,nullif(btrim(coalesce(p_description,'')),''),
      p_public_starting_price,coalesce(p_is_published,false),true,p_display_order
    ) returning id into v_id;
  else
    update public.catalogue_items set
      category_id=p_category_id,name=btrim(p_name),slug=p_slug,item_type=p_item_type,
      description=nullif(btrim(coalesce(p_description,'')),''),
      public_starting_price=p_public_starting_price,is_published=coalesce(p_is_published,false),
      display_order=p_display_order,updated_at=now()
    where business_id=p_business_id and id=p_catalogue_item_id and is_active
    returning id into v_id;
    if v_id is null then raise exception 'Catalogue item not found' using errcode = 'P0002'; end if;
  end if;
  insert into public.audit_events(business_id,actor_user_id,action,entity_type,entity_id,request_id,metadata)
  values(p_business_id,auth.uid(),case when p_catalogue_item_id is null then 'catalogue_item.created' else 'catalogue_item.updated' end,
    'catalogue_item',v_id,p_request_id,jsonb_build_object('published',coalesce(p_is_published,false),'item_type',p_item_type));
  return jsonb_build_object('id',v_id,'is_published',coalesce(p_is_published,false));
end;
$function$;

create or replace function private.owner_upsert_service_category(
  p_business_id uuid,p_category_id uuid,p_name text,p_slug text,p_description text,p_request_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare v_id uuid;
begin
  if auth.uid() is null or not private.is_active_owner(p_business_id) then
    raise exception 'Active owner membership required' using errcode = '42501';
  end if;
  if length(btrim(coalesce(p_name,''))) not between 1 and 120
     or p_slug !~ '^[a-z0-9]+(?:-[a-z0-9]+)*
  p_business_id uuid,p_catalogue_item_id uuid,p_category_id uuid,p_name text,p_slug text,
  p_item_type text,p_description text,p_public_starting_price bigint,p_is_published boolean,
  p_display_order integer,p_request_id uuid
) returns jsonb
language sql
security invoker
set search_path = ''
as $function$
  select private.owner_upsert_catalogue_item($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11);
$function$;

create or replace function private.get_public_catalogue(p_business_slug text)
returns table(
  name text,slug text,item_type text,description text,
  public_starting_price bigint,category_name text,display_order integer
)
language sql
stable
security definer
set search_path = ''
as $function$
  select ci.name,ci.slug,ci.item_type,ci.description,ci.public_starting_price,
    sc.name as category_name,ci.display_order
  from public.catalogue_items ci
  join public.businesses b on b.id=ci.business_id
  left join public.service_categories sc on sc.business_id=ci.business_id and sc.id=ci.category_id
  where b.slug=p_business_slug and b.is_active and ci.is_active and ci.is_published
    and (ci.category_id is null or sc.is_active)
  order by ci.display_order,ci.name;
$function$;

create or replace function public.owner_upsert_service_category(
  p_business_id uuid,p_category_id uuid,p_name text,p_slug text,p_description text,p_request_id uuid
) returns jsonb
language sql
security invoker
set search_path = ''
as $function$
  select private.owner_upsert_service_category($1,$2,$3,$4,$5,$6);
$function$;

create or replace function public.get_public_catalogue(p_business_slug text)
returns table(
  name text,slug text,item_type text,description text,
  public_starting_price bigint,category_name text,display_order integer
)
language sql
stable
security invoker
set search_path = ''
as $function$
  select * from private.get_public_catalogue($1);
$function$;

revoke all on function private.owner_upsert_service_category(uuid,uuid,text,text,text,uuid),
  private.owner_upsert_catalogue_item(uuid,uuid,uuid,text,text,text,text,bigint,boolean,integer,uuid)
  from public,anon,authenticated;
grant usage on schema private to authenticated;
grant execute on function private.owner_upsert_service_category(uuid,uuid,text,text,text,uuid),
  private.owner_upsert_catalogue_item(uuid,uuid,uuid,text,text,text,text,bigint,boolean,integer,uuid)
  to authenticated;
revoke all on function public.owner_upsert_service_category(uuid,uuid,text,text,text,uuid),
  public.owner_upsert_catalogue_item(uuid,uuid,uuid,text,text,text,text,bigint,boolean,integer,uuid)
  from public,anon;
grant execute on function public.owner_upsert_service_category(uuid,uuid,text,text,text,uuid),
  public.owner_upsert_catalogue_item(uuid,uuid,uuid,text,text,text,text,bigint,boolean,integer,uuid)
  to authenticated;
revoke all on function private.get_public_catalogue(text) from public,anon,authenticated;
grant usage on schema private to anon,authenticated;
grant execute on function private.get_public_catalogue(text) to anon,authenticated;
revoke all on function public.get_public_catalogue(text) from public;
grant execute on function public.get_public_catalogue(text) to anon,authenticated;

commit;
 or p_request_id is null then
    raise exception 'Invalid service category details' using errcode = '22023';
  end if;
  if p_category_id is null then
    insert into public.service_categories(business_id,name,slug,description,is_active)
    values(p_business_id,btrim(p_name),p_slug,nullif(btrim(coalesce(p_description,'')),''),true)
    returning id into v_id;
  else
    update public.service_categories set name=btrim(p_name),slug=p_slug,
      description=nullif(btrim(coalesce(p_description,'')),''),
      is_active=true,updated_at=now()
    where business_id=p_business_id and id=p_category_id
    returning id into v_id;
    if v_id is null then raise exception 'Service category not found' using errcode = 'P0002'; end if;
  end if;
  insert into public.audit_events(business_id,actor_user_id,action,entity_type,entity_id,request_id,metadata)
  values(p_business_id,auth.uid(),case when p_category_id is null then 'service_category.created' else 'service_category.updated' end,
    'service_category',v_id,p_request_id,jsonb_build_object('name',btrim(p_name),'slug',p_slug));
  return jsonb_build_object('id',v_id,'name',btrim(p_name),'slug',p_slug);
end;
$function$;

create or replace function public.owner_upsert_catalogue_item(
  p_business_id uuid,p_catalogue_item_id uuid,p_category_id uuid,p_name text,p_slug text,
  p_item_type text,p_description text,p_public_starting_price bigint,p_is_published boolean,
  p_display_order integer,p_request_id uuid
) returns jsonb
language sql
security invoker
set search_path = ''
as $function$
  select private.owner_upsert_catalogue_item($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11);
$function$;

create or replace function private.get_public_catalogue(p_business_slug text)
returns table(
  name text,slug text,item_type text,description text,
  public_starting_price bigint,category_name text,display_order integer
)
language sql
stable
security definer
set search_path = ''
as $function$
  select ci.name,ci.slug,ci.item_type,ci.description,ci.public_starting_price,
    sc.name as category_name,ci.display_order
  from public.catalogue_items ci
  join public.businesses b on b.id=ci.business_id
  left join public.service_categories sc on sc.business_id=ci.business_id and sc.id=ci.category_id
  where b.slug=p_business_slug and b.is_active and ci.is_active and ci.is_published
    and (ci.category_id is null or sc.is_active)
  order by ci.display_order,ci.name;
$function$;

create or replace function public.get_public_catalogue(p_business_slug text)
returns table(
  name text,slug text,item_type text,description text,
  public_starting_price bigint,category_name text,display_order integer
)
language sql
stable
security invoker
set search_path = ''
as $function$
  select * from private.get_public_catalogue($1);
$function$;

revoke all on function private.owner_upsert_catalogue_item(uuid,uuid,uuid,text,text,text,text,bigint,boolean,integer,uuid)
  from public,anon,authenticated;
grant usage on schema private to authenticated;
grant execute on function private.owner_upsert_catalogue_item(uuid,uuid,uuid,text,text,text,text,bigint,boolean,integer,uuid)
  to authenticated;
revoke all on function public.owner_upsert_catalogue_item(uuid,uuid,uuid,text,text,text,text,bigint,boolean,integer,uuid)
  from public,anon;
grant execute on function public.owner_upsert_catalogue_item(uuid,uuid,uuid,text,text,text,text,bigint,boolean,integer,uuid)
  to authenticated;
revoke all on function private.get_public_catalogue(text) from public,anon,authenticated;
grant usage on schema private to anon,authenticated;
grant execute on function private.get_public_catalogue(text) to anon,authenticated;
revoke all on function public.get_public_catalogue(text) from public;
grant execute on function public.get_public_catalogue(text) to anon,authenticated;

commit;
