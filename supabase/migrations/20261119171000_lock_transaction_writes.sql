-- Keep transaction inserts behind non-exposed, owner-checked RPC implementations.
-- Public wrappers are invoker functions; the private implementations verify auth.uid() and owner membership.
create or replace function private.owner_create_costing_profile_impl(
 p_profile_name text,p_components jsonb,p_direct_cost numeric,p_activate boolean default true
) returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare v_business uuid; v_version integer; v_id uuid;
begin
 select business_id into v_business from public.business_memberships where user_id=auth.uid() and role='owner' limit 1;
 if v_business is null or length(btrim(coalesce(p_profile_name,'')))<2 then raise exception 'Valid costing profile and owner workspace required'; end if;
 if jsonb_typeof(p_components)<>'array' or jsonb_array_length(p_components)=0 or p_direct_cost<0 then raise exception 'Costing profile requires components and a non-negative direct cost'; end if;
 select coalesce(max(version),0)+1 into v_version from public.costing_profiles where business_id=v_business and profile_name=btrim(p_profile_name);
 insert into public.costing_profiles(business_id,profile_name,version,is_active,components,direct_cost)
 values(v_business,btrim(p_profile_name),v_version,false,p_components,p_direct_cost) returning id into v_id;
 if p_activate then perform private.activate_costing_profile(v_business,v_id); end if;
 return v_id;
end $$;

create or replace function private.owner_create_quotation_impl(
 p_customer_id uuid,p_costing_profile_id uuid,p_quote_number text,p_valid_until date,p_lines jsonb,
 p_allow_below_floor boolean default false,p_exception_reason text default null
) returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare v_business uuid; v_user uuid; v_quote uuid; v_profile uuid; v_profile_direct_cost numeric(14,2); v_total numeric(14,2):=0; v_cost numeric(14,2):=0;
 v_line jsonb; v_qty numeric; v_price numeric; v_cost_line numeric; v_desc text;
begin
 v_user:=auth.uid();
 select business_id into v_business from public.business_memberships where user_id=v_user and role='owner' limit 1;
 if v_business is null then raise exception 'Owner workspace required'; end if;
 if not exists(select 1 from public.customers where id=p_customer_id and business_id=v_business) then raise exception 'Customer not found in this workspace'; end if;
 select id,direct_cost into v_profile,v_profile_direct_cost from public.costing_profiles where id=p_costing_profile_id and business_id=v_business and is_active;
 if v_profile is null then raise exception 'An active versioned costing profile is required before pricing this quotation'; end if;
 if jsonb_typeof(p_lines)<>'array' or jsonb_array_length(p_lines)<>1 then raise exception 'This costing profile prices one production line per quotation'; end if;
 v_cost:=v_profile_direct_cost;
 for v_line in select value from jsonb_array_elements(p_lines) loop
  v_qty:=(v_line->>'quantity')::numeric; v_price:=(v_line->>'unit_price')::numeric;
  v_cost_line:=0; v_desc:=btrim(v_line->>'description');
  if v_qty<=0 or v_price<0 or coalesce(v_desc,'')='' then raise exception 'Invalid quotation line'; end if;
  v_total:=v_total+(v_qty*v_price);
 end loop;
 if v_total<=0 then raise exception 'Quotation total must be greater than zero'; end if;
 if ((v_total-v_cost)/v_total)*100 < 30 then
  if not coalesce(p_allow_below_floor,false) or length(btrim(coalesce(p_exception_reason,'')))<8 then
   raise exception 'Quotation is below the 30% gross-margin floor. An authorised exception and reason are required.';
  end if;
 end if;
 insert into public.quotations(business_id,customer_id,costing_profile_id,quote_number,valid_until,total,created_by,below_floor_exception_reason,below_floor_approved_by)
 values(v_business,p_customer_id,v_profile,btrim(p_quote_number),p_valid_until,v_total,v_user,
  case when ((v_total-v_cost)/v_total)*100<30 then btrim(p_exception_reason) end,
  case when ((v_total-v_cost)/v_total)*100<30 then v_user end)
 returning id into v_quote;
 for v_line in select value from jsonb_array_elements(p_lines) loop
  v_qty:=(v_line->>'quantity')::numeric; v_price:=(v_line->>'unit_price')::numeric;
  insert into public.quotation_lines(business_id,quotation_id,description,quantity,unit_price,direct_cost,line_total,details)
  values(v_business,v_quote,btrim(v_line->>'description'),v_qty,v_price,v_cost,v_qty*v_price,coalesce(v_line->'details','{}'::jsonb));
 end loop;
 insert into public.audit_events(business_id,actor_user_id,event_type,entity_type,entity_id,details)
 values(v_business,v_user,'quotation.created','quotation',v_quote,jsonb_build_object('total',v_total,'direct_cost',v_cost,'gross_margin_percent',round(((v_total-v_cost)/v_total)*100,2)));
 return v_quote;
