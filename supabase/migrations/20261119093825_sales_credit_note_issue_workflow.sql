-- Owner-authorised Sales credit note issuance.
-- A credit note first reduces the invoice's outstanding balance; any excess
-- remains as customer credit. Paid invoices retain their original payment and
-- invoice records, with the full credit note becoming customer credit.
begin;

create or replace function private.owner_issue_sales_credit_note(
  p_business_id uuid,
  p_invoice_id uuid,
  p_reason text,
  p_items jsonb,
  p_discount_amount bigint,
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
  v_customer_id uuid;
  v_invoice_item public.sales_invoice_items%rowtype;
  v_item jsonb;
  v_description text;
  v_quantity numeric;
  v_unit_price bigint;
  v_item_amount bigint;
  v_invoice_item_id uuid;
  v_previously_credited bigint;
  v_subtotal bigint:=0;
  v_total bigint;
  v_existing_credit bigint;
  v_invoice_paid bigint;
  v_invoice_balance bigint;
  v_apply_amount bigint;
  v_customer_credit_balance bigint;
  v_credit_note_id uuid;
  v_credit_note_number text;
  v_cached jsonb;
  v_payload jsonb;
  v_result jsonb;
begin
  v_actor:=private.assert_active_owner(p_business_id);

  if p_invoice_id is null
     or length(btrim(coalesce(p_reason,''))) not between 1 and 1000
     or p_discount_amount is null or p_discount_amount<0
     or p_request_id is null
     or jsonb_typeof(coalesce(p_items,'[]'::jsonb))<>'array'
     or jsonb_array_length(coalesce(p_items,'[]'::jsonb)) not between 1 and 100 then
    raise exception using errcode='22023',message='Enter an invoice, reason, 1 to 100 credit note lines, a valid discount and request id';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(coalesce(p_items,'[]'::jsonb)) e(value)
    where jsonb_typeof(e.value)<>'object'
       or length(btrim(coalesce(e.value->>'description',''))) not between 1 and 500
       or coalesce(e.value->>'quantity','') !~ '^[0-9]+([.][0-9]{1,3})?$'
       or coalesce(e.value->>'unit_price','') !~ '^[0-9]+$'
       or coalesce(e.value->>'amount','') !~ '^[0-9]+$'
       or (
         nullif(e.value->>'invoice_item_id','') is not null
         and nullif(e.value->>'invoice_item_id','') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
       )
  ) then
    raise exception using errcode='22023',message='Each credit note line needs a description, positive quantity, whole-KES unit price and amount, and a valid optional invoice line';
  end if;

  for v_item in
    select value from jsonb_array_elements(coalesce(p_items,'[]'::jsonb))
  loop
    v_quantity:=(v_item->>'quantity')::numeric;
    v_unit_price:=(v_item->>'unit_price')::bigint;
    v_item_amount:=(v_item->>'amount')::bigint;
    if v_quantity<=0 or v_quantity<>round(v_quantity,3)
       or v_item_amount>round(v_quantity*v_unit_price)::bigint then
      raise exception using errcode='22023',message='Credit note line amount must be non-negative and cannot exceed its quantity multiplied by unit price';
    end if;
    v_subtotal:=v_subtotal+v_item_amount;
  end loop;

  if p_discount_amount>v_subtotal then
    raise exception using errcode='22023',message='Credit note discount cannot exceed its line subtotal';
  end if;
  v_total:=v_subtotal-p_discount_amount;
  if v_total<=0 then
    raise exception using errcode='22023',message='Credit note total must be greater than zero';
  end if;

  select si,o.customer_id
    into v_invoice,v_customer_id
  from public.sales_invoices si
  join public.orders o on o.business_id=si.business_id and o.id=si.order_id
  where si.business_id=p_business_id and si.id=p_invoice_id
  for update of si,o;
  if not found then
    raise exception using errcode='P0002',message='Sales invoice not found';
  end if;
  if v_invoice.status not in ('sent','partially_paid','paid','overdue') then
    raise exception using errcode='22023',message='A draft or void invoice cannot receive a credit note';
  end if;

  select * into v_customer
  from public.customers
  where business_id=p_business_id and id=v_customer_id and archived_at is null
  for update;
  if not found then
    raise exception using errcode='P0002',message='Active invoice customer not found';
  end if;

  v_payload:=jsonb_build_object(
    'invoice_id',p_invoice_id,
    'reason',btrim(p_reason),
    'items',p_items,
    'discount_amount',p_discount_amount
  );
  v_cached:=private.begin_idempotent_request(
    p_business_id,'issue_sales_credit_note',p_request_id,v_payload
  );
  if v_cached is not null then return v_cached; end if;

  select coalesce(sum(cn.total_amount),0)::bigint
    into v_existing_credit
  from public.sales_credit_notes cn
  where cn.business_id=p_business_id
    and cn.invoice_id=p_invoice_id
    and cn.status='issued';
  if v_total>v_invoice.total_amount-v_existing_credit then
    raise exception using errcode='22023',message='Credit notes cannot exceed the remaining value of the original invoice';
  end if;

  v_credit_note_number:=private.next_sales_document_number(p_business_id,'credit_note');
  insert into public.sales_credit_notes(
    business_id,customer_id,invoice_id,credit_note_number,status,reason,
    subtotal_amount,discount_amount,total_amount,created_by
  ) values (
    p_business_id,v_customer_id,p_invoice_id,v_credit_note_number,'draft',btrim(p_reason),
    v_subtotal,p_discount_amount,v_total,v_actor
  ) returning id into v_credit_note_id;

  for v_item in
    select value from jsonb_array_elements(coalesce(p_items,'[]'::jsonb))
  loop
    v_description:=btrim(v_item->>'description');
    v_quantity:=(v_item->>'quantity')::numeric;
    v_unit_price:=(v_item->>'unit_price')::bigint;
    v_item_amount:=(v_item->>'amount')::bigint;
    v_invoice_item_id:=nullif(v_item->>'invoice_item_id','')::uuid;

    if v_invoice_item_id is not null then
      select * into v_invoice_item
      from public.sales_invoice_items
      where business_id=p_business_id
        and invoice_id=p_invoice_id
        and id=v_invoice_item_id
      for update;
      if not found then
        raise exception using errcode='22023',message='A credit note line must reference an item on the selected invoice';
      end if;

      select coalesce(sum(cni.amount),0)::bigint
        into v_previously_credited
      from public.sales_credit_note_items cni
      join public.sales_credit_notes cn
        on cn.business_id=cni.business_id and cn.id=cni.credit_note_id
      where cni.business_id=p_business_id
        and cni.invoice_item_id=v_invoice_item_id
        and cn.status='issued';
      if v_item_amount>v_invoice_item.line_total-v_previously_credited then
        raise exception using errcode='22023',message='Credit note line exceeds the remaining value of the original invoice item';
      end if;
    end if;

    insert into public.sales_credit_note_items(
      business_id,credit_note_id,invoice_item_id,description,quantity,unit_price,amount
    ) values (
      p_business_id,v_credit_note_id,v_invoice_item_id,v_description,
      v_quantity,v_unit_price,v_item_amount
    );
  end loop;

  update public.sales_credit_notes
  set status='issued',issued_at=now()
  where business_id=p_business_id and id=v_credit_note_id;

  select coalesce(sum(a.amount),0)::bigint
    + coalesce((
      select -sum(e.amount)::bigint
      from public.sales_customer_credit_entries e
      where e.business_id=p_business_id
        and e.invoice_id=p_invoice_id
        and e.entry_type='apply_to_invoice'
    ),0)
    into v_invoice_paid
  from public.sales_invoice_payment_allocations a
  join public.payments p
    on p.business_id=a.business_id and p.id=a.payment_id
  where a.business_id=p_business_id
    and a.invoice_id=p_invoice_id
    and p.status='posted';

  v_invoice_balance:=greatest(v_invoice.total_amount-v_invoice_paid,0);
  v_apply_amount:=least(v_total,v_invoice_balance);

  insert into public.sales_customer_credit_entries(
    business_id,customer_id,entry_type,amount,invoice_id,credit_note_id,
    description,actor_user_id,request_id
  ) values (
    p_business_id,v_customer_id,'credit_note',v_total,p_invoice_id,v_credit_note_id,
    'Credit note '||v_credit_note_number||' issued against invoice '||v_invoice.invoice_number,
    v_actor,p_request_id
  );

  if v_apply_amount>0 then
    insert into public.sales_customer_credit_entries(
      business_id,customer_id,entry_type,amount,invoice_id,credit_note_id,
      description,actor_user_id,request_id
    ) values (
      p_business_id,v_customer_id,'apply_to_invoice',-v_apply_amount,p_invoice_id,v_credit_note_id,
      'Credit note '||v_credit_note_number||' applied to invoice '||v_invoice.invoice_number,
      v_actor,gen_random_uuid()
    );

    update public.sales_invoices
    set status=case
      when v_invoice_paid+v_apply_amount>=v_invoice.total_amount then 'paid'
      else 'partially_paid'
    end,
    updated_at=now()
    where business_id=p_business_id and id=p_invoice_id;
  end if;

  select coalesce(sum(amount),0)::bigint
    into v_customer_credit_balance
  from public.sales_customer_credit_entries
  where business_id=p_business_id and customer_id=v_customer_id;

  v_result:=jsonb_build_object(
    'credit_note_id',v_credit_note_id,
    'credit_note_number',v_credit_note_number,
    'status','issued',
    'invoice_id',p_invoice_id,
    'total_amount',v_total,
    'amount_applied_to_invoice',v_apply_amount,
    'invoice_balance',greatest(v_invoice_balance-v_apply_amount,0),
    'customer_credit_balance',v_customer_credit_balance,
    'invoice_status',case
      when v_apply_amount>0 and v_invoice_paid+v_apply_amount>=v_invoice.total_amount then 'paid'
      when v_apply_amount>0 then 'partially_paid'
      else v_invoice.status
    end
  );

  perform private.finish_idempotent_request(
    p_business_id,'issue_sales_credit_note',p_request_id,v_result
  );
  perform private.write_audit(
    p_business_id,v_actor,'sales.credit_note_issued','sales_credit_note',
    v_credit_note_id,p_request_id,
    jsonb_build_object(
      'invoice_id',p_invoice_id,'customer_id',v_customer_id,
      'credit_note_number',v_credit_note_number,'total_amount',v_total,
      'amount_applied_to_invoice',v_apply_amount,
      'customer_credit_balance',v_customer_credit_balance
    )
  );

  return v_result;
end;
$function$;

create or replace function public.owner_issue_sales_credit_note(
  p_business_id uuid,p_invoice_id uuid,p_reason text,p_items jsonb,
  p_discount_amount bigint,p_request_id uuid
) returns jsonb
language sql
security invoker
set search_path=''
as $function$
  select private.owner_issue_sales_credit_note($1,$2,$3,$4,$5,$6);
$function$;

revoke all on function private.owner_issue_sales_credit_note(uuid,uuid,text,jsonb,bigint,uuid)
from public,anon,authenticated;
grant execute on function private.owner_issue_sales_credit_note(uuid,uuid,text,jsonb,bigint,uuid)
to authenticated;

revoke all on function public.owner_issue_sales_credit_note(uuid,uuid,text,jsonb,bigint,uuid)
from public,anon;
grant execute on function public.owner_issue_sales_credit_note(uuid,uuid,text,jsonb,bigint,uuid)
to authenticated;

commit;
