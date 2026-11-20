-- Manual quotation acceptance evidence and immutable revision workflow.
-- New quotations remain drafts until issued and explicitly accepted by the owner.

alter table public.quotations
 add column if not exists acceptance_method text,
 add column if not exists acceptance_reference text,
 add column if not exists acceptance_notes text,
 add column if not exists accepted_revision_number integer;

alter table public.quotations drop constraint if exists quotations_acceptance_method_check;
alter table public.quotations add constraint quotations_acceptance_method_check
 check(acceptance_method is null or acceptance_method in('in_person','phone','email','whatsapp','other'));

create or replace function private.owner_create_quotation_v2_impl(
 p_customer_id uuid,p_quote_number text,p_valid_until date,p_lines jsonb,
 p_allow_below_floor boolean default false,p_exception_reason text default null
) returns uuid
language plpgsql security definer set search_path=public,private,pg_temp
as $fn$
declare
 v_business uuid; v_user uuid; v_quote uuid; v_line jsonb; v_item uuid;
 v_method text; v_profile uuid; v_profile_name text; v_profile_version integer; v_components jsonb;
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
 values(v_business,p_customer_id,btrim(p_quote_number),p_valid_until,0,v_user,'draft')
 returning id into v_quote;

 for v_line in select value from jsonb_array_elements(p_lines) loop
  v_line_count:=v_line_count+1;
  v_item:=nullif(v_line->>'catalogue_item_id','')::uuid;
  v_method:=nullif(btrim(v_line->>'production_method'),'');
  v_profile:=nullif(v_line->>'costing_profile_id','')::uuid;
  v_qty:=nullif(v_line->>'quantity','')::numeric;
  v_standard:=nullif(v_line->>'unit_price','')::numeric;
  v_desc:=btrim(coalesce(v_line->>'description',''));
  if v_desc='' or v_qty is null or v_qty<=0 or v_standard is null or v_standard<0 then
   raise exception 'Each quotation line requires a description, positive quantity and non-negative approved unit price';
  end if;
  if v_max_price is not null and v_standard>v_max_price then
   raise exception 'Unit selling price exceeds the owner-set maximum price of KSh %',v_max_price;
  end if;
  if v_item is not null and not exists(select 1 from public.catalogue_items ci
    where ci.id=v_item and ci.business_id=v_business and ci.is_active) then
   raise exception 'Catalogue item is inactive or does not belong to this workspace';
  end if;
  if v_item is not null and not exists(select 1 from public.catalogue_item_methods cm
    where cm.business_id=v_business and cm.catalogue_item_id=v_item and cm.is_active
     and (v_method is null or cm.production_method=v_method)) and v_method is not null then
   raise exception 'Selected production method is not active for this catalogue item';
  end if;
  if v_method is not null and v_method not in('sublimation','dtf','screen_printing','embroidery','vinyl_cutting','other') then
   raise exception 'Unsupported production method';
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
  elsif coalesce(v_line->>'selling_method','')<>'fixed_price' then
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
   'catalogue_item_id',v_item,'production_method',v_method,'standard_unit_price',v_standard,
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
 update public.quotations set total=round(v_lines_total,2)
 where id=v_quote;
 insert into public.audit_events(business_id,actor_user_id,event_type,entity_type,entity_id,details)
 values(v_business,v_user,'quotation.created','quotation',v_quote,
  jsonb_build_object('total',round(v_lines_total,2),'line_count',v_line_count,'direct_cost_total',round(v_all_cost,2)));
 return v_quote;
end $fn$;


create or replace function public.owner_set_quotation_status(
 p_quote_id uuid,p_status text
) returns void language plpgsql security definer set search_path=public,pg_temp
as $fn$
declare q public.quotations%rowtype;
begin
 if auth.uid() is null then raise exception 'Authentication required'; end if;
 if p_status<>'sent' then raise exception 'Use the acceptance evidence action to record customer acceptance'; end if;
 select * into q from public.quotations where id=p_quote_id for update;
 if not found or not exists(select 1 from public.business_memberships where business_id=q.business_id and user_id=auth.uid() and role='owner') then raise exception 'Quotation not found'; end if;
 if q.status<>'draft' then raise exception 'Only a draft quotation can be issued'; end if;
 if exists(select 1 from public.quotations newer where newer.supersedes_quotation_id=q.id and newer.business_id=q.business_id) then raise exception 'A superseded quotation cannot be issued'; end if;
 update public.quotations set status='sent' where id=q.id;
 insert into public.audit_events(business_id,actor_user_id,event_type,entity_type,entity_id,details)
 values(q.business_id,auth.uid(),'quotation.status_changed','quotation',q.id,jsonb_build_object('from',q.status,'to','sent','revision_number',q.revision_number));
end
$fn$;