end $$;

create or replace function private.owner_convert_quote_to_invoice_impl(
 p_quote_id uuid,p_invoice_number text,p_job_number text,p_due_date date
) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare q public.quotations%rowtype; v_invoice uuid; v_job uuid; v_user uuid; v_customer_supplied boolean; v_job_name text;
begin
 v_user:=auth.uid();
 select * into q from public.quotations where id=p_quote_id for update;
 if not found or not exists(select 1 from public.business_memberships where business_id=q.business_id and user_id=v_user and role='owner') then raise exception 'Quotation not found'; end if;
 if q.status<>'accepted' then raise exception 'Only accepted quotations can be invoiced'; end if;
 insert into public.sales_invoices(business_id,customer_id,invoice_number,status,due_date,total,amount_paid,balance,created_by)
 values(q.business_id,q.customer_id,btrim(p_invoice_number),'sent',p_due_date,q.total,0,q.total,v_user)
 returning id into v_invoice;
 insert into public.sales_invoice_items(business_id,invoice_id,description,quantity,unit_price,line_total,direct_cost,item_type)
 select q.business_id,v_invoice,l.description,l.quantity,l.unit_price,l.line_total,l.direct_cost,
  case when l.details->>'item_type' in('blank_product','printing_service','custom_production','other') then l.details->>'item_type' else 'other' end
 from public.quotation_lines l where l.quotation_id=q.id and l.business_id=q.business_id;
 select coalesce(bool_or(coalesce((details->>'customer_supplied_items')::boolean,false)),false)
 into v_customer_supplied from public.quotation_lines where quotation_id=q.id and business_id=q.business_id;
 v_job_name:='Production for '||q.quote_number;
 insert into public.production_jobs(business_id,invoice_id,quotation_id,customer_id,job_number,job_name,customer_supplied_items,actual_direct_cost,due_at)
 values(q.business_id,v_invoice,q.id,q.customer_id,btrim(p_job_number),v_job_name,v_customer_supplied,0,case when p_due_date is null then null else (p_due_date::timestamp at time zone 'Africa/Nairobi') end)
 returning id into v_job;
 update public.quotations set status='converted' where id=q.id;
 insert into public.audit_events(business_id,actor_user_id,event_type,entity_type,entity_id,details)
 values(q.business_id,v_user,'quotation.converted','quotation',q.id,jsonb_build_object('invoice_id',v_invoice,'job_id',v_job));
 return jsonb_build_object('invoice_id',v_invoice,'job_id',v_job);
end $$;

create or replace function private.owner_record_payment_impl(
 p_invoice_id uuid,p_payment_number text,p_method text,p_amount numeric,p_reference_code text default null
) returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare i public.sales_invoices%rowtype; v_payment uuid; v_user uuid;
begin
 v_user:=auth.uid();
 select * into i from public.sales_invoices where id=p_invoice_id;
 if not found or not exists(select 1 from public.business_memberships where business_id=i.business_id and user_id=v_user and role='owner') then raise exception 'Invoice not found'; end if;
 if p_method not in('cash','mpesa_paybill') or p_amount<=0 or p_amount>i.balance then raise exception 'Invalid payment method or amount exceeds invoice balance'; end if;
 insert into public.payments(business_id,customer_id,payment_number,method,amount,reference_code,received_by)
 values(i.business_id,i.customer_id,btrim(p_payment_number),p_method,p_amount,nullif(btrim(p_reference_code),''),v_user)
 returning id into v_payment;
 insert into public.payment_allocations(business_id,payment_id,invoice_id,amount)
 values(i.business_id,v_payment,i.id,p_amount);
 update public.sales_invoices set amount_paid=amount_paid+p_amount,balance=balance-p_amount,
 status=case when balance-p_amount=0 then 'paid' else 'partially_paid' end where id=i.id;
 insert into public.audit_events(business_id,actor_user_id,event_type,entity_type,entity_id,details)
 values(i.business_id,v_user,'payment.received','payment',v_payment,jsonb_build_object('invoice_id',i.id,'amount',p_amount,'method',p_method));
 return v_payment;
