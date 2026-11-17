-- MJ Tees — versioned costing, quotations and one-time quote acceptance.
begin;

create extension if not exists pgcrypto with schema extensions;

alter table public.quotation_items add column if not exists stock_item_id uuid;
do $fk$
begin
  if not exists(select 1 from pg_constraint where conname='quotation_items_stock_item_fk') then
    alter table public.quotation_items add constraint quotation_items_stock_item_fk
      foreign key (business_id,stock_item_id) references public.stock_items(business_id,id) on delete restrict;
  end if;
  if not exists(select 1 from pg_constraint where conname='order_items_business_order_item_uq') then
    alter table public.order_items add constraint order_items_business_order_item_uq unique(business_id,order_id,id);
  end if;
  if not exists(select 1 from pg_constraint where conname='discount_allocation_order_line_fk') then
    alter table public.order_item_discount_allocations add constraint discount_allocation_order_line_fk
      foreign key (business_id,order_id,order_item_id)
      references public.order_items(business_id,order_id,id) on delete restrict;
  end if;
end;
$fk$;

alter table public.quotation_items
  add constraint quotation_items_total_consistency
  check (line_total = round(quantity*unit_price)::bigint-line_discount);
alter table public.order_items
  add constraint order_items_total_consistency
  check (line_total = round(quantity*unit_price)::bigint-line_discount);

create unique index if not exists product_costing_profile_version_uq
on public.product_costing_profiles(
  business_id,
  coalesce(catalogue_item_id,'00000000-0000-0000-0000-000000000000'::uuid),
  coalesce(category_id,'00000000-0000-0000-0000-000000000000'::uuid),
  sale_mode,
  coalesce(production_method_id,'00000000-0000-0000-0000-000000000000'::uuid),
  version
);

create unique index if not exists order_item_discount_allocation_version_uq
on public.order_item_discount_allocations(business_id,order_id,order_item_id,discount_source,allocation_version);

create or replace function private.guard_order_item_discount_allocation()
returns trigger language plpgsql security definer set search_path=''
as $$
declare v_item public.order_items%rowtype;
begin
  select * into v_item from public.order_items
  where business_id=new.business_id and order_id=new.order_id and id=new.order_item_id;
  if not found or new.pre_discount_line_amount<>round(v_item.quantity*v_item.unit_price)::bigint then
    raise exception using errcode='23514',message='Discount allocation must match its order line pre-discount value';
  end if;
  if new.discount_source='line_discount' and new.allocated_discount_amount<>v_item.line_discount then
    raise exception using errcode='23514',message='Line discount allocation must equal the accepted line discount';
  end if;
  if new.allocated_discount_amount>new.pre_discount_line_amount then
    raise exception using errcode='23514',message='Discount allocation exceeds pre-discount line amount';
  end if;
  return new;
end;
$$;
create trigger order_item_discount_allocation_guard
before insert on public.order_item_discount_allocations
for each row execute function private.guard_order_item_discount_allocation();
create trigger order_item_discount_allocations_immutable
before update or delete on public.order_item_discount_allocations
for each row execute function private.reject_ledger_mutation();

create or replace function private.owner_create_costing_profile(
  p_business_id uuid,p_catalogue_item_id uuid,p_category_id uuid,p_sale_mode text,
  p_production_method_id uuid,p_components jsonb,p_request_id uuid
) returns jsonb
language plpgsql security definer set search_path=''
as $$
declare
  v_actor uuid; v_cached jsonb; v_payload jsonb; v_profile uuid; v_version integer;
  v_component jsonb; v_stock uuid; v_type text; v_driver text; v_factor numeric;
  v_waste numeric; v_fixed bigint; v_result jsonb; v_effective timestamptz:=clock_timestamp(); v_lock_key text;
