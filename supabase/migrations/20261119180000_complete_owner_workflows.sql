-- Complete the owner-facing purchasing, deposits, refunds, inventory controls and job reporting.
-- Additive only. No production data is seeded or rewritten.

create table if not exists public.supplier_payments(
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null references public.businesses(id) on delete cascade,
 supplier_id uuid not null references public.suppliers(id),
 purchase_order_id uuid references public.purchase_orders(id),
 payment_number text not null,
 method text not null check(method in('cash','mpesa_paybill')),
 amount numeric(14,2) not null check(amount>0),
 reference_code text,
 paid_at timestamptz not null default now(),
 paid_by uuid not null references auth.users(id),
 unique(business_id,payment_number)
);
alter table public.supplier_payments enable row level security;
create policy supplier_payments_owner_read on public.supplier_payments for select to authenticated
 using(business_id in(select business_id from public.business_memberships where user_id=(select auth.uid()) and role='owner'));
revoke insert,update,delete on public.supplier_payments from authenticated;
grant select on public.supplier_payments to authenticated;

create table if not exists public.quotation_deposits(
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null references public.businesses(id) on delete cascade,
 quotation_id uuid not null references public.quotations(id),
 deposit_number text not null,
 method text not null check(method in('cash','mpesa_paybill')),
 amount numeric(14,2) not null check(amount>0),
 reference_code text,
 received_by uuid not null references auth.users(id),
 received_at timestamptz not null default now(),
 unique(business_id,deposit_number)
);
alter table public.quotation_deposits enable row level security;
create policy quotation_deposits_owner_read on public.quotation_deposits for select to authenticated
 using(business_id in(select business_id from public.business_memberships where user_id=(select auth.uid()) and role='owner'));
revoke insert,update,delete on public.quotation_deposits from authenticated;
grant select on public.quotation_deposits to authenticated;

create table if not exists public.inventory_adjustments(
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null references public.businesses(id) on delete cascade,
 stock_item_id uuid not null references public.stock_items(id),
 quantity_delta numeric(14,3) not null check(quantity_delta<>0),
 reason text not null,
 created_by uuid not null references auth.users(id),
 created_at timestamptz not null default now()
);
alter table public.inventory_adjustments enable row level security;
create policy inventory_adjustments_owner_read on public.inventory_adjustments for select to authenticated
 using(business_id in(select business_id from public.business_memberships where user_id=(select auth.uid()) and role='owner'));
revoke insert,update,delete on public.inventory_adjustments from authenticated;
grant select on public.inventory_adjustments to authenticated;

create table if not exists public.supplier_price_reviews(
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null references public.businesses(id) on delete cascade,
 supplier_id uuid not null references public.suppliers(id),
 stock_item_id uuid not null references public.stock_items(id),
 previous_line_id uuid not null references public.purchase_order_lines(id),
 latest_line_id uuid not null references public.purchase_order_lines(id),
 reviewed_by uuid not null references auth.users(id),
 reviewed_at timestamptz not null default now(),
 unique(business_id,previous_line_id,latest_line_id)
);
alter table public.supplier_price_reviews enable row level security;
create policy supplier_price_reviews_owner_read on public.supplier_price_reviews for select to authenticated
 using(business_id in(select business_id from public.business_memberships where user_id=(select auth.uid()) and role='owner'));
revoke insert,update,delete on public.supplier_price_reviews from authenticated;
grant select on public.supplier_price_reviews to authenticated;

