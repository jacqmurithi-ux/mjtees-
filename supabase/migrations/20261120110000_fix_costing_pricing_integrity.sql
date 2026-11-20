-- Pricing integrity: owner-set unit ceiling, quantity-aware profile costing and true gross margin.
alter table public.business_settings
 add column if not exists max_unit_selling_price numeric(14,2)
 check(max_unit_selling_price is null or max_unit_selling_price>0);

comment on column public.business_settings.max_unit_selling_price is
 'Optional owner-controlled maximum KSh selling price per finished item. NULL means no ceiling.';

create or replace function public.owner_update_max_unit_selling_price(p_max_unit_selling_price numeric)
returns void
language plpgsql
security definer
set search_path=public,pg_temp
as $fn$
declare v_business uuid;
begin
 if p_max_unit_selling_price is not null and p_max_unit_selling_price<=0 then
  raise exception 'Maximum unit selling price must be greater than zero or null';
 end if;
 select business_id into v_business
 from public.business_memberships
 where user_id=auth.uid() and role='owner'
 limit 1;
 if v_business is null then raise exception 'Owner workspace required'; end if;
 update public.business_settings
 set max_unit_selling_price=p_max_unit_selling_price
 where business_id=v_business;
 if not found then raise exception 'Business settings not found'; end if;
 insert into public.audit_events(business_id,actor_user_id,event_type,entity_type,entity_id,details)
 values(v_business,auth.uid(),'pricing.ceiling_updated','business_settings',v_business,
  jsonb_build_object('max_unit_selling_price',p_max_unit_selling_price));
end
$fn$;

revoke all on function public.owner_update_max_unit_selling_price(numeric) from public,anon;
grant execute on function public.owner_update_max_unit_selling_price(numeric) to authenticated;

create or replace function private.owner_create_quotation_impl(
 p_customer_id uuid,p_costing_profile_id uuid,p_quote_number text,p_valid_until date,p_lines jsonb,
 p_allow_below_floor boolean default false,p_exception_reason text default null
) returns uuid
language plpgsql
security definer
set search_path=public,pg_temp
as $fn$
declare
 v_business uuid;
 v_user uuid;
 v_quote uuid;
 v_profile uuid;
 v_profile_name text;
 v_profile_version integer;
 v_components jsonb;
 v_total numeric(14,2):=0;
 v_cost numeric(14,2):=0;
 v_line jsonb;
 v_qty numeric(14,3);
 v_price numeric(14,2);
 v_desc text;
 v_customer_supplied boolean;
 v_blank_override numeric(14,2);
 v_other_costs numeric(14,2);
 v_component jsonb;
 v_component_name text;
 v_category text;
 v_basis text;
 v_component_cost numeric(14,2);
 v_component_total numeric(14,2);
 v_blank_total numeric(14,2):=0;
 v_breakdown jsonb:='[]'::jsonb;
 v_snapshot jsonb;
 v_margin_percent numeric(14,4);
 v_max_unit_price numeric(14,2);