end $$;

create or replace function private.owner_record_expense_impl(
 p_category text,p_description text,p_amount numeric,p_payment_method text,p_expense_date date default current_date
) returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare v_business uuid; v_id uuid; v_user uuid;
begin
 v_user:=auth.uid();
 select business_id into v_business from public.business_memberships where user_id=v_user and role='owner' limit 1;
 if v_business is null then raise exception 'Owner workspace required'; end if;
 if p_amount<=0 or p_payment_method not in('cash','mpesa_paybill') or length(btrim(p_description))=0 then raise exception 'Invalid expense'; end if;
 insert into public.expenses(business_id,expense_date,category,description,amount,payment_method,created_by)
 values(v_business,p_expense_date,btrim(p_category),btrim(p_description),p_amount,p_payment_method,v_user) returning id into v_id;
 return v_id;
end $$;

create or replace function private.owner_create_purchase_order_impl(
 p_supplier_id uuid,p_po_number text,p_transport_cost numeric,p_lines jsonb
) returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare v_business uuid; v_total numeric(14,2):=0; v_line jsonb; v_stock uuid; v_qty numeric; v_cost numeric; v_po uuid;
begin
 select business_id into v_business from public.business_memberships where user_id=auth.uid() and role='owner' limit 1;
 if v_business is null or not exists(select 1 from public.suppliers where id=p_supplier_id and business_id=v_business) then raise exception 'Supplier not found'; end if;
 if p_transport_cost<0 or jsonb_typeof(p_lines)<>'array' or jsonb_array_length(p_lines)=0 then raise exception 'Invalid purchase order'; end if;
 for v_line in select value from jsonb_array_elements(p_lines) loop
  v_stock:=(v_line->>'stock_item_id')::uuid; v_qty:=(v_line->>'quantity')::numeric; v_cost:=(v_line->>'unit_cost')::numeric;
  if v_qty<=0 or v_cost<0 or not exists(select 1 from public.stock_items where id=v_stock and business_id=v_business and active) then raise exception 'Invalid purchase line'; end if;
  v_total:=v_total+(v_qty*v_cost);
 end loop;
 insert into public.purchase_orders(business_id,supplier_id,po_number,status,total,transport_cost)
 values(v_business,p_supplier_id,btrim(p_po_number),'sent',v_total,p_transport_cost) returning id into v_po;
 for v_line in select value from jsonb_array_elements(p_lines) loop
  v_stock:=(v_line->>'stock_item_id')::uuid; v_qty:=(v_line->>'quantity')::numeric; v_cost:=(v_line->>'unit_cost')::numeric;
  insert into public.purchase_order_lines(business_id,purchase_order_id,stock_item_id,item_description,quantity,unit_cost)
  select v_business,v_po,s.id,s.item_name,v_qty,v_cost from public.stock_items s where s.id=v_stock and s.business_id=v_business;
 end loop;
 return v_po;
end $$;
create or replace function public.owner_create_costing_profile(p_profile_name text,p_components jsonb,p_direct_cost numeric,p_activate boolean default true)
returns uuid language sql security invoker set search_path=public,private,pg_temp as $$
 select private.owner_create_costing_profile_impl(p_profile_name,p_components,p_direct_cost,p_activate);
$$;

create or replace function public.owner_create_quotation(p_customer_id uuid,p_costing_profile_id uuid,p_quote_number text,p_valid_until date,p_lines jsonb,p_allow_below_floor boolean default false,p_exception_reason text default null)
returns uuid language sql security invoker set search_path=public,private,pg_temp as $$
 select private.owner_create_quotation_impl(p_customer_id,p_costing_profile_id,p_quote_number,p_valid_until,p_lines,p_allow_below_floor,p_exception_reason);
$$;

create or replace function public.owner_convert_quote_to_invoice(p_quote_id uuid,p_invoice_number text,p_job_number text,p_due_date date)
returns jsonb language sql security invoker set search_path=public,private,pg_temp as $$
 select private.owner_convert_quote_to_invoice_impl(p_quote_id,p_invoice_number,p_job_number,p_due_date);