create or replace function public.owner_record_supplier_payment(
 p_supplier_id uuid,p_purchase_order_id uuid,p_payment_number text,p_method text,p_amount numeric,p_reference_code text default null
) returns uuid language plpgsql security definer set search_path=public,pg_temp as $fn$
declare v_business uuid; v_due numeric(14,2); v_id uuid;
begin
 select business_id into v_business from public.business_memberships where user_id=auth.uid() and role='owner' limit 1;
 if v_business is null or not exists(select 1 from public.suppliers where id=p_supplier_id and business_id=v_business) then raise exception 'Supplier not found'; end if;
 if p_method not in('cash','mpesa_paybill') or p_amount<=0 or length(btrim(coalesce(p_payment_number,'')))=0 then raise exception 'Invalid supplier payment'; end if;
 if p_purchase_order_id is not null and not exists(select 1 from public.purchase_orders where id=p_purchase_order_id and supplier_id=p_supplier_id and business_id=v_business) then raise exception 'Purchase order does not belong to this supplier'; end if;
 select coalesce(sum(po.total+po.transport_cost),0)-coalesce((select sum(sp.amount) from public.supplier_payments sp where sp.business_id=v_business and sp.supplier_id=p_supplier_id and (p_purchase_order_id is null or sp.purchase_order_id=p_purchase_order_id)),0)
 into v_due from public.purchase_orders po where po.business_id=v_business and po.supplier_id=p_supplier_id and po.status<>'cancelled' and (p_purchase_order_id is null or po.id=p_purchase_order_id);
 if p_amount>v_due then raise exception 'Supplier payment exceeds outstanding balance'; end if;
 insert into public.supplier_payments(business_id,supplier_id,purchase_order_id,payment_number,method,amount,reference_code,paid_by)
 values(v_business,p_supplier_id,p_purchase_order_id,btrim(p_payment_number),p_method,p_amount,nullif(btrim(p_reference_code),''),auth.uid()) returning id into v_id;
 insert into public.audit_events(business_id,actor_user_id,event_type,entity_type,entity_id,details)
 values(v_business,auth.uid(),'supplier.payment_recorded','supplier_payment',v_id,jsonb_build_object('supplier_id',p_supplier_id,'purchase_order_id',p_purchase_order_id,'amount',p_amount));
 return v_id;
end $fn$;

create or replace function public.owner_record_quote_deposit(
 p_quote_id uuid,p_deposit_number text,p_method text,p_amount numeric,p_reference_code text default null
) returns uuid language plpgsql security definer set search_path=public,pg_temp as $fn$
declare q public.quotations%rowtype; v_received numeric(14,2); v_id uuid;
begin
 select * into q from public.quotations where id=p_quote_id for update;
 if not found or not exists(select 1 from public.business_memberships where business_id=q.business_id and user_id=auth.uid() and role='owner') then raise exception 'Quotation not found'; end if;
 if q.status not in('accepted','sent') then raise exception 'Only sent or accepted quotations can receive deposits'; end if;
 if p_method not in('cash','mpesa_paybill') or p_amount<=0 then raise exception 'Invalid deposit'; end if;
 select coalesce(sum(amount),0) into v_received from public.quotation_deposits where quotation_id=q.id;
 if v_received+p_amount>q.total then raise exception 'Deposit exceeds quotation total'; end if;
 insert into public.quotation_deposits(business_id,quotation_id,deposit_number,method,amount,reference_code,received_by)
 values(q.business_id,q.id,btrim(p_deposit_number),p_method,p_amount,nullif(btrim(p_reference_code),''),auth.uid()) returning id into v_id;
 insert into public.audit_events(business_id,actor_user_id,event_type,entity_type,entity_id,details)
 values(q.business_id,auth.uid(),'quotation.deposit_received','quotation',q.id,jsonb_build_object('deposit_id',v_id,'amount',p_amount));
 return v_id;
end $fn$;

create or replace function public.owner_record_refund(p_payment_id uuid,p_amount numeric,p_reason text)
returns uuid language plpgsql security definer set search_path=public,pg_temp as $fn$
declare p public.payments%rowtype; v_refunded numeric(14,2); v_id uuid;
begin
 select * into p from public.payments where id=p_payment_id;
 if not found or not exists(select 1 from public.business_memberships where business_id=p.business_id and user_id=auth.uid() and role='owner') then raise exception 'Payment not found'; end if;
 if p_amount<=0 or length(btrim(coalesce(p_reason,'')))<8 then raise exception 'A positive refund and reason of at least 8 characters are required'; end if;
 select coalesce(sum(amount),0) into v_refunded from public.refunds where payment_id=p.id and status in('pending','posted');
 if v_refunded+p_amount>p.amount then raise exception 'Refunds cannot exceed the original payment'; end if;
 insert into public.refunds(business_id,payment_id,amount,reason,status,created_by)
 values(p.business_id,p.id,p_amount,btrim(p_reason),'pending',auth.uid()) returning id into v_id;
 return v_id;
end $fn$;

