-- Automatically consume vinyl stock for successful vinyl sticker Quick Sales.
-- The RPC, invoice, stock movement and audit event share one PostgreSQL transaction.

alter table public.stock_items
  alter column quantity_on_hand type numeric(14,6)
  using quantity_on_hand::numeric(14,6);

create or replace function private.apply_stock_movement(
  p_business_id uuid,
  p_stock_item_id uuid,
  p_quantity numeric,
  p_unit_cost numeric,
  p_movement_type text
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_stock public.stock_items%rowtype;
  v_new_quantity numeric(14,6);
  v_new_cost numeric(14,2);
begin
  if auth.uid() is null or not exists (
    select 1 from public.business_memberships
    where business_id=p_business_id and user_id=auth.uid() and role='owner'
  ) then
    raise exception 'Owner authorization required';
  end if;

  if p_quantity is null or p_quantity=0 or p_unit_cost is null or p_unit_cost<0
     or p_movement_type not in ('opening','purchase','job_issue','transfer_in','transfer_out','adjustment','offcut_return','vinyl_sticker_sale') then
    raise exception 'Invalid stock movement';
  end if;

  select * into v_stock
  from public.stock_items
  where id=p_stock_item_id and business_id=p_business_id
  for update;

  if not found then raise exception 'Stock item not found'; end if;

  v_new_quantity := v_stock.quantity_on_hand + p_quantity;
  if v_new_quantity < 0 then raise exception 'Insufficient stock'; end if;

  v_new_cost := v_stock.average_unit_cost;
  if p_quantity > 0 then
    v_new_cost := case when v_new_quantity > 0
      then ((v_stock.quantity_on_hand*v_stock.average_unit_cost)+(p_quantity*p_unit_cost))/v_new_quantity
      else p_unit_cost end;
  end if;

  update public.stock_items
  set quantity_on_hand=v_new_quantity, average_unit_cost=v_new_cost
  where id=v_stock.id and business_id=p_business_id;

  insert into public.stock_movements(
    business_id,stock_item_id,movement_type,quantity,unit_cost,created_by
  ) values (
    p_business_id,p_stock_item_id,p_movement_type,p_quantity,p_unit_cost,auth.uid()
  );
end
$function$;

create or replace function public.owner_create_vinyl_sticker_quick_sale(
  p_customer_id uuid,
  p_invoice_number text,
  p_due_date date,
  p_description text,
  p_dimensions text,
  p_quantity numeric,
  p_agreed_price numeric,
  p_supply_arrangement text,
  p_direct_cost_total numeric,
  p_direct_cost_breakdown jsonb,
  p_pricing_details jsonb,
  p_allow_below_floor boolean default false,
  p_exception_reason text default null,
  p_payment_number text default null,
  p_payment_method text default null,
  p_payment_amount numeric default 0,
  p_payment_reference text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, private, pg_temp
as $function$
declare
  v_user uuid := auth.uid();
  v_business uuid;
  v_profile uuid;
  v_profile_name text;
  v_result jsonb;
  v_invoice uuid;
  v_line_total numeric(14,2);
  v_margin numeric(7,2);
  v_stock_id uuid;
  v_stock public.stock_items%rowtype;
  v_roll_width numeric;
  v_roll_length numeric;
  v_area numeric;
  v_stock_consumption numeric(14,6);
  v_pricing_details jsonb := coalesce(p_pricing_details,'{}'::jsonb);
begin
  if v_user is null then raise exception 'Authentication required'; end if;

  select business_id into v_business
  from public.business_memberships
  where user_id=v_user and role='owner'
  order by created_at limit 1;

  if v_business is null then raise exception 'Owner workspace required'; end if;
  if length(btrim(coalesce(p_description,'')))<2 then raise exception 'Sticker description is required'; end if;
  if length(btrim(coalesce(p_dimensions,'')))<2 then raise exception 'Sticker dimensions are required'; end if;
  if nullif(btrim(coalesce(p_invoice_number,'')),'') is null then raise exception 'Invoice number is required'; end if;
  if p_quantity is null or p_quantity<=0 or p_quantity<>trunc(p_quantity) then raise exception 'Quantity must be a whole number greater than zero'; end if;
  if p_agreed_price is null or p_agreed_price<=0 then raise exception 'Final agreed customer price must be greater than zero'; end if;
  if p_direct_cost_total is null or p_direct_cost_total<0 then raise exception 'Direct production cost cannot be negative'; end if;
  if jsonb_typeof(p_direct_cost_breakdown)<>'array' then raise exception 'Direct cost breakdown must be an array'; end if;
  if jsonb_typeof(p_pricing_details)<>'object' then raise exception 'Pricing details must be an object'; end if;
  if p_supply_arrangement not in ('mj_supplies','customer_supplies') then raise exception 'Invalid supply arrangement'; end if;
  if coalesce(p_payment_amount,0)<0 then raise exception 'Payment amount cannot be negative'; end if;
  if coalesce(p_allow_below_floor,false) and length(btrim(coalesce(p_exception_reason,'')))<8 then
    raise exception 'A below-floor exception reason must contain at least 8 characters';
  end if;

  -- Validate and lock MJ-owned vinyl before creating the invoice. The stock unit is metres.
  if p_supply_arrangement='mj_supplies' then
    begin
      v_stock_id := nullif(p_pricing_details->>'inventory_stock_item_id','')::uuid;
      v_roll_width := (p_pricing_details->>'stock_width_inches')::numeric;
      v_roll_length := (p_pricing_details->>'stock_length_inches')::numeric;
      v_area := (p_pricing_details->>'area_square_inches')::numeric;
    exception when others then
      raise exception 'Vinyl stock item and valid roll dimensions are required';
    end;

    if v_stock_id is null or v_roll_width<=0 or v_area<=0
       or abs(v_roll_length-39.37)>0.01 then
      raise exception 'Select an active vinyl stock item and use a 24-inch roll width and 39.37-inch metre length';
    end if;

    select * into v_stock
    from public.stock_items
    where id=v_stock_id
      and business_id=v_business
      and active=true
      and category='Vinyl sticker material'
      and unit='metre'
    for update;

    if not found then raise exception 'Selected active vinyl stock item was not found'; end if;

    v_stock_consumption := ceil(((v_area*p_quantity)/(v_roll_width*39.37))*1000000)/1000000;
    if v_stock_consumption<=0 then raise exception 'Calculated vinyl consumption must be greater than zero'; end if;
    if v_stock.quantity_on_hand<v_stock_consumption then
      raise exception 'Insufficient vinyl stock. Required: '||v_stock_consumption||' metre; available: '||v_stock.quantity_on_hand||' metre';
    end if;

    v_pricing_details := v_pricing_details || jsonb_build_object(
      'stock_item_id',v_stock.id,
      'stock_item_name',v_stock.item_name,
      'stock_unit','metre',
      'stock_consumed_quantity',v_stock_consumption,
      'stock_quantity_before',v_stock.quantity_on_hand,
      'stock_quantity_after',v_stock.quantity_on_hand-v_stock_consumption,
      'stock_movement_type','vinyl_sticker_sale'
    );
  else
    v_pricing_details := v_pricing_details || jsonb_build_object(
      'stock_consumed_quantity',0,
      'stock_movement_type',null
    );
  end if;

  -- Transaction-only profile lets the canonical Quick Sale RPC enforce margin and ledger rules.
  v_profile_name := '__vinyl_sale_'||replace(gen_random_uuid()::text,'-','');
  insert into public.costing_profiles(
    business_id,profile_name,version,is_active,components,direct_cost,margin_floor,full_cost_target
  ) values (
    v_business,v_profile_name,1,true,
    jsonb_build_array(jsonb_build_object(
      'name','Vinyl sticker direct production costs','category','production',
      'basis','per_piece','cost',round(p_direct_cost_total,2)
    )),
    round(p_direct_cost_total,2),30,1.8
  ) returning id into v_profile;

  v_result := public.owner_create_custom_job_quick_sale(
    p_customer_id=>p_customer_id,p_invoice_number=>p_invoice_number,p_due_date=>p_due_date,
    p_description=>btrim(p_description),p_dimensions=>btrim(p_dimensions),
    p_production_method=>'vinyl_cutting',p_costing_profile_id=>v_profile,
    p_quantity=>p_quantity,p_agreed_price=>round(p_agreed_price,2),
    p_supply_arrangement=>p_supply_arrangement,p_other_direct_costs=>0,
    p_allow_below_floor=>coalesce(p_allow_below_floor,false),
    p_exception_reason=>p_exception_reason,p_payment_number=>p_payment_number,
    p_payment_method=>p_payment_method,p_payment_amount=>coalesce(p_payment_amount,0),
    p_payment_reference=>p_payment_reference
  );

  v_invoice := (v_result->>'invoice_id')::uuid;
  v_line_total := round(p_quantity*p_agreed_price,2);
  v_margin := case when v_line_total>0
    then round(((v_line_total-(p_direct_cost_total*p_quantity))/v_line_total)*100,2)
    else 0 end;

  update public.sales_invoice_items
  set direct_cost=round(p_direct_cost_total*p_quantity,2),
      cost_snapshot=(coalesce(cost_snapshot,'{}'::jsonb)
        - 'profile_id' - 'profile_name' - 'profile_version' - 'components'
        - 'direct_cost_total' - 'gross_margin_percent')
        || jsonb_build_object(
          'profile_id',null,'profile_name','Vinyl sticker calculator','profile_version',null,
          'components',p_direct_cost_breakdown,
          'direct_cost_total',round(p_direct_cost_total*p_quantity,2),
          'unit_direct_cost',round(p_direct_cost_total,2),
          'gross_margin_percent',v_margin,
          'pricing_source','vinyl_sticker_calculator',
          'pricing_details',v_pricing_details,
          'supply_arrangement',p_supply_arrangement
        )
  where business_id=v_business and invoice_id=v_invoice;

  update public.audit_events
  set details=(coalesce(details,'{}'::jsonb)-'costing_profile_id'-'costing_profile_name')
    || jsonb_build_object(
      'pricing_source','vinyl_sticker_calculator',
      'direct_cost_total',round(p_direct_cost_total*p_quantity,2),
      'unit_direct_cost',round(p_direct_cost_total,2),
      'gross_margin_percent',v_margin,
      'pricing_details',v_pricing_details,
      'direct_cost_breakdown',p_direct_cost_breakdown,
      'supply_arrangement',p_supply_arrangement
    )
  where business_id=v_business and entity_type='sales_invoice' and entity_id=v_invoice
    and event_type='custom_job_quick_sale.created';

  -- Apply stock movement after invoice creation but inside this same transaction.
  -- Any stock error rolls back the invoice, payment, profile, audit and movement together.
  if p_supply_arrangement='mj_supplies' then
    perform private.apply_stock_movement(
      v_business,v_stock.id,-v_stock_consumption,v_stock.average_unit_cost,'vinyl_sticker_sale'
    );
    insert into public.audit_events(
      business_id,actor_user_id,event_type,entity_type,entity_id,details
    ) values (
      v_business,v_user,'inventory.vinyl_sticker_stock_consumed','sales_invoice',v_invoice,
      jsonb_build_object(
        'stock_item_id',v_stock.id,
        'stock_item_name',v_stock.item_name,
        'quantity',v_stock_consumption,
        'unit','metre',
        'unit_cost',v_stock.average_unit_cost,
        'roll_width_inches',v_roll_width,
        'sticker_area_square_inches',v_area,
        'order_quantity',p_quantity
      )
    );
  end if;

  delete from public.costing_profiles where id=v_profile and business_id=v_business;

  return v_result || jsonb_build_object(
    'direct_cost_total',round(p_direct_cost_total*p_quantity,2),
    'unit_direct_cost',round(p_direct_cost_total,2),
    'gross_margin_percent',v_margin,
    'pricing_source','vinyl_sticker_calculator',
    'stock_item_id',case when p_supply_arrangement='mj_supplies' then v_stock.id else null end,
    'stock_consumed_quantity',v_stock_consumption
  );
end
$function$;