begin
  v_actor:=private.assert_active_owner(p_business_id);
  if (p_catalogue_item_id is null and p_category_id is null)
    or p_sale_mode is null or p_sale_mode not in ('blank','value_added')
    or p_components is null or jsonb_typeof(p_components) is distinct from 'array'
    or jsonb_array_length(p_components) not between 1 and 100 then
    raise exception using errcode='22023',message='Cost profile requires a target, sale mode and valid components';
  end if;
  if p_catalogue_item_id is not null and not exists(select 1 from public.catalogue_items where business_id=p_business_id and id=p_catalogue_item_id) then
    raise exception using errcode='22023',message='Catalogue item belongs to another business';
  end if;
  if p_category_id is not null and not exists(select 1 from public.service_categories where business_id=p_business_id and id=p_category_id) then
    raise exception using errcode='22023',message='Category belongs to another business';
  end if;
  if p_production_method_id is not null and not exists(select 1 from public.production_methods where id=p_production_method_id and is_active) then
    raise exception using errcode='22023',message='Production method is inactive or unknown';
  end if;
  v_payload:=jsonb_build_object('catalogue_item_id',p_catalogue_item_id,'category_id',p_category_id,
    'sale_mode',p_sale_mode,'production_method_id',p_production_method_id,'components',p_components);
  v_cached:=private.begin_idempotent_request(p_business_id,'create_costing_profile',p_request_id,v_payload);
  if v_cached is not null then return v_cached; end if;

  v_lock_key:=p_business_id::text||':'||coalesce(p_catalogue_item_id::text,'-')||':'||coalesce(p_category_id::text,'-')||':'||p_sale_mode||':'||coalesce(p_production_method_id::text,'-');
  perform pg_advisory_xact_lock(hashtextextended(v_lock_key,0));
  select coalesce(max(version),0)+1 into v_version from public.product_costing_profiles
  where business_id=p_business_id and catalogue_item_id is not distinct from p_catalogue_item_id
    and category_id is not distinct from p_category_id and sale_mode=p_sale_mode
    and production_method_id is not distinct from p_production_method_id;

  update public.product_costing_profiles set is_active=false,effective_to=v_effective
  where business_id=p_business_id and catalogue_item_id is not distinct from p_catalogue_item_id
    and category_id is not distinct from p_category_id and sale_mode=p_sale_mode
    and production_method_id is not distinct from p_production_method_id
    and is_active=true and effective_from<v_effective;

  insert into public.product_costing_profiles(business_id,catalogue_item_id,category_id,sale_mode,
    production_method_id,version,effective_from,is_active)
  values(p_business_id,p_catalogue_item_id,p_category_id,p_sale_mode,p_production_method_id,v_version,v_effective,true)
  returning id into v_profile;

  for v_component in select value from jsonb_array_elements(p_components) loop
    v_type:=v_component->>'component_type';
    v_driver:=v_component->>'driver_type';
    v_stock:=nullif(v_component->>'stock_item_id','')::uuid;
    v_factor:=coalesce(nullif(v_component->>'factor','')::numeric,1);
    v_waste:=coalesce(nullif(v_component->>'expected_waste_percent','')::numeric,0);
    v_fixed:=coalesce(nullif(v_component->>'fixed_cost','')::bigint,0);
    if v_type not in ('blank_item','meter_material','area_material','consumable','machine_time','labour_time','outsourced_service','setup','packaging','other')
      or v_driver not in ('per_piece','per_order','per_metre','per_square_metre','per_minute','per_hour','fixed_setup','manual')
      or length(btrim(coalesce(v_component->>'unit','')))=0 or v_factor<0 or v_waste<0 or v_waste>100 or v_fixed<0 then
      raise exception using errcode='22023',message='Invalid costing component definition';
    end if;
    if v_stock is not null and not exists(select 1 from public.stock_items where business_id=p_business_id and id=v_stock and is_active) then
      raise exception using errcode='22023',message='Costing component stock item is invalid or inactive';
    end if;
    insert into public.costing_components(business_id,profile_id,component_type,stock_item_id,unit,
      driver_type,factor,expected_waste_percent,fixed_cost)
    values(p_business_id,v_profile,v_type,v_stock,btrim(v_component->>'unit'),v_driver,v_factor,v_waste,v_fixed);
  end loop;

  v_result:=jsonb_build_object('profile_id',v_profile,'version',v_version,'component_count',jsonb_array_length(p_components));
  perform private.finish_idempotent_request(p_business_id,'create_costing_profile',p_request_id,v_result);
  perform private.write_audit(p_business_id,v_actor,'costing_profile.created','costing_profile',v_profile,p_request_id,
    jsonb_build_object('version',v_version,'sale_mode',p_sale_mode,'component_count',jsonb_array_length(p_components)));
  return v_result;
end;
$$;

