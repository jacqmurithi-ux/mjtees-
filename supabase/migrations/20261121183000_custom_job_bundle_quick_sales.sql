-- Atomic walk-in custom job sale with optional, separately priced catalogue lines.
-- All invoice, line, payment and audit writes remain inside owner-authorised RPCs.
create or replace function public.owner_create_custom_job_bundle_quick_sale(
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
 p_catalogue_lines jsonb default '[]'::jsonb,
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
 v_customer uuid;
 v_invoice uuid;
 v_temp_invoice uuid;
 v_addon jsonb;
 v_addon_result jsonb;
 v_result jsonb;
 v_payment uuid;
 v_total numeric(14,2);
 v_paid numeric(14,2):=coalesce(p_payment_amount,0);
 v_items jsonb;
 v_line_count integer:=0;
begin
 if v_user is null then raise exception 'Authentication required'; end if;
 select business_id into v_business
 from public.business_memberships
 where user_id=v_user and role='owner'
 order by created_at limit 1;
 if v_business is null then raise exception 'Owner workspace required'; end if;
 if p_catalogue_lines is null or jsonb_typeof(p_catalogue_lines)<>'array' then
  raise exception 'Catalogue add-ons must be supplied as a JSON array';
 end if;
 if jsonb_array_length(p_catalogue_lines)>20 then
  raise exception 'A custom sale can contain no more than 20 catalogue add-on lines';
 end if;
 if v_paid<0 then raise exception 'Payment amount cannot be negative'; end if;

 -- Create the custom-job invoice first, with no payment. The existing canonical
 -- custom-job flow performs owner, profile, costing and margin-floor validation.
 v_result:=public.owner_create_custom_job_quick_sale(
  p_customer_id=>p_customer_id,
  p_invoice_number=>p_invoice_number,
  p_due_date=>p_due_date,
  p_description=>p_description,
  p_dimensions=>p_dimensions,
  p_production_method=>p_production_method,
  p_costing_profile_id=>p_costing_profile_id,
  p_quantity=>p_quantity,
  p_agreed_price=>p_agreed_price,
  p_supply_arrangement=>p_supply_arrangement,
  p_other_direct_costs=>coalesce(p_other_direct_costs,0),
  p_allow_below_floor=>coalesce(p_allow_below_floor,false),
  p_exception_reason=>p_exception_reason,
  p_payment_number=>null,
  p_payment_method=>null,
  p_payment_amount=>0,
  p_payment_reference=>null
 );
 v_invoice:=(v_result->>'invoice_id')::uuid;
 select customer_id into v_customer
 from public.sales_invoices
 where id=v_invoice and business_id=v_business
 for update;
 if v_customer is null then raise exception 'Could not resolve the customer for the custom-job invoice'; end if;

 -- Reuse the approved catalogue-sale RPC for each add-on so standard price,
 -- active item/method, costing snapshot, 30% margin and exception checks remain
 -- identical to ordinary catalogue sales. Its temporary invoice and transient
 -- audit row are folded into the primary invoice before this transaction ends.
 for v_addon in select value from jsonb_array_elements(p_catalogue_lines) loop
  v_addon_result:=public.owner_create_quick_sale(
   p_customer_id=>v_customer,
   p_invoice_number=>'__BUNDLE__'||replace(gen_random_uuid()::text,'-',''),
   p_due_date=>p_due_date,
   p_catalogue_item_id=>nullif(v_addon->>'catalogue_item_id','')::uuid,
   p_production_method=>nullif(v_addon->>'production_method',''),
   p_quantity=>nullif(v_addon->>'quantity','')::numeric,
   p_unit_price=>nullif(v_addon->>'unit_price','')::numeric,
   p_supply_arrangement=>coalesce(nullif(v_addon->>'supply_arrangement',''),'mj_supplies'),
   p_other_direct_costs=>coalesce(nullif(v_addon->>'other_direct_costs','')::numeric,0),
   p_price_reason=>nullif(v_addon->>'price_reason',''),
   p_allow_below_floor=>coalesce((v_addon->>'allow_below_floor')::boolean,false),
   p_exception_reason=>nullif(v_addon->>'exception_reason',''),
   p_payment_number=>null,
   p_payment_method=>null,
   p_payment_amount=>0,
   p_payment_reference=>null
  );
  v_temp_invoice:=(v_addon_result->>'invoice_id')::uuid;
  update public.sales_invoice_items
  set invoice_id=v_invoice
  where business_id=v_business and invoice_id=v_temp_invoice;
  if not found then raise exception 'Could not attach a catalogue add-on to the custom-job invoice'; end if;
  delete from public.audit_events
  where business_id=v_business and entity_type='sales_invoice'
   and entity_id=v_temp_invoice and event_type='quick_sale.created';
  delete from public.sales_invoices
  where business_id=v_business and id=v_temp_invoice;
  if not found then raise exception 'Could not remove the temporary add-on invoice'; end if;
  v_line_count:=v_line_count+1;
 end loop;

 select round(coalesce(sum(line_total),0),2),
        coalesce(jsonb_agg(jsonb_build_object(
         'description',description,'quantity',quantity,'unit_price',unit_price,
         'line_total',line_total,'item_type',item_type
        ) order by id),'[]'::jsonb)
 into v_total,v_items
 from public.sales_invoice_items
 where business_id=v_business and invoice_id=v_invoice;
 if v_total<=0 then raise exception 'The combined invoice total must be greater than zero'; end if;
 if v_paid>v_total then raise exception 'Payment cannot exceed the combined invoice total'; end if;
 if v_paid>0 and (
  nullif(btrim(coalesce(p_payment_number,'')),'') is null
  or p_payment_method not in('cash','mpesa_paybill')
 ) then raise exception 'A payment number and valid payment method are required for money received'; end if;

 if v_paid>0 then
  insert into public.payments(
   business_id,customer_id,payment_number,method,amount,reference_code,received_by
  ) values(
   v_business,v_customer,btrim(p_payment_number),p_payment_method,v_paid,
   nullif(btrim(p_payment_reference),''),v_user
  ) returning id into v_payment;
  insert into public.payment_allocations(business_id,payment_id,invoice_id,amount)
  values(v_business,v_payment,v_invoice,v_paid);
 end if;

 update public.sales_invoices
 set total=v_total,
     amount_paid=v_paid,
     balance=v_total-v_paid,
     status=case when v_paid=v_total then 'paid' when v_paid>0 then 'partially_paid' else 'sent' end
 where business_id=v_business and id=v_invoice;

 insert into public.audit_events(business_id,actor_user_id,event_type,entity_type,entity_id,details)
 values(v_business,v_user,'custom_job_bundle_quick_sale.created','sales_invoice',v_invoice,
  jsonb_build_object(
   'source','custom_job_with_catalogue_addons',
   'catalogue_addon_count',v_line_count,
   'invoice_total',v_total,
   'amount_received',v_paid,
   'payment_id',v_payment,
   'catalogue_lines',p_catalogue_lines
  ));

 return v_result||jsonb_build_object(
  'total',v_total,
  'amount_paid',v_paid,
  'balance',v_total-v_paid,
  'payment_id',v_payment,
  'payment_number',case when v_payment is null then null else p_payment_number end,
  'payment_method',case when v_payment is null then null else p_payment_method end,
  'payment_reference',case when v_payment is null then null else nullif(btrim(p_payment_reference),'') end,
  'items',v_items
 );
end
$fn$;

revoke all on function public.owner_create_custom_job_bundle_quick_sale(uuid,text,date,text,text,text,uuid,numeric,numeric,text,numeric,boolean,text,jsonb,text,text,numeric,text) from public,anon;
grant execute on function public.owner_create_custom_job_bundle_quick_sale(uuid,text,date,text,text,text,uuid,numeric,numeric,text,numeric,boolean,text,jsonb,text,text,numeric,text) to authenticated;

notify pgrst,'reload schema';