create or replace function public.owner_post_refund(p_refund_id uuid)
returns void language plpgsql security definer set search_path=public,pg_temp as $fn$
declare r public.refunds%rowtype;
begin
 select * into r from public.refunds where id=p_refund_id for update;
 if not found or not exists(select 1 from public.business_memberships where business_id=r.business_id and user_id=auth.uid() and role='owner') then raise exception 'Refund not found'; end if;
 if r.status<>'pending' then raise exception 'Only pending refunds can be posted'; end if;
 update public.refunds set status='posted',posted_by=auth.uid(),posted_at=now() where id=r.id;
 insert into public.audit_events(business_id,actor_user_id,event_type,entity_type,entity_id,details)
 values(r.business_id,auth.uid(),'refund.posted','refund',r.id,jsonb_build_object('payment_id',r.payment_id,'amount',r.amount,'reason',r.reason));
end $fn$;

create or replace function public.owner_adjust_inventory(p_stock_item_id uuid,p_quantity_delta numeric,p_reason text)
returns void language plpgsql security definer set search_path=public,private,pg_temp as $fn$
declare s public.stock_items%rowtype; v_business uuid;
begin
 select business_id into v_business from public.business_memberships where user_id=auth.uid() and role='owner' limit 1;
 select * into s from public.stock_items where id=p_stock_item_id and business_id=v_business and active for update;
 if not found then raise exception 'Stock item not found'; end if;
 if p_quantity_delta=0 or length(btrim(coalesce(p_reason,'')))<5 then raise exception 'Adjustment quantity and reason are required'; end if;
 perform private.apply_stock_movement(v_business,s.id,p_quantity_delta,s.average_unit_cost,'adjustment');
 insert into public.inventory_adjustments(business_id,stock_item_id,quantity_delta,reason,created_by)
 values(v_business,s.id,p_quantity_delta,btrim(p_reason),auth.uid());
end $fn$;

create or replace function public.owner_review_supplier_price_change(p_supplier_id uuid,p_stock_item_id uuid,p_previous_line_id uuid,p_latest_line_id uuid)
returns void language plpgsql security definer set search_path=public,pg_temp as $fn$
declare v_business uuid;
begin
 select business_id into v_business from public.business_memberships where user_id=auth.uid() and role='owner' limit 1;
 if not exists(select 1 from public.purchase_order_lines a join public.purchase_orders pa on pa.id=a.purchase_order_id
 join public.purchase_order_lines b on b.id=p_latest_line_id join public.purchase_orders pb on pb.id=b.purchase_order_id
 where a.id=p_previous_line_id and pa.supplier_id=p_supplier_id and pb.supplier_id=p_supplier_id
 and a.stock_item_id=p_stock_item_id and b.stock_item_id=p_stock_item_id and pa.business_id=v_business and pb.business_id=v_business) then raise exception 'Price change record not found'; end if;
 insert into public.supplier_price_reviews(business_id,supplier_id,stock_item_id,previous_line_id,latest_line_id,reviewed_by)
 values(v_business,p_supplier_id,p_stock_item_id,p_previous_line_id,p_latest_line_id,auth.uid()) on conflict do nothing;
end $fn$;

create or replace function public.owner_supplier_price_alerts()
returns jsonb language plpgsql stable security invoker set search_path=public,pg_temp as $fn$
declare v_business uuid; v_result jsonb;
begin
 select business_id into v_business from public.business_memberships where user_id=auth.uid() and role='owner' limit 1;
 if v_business is null then raise exception 'Owner workspace required'; end if;
 with ranked as (
  select po.supplier_id,s.supplier_name,pol.stock_item_id,pol.id line_id,pol.unit_cost,po.created_at,
   si.item_name,row_number() over(partition by po.supplier_id,pol.stock_item_id order by po.created_at desc,pol.id desc) rn
  from public.purchase_order_lines pol join public.purchase_orders po on po.id=pol.purchase_order_id
  join public.suppliers s on s.id=po.supplier_id join public.stock_items si on si.id=pol.stock_item_id
  where po.business_id=v_business and po.status<>'cancelled' and pol.stock_item_id is not null
 ), pairs as (
  select a.supplier_id,a.supplier_name,a.stock_item_id,a.item_name,b.line_id previous_line_id,a.line_id latest_line_id,
   b.unit_cost previous_cost,a.unit_cost latest_cost,a.created_at,
   round(((a.unit_cost-b.unit_cost)/nullif(b.unit_cost,0))*100,2) change_percent
  from ranked a join ranked b on b.supplier_id=a.supplier_id and b.stock_item_id=a.stock_item_id and b.rn=2
  where a.rn=1 and a.unit_cost<>b.unit_cost
 )
 select coalesce(jsonb_agg(jsonb_build_object('supplier_id',p.supplier_id,'supplier_name',p.supplier_name,'stock_item_id',p.stock_item_id,'item_name',p.item_name,'previous_line_id',p.previous_line_id,'latest_line_id',p.latest_line_id,'previous_cost',p.previous_cost,'latest_cost',p.latest_cost,'change_percent',p.change_percent,'created_at',p.created_at,'reviewed',exists(select 1 from public.supplier_price_reviews r where r.business_id=v_business and r.previous_line_id=p.previous_line_id and r.latest_line_id=p.latest_line_id)) order by p.created_at desc),'[]'::jsonb)
 into v_result from pairs p;
 return v_result;
