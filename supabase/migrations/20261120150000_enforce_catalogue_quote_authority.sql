-- Make the active catalogue the sole authority for quotation prices, selling methods and costing-profile links.
-- Additive replacement only: no data changes occur until an explicitly approved migration is run.
create or replace function private.owner_create_quotation_v2_impl(
 p_customer_id uuid,p_quote_number text,p_valid_until date,p_lines jsonb,
 p_allow_below_floor boolean default false,p_exception_reason text default null
) returns uuid
language plpgsql security definer set search_path=public,private,pg_temp
as $fn$
declare
 v_business uuid; v_user uuid; v_quote uuid; v_line jsonb; v_item uuid;
 v_method text; v_profile uuid; v_profile_name text; v_profile_version integer; v_components jsonb;
 v_selling_method text; v_catalogue_price numeric(14,2); v_catalogue_name text;
 v_method_count integer:=0; v_preferred_count integer:=0; v_client_profile uuid;
 v_qty numeric(14,3); v_standard numeric(14,2); v_discount_type text; v_discount_value numeric(14,2);
 v_discount numeric(14,2); v_unit_net numeric(14,2); v_total numeric(14,2); v_cost numeric(14,2);
 v_component jsonb; v_component_cost numeric(14,2); v_basis text; v_category text;
 v_customer_supplied boolean; v_blank_override numeric(14,2); v_other numeric(14,2);
 v_breakdown jsonb; v_snapshot jsonb; v_margin numeric(7,2); v_desc text;
 v_line_total numeric(14,2); v_discount_reason text; v_lines_total numeric(14,2):=0;
 v_all_cost numeric(14,2):=0; v_max_price numeric(14,2); v_line_count integer:=0;
