-- Preserve garment-supply and printing revenue as accepted-order snapshots.
-- Legacy quotations without an explicit split remain unclassified and are ineligible
-- for temporary-labour allocation; no historical amounts are guessed.

begin;

alter table public.quotation_items
  add column price_components jsonb
  check (price_components is null or jsonb_typeof(price_components) = 'object');

alter table public.order_items
  add column price_components_snapshot jsonb
  check (price_components_snapshot is null or jsonb_typeof(price_components_snapshot) = 'object');

alter table public.order_items add column quotation_item_id uuid;
alter table public.order_items
  add constraint order_items_quotation_item_fk
  foreign key (business_id,quotation_item_id)
  references public.quotation_items(business_id,id) on delete restrict;
create unique index order_items_quotation_item_unique_idx
  on public.order_items(business_id,quotation_item_id)
  where quotation_item_id is not null;

create or replace function private.allocate_two_component_discount(
  p_discount bigint,
  p_garment_gross bigint,
  p_printing_gross bigint
)
returns bigint[]
language plpgsql
immutable
set search_path = ''
as $function$
declare
  v_total numeric;
  v_garment_floor bigint;
  v_printing_floor bigint;
  v_remaining bigint;
  v_garment_remainder numeric;
  v_printing_remainder numeric;
begin
  if p_discount is null or p_discount < 0
    or p_garment_gross is null or p_garment_gross < 0
    or p_printing_gross is null or p_printing_gross < 0 then
    raise exception using errcode='22023', message='Invalid component discount inputs';
  end if;

  v_total := p_garment_gross::numeric + p_printing_gross::numeric;
  if p_discount > v_total then
    raise exception using errcode='22023', message='Component discount exceeds gross value';
  end if;
  if v_total = 0 then
    return array[0::bigint,0::bigint];
  end if;

  v_garment_floor := floor(p_discount::numeric * p_garment_gross / v_total)::bigint;
  v_printing_floor := floor(p_discount::numeric * p_printing_gross / v_total)::bigint;
  v_garment_remainder := mod(p_discount::numeric * p_garment_gross, v_total);
  v_printing_remainder := mod(p_discount::numeric * p_printing_gross, v_total);
  v_remaining := p_discount - v_garment_floor - v_printing_floor;

  if v_remaining > 0 then
    if v_garment_remainder >= v_printing_remainder then
      v_garment_floor := v_garment_floor + v_remaining;
    else
      v_printing_floor := v_printing_floor + v_remaining;
    end if;
  end if;

  return array[v_garment_floor,v_printing_floor];
end;
$function$;