create or replace function private.owner_upsert_pricing_rule(
  p_business_id uuid,p_rule_id uuid,p_category_id uuid,p_catalogue_item_id uuid,p_name text,
  p_markup_method text,p_markup_value numeric,p_effective_from date,p_effective_to date,
  p_is_active boolean,p_request_id uuid
) returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_actor uuid; v_cached jsonb; v_payload jsonb; v_id uuid; v_created boolean; v_result jsonb;
begin
  v_actor:=private.assert_active_owner(p_business_id);
  if p_category_id is null and p_catalogue_item_id is null
    or length(btrim(coalesce(p_name,''))) not between 1 and 120
    or p_markup_method is null or p_markup_method not in ('percentage_on_cost','margin_on_price','fixed_amount','manual')
    or p_effective_from is null or (p_effective_to is not null and p_effective_to<p_effective_from)
    or (p_markup_method in ('percentage_on_cost','margin_on_price','fixed_amount') and (p_markup_value is null or p_markup_value<0))
    or (p_markup_method='margin_on_price' and p_markup_value>=100) then
    raise exception using errcode='22023',message='Invalid pricing rule';
  end if;
  if p_category_id is not null and not exists(select 1 from public.service_categories where business_id=p_business_id and id=p_category_id) then
    raise exception using errcode='22023',message='Pricing category belongs to another business';
  end if;
  if p_catalogue_item_id is not null and not exists(select 1 from public.catalogue_items where business_id=p_business_id and id=p_catalogue_item_id) then
    raise exception using errcode='22023',message='Pricing catalogue item belongs to another business';
  end if;
  v_lock_key:=p_business_id::text||':'||coalesce(p_category_id::text,'-')||':'||coalesce(p_catalogue_item_id::text,'-');
  perform pg_advisory_xact_lock(hashtextextended(v_lock_key,0));
  if exists(select 1 from public.pricing_rules r where r.business_id=p_business_id and r.id is distinct from p_rule_id
    and r.category_id is not distinct from p_category_id and r.catalogue_item_id is not distinct from p_catalogue_item_id
    and daterange(r.effective_from,coalesce(r.effective_to,'infinity'::date),'[]')
      && daterange(p_effective_from,coalesce(p_effective_to,'infinity'::date),'[]')) then
    raise exception using errcode='23P01',message='Pricing rule effective dates overlap an existing rule for this target';
  end if;
  v_payload:=jsonb_build_object('rule_id',p_rule_id,'category_id',p_category_id,'catalogue_item_id',p_catalogue_item_id,
    'name',p_name,'markup_method',p_markup_method,'markup_value',p_markup_value,'effective_from',p_effective_from,
    'effective_to',p_effective_to,'is_active',coalesce(p_is_active,true));
  v_cached:=private.begin_idempotent_request(p_business_id,'upsert_pricing_rule',p_request_id,v_payload);
  if v_cached is not null then return v_cached; end if;
  if p_rule_id is null then
    insert into public.pricing_rules(business_id,category_id,catalogue_item_id,name,cost_basis,markup_method,markup_value,
      effective_from,effective_to,is_active,created_by)
    values(p_business_id,p_category_id,p_catalogue_item_id,btrim(p_name),'estimated_unit_cost',p_markup_method,p_markup_value,
      p_effective_from,p_effective_to,coalesce(p_is_active,true),v_actor)
    returning id into v_id;
    v_created:=true;
  else
    update public.pricing_rules set category_id=p_category_id,catalogue_item_id=p_catalogue_item_id,name=btrim(p_name),
      cost_basis='estimated_unit_cost',markup_method=p_markup_method,markup_value=p_markup_value,
      effective_from=p_effective_from,effective_to=p_effective_to,is_active=coalesce(p_is_active,true)
    where business_id=p_business_id and id=p_rule_id returning id into v_id;
    if v_id is null then raise exception using errcode='P0002',message='Pricing rule not found'; end if;
    v_created:=false;
  end if;
  v_result:=jsonb_build_object('pricing_rule_id',v_id,'created',v_created);
  perform private.finish_idempotent_request(p_business_id,'upsert_pricing_rule',p_request_id,v_result);
  perform private.write_audit(p_business_id,v_actor,case when v_created then 'pricing_rule.created' else 'pricing_rule.updated' end,
    'pricing_rule',v_id,p_request_id,'{}'::jsonb);
  return v_result;
end;
$$;

create or replace function private.estimate_line_cost(
  p_business_id uuid,p_catalogue_item_id uuid,p_category_id uuid,p_stock_item_id uuid,
  p_sale_mode text,p_production_method_id uuid,p_quantity numeric,p_customer_supplies_item boolean,
  p_specification jsonb
) returns jsonb language plpgsql security definer set search_path=''
as $$
declare
  v_profile public.product_costing_profiles%rowtype;
  v_component record;
  v_driver numeric;
  v_consumption numeric;
  v_unit_cost bigint;
  v_cost bigint;
  v_total bigint:=0;
  v_breakdown jsonb:='[]'::jsonb;
  v_spec jsonb:=coalesce(p_specification,'{}'::jsonb);
  v_stock uuid;
  v_manual numeric;