create or replace function public.owner_record_quotation_acceptance(
 p_quote_id uuid,p_acceptance_method text,p_acceptance_reference text,p_acceptance_notes text
) returns void language plpgsql security definer set search_path=public,pg_temp
as $fn$
declare q public.quotations%rowtype;
begin
 if auth.uid() is null then raise exception 'Authentication required'; end if;
 if p_acceptance_method not in('in_person','phone','email','whatsapp','other') then raise exception 'Select how the customer confirmed acceptance'; end if;
 if length(btrim(coalesce(p_acceptance_notes,'')))<3 then raise exception 'Acceptance notes are required'; end if;
 select * into q from public.quotations where id=p_quote_id for update;
 if not found or not exists(select 1 from public.business_memberships where business_id=q.business_id and user_id=auth.uid() and role='owner') then raise exception 'Quotation not found'; end if;
 if q.status<>'sent' then raise exception 'Only an issued quotation can be accepted'; end if;
 if exists(select 1 from public.quotations newer where newer.supersedes_quotation_id=q.id and newer.business_id=q.business_id) then raise exception 'Only the current issued quotation revision can be accepted'; end if;
 update public.quotations set status='accepted',accepted_at=now(),accepted_recorded_by=auth.uid(),
  acceptance_method=p_acceptance_method,acceptance_reference=nullif(btrim(p_acceptance_reference),''),
  acceptance_notes=btrim(p_acceptance_notes),accepted_revision_number=revision_number
 where id=q.id;
 insert into public.audit_events(business_id,actor_user_id,event_type,entity_type,entity_id,details)
 values(q.business_id,auth.uid(),'quotation.accepted','quotation',q.id,jsonb_build_object(
  'quote_number',q.quote_number,'revision_number',q.revision_number,'accepted_at',now(),
  'acceptance_method',p_acceptance_method,'acceptance_reference',nullif(btrim(p_acceptance_reference),''),
  'acceptance_notes',btrim(p_acceptance_notes)));
end
$fn$;

create or replace function public.owner_create_quotation_revision(
 p_quote_id uuid,p_quote_number text,p_valid_until date,p_lines jsonb,
 p_allow_below_floor boolean default false,p_exception_reason text default null,p_revision_reason text default null
) returns uuid language plpgsql security definer set search_path=public,private,pg_temp
as $fn$
declare q public.quotations%rowtype; v_new_quote uuid; v_revision integer;
begin
 if auth.uid() is null then raise exception 'Authentication required'; end if;
 if length(btrim(coalesce(p_revision_reason,'')))<5 then raise exception 'A revision reason of at least 5 characters is required'; end if;
 select * into q from public.quotations where id=p_quote_id for update;
 if not found or not exists(select 1 from public.business_memberships where business_id=q.business_id and user_id=auth.uid() and role='owner') then raise exception 'Quotation not found'; end if;
 if q.status not in('sent','accepted') then raise exception 'Only an issued or accepted quotation can be revised'; end if;
 if exists(select 1 from public.quotations newer where newer.supersedes_quotation_id=q.id and newer.business_id=q.business_id) then raise exception 'Only the current quotation revision can be revised'; end if;
 if exists(select 1 from public.sales_invoices where quotation_id=q.id and business_id=q.business_id) then raise exception 'An invoiced quotation cannot be revised'; end if;
 v_revision:=q.revision_number+1;
 v_new_quote:=private.owner_create_quotation_v2_impl(q.customer_id,p_quote_number,p_valid_until,p_lines,p_allow_below_floor,p_exception_reason);
 update public.quotations set revision_number=v_revision,revision_reason=btrim(p_revision_reason),supersedes_quotation_id=q.id
 where id=v_new_quote and business_id=q.business_id;
 insert into public.quotation_revision_history(business_id,quotation_id,revision_number,revision_reason,snapshot,created_by)
 values(q.business_id,q.id,q.revision_number,btrim(p_revision_reason),jsonb_build_object(
  'quotation',to_jsonb(q),'lines',(select coalesce(jsonb_agg(to_jsonb(l) order by l.line_number nulls last,l.id),'[]'::jsonb) from public.quotation_lines l where l.quotation_id=q.id and l.business_id=q.business_id)
 ),auth.uid());
 insert into public.audit_events(business_id,actor_user_id,event_type,entity_type,entity_id,details)
 values(q.business_id,auth.uid(),'quotation.revision_created','quotation',v_new_quote,jsonb_build_object(
  'supersedes_quotation_id',q.id,'revision_number',v_revision,'revision_reason',btrim(p_revision_reason)));
 return v_new_quote;
end
$fn$;

create or replace function public.owner_convert_accepted_quote_to_invoice(
 p_quote_id uuid,p_invoice_number text,p_due_date date default null
) returns jsonb
language plpgsql
security definer
set search_path=public,pg_temp
as $fn$
declare
 q public.quotations%rowtype;
 v_invoice public.sales_invoices%rowtype;
 v_invoice_id uuid;
 v_user uuid;
 v_line_count integer;
 v_lines_total numeric(14,2);
 v_paid numeric(14,2):=0;
 v_deposit record;
 v_payment uuid;
