-- Use contribution divided by direct cost as the MJ Tees pricing margin.
-- Quote-level direct_cost in line details is the computed blank cost + other direct costs.
create or replace function private.owner_create_quotation_impl(
 p_customer_id uuid,p_costing_profile_id uuid,p_quote_number text,p_valid_until date,p_lines jsonb,
 p_allow_below_floor boolean default false,p_exception_reason text default null
) returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare
 v_business uuid; v_user uuid; v_quote uuid; v_profile uuid;
 v_profile_direct_cost numeric(14,2); v_total numeric(14,2):=0; v_cost numeric(14,2):=0;
 v_margin_percent numeric(14,4); v_line jsonb; v_qty numeric; v_price numeric; v_desc text;
begin
 v_user:=auth.uid();
 select business_id into v_business from public.business_memberships where user_id=v_user and role='owner' limit 1;
 if v_business is null then raise exception 'Owner workspace required'; end if;
 if not exists(select 1 from public.customers where id=p_customer_id and business_id=v_business) then raise exception 'Customer not found in this workspace'; end if;
 select id,direct_cost into v_profile,v_profile_direct_cost from public.costing_profiles
 where id=p_costing_profile_id and business_id=v_business and is_active;
 if v_profile is null then raise exception 'An active versioned costing profile is required before pricing this quotation'; end if;
 if jsonb_typeof(p_lines)<>'array' or jsonb_array_length(p_lines)<>1 then raise exception 'This costing profile prices one production line per quotation'; end if;
 v_cost:=v_profile_direct_cost;
 for v_line in select value from jsonb_array_elements(p_lines) loop
  v_qty:=(v_line->>'quantity')::numeric;
  v_price:=(v_line->>'unit_price')::numeric;
  v_desc:=btrim(v_line->>'description');
  if v_qty<=0 or v_price<0 or coalesce(v_desc,'')='' then raise exception 'Invalid quotation line'; end if;
  if coalesce(v_line->'details'->>'blank_cost_per_piece','')<>'' or coalesce(v_line->'details'->>'other_costs_total','')<>'' then
   v_cost:=coalesce(nullif(v_line->'details'->>'blank_cost_per_piece','')::numeric,0)*v_qty
    +coalesce(nullif(v_line->'details'->>'other_costs_total','')::numeric,0);
  elsif coalesce(v_line->'details'->>'direct_cost','')<>'' then
   v_cost:=(v_line->'details'->>'direct_cost')::numeric;
  end if;
  v_total:=v_total+(v_qty*v_price);
 end loop;
 if v_cost<0 then raise exception 'Direct cost cannot be negative'; end if;
 if v_total<=0 then raise exception 'Quotation total must be greater than zero'; end if;
 v_margin_percent:=case when v_cost>0 then ((v_total-v_cost)/v_cost)*100 else null end;
 if v_margin_percent is not null and v_margin_percent<30 then
  if not coalesce(p_allow_below_floor,false) or length(btrim(coalesce(p_exception_reason,'')))<8 then
   raise exception 'Quotation is below the 30%% gross-margin floor. An authorised exception and reason are required.';
  end if;
 end if;
 insert into public.quotations(business_id,customer_id,costing_profile_id,quote_number,valid_until,total,created_by,below_floor_exception_reason,below_floor_approved_by)
 values(v_business,p_customer_id,v_profile,btrim(p_quote_number),p_valid_until,v_total,v_user,
  case when v_margin_percent is not null and v_margin_percent<30 then btrim(p_exception_reason) end,
  case when v_margin_percent is not null and v_margin_percent<30 then v_user end)
 returning id into v_quote;
 for v_line in select value from jsonb_array_elements(p_lines) loop
  v_qty:=(v_line->>'quantity')::numeric;
  v_price:=(v_line->>'unit_price')::numeric;
  insert into public.quotation_lines(business_id,quotation_id,description,quantity,unit_price,direct_cost,line_total,details)
  values(v_business,v_quote,btrim(v_line->>'description'),v_qty,v_price,v_cost,v_qty*v_price,coalesce(v_line->'details','{}'::jsonb));
 end loop;
 insert into public.audit_events(business_id,actor_user_id,event_type,entity_type,entity_id,details)
 values(v_business,v_user,'quotation.created','quotation',v_quote,
  jsonb_build_object('total',v_total,'direct_cost',v_cost,'gross_margin_percent',v_margin_percent));
 return v_quote;
end $$;

create or replace function public.owner_operational_report()
returns jsonb language plpgsql stable security invoker set search_path=public,pg_temp as $$
declare v_business uuid; v_result jsonb; v_sales numeric(14,2); v_cost numeric(14,2);
begin
 select business_id into v_business from public.business_memberships where user_id=auth.uid() and role='owner' limit 1;
 if v_business is null then raise exception 'Owner workspace required'; end if;
 select coalesce(sum(i.total),0) into v_sales from public.sales_invoices i
 where i.business_id=v_business and i.status not in('draft','void');
 select coalesce(sum(ii.direct_cost),0) into v_cost from public.sales_invoice_items ii
 join public.sales_invoices i on i.id=ii.invoice_id
 where ii.business_id=v_business and i.status not in('draft','void');
 select jsonb_build_object(
  'invoiced_sales',v_sales,
  'direct_production_cost',v_cost,
  'gross_profit',v_sales-v_cost,
  'gross_margin_percent',case when v_cost>0 then round(((v_sales-v_cost)/v_cost)*100,2) else null end,
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
end $$;
revoke all on function private.owner_create_quotation_impl(uuid,uuid,text,date,jsonb,boolean,text) from public,anon;
grant execute on function private.owner_create_quotation_impl(uuid,uuid,text,date,jsonb,boolean,text) to authenticated;