begin
  select * into v_profile from public.product_costing_profiles p
  where p.business_id=p_business_id and p.sale_mode=p_sale_mode and p.is_active
    and p.effective_from<=clock_timestamp() and (p.effective_to is null or p.effective_to>clock_timestamp())
    and (p.catalogue_item_id=p_catalogue_item_id or (p.catalogue_item_id is null and p.category_id=p_category_id))
    and (p.production_method_id is null or p.production_method_id=p_production_method_id)
  order by (p.catalogue_item_id is not null) desc,(p.production_method_id is not null) desc,p.version desc
  limit 1;

  if not found then
    if p_sale_mode='blank' and p_stock_item_id is not null and not coalesce(p_customer_supplies_item,false) then
      select current_average_unit_cost into v_unit_cost from public.stock_items
      where business_id=p_business_id and id=p_stock_item_id and is_active;
      if not found then raise exception using errcode='22023',message='Blank stock SKU is invalid'; end if;
      v_total:=round(p_quantity*v_unit_cost)::bigint;
      return jsonb_build_object('profile_id',null,'profile_version',null,'estimated_total_cost',v_total,
        'estimated_unit_cost',round(v_total/p_quantity)::bigint,'calculation_version','mj-costing-v1',
        'components',jsonb_build_array(jsonb_build_object('component_type','blank_item','stock_item_id',p_stock_item_id,
          'quantity',p_quantity,'unit_cost',v_unit_cost,'cost',v_total)));
    end if;
    raise exception using errcode='22023',message='An active versioned costing profile is required before this quotation can be priced';
  end if;

  for v_component in
    select c.* from public.costing_components c
    where c.business_id=p_business_id and c.profile_id=v_profile.id
    order by c.created_at,c.id
  loop
    if v_component.component_type='blank_item' and coalesce(p_customer_supplies_item,false) then
      continue;
    end if;
    if v_component.driver_type='manual' then
      v_stock:=null;
      v_manual:=nullif(v_spec->'manual_component_costs'->>v_component.id::text,'')::numeric;
      if v_manual is null or v_manual<0 then
        raise exception using errcode='22023',message='A non-negative manual cost is required for each manual costing component';
      end if;
      v_driver:=1;
      v_consumption:=0;
      v_cost:=round(v_manual)::bigint;
      v_unit_cost:=0;
    else
      v_driver:=case v_component.driver_type
        when 'per_piece' then p_quantity
        when 'per_order' then 1
        when 'per_metre' then nullif(v_spec->>'linear_metres','')::numeric
        when 'per_square_metre' then nullif(v_spec->>'area_square_metres','')::numeric
        when 'per_minute' then nullif(v_spec->>'machine_minutes','')::numeric
        when 'per_hour' then nullif(v_spec->>'labour_hours','')::numeric
        when 'fixed_setup' then 1
        else null end;
      if v_driver is null and v_component.factor>0 then
        raise exception using errcode='22023',message='Production specification is missing a driver required by the costing profile';
      end if;
      v_consumption:=coalesce(v_driver,0)*v_component.factor*(1+(v_component.expected_waste_percent/100));
      v_stock:=case when v_component.component_type='blank_item' and p_stock_item_id is not null
        then p_stock_item_id else v_component.stock_item_id end;
      if v_stock is not null then
        select current_average_unit_cost into v_unit_cost from public.stock_items
        where business_id=p_business_id and id=v_stock and is_active;
        if not found then raise exception using errcode='22023',message='Costing component references an inactive stock SKU'; end if;
        v_cost:=round(v_consumption*v_unit_cost)::bigint+v_component.fixed_cost;
      else
        v_unit_cost:=v_component.fixed_cost;
        v_cost:=round(v_consumption*v_component.fixed_cost)::bigint;
      end if;
    end if;
    v_total:=v_total+v_cost;
    v_breakdown:=v_breakdown||jsonb_build_array(jsonb_build_object(
      'component_id',v_component.id,'component_type',v_component.component_type,'stock_item_id',coalesce(v_stock,v_component.stock_item_id),
      'driver_type',v_component.driver_type,'driver_quantity',v_driver,'factor',v_component.factor,
      'expected_waste_percent',v_component.expected_waste_percent,'consumption_quantity',v_consumption,
      'unit_cost_snapshot',v_unit_cost,'component_cost',v_cost
    ));
  end loop;

  return jsonb_build_object('profile_id',v_profile.id,'profile_version',v_profile.version,
    'estimated_total_cost',v_total,'estimated_unit_cost',round(v_total/p_quantity)::bigint,
    'calculation_version','mj-costing-v1','inputs',v_spec,'components',v_breakdown);
end;
$$;

create or replace function private.owner_create_quotation(
  p_business_id uuid,p_customer_id uuid,p_enquiry_id uuid,p_lines jsonb,
  p_expires_at timestamptz,p_customer_notes text,p_internal_notes text,p_request_id uuid
) returns jsonb language plpgsql security definer set search_path=''
as $$
declare
  v_actor uuid; v_cached jsonb; v_payload jsonb; v_quote uuid; v_number text; v_line jsonb;
  v_catalogue public.catalogue_items%rowtype; v_rule public.pricing_rules%rowtype;
  v_catalogue_id uuid; v_category_id uuid; v_stock_id uuid; v_method uuid;
  v_description text; v_unit text; v_quantity numeric; v_price bigint; v_input_price bigint;
  v_discount bigint; v_gross bigint; v_line_total bigint; v_subtotal bigint:=0; v_discounts bigint:=0; v_total bigint:=0;
  v_sale_mode text; v_customer_supplies boolean; v_spec jsonb; v_estimate jsonb; v_unit_cost numeric;
  v_price_snapshot jsonb; v_result jsonb; v_item_type text;