begin
 v_user:=auth.uid();
 if v_user is null then raise exception 'Authentication required'; end if;

 select * into q from public.quotations where id=p_quote_id for update;
 if not found or not exists(
  select 1 from public.business_memberships
  where business_id=q.business_id and user_id=v_user and role='owner'
 ) then raise exception 'Quotation not found'; end if;

 -- Idempotency: a quotation can produce only one invoice.
 select * into v_invoice from public.sales_invoices
 where quotation_id=q.id and business_id=q.business_id for update;
 if found then
  return jsonb_build_object(
   'invoice_id',v_invoice.id,'quotation_id',q.id,
   'deposits_applied',v_invoice.amount_paid,'balance',v_invoice.balance,
   'already_converted',true
  );
 end if;

 if q.status<>'accepted' then
  raise exception 'Only fully accepted quotations can be converted to an invoice';
 end if;
 if exists(select 1 from public.quotations newer where newer.supersedes_quotation_id=q.id and newer.business_id=q.business_id) then
  raise exception 'Only the current quotation revision can be converted to an invoice';
 end if;
 if nullif(btrim(p_invoice_number),'') is null then
  raise exception 'Invoice number is required';
 end if;

 select count(*),coalesce(sum(line_total),0)
 into v_line_count,v_lines_total
 from public.quotation_lines
 where quotation_id=q.id and business_id=q.business_id;
 if v_line_count=0 then raise exception 'The accepted quotation has no lines'; end if;
 if round(v_lines_total,2)<>round(q.total,2) then
  raise exception 'Quotation line totals do not match the accepted quotation total';
 end if;

 select coalesce(sum(amount),0) into v_paid
 from public.quotation_deposits
 where quotation_id=q.id and business_id=q.business_id;
 if v_paid>q.total then raise exception 'Recorded deposits exceed quotation total'; end if;

 insert into public.sales_invoices(
  business_id,customer_id,quotation_id,invoice_number,status,due_date,total,amount_paid,balance,created_by
 ) values(
  q.business_id,q.customer_id,q.id,btrim(p_invoice_number),
  case when v_paid=q.total then 'paid' when v_paid>0 then 'partially_paid' else 'sent' end,
  p_due_date,q.total,v_paid,q.total-v_paid,v_user
 ) returning id into v_invoice_id;

 -- Copy every accepted quotation line without recalculating its price or cost snapshot.
 insert into public.sales_invoice_items(
  business_id,invoice_id,quotation_line_id,description,quantity,unit_price,line_total,direct_cost,cost_snapshot,item_type
 )
 select q.business_id,v_invoice_id,l.id,l.description,l.quantity,l.unit_price,l.line_total,l.direct_cost,
  coalesce(l.details->'cost_snapshot','{}'::jsonb),
  case when l.details->>'item_type' in('blank_product','printing_service','custom_production','other')
   then l.details->>'item_type' else 'other' end
 from public.quotation_lines l
 where l.quotation_id=q.id and l.business_id=q.business_id
 order by l.line_number nulls last,l.id;

 -- Preserve the existing deposit-to-payment allocation workflow.
 for v_deposit in
  select * from public.quotation_deposits
  where quotation_id=q.id and business_id=q.business_id order by received_at,id
 loop
  insert into public.payments(
   business_id,customer_id,payment_number,method,amount,reference_code,received_by,received_at
  ) values(
   q.business_id,q.customer_id,'QD-'||v_deposit.deposit_number,v_deposit.method,
   v_deposit.amount,v_deposit.reference_code,v_deposit.received_by,v_deposit.received_at
  ) returning id into v_payment;
  insert into public.payment_allocations(business_id,payment_id,invoice_id,amount)
  values(q.business_id,v_payment,v_invoice_id,v_deposit.amount);
 end loop;

 update public.quotations set status='converted' where id=q.id;
 insert into public.audit_events(business_id,actor_user_id,event_type,entity_type,entity_id,details)
 values(q.business_id,v_user,'quotation.invoiced','quotation',q.id,
  jsonb_build_object('invoice_id',v_invoice_id,'deposits_applied',v_paid,'production_job_created',false));

 return jsonb_build_object(
  'invoice_id',v_invoice_id,'quotation_id',q.id,
  'deposits_applied',v_paid,'balance',q.total-v_paid,
  'production_job_created',false,'already_converted',false
 );
end
$fn$;


revoke all on function public.owner_record_quotation_acceptance(uuid,text,text,text) from public,anon;
revoke all on function public.owner_create_quotation_revision(uuid,text,date,jsonb,boolean,text,text) from public,anon;
grant execute on function public.owner_record_quotation_acceptance(uuid,text,text,text) to authenticated;
grant execute on function public.owner_create_quotation_revision(uuid,text,date,jsonb,boolean,text,text) to authenticated;
notify pgrst,'reload schema';