end $fn$;

create or replace function public.owner_job_report()
returns jsonb language plpgsql stable security invoker set search_path=public,pg_temp as $fn$
declare v_business uuid; v_result jsonb;
begin
 select business_id into v_business from public.business_memberships where user_id=auth.uid() and role='owner' limit 1;
 if v_business is null then raise exception 'Owner workspace required'; end if;
 select coalesce(jsonb_agg(jsonb_build_object(
  'job_id',j.id,'job_number',j.job_number,'job_name',j.job_name,'customer_name',c.customer_name,'stage',j.stage,
  'created_at',j.created_at,'due_at',j.due_at,'delivered_at',j.delivered_at,
  'invoice_number',i.invoice_number,'revenue',coalesce(i.total,0),
  'direct_cost',coalesce(nullif(j.actual_direct_cost,0),(select sum(ii.direct_cost) from public.sales_invoice_items ii where ii.invoice_id=i.id),0),
  'gross_profit',coalesce(i.total,0)-coalesce(nullif(j.actual_direct_cost,0),(select sum(ii.direct_cost) from public.sales_invoice_items ii where ii.invoice_id=i.id),0),
  'gross_margin_percent',case when coalesce(nullif(j.actual_direct_cost,0),(select sum(ii.direct_cost) from public.sales_invoice_items ii where ii.invoice_id=i.id),0)>0 then round(((coalesce(i.total,0)-coalesce(nullif(j.actual_direct_cost,0),(select sum(ii.direct_cost) from public.sales_invoice_items ii where ii.invoice_id=i.id),0))/coalesce(nullif(j.actual_direct_cost,0),(select sum(ii.direct_cost) from public.sales_invoice_items ii where ii.invoice_id=i.id),0))*100,2) else null end,
  'amount_paid',coalesce(i.amount_paid,0),'balance',coalesce(i.balance,0),
  'turnaround_hours',case when j.delivered_at is not null then round((extract(epoch from (j.delivered_at-j.created_at))/3600)::numeric,2) else null end
 ) order by j.created_at desc),'[]'::jsonb)
 into v_result from public.production_jobs j join public.customers c on c.id=j.customer_id
 left join public.sales_invoices i on i.id=j.invoice_id where j.business_id=v_business;
 return v_result;
end $fn$;

revoke all on function public.owner_record_supplier_payment(uuid,uuid,text,text,numeric,text) from public,anon;
revoke all on function public.owner_record_quote_deposit(uuid,text,text,numeric,text) from public,anon;
revoke all on function public.owner_record_refund(uuid,numeric,text) from public,anon;
revoke all on function public.owner_post_refund(uuid) from public,anon;
revoke all on function public.owner_adjust_inventory(uuid,numeric,text) from public,anon;
revoke all on function public.owner_review_supplier_price_change(uuid,uuid,uuid,uuid) from public,anon;
revoke all on function public.owner_supplier_price_alerts() from public,anon;
revoke all on function public.owner_job_report() from public,anon;
grant execute on function public.owner_record_supplier_payment(uuid,uuid,text,text,numeric,text) to authenticated;
grant execute on function public.owner_record_quote_deposit(uuid,text,text,numeric,text) to authenticated;
grant execute on function public.owner_record_refund(uuid,numeric,text) to authenticated;
grant execute on function public.owner_post_refund(uuid) to authenticated;
grant execute on function public.owner_adjust_inventory(uuid,numeric,text) to authenticated;
grant execute on function public.owner_review_supplier_price_change(uuid,uuid,uuid,uuid) to authenticated;
grant execute on function public.owner_supplier_price_alerts() to authenticated;
grant execute on function public.owner_job_report() to authenticated;