begin
  v_actor:=private.assert_active_owner(p_business_id);
  if not exists(select 1 from public.customers where business_id=p_business_id and id=p_customer_id and archived_at is null)
    or (p_enquiry_id is not null and not exists(select 1 from public.enquiries where business_id=p_business_id and id=p_enquiry_id))
    or p_lines is null or jsonb_typeof(p_lines) is distinct from 'array' or jsonb_array_length(p_lines) not between 1 and 100
    or (p_expires_at is not null and p_expires_at<=now())
    or length(coalesce(p_customer_notes,''))>4000 or length(coalesce(p_internal_notes,''))>4000 then
    raise exception using errcode='22023',message='Invalid quotation header or lines';
  end if;
  v_payload:=jsonb_build_object('customer_id',p_customer_id,'enquiry_id',p_enquiry_id,'lines',p_lines,
    'expires_at',p_expires_at,'customer_notes',p_customer_notes,'internal_notes',p_internal_notes);
  v_cached:=private.begin_idempotent_request(p_business_id,'create_quotation',p_request_id,v_payload);
  if v_cached is not null then return v_cached; end if;

  v_number:=private.next_document_number(p_business_id,'quote');
  insert into public.quotations(business_id,quote_number,customer_id,enquiry_id,status,expires_at,
    customer_notes,internal_notes,created_by)
  values(p_business_id,v_number,p_customer_id,p_enquiry_id,'draft',p_expires_at,p_customer_notes,p_internal_notes,v_actor)
  returning id into v_quote;

  for v_line in select value from jsonb_array_elements(p_lines) loop
    v_catalogue_id:=nullif(v_line->>'catalogue_item_id','')::uuid;
    v_category_id:=nullif(v_line->>'category_id','')::uuid;
    v_stock_id:=nullif(v_line->>'stock_item_id','')::uuid;
    v_method:=nullif(v_line->>'production_method_id','')::uuid;
    v_quantity:=nullif(v_line->>'quantity','')::numeric;
    v_input_price:=nullif(v_line->>'unit_price','')::bigint;
    v_discount:=coalesce(nullif(v_line->>'line_discount','')::bigint,0);
    v_sale_mode:=v_line->>'sale_mode';
    v_customer_supplies:=coalesce((v_line->>'customer_supplies_item')::boolean,false);
    v_spec:=coalesce(v_line->'production_specification','{}'::jsonb);
    v_description:=nullif(btrim(v_line->>'description'),'');
    v_unit:=nullif(btrim(v_line->>'unit'),'');
    v_item_type:=null;

    if v_quantity is null or v_quantity<=0 or v_sale_mode not in ('blank','value_added')
      or v_sale_mode is null or v_discount<0 or v_unit is null or length(v_unit)>24 or jsonb_typeof(v_spec) is distinct from 'object'
      or (v_sale_mode='blank' and (v_method is not null or v_customer_supplies))
      or (v_customer_supplies and v_stock_id is not null) then
      raise exception using errcode='22023',message='Invalid quotation line details';
    end if;
    if v_catalogue_id is not null then
      select * into v_catalogue from public.catalogue_items
      where business_id=p_business_id and id=v_catalogue_id and is_active;
      if not found then raise exception using errcode='22023',message='Catalogue item is inactive or outside this business'; end if;
      v_item_type:=v_catalogue.item_type;
      if v_category_id is not null and v_category_id is distinct from v_catalogue.category_id then
        raise exception using errcode='22023',message='Quotation category does not match catalogue item';
      end if;
      v_category_id:=v_catalogue.category_id;
      v_description:=coalesce(v_description,v_catalogue.name);
    end if;
    if v_description is null or length(v_description)>240 then
      raise exception using errcode='22023',message='Quotation line description is required';
    end if;
    if v_category_id is not null and not exists(select 1 from public.service_categories where business_id=p_business_id and id=v_category_id and is_active) then
      raise exception using errcode='22023',message='Quotation category is inactive or outside this business';
    end if;
    if v_stock_id is not null and not exists(select 1 from public.stock_items where business_id=p_business_id and id=v_stock_id and is_active and base_unit=v_unit) then
      raise exception using errcode='22023',message='Selected stock SKU is inactive or its base unit does not match the quotation line';
    end if;
    if v_method is not null and not exists(select 1 from public.production_methods where id=v_method and is_active) then
      raise exception using errcode='22023',message='Selected production method is inactive';
    end if;
    if v_sale_mode='value_added' and v_item_type='product' and v_method is null then
      raise exception using errcode='22023',message='Value-added products require a production method';
    end if;

    v_estimate:=private.estimate_line_cost(p_business_id,v_catalogue_id,v_category_id,v_stock_id,
      v_sale_mode,v_method,v_quantity,v_customer_supplies,v_spec);
    v_unit_cost:=(v_estimate->>'estimated_total_cost')::numeric/v_quantity;

    select * into v_rule from public.pricing_rules r
    where r.business_id=p_business_id and r.is_active and r.effective_from<=current_date
      and (r.effective_to is null or r.effective_to>=current_date)
      and ((v_catalogue_id is not null and r.catalogue_item_id=v_catalogue_id)
        or (r.catalogue_item_id is null and v_category_id is not null and r.category_id=v_category_id))
    order by (r.catalogue_item_id is not null) desc,r.effective_from desc,r.created_at desc
    limit 1;
    if found and v_rule.cost_basis<>'estimated_unit_cost' then
      raise exception using errcode='22023',message='Pricing rule cost basis is not supported by this costing version';
    end if;
    if v_input_price is not null then
      v_price:=v_input_price;
    elsif found and v_rule.markup_method='percentage_on_cost' then
      v_price:=round(v_unit_cost*(1+v_rule.markup_value/100))::bigint;
    elsif found and v_rule.markup_method='margin_on_price' then
      v_price:=round(v_unit_cost/(1-v_rule.markup_value/100))::bigint;
    elsif found and v_rule.markup_method='fixed_amount' then
      v_price:=round(v_unit_cost+v_rule.markup_value)::bigint;
    else
      raise exception using errcode='22023',message='A manual unit price or active automatic pricing rule is required';
    end if;
    if v_price<0 then raise exception using errcode='22023',message='Unit price cannot be negative'; end if;
    v_gross:=round(v_quantity*v_price)::bigint;
    if v_discount>v_gross then raise exception using errcode='22023',message='Line discount exceeds gross line amount'; end if;
    v_line_total:=v_gross-v_discount;
    v_price_snapshot:=jsonb_build_object('pricing_rule_id',case when found then v_rule.id else null end,
      'markup_method',case when found then v_rule.markup_method else 'manual' end,
      'markup_value',case when found then v_rule.markup_value else null end,
      'estimated_unit_cost',v_unit_cost,'unit_price',v_price,'manual_override',v_input_price is not null);

    insert into public.quotation_items(business_id,quotation_id,catalogue_item_id,category_id,stock_item_id,
      description,quantity,unit,unit_price,line_discount,line_total,customer_supplies_item,sale_mode,
      production_method_id,production_specification,pricing_snapshot,cost_estimate_snapshot)
    values(p_business_id,v_quote,v_catalogue_id,v_category_id,v_stock_id,v_description,v_quantity,v_unit,
      v_price,v_discount,v_line_total,v_customer_supplies,v_sale_mode,v_method,v_spec,v_price_snapshot,v_estimate);

    v_subtotal:=v_subtotal+v_gross;
    v_discounts:=v_discounts+v_discount;
    v_total:=v_total+v_line_total;
  end loop;

  update public.quotations set subtotal_amount=v_subtotal,discount_amount=v_discounts,total_amount=v_total,updated_at=now()
  where business_id=p_business_id and id=v_quote;
  insert into public.quotation_events(business_id,quotation_id,event_type,actor_user_id,source)
  values(p_business_id,v_quote,'created',v_actor,'owner');
  v_result:=jsonb_build_object('quotation_id',v_quote,'quote_number',v_number,'subtotal_amount',v_subtotal,
    'discount_amount',v_discounts,'total_amount',v_total,'currency_code','KES');
  perform private.finish_idempotent_request(p_business_id,'create_quotation',p_request_id,v_result);
  perform private.write_audit(p_business_id,v_actor,'quotation.created','quotation',v_quote,p_request_id,
    jsonb_build_object('quote_number',v_number,'total_amount',v_total,'line_count',jsonb_array_length(p_lines)));
  return v_result;
