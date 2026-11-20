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
set search_path to 'public','pg_temp'
as $function$
declare
 v_user uuid:=auth.uid();
 v_business uuid;
 v_profile uuid;
 v_profile_name text;
 v_result jsonb;
 v_invoice uuid;
 v_line_total numeric(14,2);
 v_margin numeric(7,2);
 v_label text;
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

 -- A transaction-only profile lets the existing canonical sale RPC enforce the
 -- 30% direct-cost margin floor and create the invoice/payment ledger atomically.
 -- It is deleted before commit; its cost snapshot is replaced with the calculator's
 -- itemised, job-specific evidence below.
 v_profile_name:='__vinyl_sale_'||replace(gen_random_uuid()::text,'-','');
 insert into public.costing_profiles(
  business_id,profile_name,version,is_active,components,direct_cost,margin_floor,full_cost_target
 ) values(
  v_business,v_profile_name,1,true,
  jsonb_build_array(jsonb_build_object(
   'name','Vinyl sticker direct production costs','category','production',
   'basis','per_job','cost',round(p_direct_cost_total,2)
  )),
  round(p_direct_cost_total,2),30,1.8
 ) returning id into v_profile;

 v_label:=btrim(p_description)||' ('||btrim(p_dimensions)||')';
 v_result:=public.owner_create_custom_job_quick_sale(
  p_customer_id=>p_customer_id,
  p_invoice_number=>p_invoice_number,
  p_due_date=>p_due_date,
  p_description=>btrim(p_description),
  p_dimensions=>btrim(p_dimensions),
  p_production_method=>'vinyl_cutting',
  p_costing_profile_id=>v_profile,
  p_quantity=>p_quantity,
  p_agreed_price=>round(p_agreed_price,2),
  p_supply_arrangement=>p_supply_arrangement,
  p_other_direct_costs=>0,
  p_allow_below_floor=>coalesce(p_allow_below_floor,false),
  p_exception_reason=>p_exception_reason,
  p_payment_number=>p_payment_number,
  p_payment_method=>p_payment_method,
  p_payment_amount=>coalesce(p_payment_amount,0),
  p_payment_reference=>p_payment_reference
 );
 v_invoice:=(v_result->>'invoice_id')::uuid;
 v_line_total:=round(p_quantity*p_agreed_price,2);
 v_margin:=case when v_line_total>0 then round(((v_line_total-(p_direct_cost_total*p_quantity))/v_line_total)*100,2) else 0 end;

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
        'pricing_details',p_pricing_details,
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
    'pricing_details',p_pricing_details,
    'direct_cost_breakdown',p_direct_cost_breakdown,
    'supply_arrangement',p_supply_arrangement
   )
 where business_id=v_business and entity_type='sales_invoice' and entity_id=v_invoice
  and event_type='custom_job_quick_sale.created';

 delete from public.costing_profiles where id=v_profile and business_id=v_business;

 return v_result || jsonb_build_object(
  'direct_cost_total',round(p_direct_cost_total*p_quantity,2),
  'unit_direct_cost',round(p_direct_cost_total,2),
  'gross_margin_percent',v_margin,
  'pricing_source','vinyl_sticker_calculator'
 );
end
$function$;

revoke all on function public.owner_create_vinyl_sticker_quick_sale(uuid,text,date,text,text,numeric,numeric,text,numeric,jsonb,jsonb,boolean,text,text,text,numeric,text) from public,anon;
grant execute on function public.owner_create_vinyl_sticker_quick_sale(uuid,text,date,text,text,numeric,numeric,text,numeric,jsonb,jsonb,boolean,text,text,text,numeric,text) to authenticated;
