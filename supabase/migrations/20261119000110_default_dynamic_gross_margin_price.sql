-- When no optional pricing rule exists, recommend the 30% gross-margin
-- floor from the current line cost estimate. The owner may enter a negotiated
-- final price; existing below-floor approval controls remain in force.
CREATE OR REPLACE FUNCTION private.owner_create_quotation(p_business_id uuid, p_customer_id uuid, p_enquiry_id uuid, p_lines jsonb, p_expires_at timestamp with time zone, p_customer_notes text, p_internal_notes text, p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
      -- With no active category/item rule, recommend the exact 30% gross-margin
      -- floor from the latest live cost estimate. Owner-entered prices still win.
      v_price:=ceil(v_unit_cost/0.70)::bigint;
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
$function$;
