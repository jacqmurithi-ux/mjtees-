-- MJ Tees Sales — apply customer credit to an issued invoice.

begin;

create or replace function private.owner_apply_sales_customer_credit(
  p_business_id uuid,
  p_customer_id uuid,
  p_invoice_id uuid,
  p_amount bigint,
  p_request_id uuid
) returns jsonb
language plpgsql
security definer
set search_path=''
as $function$
declare
  v_actor uuid;
  v_invoice public.sales_invoices%rowtype;
  v_customer public.customers%rowtype;
  v_cached jsonb;
  v_payload jsonb;
  v_available_credit bigint;
  v_invoice_paid bigint;
  v_invoice_balance bigint;
  v_result jsonb;
begin
  v_actor:=private.assert_active_owner(p_business_id);
  if p_amount is null or p_amount<=0 then
    raise exception using errcode='22023',message='Credit application amount must be a positive whole-KES amount';
  end if;

  select si.* into v_invoice
  from public.sales_invoices si
  join public.orders o on o.business_id=si.business_id and o.id=si.order_id
  where si.business_id=p_business_id and si.id=p_invoice_id and o.customer_id=p_customer_id
  for update of si,o;
  if not found then
    raise exception using errcode='P0002',message='Issued invoice for this customer not found';
  end if;
  v_payload:=jsonb_build_object(
    'customer_id',p_customer_id,'invoice_id',p_invoice_id,'amount',p_amount
  );
  v_cached:=private.begin_idempotent_request(p_business_id,'apply_sales_customer_credit',p_request_id,v_payload);
  if v_cached is not null then return v_cached; end if;

  if v_invoice.status not in ('sent','partially_paid','overdue') then
    raise exception using errcode='22023',message='Only issued invoices with an outstanding balance can receive customer credit';
  end if;

  select * into v_customer
  from public.customers
  where business_id=p_business_id and id=p_customer_id and archived_at is null
  for update;
  if not found then
    raise exception using errcode='P0002',message='Active customer not found';
  end if;

  select coalesce(sum(amount),0)::bigint into v_available_credit
  from public.sales_customer_credit_entries
  where business_id=p_business_id and customer_id=p_customer_id;
  if p_amount>v_available_credit then
    raise exception using errcode='22023',message='Credit application exceeds the customer credit balance';
  end if;

  select coalesce(sum(a.amount),0)::bigint
    + coalesce((
      select -sum(e.amount)::bigint
      from public.sales_customer_credit_entries e
      where e.business_id=p_business_id and e.invoice_id=p_invoice_id
        and e.entry_type='apply_to_invoice'
    ),0)
  into v_invoice_paid
  from public.sales_invoice_payment_allocations a
  join public.payments p on p.business_id=a.business_id and p.id=a.payment_id
  where a.business_id=p_business_id and a.invoice_id=p_invoice_id and p.status='posted';

  v_invoice_balance:=greatest(v_invoice.total_amount-v_invoice_paid,0);
  if p_amount>v_invoice_balance then
    raise exception using errcode='22023',message='Credit application exceeds the outstanding invoice balance';
  end if;

  insert into public.sales_customer_credit_entries(
    business_id,customer_id,entry_type,amount,invoice_id,description,actor_user_id,request_id
  ) values (
    p_business_id,p_customer_id,'apply_to_invoice',-p_amount,p_invoice_id,
    'Customer credit applied to invoice '||v_invoice.invoice_number,v_actor,p_request_id
  );

  update public.sales_invoices
  set status=case
    when v_invoice_paid+p_amount>=v_invoice.total_amount then 'paid'
    when v_invoice_paid+p_amount>0 then 'partially_paid'
    else status end,
    updated_at=now()
  where business_id=p_business_id and id=p_invoice_id;

  v_result:=jsonb_build_object(
    'invoice_id',p_invoice_id,'amount_applied',p_amount,
    'customer_credit_balance',v_available_credit-p_amount,
    'invoice_balance',v_invoice_balance-p_amount,'status',
    case when v_invoice_paid+p_amount>=v_invoice.total_amount then 'paid' else 'partially_paid' end
  );
  perform private.finish_idempotent_request(p_business_id,'apply_sales_customer_credit',p_request_id,v_result);
  perform private.write_audit(p_business_id,v_actor,'sales.customer_credit_applied','sales_invoice',p_invoice_id,p_request_id,
    jsonb_build_object('customer_id',p_customer_id,'amount',p_amount,'credit_balance_after',v_available_credit-p_amount));
  return v_result;
end;
$function$;

create or replace function public.owner_apply_sales_customer_credit(
  p_business_id uuid,p_customer_id uuid,p_invoice_id uuid,p_amount bigint,p_request_id uuid
) returns jsonb
language sql
security invoker
set search_path=''
as $function$
  select private.owner_apply_sales_customer_credit($1,$2,$3,$4,$5);
$function$;

revoke all on function private.owner_apply_sales_customer_credit(uuid,uuid,uuid,bigint,uuid) from public,anon,authenticated;
grant execute on function private.owner_apply_sales_customer_credit(uuid,uuid,uuid,bigint,uuid) to authenticated;

revoke all on function public.owner_apply_sales_customer_credit(uuid,uuid,uuid,bigint,uuid)
from public,anon;
grant execute on function public.owner_apply_sales_customer_credit(uuid,uuid,uuid,bigint,uuid)
to authenticated;

commit;
