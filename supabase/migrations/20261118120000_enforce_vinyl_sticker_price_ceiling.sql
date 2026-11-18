-- Enforce the owner-configured vinyl sticker upper price boundary in the database.
-- The price is checked against the server-generated cost_estimate_snapshot, never
-- against client-supplied direct_cost_estimate / ceiling_price fields.
-- The owner ceiling is stored as a named pricing rule by the existing owner RPC.
-- Default ceiling: 400% markup on direct cost (5x direct cost).

create or replace function private.enforce_vinyl_sticker_price_ceiling()
returns trigger
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_category_name text;
  v_stock_sku text;
  v_stock_name text;
  v_is_vinyl_sticker boolean;
  v_markup numeric := 400;
  v_direct_cost numeric;
  v_unit_cost numeric;
  v_max_unit_price bigint;
  v_rule public.pricing_rules%rowtype;
begin
  if new.sale_mode <> 'value_added' then
    return new;
  end if;

  select c.name into v_category_name
  from public.service_categories c
  where c.business_id = new.business_id
    and c.id = new.category_id;

  if new.stock_item_id is not null then
    select s.sku, s.name into v_stock_sku, v_stock_name
    from public.stock_items s
    where s.business_id = new.business_id
      and s.id = new.stock_item_id;
  end if;

  v_is_vinyl_sticker :=
    coalesce(new.production_specification->>'type' = 'vinyl_sticker', false)
    or coalesce(v_stock_sku like 'VIN-STK-%' or v_stock_sku like 'VIN-HOT-%', false)
    or coalesce(v_stock_name ilike '%sticker vinyl%' or v_stock_name ilike '%vinyl sticker%', false)
    or coalesce(v_category_name ilike '%sticker%' or v_category_name ilike '%vinyl%', false);

  if not v_is_vinyl_sticker then
    return new;
  end if;

  if new.quantity is null or new.quantity <= 0
    or new.cost_estimate_snapshot is null
    or not (new.cost_estimate_snapshot ? 'estimated_total_cost')
    or nullif(new.cost_estimate_snapshot->>'estimated_total_cost', '') is null then
    raise exception using errcode='23514',
      message='Vinyl sticker quotation requires a server-calculated direct-cost snapshot';
  end if;

  v_direct_cost := (new.cost_estimate_snapshot->>'estimated_total_cost')::numeric;
  if v_direct_cost <= 0 then
    raise exception using errcode='23514',
      message='Vinyl sticker quotation requires a positive direct production cost';
  end if;

  v_unit_cost := v_direct_cost / new.quantity;

  if new.category_id is not null and v_category_name is not null then
    select * into v_rule
    from public.pricing_rules r
    where r.business_id = new.business_id
      and r.category_id = new.category_id
      and r.catalogue_item_id is null
      and r.name = 'Vinyl sticker price ceiling · ' || v_category_name
      and r.is_active
      and r.effective_from <= current_date
      and (r.effective_to is null or r.effective_to >= current_date)
    order by r.effective_from desc, r.created_at desc
    limit 1;

    if found then
      if v_rule.markup_method <> 'percentage_on_cost'
        or v_rule.cost_basis <> 'estimated_unit_cost'
        or v_rule.markup_value < 0
        or v_rule.markup_value > 2000 then
        raise exception using errcode='23514',
          message='The owner-configured vinyl price ceiling is invalid';
      end if;
      v_markup := v_rule.markup_value;
    end if;
  end if;

  v_max_unit_price := floor(v_unit_cost * (1 + v_markup / 100))::bigint;

  if new.unit_price is null or new.unit_price > v_max_unit_price then
    raise exception using errcode='23514',
      message=format(
        'Vinyl sticker unit price exceeds the owner ceiling of KES %s (%.2f%% markup on server-calculated direct cost)',
        v_max_unit_price, v_markup
      );
  end if;

  return new;
end;
$function$;

revoke all on function private.enforce_vinyl_sticker_price_ceiling()
  from public, anon, authenticated;

drop trigger if exists quotation_items_enforce_vinyl_price_ceiling
  on public.quotation_items;

create trigger quotation_items_enforce_vinyl_price_ceiling
before insert or update of business_id, category_id, stock_item_id, quantity,
  unit_price, sale_mode, production_specification, cost_estimate_snapshot
on public.quotation_items
for each row
execute function private.enforce_vinyl_sticker_price_ceiling();

-- Configure only 24-inch vinyl stock rows whose dimensions are still unset.
-- 24 inches = 609.6 mm; 2 cm trim on each side leaves 569.6 mm usable width.
-- COALESCE preserves any dimensions an owner has already entered.
update public.stock_items
set roll_width_mm = coalesce(roll_width_mm, 609.6),
    usable_width_mm = coalesce(usable_width_mm, 569.6),
    updated_at = now()
where is_active
  and stock_kind = 'material'
  and name ilike '%vinyl%'
  and name ilike '%24-inch%'
  and (roll_width_mm is null or usable_width_mm is null);