begin
 v_user:=auth.uid();
 select business_id into v_business
 from public.business_memberships
 where user_id=v_user and role='owner'
 limit 1;
 if v_business is null then raise exception 'Owner workspace required'; end if;
 if not exists(select 1 from public.customers where id=p_customer_id and business_id=v_business) then
  raise exception 'Customer not found in this workspace';
 end if;

 select id,profile_name,version,components
 into v_profile,v_profile_name,v_profile_version,v_components
 from public.costing_profiles
 where id=p_costing_profile_id and business_id=v_business and is_active
 for share;
 if v_profile is null then raise exception 'An active versioned costing profile is required before pricing this quotation'; end if;
 if jsonb_typeof(v_components)<>'array' or jsonb_array_length(v_components)=0 then
  raise exception 'The active costing profile has no cost components';
 end if;
 if jsonb_typeof(p_lines)<>'array' or jsonb_array_length(p_lines)<>1 then
  raise exception 'This costing profile prices one production line per quotation';
 end if;

 select max_unit_selling_price into v_max_unit_price
 from public.business_settings where business_id=v_business;

 v_line:=p_lines->0;
 v_qty:=nullif(v_line->>'quantity','')::numeric;
 v_price:=nullif(v_line->>'unit_price','')::numeric;
 v_desc:=btrim(coalesce(v_line->>'description',''));
 if v_qty is null or v_qty<=0 or v_price is null or v_price<0 or v_desc='' then
  raise exception 'Invalid quotation line';
 end if;
 if v_max_unit_price is not null and v_price>v_max_unit_price then
  raise exception 'Unit selling price exceeds the owner-set maximum price of KSh %',v_max_unit_price;
 end if;

 v_customer_supplied:=coalesce((v_line->'details'->>'customer_supplied_items')::boolean,false);
 v_blank_override:=nullif(v_line->'details'->>'blank_cost_per_piece','')::numeric;
 v_other_costs:=coalesce(nullif(v_line->'details'->>'other_costs_total','')::numeric,0);
 if coalesce(v_other_costs,0)<0 or coalesce(v_blank_override,0)<0 then
  raise exception 'Direct cost inputs cannot be negative';
 end if;

 if not v_customer_supplied and v_blank_override is not null then
  v_blank_total:=v_blank_override*v_qty;
  v_cost:=v_cost+v_blank_total;
  v_breakdown:=v_breakdown||jsonb_build_array(jsonb_build_object(
   'name','Blank garment / item (owner quote override)','category','blank_item',
   'basis','per_piece','unit_cost',v_blank_override,'quantity',v_qty,'total_cost',v_blank_total
  ));
 end if;

 for v_component in select value from jsonb_array_elements(v_components) loop
  v_component_name:=btrim(coalesce(v_component->>'name',''));
  v_category:=coalesce(nullif(v_component->>'category',''),'production');
  v_basis:=coalesce(nullif(v_component->>'basis',''),'per_piece');
  v_component_cost:=coalesce(nullif(v_component->>'cost','')::numeric,0);
  if v_component_name='' or v_component_cost<0
    or v_basis not in('per_piece','per_job')
    or v_category not in('blank_item','production') then
   raise exception 'Costing profile contains an invalid component or cost basis';
  end if;
  if v_category='blank_item' and (v_customer_supplied or (v_blank_override is not null and v_basis='per_piece')) then
   continue;
  end if;
  v_component_total:=case when v_basis='per_job' then v_component_cost else v_component_cost*v_qty end;
  v_cost:=v_cost+v_component_total;
  v_breakdown:=v_breakdown||jsonb_build_array(jsonb_build_object(
   'name',v_component_name,'category',v_category,'basis',v_basis,
   'unit_cost',v_component_cost,'quantity',case when v_basis='per_job' then 1 else v_qty end,
   'total_cost',v_component_total
  ));
 end loop;

 if v_other_costs>0 then
  v_cost:=v_cost+v_other_costs;
  v_breakdown:=v_breakdown||jsonb_build_array(jsonb_build_object(
   'name',coalesce(nullif(v_line->'details'->>'other_costs_note',''),'Other direct job costs'),
   'category','production','basis','per_job','unit_cost',v_other_costs,'quantity',1,'total_cost',v_other_costs
  ));
 end if;
 if v_cost<0 then raise exception 'Direct cost cannot be negative'; end if;
 v_total:=v_qty*v_price;
 if v_total<=0 then raise exception 'Quotation total must be greater than zero'; end if;
 v_margin_percent:=case when v_total>0 then ((v_total-v_cost)/v_total)*100 else null end;

 if v_margin_percent<30 then
  if not coalesce(p_allow_below_floor,false) or length(btrim(coalesce(p_exception_reason,'')))<8 then
   raise exception 'Quotation is below the 30%% gross-margin floor. An authorised exception and reason are required.';
  end if;
 end if;

 v_snapshot:=jsonb_build_object(
  'profile_id',v_profile,'profile_name',v_profile_name,'profile_version',v_profile_version,
  'quantity',v_qty,'customer_supplied_items',v_customer_supplied,
  'components',v_breakdown,'other_costs_total',v_other_costs,
  'direct_cost_total',round(v_cost,2),
  'direct_cost_per_piece',round(v_cost/v_qty,2),
  'gross_margin_percent',round(v_margin_percent,2)
 );

 insert into public.quotations(
  business_id,customer_id,costing_profile_id,quote_number,valid_until,total,created_by,
  below_floor_exception_reason,below_floor_approved_by
 ) values(
  v_business,p_customer_id,v_profile,btrim(p_quote_number),p_valid_until,v_total,v_user,
  case when v_margin_percent<30 then btrim(p_exception_reason) end,
  case when v_margin_percent<30 then v_user end
 ) returning id into v_quote;

 insert into public.quotation_lines(
  business_id,quotation_id,description,quantity,unit_price,direct_cost,line_total,details
 ) values(
  v_business,v_quote,v_desc,v_qty,v_price,round(v_cost,2),v_total,
  coalesce(v_line->'details','{}'::jsonb)||jsonb_build_object('cost_snapshot',v_snapshot)
 );

 insert into public.audit_events(business_id,actor_user_id,event_type,entity_type,entity_id,details)
 values(v_business,v_user,'quotation.created','quotation',v_quote,
  jsonb_build_object('total',v_total,'direct_cost',round(v_cost,2),
   'gross_margin_percent',round(v_margin_percent,2),'cost_snapshot',v_snapshot));
 return v_quote;
