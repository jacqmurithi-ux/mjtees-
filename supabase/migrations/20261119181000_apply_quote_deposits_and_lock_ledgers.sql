-- Apply accepted quotation deposits to the invoice as actual customer payments.
create or replace function public.owner_convert_quote_to_invoice(
 p_quote_id uuid,p_invoice_number text,p_job_number text,p_due_date date
) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare q public.quotations%rowtype; v_invoice uuid; v_job uuid; v_user uuid; v_customer_supplied boolean; v_job_name text;
 v_deposit record; v_paid numeric(14,2):=0; v_payment uuid;
begin
 v_user:=auth.uid();
 if v_user is null then raise exception 'Authentication required'; end if;
 select * into q from public.quotations where id=p_quote_id for update;
 if not found or not exists(select 1 from public.business_memberships where business_id=q.business_id and user_id=v_user and role='owner') then raise exception 'Quotation not found'; end if;
 if q.status<>'accepted' then raise exception 'Only accepted quotations can be invoiced'; end if;
 select coalesce(sum(amount),0) into v_paid from public.quotation_deposits where quotation_id=q.id and business_id=q.business_id;
 if v_paid>q.total then raise exception 'Recorded deposits exceed quotation total'; end if;
 insert into public.sales_invoices(business_id,customer_id,invoice_number,status,due_date,total,amount_paid,balance,created_by)
 values(q.business_id,q.customer_id,btrim(p_invoice_number),case when v_paid=q.total then 'paid' when v_paid>0 then 'partially_paid' else 'sent' end,p_due_date,q.total,v_paid,q.total-v_paid,v_user)
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
 for v_deposit in select * from public.quotation_deposits where quotation_id=q.id and business_id=q.business_id order by received_at,id loop
  insert into public.payments(business_id,customer_id,payment_number,method,amount,reference_code,received_by,received_at)
  values(q.business_id,q.customer_id,'QD-'||v_deposit.deposit_number,v_deposit.method,v_deposit.amount,v_deposit.reference_code,v_deposit.received_by,v_deposit.received_at)
  returning id into v_payment;
  insert into public.payment_allocations(business_id,payment_id,invoice_id,amount)
  values(q.business_id,v_payment,v_invoice,v_deposit.amount);
 end loop;
 update public.quotations set status='converted' where id=q.id;
 insert into public.audit_events(business_id,actor_user_id,event_type,entity_type,entity_id,details)
 values(q.business_id,v_user,'quotation.converted','quotation',q.id,jsonb_build_object('invoice_id',v_invoice,'job_id',v_job,'deposits_applied',v_paid));
 return jsonb_build_object('invoice_id',v_invoice,'job_id',v_job,'deposits_applied',v_paid,'balance',q.total-v_paid);
end $$;

-- RPCs perform all inserts under a checked owner identity; browser clients remain read-only on ledgers.
alter table public.supplier_payments enable row level security;
alter table public.quotation_deposits enable row level security;
alter table public.inventory_adjustments enable row level security;
alter table public.supplier_price_reviews enable row level security;
revoke insert,update,delete on public.supplier_payments,public.quotation_deposits,public.inventory_adjustments,public.supplier_price_reviews,public.refunds from authenticated;
grant select on public.supplier_payments,public.quotation_deposits,public.inventory_adjustments,public.supplier_price_reviews,public.refunds to authenticated;

revoke all on function public.owner_convert_quote_to_invoice(uuid,text,text,date) from public,anon;
grant execute on function public.owner_convert_quote_to_invoice(uuid,text,text,date) to authenticated;