create or replace function private.owner_create_quotation_with_price_components(
  p_business_id uuid,
  p_customer_id uuid,
  p_enquiry_id uuid,
  p_lines jsonb,
  p_expires_at timestamptz,
  p_customer_notes text,
  p_internal_notes text,
  p_request_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_actor uuid;
  v_cached jsonb;
  v_payload jsonb;
  v_result jsonb;
  v_quote_id uuid;
  v_line record;
  v_garment_unit bigint;
  v_count integer := 0;
begin
  v_actor := private.assert_active_owner(p_business_id);
  if p_request_id is null or p_lines is null or jsonb_typeof(p_lines) is distinct from 'array' then
    raise exception using errcode='22023', message='Request ID and quotation lines are required';
  end if;

  v_payload := jsonb_build_object(
    'customer_id',p_customer_id,'enquiry_id',p_enquiry_id,'lines',p_lines,
    'expires_at',p_expires_at,'customer_notes',p_customer_notes,'internal_notes',p_internal_notes
  );
  v_cached := private.begin_idempotent_request(
    p_business_id,'create_quotation_with_price_components',p_request_id,v_payload
  );
  if v_cached is not null then return v_cached; end if;

  v_result := private.owner_create_quotation(
    p_business_id,p_customer_id,p_enquiry_id,p_lines,p_expires_at,
    p_customer_notes,p_internal_notes,
    private.derived_request_uuid(p_request_id,'base-quotation')
  );
  v_quote_id := (v_result->>'quotation_id')::uuid;

  for v_line in
    select qi.id,qi.unit_price,qi.sale_mode,qi.customer_supplies_item,x.value as payload
    from jsonb_array_elements(p_lines) with ordinality x(value,ordinality)
    join public.quotation_items qi
      on qi.business_id=p_business_id
     and qi.quotation_id=v_quote_id
     and qi.line_sequence=x.ordinality
    order by x.ordinality
  loop
    if v_line.customer_supplies_item then
      v_garment_unit := 0;
    elsif v_line.sale_mode = 'blank' then
      v_garment_unit := v_line.unit_price;
    else
      v_garment_unit := nullif(v_line.payload->>'garment_supply_unit_price','')::bigint;
    end if;

    if v_garment_unit is null or v_garment_unit < 0 or v_garment_unit > v_line.unit_price then
      raise exception using errcode='22023',
        message='Enter a valid garment-supply unit price not exceeding the total unit price';
    end if;

    update public.quotation_items
    set price_components = jsonb_build_object(
      'version',1,
      'currency_code','KES',
      'garment_supply_unit_price',v_garment_unit,
      'printing_unit_price',v_line.unit_price-v_garment_unit,
      'classification','explicit'
    )
    where business_id=p_business_id and id=v_line.id;

    v_count := v_count + 1;
  end loop;

  if v_count <> jsonb_array_length(p_lines) then
    raise exception using errcode='23514', message='Quotation price components could not be matched to every line';
  end if;

  v_result := v_result || jsonb_build_object('price_components_version',1);
  perform private.finish_idempotent_request(
    p_business_id,'create_quotation_with_price_components',p_request_id,v_result
  );
  perform private.write_audit(
    p_business_id,v_actor,'quotation.price_components_saved','quotation',v_quote_id,p_request_id,
    jsonb_build_object('line_count',v_count,'version',1)
  );
  return v_result;
end;
$function$;

create or replace function private.owner_create_quotation_revision_with_price_components(
  p_original_quotation_id uuid,
  p_lines jsonb,
  p_expires_at timestamptz,
  p_customer_notes text,
  p_internal_notes text,
  p_request_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_original public.quotations%rowtype;
  v_actor uuid;
  v_cached jsonb;
  v_payload jsonb;
  v_result jsonb;
  v_quote_id uuid;
  v_line record;
  v_garment_unit bigint;
  v_count integer := 0;
begin
  select * into v_original from public.quotations where id=p_original_quotation_id;
  if not found then
    raise exception using errcode='P0002', message='Original quotation not found';
  end if;
  v_actor := private.assert_active_owner(v_original.business_id);
  if p_request_id is null or p_lines is null or jsonb_typeof(p_lines) is distinct from 'array' then
    raise exception using errcode='22023', message='Request ID and quotation lines are required';
  end if;

  v_payload := jsonb_build_object(
    'original_quotation_id',p_original_quotation_id,'lines',p_lines,
    'expires_at',p_expires_at,'customer_notes',p_customer_notes,'internal_notes',p_internal_notes
  );
  v_cached := private.begin_idempotent_request(
    v_original.business_id,'create_quotation_revision_with_price_components',p_request_id,v_payload
  );
  if v_cached is not null then return v_cached; end if;

  v_result := private.owner_create_quotation_revision(
    p_original_quotation_id,p_lines,p_expires_at,p_customer_notes,p_internal_notes,
    private.derived_request_uuid(p_request_id,'base-revision')
  );
  v_quote_id := (v_result->>'quotation_id')::uuid;

  for v_line in
    select qi.id,qi.unit_price,qi.sale_mode,qi.customer_supplies_item,x.value as payload
    from jsonb_array_elements(p_lines) with ordinality x(value,ordinality)
    join public.quotation_items qi
      on qi.business_id=v_original.business_id
     and qi.quotation_id=v_quote_id
     and qi.line_sequence=x.ordinality
    order by x.ordinality
  loop
    if v_line.customer_supplies_item then
      v_garment_unit := 0;
    elsif v_line.sale_mode = 'blank' then
      v_garment_unit := v_line.unit_price;
    else
      v_garment_unit := nullif(v_line.payload->>'garment_supply_unit_price','')::bigint;
    end if;

    if v_garment_unit is null or v_garment_unit < 0 or v_garment_unit > v_line.unit_price then
      raise exception using errcode='22023',
        message='Enter a valid garment-supply unit price not exceeding the total unit price';
    end if;

    update public.quotation_items
    set price_components = jsonb_build_object(
      'version',1,
      'currency_code','KES',
      'garment_supply_unit_price',v_garment_unit,
      'printing_unit_price',v_line.unit_price-v_garment_unit,
      'classification','explicit'
    )
    where business_id=v_original.business_id and id=v_line.id;

    v_count := v_count + 1;
  end loop;

  if v_count <> jsonb_array_length(p_lines) then
    raise exception using errcode='23514', message='Quotation revision price components could not be matched to every line';
  end if;

  v_result := v_result || jsonb_build_object('price_components_version',1);
  perform private.finish_idempotent_request(
    v_original.business_id,'create_quotation_revision_with_price_components',p_request_id,v_result
  );
  perform private.write_audit(
    v_original.business_id,v_actor,'quotation.revision_price_components_saved','quotation',v_quote_id,p_request_id,
    jsonb_build_object('line_count',v_count,'version',1,'revision_of',p_original_quotation_id)
  );
  return v_result;
end;
$function$;

create or replace function private.snapshot_order_item_price_components()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_components jsonb;
  v_garment_unit bigint;
  v_gross_total bigint;
  v_garment_gross bigint;
  v_printing_gross bigint;
  v_printing_unit bigint;
  v_gross_parts bigint[];
  v_line_discount bigint[]
  v_order_discount bigint[];
  v_printing_net bigint;
begin
  select qi.price_components
  into v_components
  from public.quotation_items qi
  where qi.business_id=new.business_id
    and qi.id=new.quotation_item_id;

  if v_components is null then
    return new;
  end if;

  v_garment_unit := (v_components->>'garment_supply_unit_price')::bigint;
  v_gross_total := round(new.quantity*new.unit_price)::bigint;
  v_printing_unit := new.unit_price-v_garment_unit;
  v_gross_parts := private.allocate_two_component_discount(v_gross_total,v_garment_unit,v_printing_unit);
  v_garment_gross := v_gross_parts[1];
  v_printing_gross := v_gross_parts[2];

  if v_garment_gross < 0 or v_printing_gross < 0
    or v_garment_gross+v_printing_gross <> v_gross_total then
    raise exception using errcode='23514', message='Accepted price components do not reconcile to the order line';
  end if;

  v_line_discount := private.allocate_two_component_discount(
    new.line_discount,v_garment_gross,v_printing_gross
  );
  v_order_discount := private.allocate_two_component_discount(
    new.order_discount_allocated,v_garment_gross-v_line_discount[1],
    v_printing_gross-v_line_discount[2]
  );
  v_printing_net := v_printing_gross-v_line_discount[2]-v_order_discount[2];

  update public.order_items
  set price_components_snapshot = jsonb_build_object(
    'version',1,
    'currency_code','KES',
    'garment_supply_unit_price',v_garment_unit,
    'printing_unit_price',v_printing_unit,
    'garment_supply_gross_amount',v_garment_gross,
    'printing_gross_amount',v_printing_gross,
    'line_discount_garment_supply',v_line_discount[1],
    'line_discount_printing',v_line_discount[2],
    'order_discount_garment_supply',v_order_discount[1],
    'order_discount_printing',v_order_discount[2],
    'garment_supply_net_amount',v_garment_gross-v_line_discount[1]-v_order_discount[1],
    'printing_net_amount',v_printing_net,
    'eligible_printing_revenue',v_printing_net
  )
  where business_id=new.business_id and id=new.id;

  return new;
end;
$function$;

create trigger order_items_snapshot_price_components
after insert on public.order_items
for each row execute function private.snapshot_order_item_price_components();

create or replace function private.order_item_eligible_printing_revenue(p_order_item_id uuid)
returns bigint
language sql
stable
security definer
set search_path = ''
as $function$
  select coalesce((oi.price_components_snapshot->>'eligible_printing_revenue')::bigint,0)
  from public.order_items oi
  where oi.id=p_order_item_id;
$function$;

create or replace function public.owner_create_quotation_with_price_components(
  p_business_id uuid,p_customer_id uuid,p_enquiry_id uuid,p_lines jsonb,
  p_expires_at timestamptz,p_customer_notes text,p_internal_notes text,p_request_id uuid
)
returns jsonb
language sql
security invoker
set search_path = ''
as $function$
  select private.owner_create_quotation_with_price_components($1,$2,$3,$4,$5,$6,$7,$8);
$function$;

create or replace function public.owner_create_quotation_revision_with_price_components(
  p_original_quotation_id uuid,p_lines jsonb,p_expires_at timestamptz,
  p_customer_notes text,p_internal_notes text,p_request_id uuid
)
returns jsonb
language sql
security invoker
set search_path = ''
as $function$
  select private.owner_create_quotation_revision_with_price_components($1,$2,$3,$4,$5,$6);
$function$;

revoke all on function private.allocate_two_component_discount(bigint,bigint,bigint) from public,anon,authenticated;
revoke all on function private.snapshot_order_item_price_components() from public,anon,authenticated;
revoke all on function private.order_item_eligible_printing_revenue(uuid) from public,anon,authenticated;
revoke all on function private.owner_create_quotation_with_price_components(uuid,uuid,uuid,jsonb,timestamptz,text,text,uuid) from public,anon,authenticated;
revoke all on function private.owner_create_quotation_revision_with_price_components(uuid,jsonb,timestamptz,text,text,uuid) from public,anon,authenticated;
grant usage on schema private to authenticated;
grant execute on function private.owner_create_quotation_with_price_components(uuid,uuid,uuid,jsonb,timestamptz,text,text,uuid) to authenticated;
grant execute on function private.owner_create_quotation_revision_with_price_components(uuid,jsonb,timestamptz,text,text,uuid) to authenticated;

revoke all on function public.owner_create_quotation_with_price_components(uuid,uuid,uuid,jsonb,timestamptz,text,text,uuid) from public,anon;
revoke all on function public.owner_create_quotation_revision_with_price_components(uuid,jsonb,timestamptz,text,text,uuid) from public,anon;
grant execute on function public.owner_create_quotation_with_price_components(uuid,uuid,uuid,jsonb,timestamptz,text,text,uuid) to authenticated;
grant execute on function public.owner_create_quotation_revision_with_price_components(uuid,jsonb,timestamptz,text,text,uuid) to authenticated;


create or replace function private.owner_classify_order_item_price_components(
  p_order_item_id uuid,
  p_garment_supply_unit_price bigint,
  p_reason text,
  p_request_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_item public.order_items%rowtype;
  v_actor uuid;
  v_cached jsonb;
  v_payload jsonb;
  v_garment_unit bigint;
  v_gross_total bigint;
  v_garment_gross bigint;
  v_printing_gross bigint;
  v_printing_unit bigint;
  v_gross_parts bigint[];
  v_line_discount bigint[]
  v_order_discount bigint[];
  v_result jsonb;
begin
  select * into v_item from public.order_items where id=p_order_item_id;
  if not found then raise exception using errcode='P0002',message='Order item not found'; end if;
  v_actor:=private.assert_active_owner(v_item.business_id);
  if p_request_id is null or length(btrim(coalesce(p_reason,''))) not between 1 and 500 then
    raise exception using errcode='22023',message='Classification reason and request ID are required';
  end if;

  v_payload:=jsonb_build_object('order_item_id',p_order_item_id,
    'garment_supply_unit_price',p_garment_supply_unit_price,'reason',btrim(p_reason));
  v_cached:=private.begin_idempotent_request(v_item.business_id,'classify_order_item_price_components',p_request_id,v_payload);
  if v_cached is not null then return v_cached; end if;

  select * into v_item from public.order_items
  where business_id=v_item.business_id and id=p_order_item_id for update;
  if v_item.price_components_snapshot is not null then
    raise exception using errcode='22023',message='Order item already has an immutable price-component snapshot';
  end if;

  if v_item.customer_supplies_item then
    v_garment_unit:=0;
  elsif v_item.sale_mode='blank' then
    v_garment_unit:=v_item.unit_price;
  else
    v_garment_unit:=p_garment_supply_unit_price;
  end if;

  if v_garment_unit is null or v_garment_unit<0 or v_garment_unit>v_item.unit_price then
    raise exception using errcode='22023',message='Garment-supply unit price must be between zero and the total unit price';
  end if;

  v_gross_total:=round(v_item.quantity*v_item.unit_price)::bigint;
  v_printing_unit:=v_item.unit_price-v_garment_unit;
  v_gross_parts:=private.allocate_two_component_discount(v_gross_total,v_garment_unit,v_printing_unit);
  v_garment_gross:=v_gross_parts[1];
  v_printing_gross:=v_gross_parts[2];
  v_line_discount:=private.allocate_two_component_discount(
    v_item.line_discount,v_garment_gross,v_printing_gross
  );
  v_order_discount:=private.allocate_two_component_discount(
    v_item.order_discount_allocated,v_garment_gross-v_line_discount[1],
    v_printing_gross-v_line_discount[2]
  );

  update public.order_items
  set price_components_snapshot=jsonb_build_object(
    'version',1,
    'currency_code','KES',
    'garment_supply_unit_price',v_garment_unit,
    'printing_unit_price',v_printing_unit,
    'garment_supply_gross_amount',v_garment_gross,
    'printing_gross_amount',v_printing_gross,
    'line_discount_garment_supply',v_line_discount[1],
    'line_discount_printing',v_line_discount[2],
    'order_discount_garment_supply',v_order_discount[1],
    'order_discount_printing',v_order_discount[2],
    'garment_supply_net_amount',v_garment_gross-v_line_discount[1]-v_order_discount[1],
    'printing_net_amount',v_printing_gross-v_line_discount[2]-v_order_discount[2],
    'eligible_printing_revenue',v_printing_gross-v_line_discount[2]-v_order_discount[2],
    'classification','owner_manual',
    'classification_reason',btrim(p_reason)
  )
  where business_id=v_item.business_id and id=p_order_item_id;

  v_result:=jsonb_build_object('order_item_id',p_order_item_id,
    'garment_supply_unit_price',v_garment_unit,
    'printing_unit_price',v_printing_unit,
    'eligible_printing_revenue',v_printing_gross-v_line_discount[2]-v_order_discount[2],
    'classification','owner_manual');
  perform private.finish_idempotent_request(v_item.business_id,'classify_order_item_price_components',p_request_id,v_result);
  perform private.write_audit(v_item.business_id,v_actor,'order_item.price_components_classified',
    'order_item',p_order_item_id,p_request_id,
    jsonb_build_object('garment_supply_unit_price',v_garment_unit,
      'printing_unit_price',v_printing_unit,'reason',btrim(p_reason)));
  return v_result;
end;
$function$;

create or replace function public.owner_classify_order_item_price_components(
  p_order_item_id uuid,p_garment_supply_unit_price bigint,p_reason text,p_request_id uuid
)
returns jsonb language sql security invoker set search_path=''
as $function$
  select private.owner_classify_order_item_price_components($1,$2,$3,$4);
$function$;

revoke all on function private.owner_classify_order_item_price_components(uuid,bigint,text,uuid) from public,anon,authenticated;
grant usage on schema private to authenticated;
grant execute on function private.owner_classify_order_item_price_components(uuid,bigint,text,uuid) to authenticated;
revoke all on function public.owner_classify_order_item_price_components(uuid,bigint,text,uuid) from public,anon;
grant execute on function public.owner_classify_order_item_price_components(uuid,bigint,text,uuid) to authenticated;

create or replace function private.accept_quotation_token(p_token text,p_request_id uuid)
returns jsonb language plpgsql security definer set search_path=''
as $function$
declare
  v_hash bytea;
  v_token private.quote_acceptance_tokens%rowtype;
  v_quote public.quotations%rowtype;
  v_cached jsonb;
  v_payload jsonb;
  v_order uuid;
  v_order_number text;
  v_owner uuid;
  v_line record;
  v_order_item uuid;
  v_unit_cost bigint;
  v_total_cost bigint;
  v_result jsonb;
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
    order by qi.line_sequence,qi.id
  loop
    v_total_cost:=coalesce((v_line.cost_estimate_snapshot->>'estimated_total_cost')::bigint,0);
    v_unit_cost:=coalesce((v_line.cost_estimate_snapshot->>'estimated_unit_cost')::bigint,0);
    insert into public.order_items(
      business_id,order_id,quotation_item_id,description,quantity,unit,unit_price,line_discount,line_total,
      category_id,stock_item_id,customer_supplies_item,sale_mode,production_method_id,production_specification,
      estimated_unit_cost,estimated_total_cost,cost_breakdown_snapshot,cost_calculation_version
    )
    values(
      v_quote.business_id,v_order,v_line.id,v_line.description,v_line.quantity,v_line.unit,v_line.unit_price,
      v_line.line_discount,v_line.line_total,v_line.category_id,v_line.stock_item_id,v_line.customer_supplies_item,
      v_line.sale_mode,v_line.production_method_id,v_line.production_specification,v_unit_cost,v_total_cost,
      v_line.cost_estimate_snapshot,v_line.cost_estimate_snapshot->>'calculation_version'
    )
    returning id into v_order_item;
    if v_line.line_discount>0 then
      insert into public.order_item_discount_allocations(
        business_id,order_id,order_item_id,discount_source,pre_discount_line_amount,
        allocated_discount_amount,allocation_version,created_by
      )
      values(
        v_quote.business_id,v_order,v_order_item,'line_discount',
        round(v_line.quantity*v_line.unit_price)::bigint,v_line.line_discount,'line-discount-v1',null
      );
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
$function$;


commit;
