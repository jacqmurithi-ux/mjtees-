-- Separate invoice conversion from production-job creation.
-- Preserve quotation line snapshots and deposit allocation; no production job is created here.

alter table public.sales_invoices
 add column if not exists quotation_id uuid references public.quotations(id) on delete restrict;

alter table public.sales_invoice_items
 add column if not exists quotation_line_id uuid references public.quotation_lines(id) on delete restrict;
create unique index if not exists sales_invoice_items_one_per_quotation_line
 on public.sales_invoice_items(quotation_line_id) where quotation_line_id is not null;

do $$
begin
 if exists(
  select quotation_id
  from public.production_jobs
  where quotation_id is not null and invoice_id is not null
  group by quotation_id
  having count(distinct invoice_id)>1
 ) then
  raise exception 'Cannot backfill invoice links: a quotation is linked to multiple invoices';
 end if;
end
$$;

update public.sales_invoices i
set quotation_id=j.quotation_id
from public.production_jobs j
where j.invoice_id=i.id and j.quotation_id is not null
 and i.quotation_id is null;

create unique index if not exists sales_invoices_one_per_quotation
 on public.sales_invoices(quotation_id) where quotation_id is not null;

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

create or replace function public.owner_create_production_job_from_quote(
 p_quote_id uuid,p_job_number text,p_due_date date default null
) returns jsonb
language plpgsql
security definer
set search_path=public,pg_temp
as $fn$
declare
 q public.quotations%rowtype;
 v_invoice uuid;
 v_job public.production_jobs%rowtype;
 v_job_id uuid;
 v_customer_supplied boolean;
 v_user uuid;
begin
 v_user:=auth.uid();
 if v_user is null then raise exception 'Authentication required'; end if;

 select * into q from public.quotations where id=p_quote_id for update;
 if not found or not exists(
  select 1 from public.business_memberships
  where business_id=q.business_id and user_id=v_user and role='owner'
 ) then raise exception 'Quotation not found'; end if;

 select * into v_job from public.production_jobs
 where quotation_id=q.id and business_id=q.business_id for update;
 if found then
  return jsonb_build_object('job_id',v_job.id,'invoice_id',v_job.invoice_id,'already_created',true);
 end if;

 if q.status<>'converted' then
  raise exception 'Create the invoice before creating its production job';
 end if;
 if nullif(btrim(p_job_number),'') is null then raise exception 'Production job number is required'; end if;

 select id into v_invoice from public.sales_invoices
 where quotation_id=q.id and business_id=q.business_id for update;
 if v_invoice is null then raise exception 'Invoice for this quotation was not found'; end if;

 select coalesce(bool_or(
  supply_arrangement='customer_supplies'
  or coalesce((details->>'customer_supplied_items')::boolean,false)
 ),false)
 into v_customer_supplied
 from public.quotation_lines
 where quotation_id=q.id and business_id=q.business_id;

 insert into public.production_jobs(
  business_id,invoice_id,quotation_id,customer_id,job_number,job_name,
  customer_supplied_items,actual_direct_cost,due_at
 ) values(
  q.business_id,v_invoice,q.id,q.customer_id,btrim(p_job_number),
  'Production for '||q.quote_number,v_customer_supplied,0,
  case when p_due_date is null then null else (p_due_date::timestamp at time zone 'Africa/Nairobi') end
 ) returning id into v_job_id;

 insert into public.audit_events(business_id,actor_user_id,event_type,entity_type,entity_id,details)
 values(q.business_id,v_user,'production_job.created','production_job',v_job_id,
  jsonb_build_object('quotation_id',q.id,'invoice_id',v_invoice));

 return jsonb_build_object('job_id',v_job_id,'invoice_id',v_invoice,'already_created',false);
end
$fn$;

-- Retire the legacy combined action so no caller can accidentally create a job during invoicing.
revoke all on function public.owner_convert_quote_to_invoice(uuid,text,text,date) from public,anon,authenticated;
revoke all on function public.owner_convert_accepted_quote_to_invoice(uuid,text,date) from public,anon;
revoke all on function public.owner_create_production_job_from_quote(uuid,text,date) from public,anon;
grant execute on function public.owner_convert_accepted_quote_to_invoice(uuid,text,date) to authenticated;
grant execute on function public.owner_create_production_job_from_quote(uuid,text,date) to authenticated;

notify pgrst,'reload schema';