begin
 v_user:=auth.uid();
 select business_id into v_business from public.business_memberships
 where user_id=v_user and role='owner' limit 1;
 if v_business is null then raise exception 'Owner workspace required'; end if;
 if not exists(select 1 from public.customers where id=p_customer_id and business_id=v_business) then
  raise exception 'Customer not found in this workspace';
 end if;
 if jsonb_typeof(p_lines)<>'array' or jsonb_array_length(p_lines)<1 then
  raise exception 'At least one quotation line is required';
 end if;
 select max_unit_selling_price into v_max_price from public.business_settings where business_id=v_business;

 insert into public.quotations(business_id,customer_id,quote_number,valid_until,total,created_by,status)
 values(v_business,p_customer_id,btrim(p_quote_number),p_valid_until,0,v_user,'accepted')
 returning id into v_quote;

 for v_line in select value from jsonb_array_elements(p_lines) loop
  v_line_count:=v_line_count+1;
  v_item:=nullif(v_line->>'catalogue_item_id','')::uuid;
  v_method:=nullif(btrim(v_line->>'production_method'),'');
  v_client_profile:=nullif(v_line->>'costing_profile_id','')::uuid;
  v_qty:=nullif(v_line->>'quantity','')::numeric;
  v_desc:=btrim(coalesce(v_line->>'description',''));
  if v_item is null then raise exception 'Every quotation line must use an active catalogue item'; end if;
  if v_desc='' or v_qty is null or v_qty<=0 then raise exception 'Each quotation line requires a description and positive quantity'; end if;
  select ci.selling_method,ci.standard_unit_price,ci.name into v_selling_method,v_catalogue_price,v_catalogue_name from public.catalogue_items ci where ci.id=v_item and ci.business_id=v_business and ci.is_active for share;
  if not found then raise exception 'Catalogue item is inactive or does not belong to this workspace'; end if;
  if v_catalogue_price is null then raise exception 'Catalogue item % has no owner-approved standard price',v_catalogue_name; end if;
  -- The catalogue owns the base price. Browser-submitted unit_price is never trusted.
  v_standard:=v_catalogue_price;
  select count(*) into v_method_count from public.catalogue_item_methods cm where cm.business_id=v_business and cm.catalogue_item_id=v_item and cm.is_active;
  if v_method is null and v_method_count>0 then
   select count(*) into v_preferred_count from public.catalogue_item_methods cm where cm.business_id=v_business and cm.catalogue_item_id=v_item and cm.is_active and cm.is_preferred;
   if v_method_count=1 then select cm.production_method into v_method from public.catalogue_item_methods cm where cm.business_id=v_business and cm.catalogue_item_id=v_item and cm.is_active;
   elsif v_preferred_count=1 then select cm.production_method into v_method from public.catalogue_item_methods cm where cm.business_id=v_business and cm.catalogue_item_id=v_item and cm.is_active and cm.is_preferred;
   else raise exception 'Select one of the active production methods configured for %',v_catalogue_name; end if;
  end if;
  v_profile:=null;
  if v_method is not null then
   select cm.costing_profile_id into v_profile from public.catalogue_item_methods cm where cm.business_id=v_business and cm.catalogue_item_id=v_item and cm.production_method=v_method and cm.is_active for share;
   if not found then raise exception 'Selected production method is not active for this catalogue item'; end if;
  end if;
  if v_client_profile is not null and v_client_profile is distinct from v_profile then raise exception 'Costing profile is controlled by the selected catalogue production method'; end if;
  if v_selling_method in('job_costed','quantity_tier') and (v_method is null or v_profile is null) then raise exception 'This catalogue item requires an active production method with its linked costing profile'; end if;
  if v_selling_method not in('fixed_price','job_costed','quantity_tier') then raise exception 'Catalogue item has an unsupported selling method'; end if;
  if v_max_price is not null and v_standard>v_max_price then
   raise exception 'Unit selling price exceeds the owner-set maximum price of KSh %',v_max_price;
  end if;
  v_customer_supplied:=coalesce(v_line->>'supply_arrangement','mj_supplies')='customer_supplies';
  if coalesce(v_line->>'supply_arrangement','mj_supplies') not in('mj_supplies','customer_supplies') then
   raise exception 'Invalid supply arrangement';
  end if;
  v_discount_type:=coalesce(nullif(v_line->>'discount_type',''),'none');
  v_discount_value:=coalesce(nullif(v_line->>'discount_value','')::numeric,0);
  v_discount_reason:=nullif(btrim(v_line->>'discount_reason'),'');
  if v_discount_type not in('none','fixed_amount','percentage') or v_discount_value<0 then
   raise exception 'Invalid line discount';
  end if;
  if v_discount_type='none' and v_discount_value<>0 then raise exception 'A discount value requires a discount type'; end if;
  if v_discount_type<>'none' and coalesce(length(v_discount_reason),0)<3 then
   raise exception 'A reason is required for every discretionary line discount';
  end if;
  if v_discount_type='percentage' and v_discount_value>100 then raise exception 'Percentage discount cannot exceed 100';
  end if;
  v_discount:=case when v_discount_type='fixed_amount' then v_discount_value
    when v_discount_type='percentage' then round(v_standard*v_discount_value/100,2) else 0 end;
  if v_discount>v_standard then raise exception 'Line discount cannot exceed its standard unit price';
  end if;
  v_unit_net:=v_standard-v_discount;
  v_line_total:=round(v_unit_net*v_qty,2);
  v_cost:=0; v_breakdown:='[]'::jsonb; v_snapshot:='{}'::jsonb;
  v_blank_override:=nullif(v_line->>'blank_cost_per_piece','')::numeric;
  v_other:=coalesce(nullif(v_line->>'other_costs_total','')::numeric,0);
  if coalesce(v_blank_override,0)<0 or v_other<0 then raise exception 'Direct costs cannot be negative'; end if;

  if v_profile is not null then
   select cp.profile_name,cp.version,cp.components into v_profile_name,v_profile_version,v_components
   from public.costing_profiles cp where cp.id=v_profile and cp.business_id=v_business and cp.is_active for share;
   if v_profile_name is null then raise exception 'Costing profile must be active and belong to this business'; end if;
   if jsonb_typeof(v_components)<>'array' then raise exception 'Costing profile components are invalid'; end if;
   for v_component in select value from jsonb_array_elements(v_components) loop
    v_category:=coalesce(v_component->>'category','production');
    v_basis:=coalesce(v_component->>'basis','per_piece');
    v_component_cost:=coalesce(nullif(v_component->>'cost','')::numeric,0);
    if v_component_cost<0 or v_basis not in('per_piece','per_job') then raise exception 'Invalid costing component'; end if;
    if v_category='blank_item' and (v_customer_supplied or (v_blank_override is not null and v_basis='per_piece')) then continue; end if;
    if v_category not in('blank_item','production') then raise exception 'Invalid costing category'; end if;
    v_cost:=v_cost+case when v_basis='per_job' then v_component_cost else v_component_cost*v_qty end;
    v_breakdown:=v_breakdown||jsonb_build_array(jsonb_build_object(
     'name',v_component->>'name','category',v_category,'basis',v_basis,'unit_cost',v_component_cost,
     'quantity',case when v_basis='per_job' then 1 else v_qty end,
     'total_cost',case when v_basis='per_job' then v_component_cost else v_component_cost*v_qty end));
   end loop;
  elsif v_selling_method<>'fixed_price' then
   raise exception 'A costing profile is required for job-costed or quantity-tier lines';
  end if;
  if not v_customer_supplied and v_blank_override is not null then
   v_cost:=v_cost+(v_blank_override*v_qty);
   v_breakdown:=v_breakdown||jsonb_build_array(jsonb_build_object('name','Blank item override','category','blank_item','basis','per_piece','unit_cost',v_blank_override,'quantity',v_qty,'total_cost',v_blank_override*v_qty));
  end if;
  if v_other>0 then v_cost:=v_cost+v_other; v_breakdown:=v_breakdown||jsonb_build_array(jsonb_build_object('name',coalesce(v_line->>'other_costs_note','Other direct costs'),'basis','per_job','unit_cost',v_other,'quantity',1,'total_cost',v_other)); end if;
  v_margin:=case when v_line_total>0 then round(((v_line_total-v_cost)/v_line_total)*100,2) else case when v_cost=0 then 100 else -100 end end;
  if v_cost>0 and v_margin<30 then
   if not coalesce(p_allow_below_floor,false) or length(btrim(coalesce(p_exception_reason,'')))<8 then
    raise exception 'Quotation line % is below the 30%% gross-margin floor. An authorised exception and reason are required',v_line_count;
   end if;
  end if;
  v_snapshot:=jsonb_build_object('profile_id',v_profile,'profile_name',v_profile_name,'profile_version',v_profile_version,
   'quantity',v_qty,'supply_arrangement',case when v_customer_supplied then 'customer_supplies' else 'mj_supplies' end,
   'components',v_breakdown,'direct_cost_total',round(v_cost,2),'gross_margin_percent',v_margin,
   'catalogue_item_id',v_item,'catalogue_item_name',v_catalogue_name,'selling_method',v_selling_method,'production_method',v_method,'standard_unit_price',v_standard,
   'discount_type',v_discount_type,'discount_value',v_discount_value,'discount_amount_per_unit',v_discount,
   'net_unit_price',v_unit_net);
  insert into public.quotation_lines(business_id,quotation_id,catalogue_item_id,description,quantity,unit_price,
   standard_unit_price,direct_cost,line_total,production_method,costing_profile_id,
   supply_arrangement,discount_type,discount_value,discount_amount,net_unit_price,gross_margin_percent,
   discount_reason,below_floor_exception_reason,cost_snapshot,details)
  values(v_business,v_quote,v_item,v_desc,v_qty,v_unit_net,v_standard,round(v_cost,2),v_line_total,
   v_method,v_profile,case when v_customer_supplied then 'customer_supplies' else 'mj_supplies' end,
   v_discount_type,v_discount_value,round(v_discount*v_qty,2),v_unit_net,v_margin,v_discount_reason,
   case when v_cost>0 and v_margin<30 then btrim(p_exception_reason) end,v_snapshot,
   coalesce(v_line->'details','{}'::jsonb)||jsonb_build_object('cost_snapshot',v_snapshot));
  v_lines_total:=v_lines_total+v_line_total; v_all_cost:=v_all_cost+v_cost;
 end loop;
 if v_line_count=0 then raise exception 'At least one quotation line is required'; end if;
 update public.quotations set total=round(v_lines_total,2),accepted_at=now(),accepted_recorded_by=v_user
 where id=v_quote;
 insert into public.quotation_revision_history(business_id,quotation_id,revision_number,revision_reason,snapshot,created_by)
 select v_business,v_quote,1,'Initial accepted quotation',jsonb_build_object(
  'quote_number',p_quote_number,'customer_id',p_customer_id,'total',round(v_lines_total,2),
  'line_count',v_line_count,'direct_cost_total',round(v_all_cost,2),
  'lines',(select coalesce(jsonb_agg(to_jsonb(ql) order by ql.id),'[]'::jsonb) from public.quotation_lines ql where ql.quotation_id=v_quote)),v_user;
 insert into public.audit_events(business_id,actor_user_id,event_type,entity_type,entity_id,details)
 values(v_business,v_user,'quotation.accepted_created','quotation',v_quote,
  jsonb_build_object('total',round(v_lines_total,2),'line_count',v_line_count,'direct_cost_total',round(v_all_cost,2)));
 return v_quote;
end $fn$;


create or replace function public.owner_create_accepted_quotation(
 p_customer_id uuid,p_quote_number text,p_valid_until date,p_lines jsonb,
 p_allow_below_floor boolean default false,p_exception_reason text default null
) returns uuid language sql security invoker set search_path=public,private,pg_temp
as $fn$ select private.owner_create_quotation_v2_impl(
 p_customer_id,p_quote_number,p_valid_until,p_lines,p_allow_below_floor,p_exception_reason) $fn$;

revoke all on function private.owner_create_quotation_v2_impl(uuid,text,date,jsonb,boolean,text) from public,anon,authenticated;
revoke all on function public.owner_create_accepted_quotation(uuid,text,date,jsonb,boolean,text) from public,anon;
grant execute on function public.owner_create_accepted_quotation(uuid,text,date,jsonb,boolean,text) to authenticated;
notify pgrst,'reload schema';