end
$fn$;

-- Reports use gross margin (gross profit / sales), not markup (gross profit / cost).
create or replace function public.owner_operational_report()
returns jsonb
language plpgsql
stable
security invoker
set search_path=public,pg_temp
as $fn$
declare v_business uuid; v_result jsonb; v_sales numeric(14,2); v_cost numeric(14,2);
begin
 select business_id into v_business from public.business_memberships
 where user_id=auth.uid() and role='owner' limit 1;
 if v_business is null then raise exception 'Owner workspace required'; end if;
 select coalesce(sum(i.total),0) into v_sales from public.sales_invoices i
 where i.business_id=v_business and i.status not in('draft','void');
 select coalesce(sum(ii.direct_cost),0) into v_cost
 from public.sales_invoice_items ii join public.sales_invoices i on i.id=ii.invoice_id
 where ii.business_id=v_business and i.status not in('draft','void');
 select jsonb_build_object(
  'invoiced_sales',v_sales,'direct_production_cost',v_cost,'gross_profit',v_sales-v_cost,
  'gross_margin_percent',case when v_sales>0 then round(((v_sales-v_cost)/v_sales)*100,2) else null end,
  'payments_received',coalesce((select sum(amount) from public.payments where business_id=v_business),0),
  'outstanding_receivables',coalesce((select sum(balance) from public.sales_invoices where business_id=v_business and status not in('draft','void')),0),
  'active_jobs',(select count(*) from public.production_jobs where business_id=v_business and stage not in('delivered','cancelled')),
  'delivered_jobs',(select count(*) from public.production_jobs where business_id=v_business and stage='delivered'),
  'average_turnaround_hours',(select round(avg(extract(epoch from (delivered_at-created_at))/3600)::numeric,2) from public.production_jobs where business_id=v_business and delivered_at is not null),
  'stock_items',(select count(*) from public.stock_items where business_id=v_business and active),
  'low_stock_items',(select count(*) from public.stock_items where business_id=v_business and active and quantity_on_hand<=reorder_level),
  'expenses',coalesce((select sum(amount) from public.expenses where business_id=v_business),0),
  'cash_received',coalesce((select sum(amount) from public.payments where business_id=v_business and method='cash'),0),
  'mpesa_received',coalesce((select sum(amount) from public.payments where business_id=v_business and method='mpesa_paybill'),0)
 ) into v_result;
 return v_result;
end
$fn$;

notify pgrst,'reload schema';



-- Per-job reports use the same gross-margin denominator as quotations and business reports.
create or replace function public.owner_job_report()
returns jsonb
language plpgsql
stable
security invoker
set search_path=public,pg_temp
as $fn$
declare v_business uuid; v_result jsonb;
begin
 select business_id into v_business from public.business_memberships
 where user_id=auth.uid() and role='owner' limit 1;
 if v_business is null then raise exception 'Owner workspace required'; end if;
 select coalesce(jsonb_agg(jsonb_build_object(
  'job_id',j.id,'job_number',j.job_number,'job_name',j.job_name,
  'customer_name',c.customer_name,'stage',j.stage,
  'created_at',j.created_at,'due_at',j.due_at,'delivered_at',j.delivered_at,
  'invoice_number',i.invoice_number,'revenue',coalesce(i.total,0),
  'direct_cost',coalesce(nullif(j.actual_direct_cost,0),
   (select sum(ii.direct_cost) from public.sales_invoice_items ii where ii.invoice_id=i.id),0),
  'gross_profit',coalesce(i.total,0)-coalesce(nullif(j.actual_direct_cost,0),
   (select sum(ii.direct_cost) from public.sales_invoice_items ii where ii.invoice_id=i.id),0),
  'gross_margin_percent',case
   when coalesce(i.total,0)>0 then round((
    (coalesce(i.total,0)-coalesce(nullif(j.actual_direct_cost,0),
     (select sum(ii.direct_cost) from public.sales_invoice_items ii where ii.invoice_id=i.id),0))
    /coalesce(i.total,0))*100,2)
   else null end,
  'amount_paid',coalesce(i.amount_paid,0),'balance',coalesce(i.balance,0),
  'turnaround_hours',case when j.delivered_at is not null
   then round((extract(epoch from (j.delivered_at-j.created_at))/3600)::numeric,2)
   else null end
 ) order by j.created_at desc),'[]'::jsonb)
 into v_result
 from public.production_jobs j
 join public.customers c on c.id=j.customer_id
 left join public.sales_invoices i on i.id=j.invoice_id
 where j.business_id=v_business;
 return v_result;
end
$fn$;

notify pgrst,'reload schema';