end;
$$;

create or replace function private.owner_send_quotation(
  p_quotation_id uuid,p_expires_at timestamptz,p_request_id uuid
) returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_quote public.quotations%rowtype; v_actor uuid; v_cached jsonb; v_payload jsonb;
  v_token text; v_expiry timestamptz; v_hash bytea; v_result jsonb;
begin
  select * into v_quote from public.quotations where id=p_quotation_id;
  if not found then raise exception using errcode='P0002',message='Quotation not found'; end if;
  v_actor:=private.assert_active_owner(v_quote.business_id);
  v_payload:=jsonb_build_object('quotation_id',p_quotation_id,'expires_at',p_expires_at);
  v_cached:=private.begin_idempotent_request(v_quote.business_id,'send_quotation',p_request_id,v_payload);
  if v_cached is not null then return v_cached; end if;
  select * into v_quote from public.quotations where business_id=v_quote.business_id and id=p_quotation_id for update;
  if v_quote.status not in ('draft','sent') then raise exception using errcode='22023',message='Only draft or sent quotations can be sent'; end if;
  v_expiry:=coalesce(p_expires_at,v_quote.expires_at,now()+interval '14 days');
  if v_expiry<=now() then raise exception using errcode='22023',message='Quote expiry must be in the future'; end if;
  v_token:=gen_random_uuid()::text||gen_random_uuid()::text;
  v_hash:=extensions.digest(convert_to(v_token,'UTF8'),'sha256');
  update private.quote_acceptance_tokens set expires_at=least(expires_at,now())
  where business_id=v_quote.business_id and quotation_id=p_quotation_id and used_at is null;
  insert into private.quote_acceptance_tokens(business_id,quotation_id,token_hash,expires_at)
  values(v_quote.business_id,p_quotation_id,v_hash,v_expiry);
  update public.quotations set status='sent',issued_at=coalesce(issued_at,now()),expires_at=v_expiry,updated_at=now()
  where business_id=v_quote.business_id and id=p_quotation_id;
  insert into public.quotation_events(business_id,quotation_id,event_type,actor_user_id,source)
  values(v_quote.business_id,p_quotation_id,'sent',v_actor,'owner');
  v_result:=jsonb_build_object('quotation_id',p_quotation_id,'quote_number',v_quote.quote_number,
    'acceptance_token',v_token,'expires_at',v_expiry,'total_amount',v_quote.total_amount);
  perform private.finish_idempotent_request(v_quote.business_id,'send_quotation',p_request_id,v_result);
  perform private.write_audit(v_quote.business_id,v_actor,'quotation.sent','quotation',p_quotation_id,p_request_id,
    jsonb_build_object('expires_at',v_expiry));
  return v_result;