$$;

create or replace function public.owner_record_payment(p_invoice_id uuid,p_payment_number text,p_method text,p_amount numeric,p_reference_code text default null)
returns uuid language sql security invoker set search_path=public,private,pg_temp as $$
 select private.owner_record_payment_impl(p_invoice_id,p_payment_number,p_method,p_amount,p_reference_code);
$$;

create or replace function public.owner_record_expense(p_category text,p_description text,p_amount numeric,p_payment_method text,p_expense_date date default current_date)
returns uuid language sql security invoker set search_path=public,private,pg_temp as $$
 select private.owner_record_expense_impl(p_category,p_description,p_amount,p_payment_method,p_expense_date);
$$;

create or replace function public.owner_create_purchase_order(p_supplier_id uuid,p_po_number text,p_transport_cost numeric,p_lines jsonb)
returns uuid language sql security invoker set search_path=public,private,pg_temp as $$
 select private.owner_create_purchase_order_impl(p_supplier_id,p_po_number,p_transport_cost,p_lines);
$$;
revoke all on function private.owner_create_costing_profile_impl(text,jsonb,numeric,boolean) from public,anon;
grant execute on function private.owner_create_costing_profile_impl(text,jsonb,numeric,boolean) to authenticated;
revoke all on function public.owner_create_costing_profile(text,jsonb,numeric,boolean) from public,anon;
grant execute on function public.owner_create_costing_profile(text,jsonb,numeric,boolean) to authenticated;
revoke all on function private.owner_create_quotation_impl(uuid,uuid,text,date,jsonb,boolean,text) from public,anon;
grant execute on function private.owner_create_quotation_impl(uuid,uuid,text,date,jsonb,boolean,text) to authenticated;
revoke all on function public.owner_create_quotation(uuid,uuid,text,date,jsonb,boolean,text) from public,anon;
grant execute on function public.owner_create_quotation(uuid,uuid,text,date,jsonb,boolean,text) to authenticated;
revoke all on function private.owner_convert_quote_to_invoice_impl(uuid,text,text,date) from public,anon;
grant execute on function private.owner_convert_quote_to_invoice_impl(uuid,text,text,date) to authenticated;
revoke all on function public.owner_convert_quote_to_invoice(uuid,text,text,date) from public,anon;
grant execute on function public.owner_convert_quote_to_invoice(uuid,text,text,date) to authenticated;
revoke all on function private.owner_record_payment_impl(uuid,text,text,numeric,text) from public,anon;
grant execute on function private.owner_record_payment_impl(uuid,text,text,numeric,text) to authenticated;
revoke all on function public.owner_record_payment(uuid,text,text,numeric,text) from public,anon;
grant execute on function public.owner_record_payment(uuid,text,text,numeric,text) to authenticated;
revoke all on function private.owner_record_expense_impl(text,text,numeric,text,date) from public,anon;
grant execute on function private.owner_record_expense_impl(text,text,numeric,text,date) to authenticated;
revoke all on function public.owner_record_expense(text,text,numeric,text,date) from public,anon;
grant execute on function public.owner_record_expense(text,text,numeric,text,date) to authenticated;
revoke all on function private.owner_create_purchase_order_impl(uuid,text,numeric,jsonb) from public,anon;
grant execute on function private.owner_create_purchase_order_impl(uuid,text,numeric,jsonb) to authenticated;
revoke all on function public.owner_create_purchase_order(uuid,text,numeric,jsonb) from public,anon;
grant execute on function public.owner_create_purchase_order(uuid,text,numeric,jsonb) to authenticated;

revoke insert on public.costing_profiles,public.quotations,public.quotation_lines,
 public.sales_invoices,public.sales_invoice_items,public.production_jobs,
 public.purchase_orders,public.purchase_order_lines,public.payments,
 public.payment_allocations,public.expenses,public.audit_events
from authenticated;
grant select on public.costing_profiles,public.quotations,public.quotation_lines,
 public.sales_invoices,public.sales_invoice_items,public.production_jobs,
 public.purchase_orders,public.purchase_order_lines,public.payments,
 public.payment_allocations,public.expenses,public.audit_events
to authenticated;