create or replace function public.owner_get_max_unit_selling_price()
returns numeric(14,2)
language plpgsql
stable
security definer
set search_path=public,pg_temp
as $fn$
declare v_business uuid; v_price numeric(14,2);
begin
 select business_id into v_business from public.business_memberships
 where user_id=auth.uid() and role='owner' limit 1;
 if v_business is null then raise exception 'Owner workspace required'; end if;
 select max_unit_selling_price into v_price
 from public.business_settings where business_id=v_business;
 return v_price;
end
$fn$;
revoke all on function public.owner_get_max_unit_selling_price() from public,anon;
grant execute on function public.owner_get_max_unit_selling_price() to authenticated;


-- Carry the immutable quotation component snapshot into the matching invoice line.
alter table public.sales_invoice_items
 add column if not exists cost_snapshot jsonb not null default '{}'::jsonb;
comment on column public.sales_invoice_items.cost_snapshot is
 'Immutable copy of the quotation line cost snapshot used when this invoice was created.';

create or replace function public.owner_convert_quote_to_invoice(
 p_quote_id uuid,p_invoice_number text,p_job_number text,p_due_date date
) returns jsonb
language plpgsql
security definer
set search_path=public,pg_temp
as $fn$
declare
 q public.quotations%rowtype;
 v_invoice uuid;
 v_job uuid;
 v_user uuid;
 v_customer_supplied boolean;
 v_job_name text;
 v_deposit record;
 v_paid numeric(14,2):=0;
 v_payment uuid;
begin
 v_user:=auth.uid();
 if v_user is null then raise exception 'Authentication required'; end if;
 select * into q from public.quotations where id=p_quote_id for update;
 if not found or not exists(
  select 1 from public.business_memberships
  where business_id=q.business_id and user_id=v_user and role='owner'
 ) then raise exception 'Quotation not found'; end if;
 if q.status<>'accepted' then raise exception 'Only accepted quotations can be invoiced'; end if;
 select coalesce(sum(amount),0) into v_paid
 from public.quotation_deposits where quotation_id=q.id and business_id=q.business_id;
 if v_paid>q.total then raise exception 'Recorded deposits exceed quotation total'; end if;
 insert into public.sales_invoices(
  business_id,customer_id,invoice_number,status,due_date,total,amount_paid,balance,created_by
 ) values(
  q.business_id,q.customer_id,btrim(p_invoice_number),
  case when v_paid=q.total then 'paid' when v_paid>0 then 'partially_paid' else 'sent' end,
  p_due_date,q.total,v_paid,q.total-v_paid,v_user
 ) returning id into v_invoice;

 insert into public.sales_invoice_items(
  business_id,invoice_id,description,quantity,unit_price,line_total,direct_cost,cost_snapshot,item_type
 )
 select q.business_id,v_invoice,l.description,l.quantity,l.unit_price,l.line_total,l.direct_cost,
  coalesce(l.details->'cost_snapshot','{}'::jsonb),
  case when l.details->>'item_type' in('blank_product','printing_service','custom_production','other')
   then l.details->>'item_type' else 'other' end
 from public.quotation_lines l
 where l.quotation_id=q.id and l.business_id=q.business_id;

 select coalesce(bool_or(coalesce((details->>'customer_supplied_items')::boolean,false)),false)
 into v_customer_supplied
 from public.quotation_lines where quotation_id=q.id and business_id=q.business_id;
 v_job_name:='Production for '||q.quote_number;
 insert into public.production_jobs(
  business_id,invoice_id,quotation_id,customer_id,job_number,job_name,
  customer_supplied_items,actual_direct_cost,due_at
 ) values(
  q.business_id,v_invoice,q.id,q.customer_id,btrim(p_job_number),v_job_name,
  v_customer_supplied,0,
  case when p_due_date is null then null else (p_due_date::timestamp at time zone 'Africa/Nairobi') end
 ) returning id into v_job;

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
  values(q.business_id,v_payment,v_invoice,v_deposit.amount);
 end loop;

 update public.quotations set status='converted' where id=q.id;
 insert into public.audit_events(business_id,actor_user_id,event_type,entity_type,entity_id,details)
 values(q.business_id,v_user,'quotation.converted','quotation',q.id,
  jsonb_build_object('invoice_id',v_invoice,'job_id',v_job,'deposits_applied',v_paid));
 return jsonb_build_object(
  'invoice_id',v_invoice,'job_id',v_job,'deposits_applied',v_paid,'balance',q.total-v_paid
 );
end
$fn$;

revoke all on function public.owner_convert_quote_to_invoice(uuid,text,text,date) from public,anon;
grant execute on function public.owner_convert_quote_to_invoice(uuid,text,text,date) to authenticated;
notify pgrst,'reload schema';