end;
$$;

create or replace function private.accept_quotation_token(p_token text,p_request_id uuid)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_hash bytea; v_token private.quote_acceptance_tokens%rowtype; v_quote public.quotations%rowtype;
  v_cached jsonb; v_payload jsonb; v_order uuid; v_order_number text; v_owner uuid; v_line record;
  v_order_item uuid; v_unit_cost bigint; v_total_cost bigint; v_result jsonb;
begin
  if p_token is null or length(p_token) not between 32 and 256 or p_request_id is null then
    raise exception using errcode='22023',message='Invalid quote acceptance token';
  end if;
  v_hash:=extensions.digest(convert_to(p_token,'UTF8'),'sha256');
  select * into v_token from private.quote_acceptance_tokens where token_hash=v_hash;
  if not found then raise exception using errcode='P0002',message='Quote acceptance link is invalid'; end if;
  select * into v_quote from public.quotations where business_id=v_token.business_id and id=v_token.quotation_id for update;
  if not found then raise exception using errcode='P0002',message='Quotation not found'; end if;
  v_payload:=jsonb_build_object('token_hash',encode(v_hash,'hex'));
  v_cached:=private.begin_idempotent_request(v_quote.business_id,'accept_quotation',p_request_id,v_payload);
  if v_cached is not null then return v_cached; end if;
  select * into v_token from private.quote_acceptance_tokens where id=v_token.id for update;
  if v_token.used_at is not null or v_token.expires_at<=now()
    or (v_quote.expires_at is not null and v_quote.expires_at<=now()) or v_quote.status<>'sent' then
    raise exception using errcode='22023',message='Quote acceptance link has expired or was already used';
  end if;
  select user_id into v_owner from public.business_memberships
  where business_id=v_quote.business_id and role='owner' and status='active'
  order by created_at,id limit 1;
  if v_owner is null then raise exception using errcode='23514',message='Business has no active owner'; end if;
  v_order_number:=private.next_document_number(v_quote.business_id,'order');
  insert into public.orders(business_id,order_number,customer_id,quotation_id,status,currency_code,
    subtotal_amount,discount_amount,total_amount,created_by)
  values(v_quote.business_id,v_order_number,v_quote.customer_id,v_quote.id,'confirmed','KES',
    v_quote.subtotal_amount,v_quote.discount_amount,v_quote.total_amount,v_owner)
  returning id into v_order;

  for v_line in
    select qi.* from public.quotation_items qi
    where qi.business_id=v_quote.business_id and qi.quotation_id=v_quote.id
    order by qi.created_at,qi.id
  loop
    v_total_cost:=coalesce((v_line.cost_estimate_snapshot->>'estimated_total_cost')::bigint,0);
    v_unit_cost:=coalesce((v_line.cost_estimate_snapshot->>'estimated_unit_cost')::bigint,0);
    insert into public.order_items(business_id,order_id,description,quantity,unit,unit_price,line_discount,line_total,
      category_id,stock_item_id,customer_supplies_item,sale_mode,production_method_id,production_specification,
      estimated_unit_cost,estimated_total_cost,cost_breakdown_snapshot,cost_calculation_version)
    values(v_quote.business_id,v_order,v_line.description,v_line.quantity,v_line.unit,v_line.unit_price,
      v_line.line_discount,v_line.line_total,v_line.category_id,v_line.stock_item_id,v_line.customer_supplies_item,
      v_line.sale_mode,v_line.production_method_id,v_line.production_specification,v_unit_cost,v_total_cost,
      v_line.cost_estimate_snapshot,v_line.cost_estimate_snapshot->>'calculation_version')
    returning id into v_order_item;
    if v_line.line_discount>0 then
      insert into public.order_item_discount_allocations(business_id,order_id,order_item_id,discount_source,
        pre_discount_line_amount,allocated_discount_amount,allocation_version,created_by)
      values(v_quote.business_id,v_order,v_order_item,'line_discount',
        round(v_line.quantity*v_line.unit_price)::bigint,v_line.line_discount,'line-discount-v1',null);
    end if;
  end loop;

  update public.quotations set status='accepted',accepted_at=now(),updated_at=now()
  where business_id=v_quote.business_id and id=v_quote.id;
  update private.quote_acceptance_tokens set used_at=clock_timestamp() where id=v_token.id;
  insert into public.quotation_events(business_id,quotation_id,event_type,source)
  values(v_quote.business_id,v_quote.id,'accepted','customer_link');
  insert into public.order_events(business_id,order_id,event_type,to_status,actor_user_id,reason)
  values(v_quote.business_id,v_order,'created','confirmed',null,'Accepted quotation '||v_quote.quote_number);
  v_result:=jsonb_build_object('ok',true,'order_number',v_order_number,'total_amount',v_quote.total_amount,
    'currency_code','KES','message','Quotation accepted and order created');
  perform private.finish_idempotent_request(v_quote.business_id,'accept_quotation',p_request_id,v_result);
  perform private.write_audit(v_quote.business_id,null,'quotation.accepted','quotation',v_quote.id,p_request_id,
    jsonb_build_object('order_number',v_order_number,'order_id',v_order));
  return v_result;
