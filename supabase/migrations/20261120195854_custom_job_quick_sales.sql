-- One-off custom jobs are invoiced at the agreed job price without creating
-- or requiring an owner-approved catalogue standard price.
create or replace function public.owner_create_custom_job_quick_sale(
 p_customer_id uuid,
 p_invoice_number text,
 p_due_date date,
 p_description text,
 p_dimensions text,
 p_production_method text,
 p_costing_profile_id uuid,
 p_quantity numeric,
 p_agreed_price numeric,
 p_supply_arrangement text,
 p_other_direct_costs numeric default 0,
 p_allow_below_floor boolean default false,
 p_exception_reason text default null,
 p_payment_number text default null,
 p_payment_method text default null,
 p_payment_amount numeric default 0,
 p_payment_reference text default null
) returns jsonb
language plpgsql
security definer
set search_path=public,pg_temp
as $fn$
declare
 v_user uuid:=auth.uid();
 v_business uuid;
 v_item uuid;
 v_profile_name text;
 v_result jsonb;
 v_label text;
begin
 if v_user is null then raise exception 'Authentication required'; end if;
 select business_id into v_business
 from public.business_memberships
 where user_id=v_user and role='owner'
 order by created_at limit 1;
 if v_business is null then raise exception 'Owner workspace required'; end if;
 if length(btrim(coalesce(p_description,'')))<2 then raise exception 'Custom job description is required'; end if;
 if length(btrim(coalesce(p_dimensions,'')))<2 then raise exception 'Custom job dimensions or size are required'; end if;
 if p_production_method is null or p_production_method not in('vinyl_cutting','dtf','screen_printing','sublimation','embroidery','other') then
  raise exception 'Unsupported custom job production method';
 end if;
 if p_quantity is null or p_quantity<=0 or p_quantity<>trunc(p_quantity) then
  raise exception 'Quantity must be a whole number greater than zero';
 end if;
 if p_costing_profile_id is null then raise exception 'An active costing profile is required for a custom job'; end if;
 select profile_name into v_profile_name from public.costing_profiles
 where id=p_costing_profile_id and business_id=v_business and is_active for share;
 if v_profile_name is null then raise exception 'Costing profile must be active and belong to this business'; end if;
 if p_agreed_price is null or p_agreed_price<=0 then raise exception 'Agreed custom job price must be greater than zero'; end if;
 if p_supply_arrangement is null or p_supply_arrangement not in('mj_supplies','customer_supplies') then raise exception 'Invalid supply arrangement'; end if;
 if coalesce(p_other_direct_costs,0)<0 then raise exception 'Other direct costs cannot be negative'; end if;
 if coalesce(p_payment_amount,0)<0 then raise exception 'Payment amount cannot be negative'; end if;
 if coalesce(p_allow_below_floor,false) and length(btrim(coalesce(p_exception_reason,'')))<8 then
  raise exception 'A below-floor exception reason must contain at least 8 characters';
 end if;

 v_label:=btrim(p_description)||' ('||btrim(p_dimensions)||')';
 -- Create a transaction-scoped catalogue record with the agreed one-off price.
 -- It is used only to reuse the canonical Quick Sale accounting and costing path,
 -- then removed before this function returns. It never becomes a standard catalogue item.
 insert into public.catalogue_items(
  business_id,name,description,item_type,category,shop_location,selling_method,
  standard_unit_price,price_unit,minimum_quantity,
  quantity_rules,is_active
 ) values(
  v_business,v_label,'Temporary transaction record for custom job: '||v_label,
  'service','Custom jobs','shop_1','job_costed',
  round(p_agreed_price,2),'job',null,
  jsonb_build_object('one_off_custom_job',true),true
 ) returning id into v_item;

 insert into public.catalogue_item_methods(
  business_id,catalogue_item_id,production_method,costing_profile_id,
  is_preferred,is_active,suitability_notes
 ) values(
  v_business,v_item,p_production_method,p_costing_profile_id,true,true,
  'One-off custom job; dimensions and description are retained on the invoice.'
 );

 v_result:=public.owner_create_quick_sale(
  p_customer_id=>p_customer_id,
  p_invoice_number=>p_invoice_number,
  p_due_date=>p_due_date,
  p_catalogue_item_id=>v_item,
  p_production_method=>p_production_method,
  p_quantity=>p_quantity,
  p_unit_price=>round(p_agreed_price,2),
  p_supply_arrangement=>p_supply_arrangement,
  p_other_direct_costs=>coalesce(p_other_direct_costs,0),
  p_price_reason=>null,
  p_allow_below_floor=>coalesce(p_allow_below_floor,false),
  p_exception_reason=>p_exception_reason,
  p_payment_number=>p_payment_number,
  p_payment_method=>p_payment_method,
  p_payment_amount=>coalesce(p_payment_amount,0),
  p_payment_reference=>p_payment_reference
 );

 -- Replace the canonical catalogue-shaped snapshot with an explicit one-off
 -- custom-job snapshot before deleting the temporary catalogue record. The
 -- agreed price must never be represented as an approved catalogue price.
 update public.sales_invoice_items
 set description=v_label,
     item_type='custom_production',
     cost_snapshot=(
      coalesce(cost_snapshot,'{}'::jsonb)
       - 'catalogue_item_id'
       - 'catalogue_item_name'
       - 'catalogue_standard_price'
       - 'selling_method'
     ) || jsonb_build_object(
      'transaction_type','custom_job',
      'one_off_price',true,
      'agreed_unit_price',round(p_agreed_price,2),
      'description',btrim(p_description),
      'dimensions',btrim(p_dimensions),
      'production_method',p_production_method,
      'profile_id',p_costing_profile_id,
      'profile_name',v_profile_name
     )
 where business_id=v_business and invoice_id=(v_result->>'invoice_id')::uuid;

 -- The canonical audit event initially records the temporary catalogue ID.
 -- Remove that transient reference and identify the source as a custom job.
 update public.audit_events
 set details=(coalesce(details,'{}'::jsonb)-'catalogue_item_id') || jsonb_build_object(
  'source','custom_job','one_off_price',true,
  'agreed_unit_price',round(p_agreed_price,2),
  'description',btrim(p_description),'dimensions',btrim(p_dimensions),
  'production_method',p_production_method,'costing_profile_id',p_costing_profile_id
 )
 where business_id=v_business
  and entity_type='sales_invoice'
  and entity_id=(v_result->>'invoice_id')::uuid
  and event_type='quick_sale.created';

 delete from public.catalogue_item_methods
 where business_id=v_business and catalogue_item_id=v_item;
 delete from public.catalogue_items
 where business_id=v_business and id=v_item;

 insert into public.audit_events(business_id,actor_user_id,event_type,entity_type,entity_id,details)
 values(v_business,v_user,'custom_job_quick_sale.created','sales_invoice',(v_result->>'invoice_id')::uuid,
  jsonb_build_object(
   'description',btrim(p_description),'dimensions',btrim(p_dimensions),
   'production_method',p_production_method,'costing_profile_id',p_costing_profile_id,
   'costing_profile_name',v_profile_name,'quantity',p_quantity,
   'agreed_unit_price',round(p_agreed_price,2),'supply_arrangement',p_supply_arrangement,
   'one_off_price',true
  ));

 return jsonb_set(v_result,'{description}',to_jsonb(v_label),true);
end
$fn$;

revoke all on function public.owner_create_custom_job_quick_sale(uuid,text,date,text,text,text,uuid,numeric,numeric,text,numeric,boolean,text,text,text,numeric,text) from public,anon;
grant execute on function public.owner_create_custom_job_quick_sale(uuid,text,date,text,text,text,uuid,numeric,numeric,text,numeric,boolean,text,text,text,numeric,text) to authenticated;

notify pgrst,'reload schema';