end;
$$;

create or replace function public.owner_create_costing_profile(
 p_business_id uuid,p_catalogue_item_id uuid,p_category_id uuid,p_sale_mode text,
 p_production_method_id uuid,p_components jsonb,p_request_id uuid
) returns jsonb language sql security invoker set search_path=''
as $$ select private.owner_create_costing_profile($1,$2,$3,$4,$5,$6,$7); $$;

create or replace function public.owner_upsert_pricing_rule(
 p_business_id uuid,p_rule_id uuid,p_category_id uuid,p_catalogue_item_id uuid,p_name text,
 p_markup_method text,p_markup_value numeric,p_effective_from date,p_effective_to date,
 p_is_active boolean,p_request_id uuid
) returns jsonb language sql security invoker set search_path=''
as $$ select private.owner_upsert_pricing_rule($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11); $$;

create or replace function public.owner_create_quotation(
 p_business_id uuid,p_customer_id uuid,p_enquiry_id uuid,p_lines jsonb,
 p_expires_at timestamptz,p_customer_notes text,p_internal_notes text,p_request_id uuid
) returns jsonb language sql security invoker set search_path=''
as $$ select private.owner_create_quotation($1,$2,$3,$4,$5,$6,$7,$8); $$;

create or replace function public.owner_send_quotation(p_quotation_id uuid,p_expires_at timestamptz,p_request_id uuid)
returns jsonb language sql security invoker set search_path=''
as $$ select private.owner_send_quotation($1,$2,$3); $$;

create or replace function public.accept_quotation(p_token text,p_request_id uuid)
returns jsonb language sql security definer set search_path=''
as $$ select private.accept_quotation_token($1,$2); $$;

revoke all on function private.owner_create_costing_profile(uuid,uuid,uuid,text,uuid,jsonb,uuid),
 private.owner_upsert_pricing_rule(uuid,uuid,uuid,uuid,text,text,numeric,date,date,boolean,uuid),
 private.estimate_line_cost(uuid,uuid,uuid,uuid,text,uuid,numeric,boolean,jsonb),
 private.owner_create_quotation(uuid,uuid,uuid,jsonb,timestamptz,text,text,uuid),
 private.owner_send_quotation(uuid,timestamptz,uuid),
 private.accept_quotation_token(text,uuid)
from public,anon,authenticated;
grant execute on function private.owner_create_costing_profile(uuid,uuid,uuid,text,uuid,jsonb,uuid),
 private.owner_upsert_pricing_rule(uuid,uuid,uuid,uuid,text,text,numeric,date,date,boolean,uuid),
 private.owner_create_quotation(uuid,uuid,uuid,jsonb,timestamptz,text,text,uuid),
 private.owner_send_quotation(uuid,timestamptz,uuid)
to authenticated;

revoke all on function public.owner_create_costing_profile(uuid,uuid,uuid,text,uuid,jsonb,uuid),
 public.owner_upsert_pricing_rule(uuid,uuid,uuid,uuid,text,text,numeric,date,date,boolean,uuid),
 public.owner_create_quotation(uuid,uuid,uuid,jsonb,timestamptz,text,text,uuid),
 public.owner_send_quotation(uuid,timestamptz,uuid)
from public,anon;
grant execute on function public.owner_create_costing_profile(uuid,uuid,uuid,text,uuid,jsonb,uuid),
 public.owner_upsert_pricing_rule(uuid,uuid,uuid,uuid,text,text,numeric,date,date,boolean,uuid),
 public.owner_create_quotation(uuid,uuid,uuid,jsonb,timestamptz,text,text,uuid),
 public.owner_send_quotation(uuid,timestamptz,uuid)
to authenticated;

revoke all on function public.accept_quotation(text,uuid) from public;
grant execute on function public.accept_quotation(text,uuid) to anon,authenticated;

commit;
