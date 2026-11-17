-- MJ Tees — payment reversal controls, order-level discounts and direct owner orders.
begin;

-- Payment status may only change from posted to reversed through the guarded RPC below.
create or replace function private.guard_payment_update()
returns trigger language plpgsql security definer set search_path=''
as $$
begin
  if old.status='posted' and new.status='reversed'
     and (to_jsonb(old)-'status')=(to_jsonb(new)-'status') then
    return new;
  end if;
  if (to_jsonb(old)-'status'-'verified_by'-'verified_at')<>(to_jsonb(new)-'status'-'verified_by'-'verified_at')
     or old.status<>'pending_verification'
     or new.status not in ('posted','rejected')
     or new.verified_by is null or new.verified_at is null then
    raise exception using errcode='55000',message='Payment evidence is immutable; only pending verification to posted/rejected or guarded posted to reversed is allowed';
  end if;
  return new;
end;
$$;

alter table public.quotation_items add column order_discount_allocated bigint not null default 0 check(order_discount_allocated>=0);
alter table public.order_items add column order_discount_allocated bigint not null default 0 check(order_discount_allocated>=0);
alter table public.quotation_items add column line_sequence integer not null default 0;
alter table public.order_items add column line_sequence integer not null default 0;

alter table public.quotation_items drop constraint quotation_items_total_consistency;
alter table public.order_items drop constraint order_items_total_consistency;
alter table public.quotation_items add constraint quotation_items_total_consistency
  check (line_sequence>0 and line_total=round(quantity*unit_price)::bigint-line_discount-order_discount_allocated);
alter table public.order_items add constraint order_items_total_consistency
  check (line_sequence>0 and line_total=round(quantity*unit_price)::bigint-line_discount-order_discount_allocated);

create unique index if not exists quotation_items_line_sequence_uq
on public.quotation_items(business_id,quotation_id,line_sequence);
create unique index if not exists order_items_line_sequence_uq
on public.order_items(business_id,order_id,line_sequence);

create or replace function private.assign_quotation_line_sequence()
returns trigger language plpgsql security definer set search_path=''
as $$
begin
  if new.line_sequence is null or new.line_sequence<=0 then
    select coalesce(max(line_sequence),0)+1 into new.line_sequence
    from public.quotation_items where business_id=new.business_id and quotation_id=new.quotation_id;
  end if;
  return new;
end;
$$;
create trigger quotation_items_assign_sequence
before insert on public.quotation_items
for each row execute function private.assign_quotation_line_sequence();

create or replace function private.assign_order_line_sequence()
returns trigger language plpgsql security definer set search_path=''
as $$
begin
  if new.line_sequence is null or new.line_sequence<=0 then
    select coalesce(max(line_sequence),0)+1 into new.line_sequence
    from public.order_items where business_id=new.business_id and order_id=new.order_id;
  end if;
  return new;
end;
$$;
create trigger order_items_assign_sequence
before insert on public.order_items
for each row execute function private.assign_order_line_sequence();

create or replace function private.guard_order_item_discount_allocation()
returns trigger language plpgsql security definer set search_path=''
as $$
declare v_item public.order_items%rowtype; v_gross bigint;
begin
  select * into v_item from public.order_items
  where business_id=new.business_id and order_id=new.order_id and id=new.order_item_id;
  if not found then raise exception using errcode='23514',message='Discount allocation order line not found'; end if;
  v_gross:=round(v_item.quantity*v_item.unit_price)::bigint;
  if new.discount_source='line_discount' then
    if new.pre_discount_line_amount<>v_gross or new.allocated_discount_amount<>v_item.line_discount then
      raise exception using errcode='23514',message='Line discount allocation does not match the accepted line discount';
    end if;
  elsif new.discount_source='order_discount' then
    if new.pre_discount_line_amount<>v_gross-v_item.line_discount
      or new.allocated_discount_amount<>v_item.order_discount_allocated then
      raise exception using errcode='23514',message='Order discount allocation does not match the accepted order discount';
    end if;
  end if;
  if new.allocated_discount_amount>new.pre_discount_line_amount then
    raise exception using errcode='23514',message='Discount allocation exceeds its pre-discount line amount';
  end if;
  return new;
end;
$$;

create or replace function private.owner_create_quotation_with_discount(
  p_business_id uuid,p_customer_id uuid,p_enquiry_id uuid,p_lines jsonb,p_order_discount bigint,
  p_expires_at timestamptz,p_customer_notes text,p_internal_notes text,p_request_id uuid
) returns jsonb language plpgsql security definer set search_path=''
as $$
declare
  v_actor uuid; v_cached jsonb; v_payload jsonb; v_base jsonb; v_quote_id uuid;
  v_quote public.quotations%rowtype; v_pre_total bigint; v_discount bigint; v_floor_total bigint;
  v_remaining bigint; v_result jsonb;
begin
  v_actor:=private.assert_active_owner(p_business_id);
  v_discount:=coalesce(p_order_discount,0);
  if v_discount<0 then raise exception using errcode='22023',message='Order discount cannot be negative'; end if;
  v_payload:=jsonb_build_object('customer_id',p_customer_id,'enquiry_id',p_enquiry_id,'lines',p_lines,
    'order_discount',v_discount,'expires_at',p_expires_at,'customer_notes',p_customer_notes,'internal_notes',p_internal_notes);
  v_cached:=private.begin_idempotent_request(p_business_id,'create_quotation_with_discount',p_request_id,v_payload);
  if v_cached is not null then return v_cached; end if;

  v_base:=private.owner_create_quotation(p_business_id,p_customer_id,p_enquiry_id,p_lines,p_expires_at,
    p_customer_notes,p_internal_notes,private.derived_request_uuid(p_request_id,'base-quotation'));
  v_quote_id:=(v_base->>'quotation_id')::uuid;
  select * into v_quote from public.quotations where business_id=p_business_id and id=v_quote_id for update;
  v_pre_total:=v_quote.total_amount;
  if v_discount>v_pre_total then raise exception using errcode='22023',message='Order discount exceeds the total after line discounts'; end if;

  if v_discount>0 then
    with bases as (
      select qi.id,qi.line_sequence,qi.line_total as base_amount,
        floor((v_discount::numeric*qi.line_total)/v_pre_total)::bigint as floor_amount,
        mod((v_discount::numeric*qi.line_total),v_pre_total::numeric) as remainder
      from public.quotation_items qi
      where qi.business_id=p_business_id and qi.quotation_id=v_quote_id and qi.line_total>0
    ), ranked as (
      select b.*,row_number() over(order by b.remainder desc,b.line_sequence,b.id) as allocation_rank,
        sum(b.floor_amount) over() as floors_total
      from bases b
    ), allocations as (
      select id,base_amount,
        floor_amount+case when allocation_rank<=v_discount-floors_total then 1 else 0 end as allocated
      from ranked
    )
    update public.quotation_items qi set
      order_discount_allocated=a.allocated,
      line_total=a.base_amount-a.allocated
    from allocations a where qi.business_id=p_business_id and qi.quotation_id=v_quote_id and qi.id=a.id;
  end if;

  update public.quotations set discount_amount=discount_amount+v_discount,
    total_amount=total_amount-v_discount,updated_at=now()
  where business_id=p_business_id and id=v_quote_id returning * into v_quote;

  v_result:=jsonb_build_object('quotation_id',v_quote_id,'quote_number',v_quote.quote_number,
    'subtotal_amount',v_quote.subtotal_amount,'discount_amount',v_quote.discount_amount,
    'total_amount',v_quote.total_amount,'order_discount',v_discount,'currency_code','KES');
  perform private.finish_idempotent_request(p_business_id,'create_quotation_with_discount',p_request_id,v_result);
  perform private.write_audit(p_business_id,v_actor,'quotation.order_discount_allocated','quotation',v_quote_id,p_request_id,
    jsonb_build_object('order_discount',v_discount,'allocation_method','largest_remainder_v1'));
  return v_result;
end;
$$;

create or replace function private.accept_quotation_token(p_token text,p_request_id uuid)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_hash bytea; v_token private.quote_acceptance_tokens%rowtype; v_quote public.quotations%rowtype;
  v_cached jsonb; v_payload jsonb; v_order uuid; v_order_number text; v_owner uuid; v_line record;
  v_order_item uuid; v_unit_cost bigint; v_total_cost bigint; v_gross bigint; v_result jsonb;
begin
  if p_token is null or length(p_token) not between 32 and 256 or p_request_id is null then
    raise exception using errcode='22023',message='Invalid quote acceptance token';
  end if;
  v_hash:=extensions.digest(convert_to(p_token,'UTF8'),'sha256');
  select * into v_token from private.quote_acceptance_tokens where token_hash=v_hash;
  if not found then raise exception using errcode='P0002',message='Quote acceptance link is invalid'; end if;
  select * into v_quote from public.quotations where business_id=v_token.business_id and id=v_token.quotation_id for update;
  if not found then raise exception using errcode='P0002',message='Quotation not found'; end if;
  v_payload:=jsonb_build_object('token_hash',encode(v_hash,'hex'));
  v_cached:=private.begin_idempotent_request(v_quote.business_id,'accept_quotation',p_request_id,v_payload);
  if v_cached is not null then return v_cached; end if;
  select * into v_token from private.quote_acceptance_tokens where id=v_token.id for update;
  if v_token.used_at is not null or v_token.expires_at<=now()
    or (v_quote.expires_at is not null and v_quote.expires_at<=now()) or v_quote.status<>'sent' then
    raise exception using errcode='22023',message='Quote acceptance link has expired or was already used';
  end if;
  select user_id into v_owner from public.business_memberships
  where business_id=v_quote.business_id and role='owner' and status='active'
  order by created_at,id limit 1;
  if v_owner is null then raise exception using errcode='23514',message='Business has no active owner'; end if;
  v_order_number:=private.next_document_number(v_quote.business_id,'order');
  insert into public.orders(business_id,order_number,customer_id,quotation_id,status,currency_code,
    subtotal_amount,discount_amount,total_amount,created_by)
  values(v_quote.business_id,v_order_number,v_quote.customer_id,v_quote.id,'confirmed','KES',
    v_quote.subtotal_amount,v_quote.discount_amount,v_quote.total_amount,v_owner)
  returning id into v_order;

  for v_line in
    select qi.* from public.quotation_items qi
    where qi.business_id=v_quote.business_id and qi.quotation_id=v_quote.id
    order by qi.line_sequence,qi.id
  loop
    v_total_cost:=coalesce((v_line.cost_estimate_snapshot->>'estimated_total_cost')::bigint,0);
    v_unit_cost:=coalesce((v_line.cost_estimate_snapshot->>'estimated_unit_cost')::bigint,0);
    v_gross:=round(v_line.quantity*v_line.unit_price)::bigint;
    insert into public.order_items(business_id,order_id,line_sequence,description,quantity,unit,unit_price,
      line_discount,order_discount_allocated,line_total,category_id,stock_item_id,customer_supplies_item,
      sale_mode,production_method_id,production_specification,estimated_unit_cost,estimated_total_cost,
      cost_breakdown_snapshot,cost_calculation_version)
    values(v_quote.business_id,v_order,v_line.line_sequence,v_line.description,v_line.quantity,v_line.unit,
      v_line.unit_price,v_line.line_discount,v_line.order_discount_allocated,v_line.line_total,
      v_line.category_id,v_line.stock_item_id,v_line.customer_supplies_item,v_line.sale_mode,
      v_line.production_method_id,v_line.production_specification,v_unit_cost,v_total_cost,
      v_line.cost_estimate_snapshot,v_line.cost_estimate_snapshot->>'calculation_version')
    returning id into v_order_item;

    if v_line.line_discount>0 then
      insert into public.order_item_discount_allocations(business_id,order_id,order_item_id,discount_source,
        pre_discount_line_amount,allocated_discount_amount,allocation_version,created_by)
      values(v_quote.business_id,v_order,v_order_item,'line_discount',v_gross,v_line.line_discount,'line-discount-v1',null);
    end if;
    if v_line.order_discount_allocated>0 then
      insert into public.order_item_discount_allocations(business_id,order_id,order_item_id,discount_source,
        pre_discount_line_amount,allocated_discount_amount,allocation_version,created_by)
      values(v_quote.business_id,v_order,v_order_item,'order_discount',v_gross-v_line.line_discount,
        v_line.order_discount_allocated,'order-discount-largest-remainder-v1',null);
    end if;
  end loop;

  update public.quotations set status='accepted',accepted_at=now(),updated_at=now()
  where business_id=v_quote.business_id and id=v_quote.id;
  update private.quote_acceptance_tokens set used_at=clock_timestamp() where id=v_token.id;
  insert into public.quotation_events(business_id,quotation_id,event_type,source)
  values(v_quote.business_id,v_quote.id,'accepted','customer_link');
  insert into public.order_events(business_id,order_id,event_type,to_status,actor_user_id,reason)
  values(v_quote.business_id,v_order,'created','confirmed',null,'Accepted quotation '||v_quote.quote_number);
  v_result:=jsonb_build_object('ok',true,'order_number',v_order_number,'total_amount',v_quote.total_amount,
    'currency_code','KES','message','Quotation accepted and order created');
  perform private.finish_idempotent_request(v_quote.business_id,'accept_quotation',p_request_id,v_result);
  perform private.write_audit(v_quote.business_id,null,'quotation.accepted','quotation',v_quote.id,p_request_id,
    jsonb_build_object('order_number',v_order_number,'order_id',v_order));
  return v_result;
end;
$$;

create or replace function private.owner_create_direct_order(
  p_business_id uuid,p_customer_id uuid,p_enquiry_id uuid,p_lines jsonb,p_order_discount bigint,
  p_customer_notes text,p_internal_notes text,p_request_id uuid
) returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_actor uuid; v_cached jsonb; v_payload jsonb; v_quote jsonb; v_send jsonb; v_accept jsonb; v_result jsonb; v_quote_id uuid;
begin
  v_actor:=private.assert_active_owner(p_business_id);
  v_payload:=jsonb_build_object('customer_id',p_customer_id,'enquiry_id',p_enquiry_id,'lines',p_lines,
    'order_discount',p_order_discount,'customer_notes',p_customer_notes,'internal_notes',p_internal_notes);
  v_cached:=private.begin_idempotent_request(p_business_id,'create_direct_order',p_request_id,v_payload);
  if v_cached is not null then return v_cached; end if;
  v_quote:=private.owner_create_quotation_with_discount(p_business_id,p_customer_id,p_enquiry_id,p_lines,
    p_order_discount,now()+interval '1 day',p_customer_notes,p_internal_notes,
    private.derived_request_uuid(p_request_id,'direct-order-quote'));
  v_quote_id:=(v_quote->>'quotation_id')::uuid;
  v_send:=private.owner_send_quotation(v_quote_id,now()+interval '1 day',
    private.derived_request_uuid(p_request_id,'direct-order-send'));
  v_accept:=private.accept_quotation_token(v_send->>'acceptance_token',
    private.derived_request_uuid(p_request_id,'direct-order-accept'));
  v_result:=jsonb_build_object('order_number',v_accept->>'order_number','total_amount',v_accept->'total_amount',
    'currency_code','KES','status','confirmed');
  perform private.finish_idempotent_request(p_business_id,'create_direct_order',p_request_id,v_result);
  perform private.write_audit(p_business_id,v_actor,'order.created_directly','order',null,p_request_id,
    jsonb_build_object('order_number',v_accept->>'order_number','quotation_id',v_quote_id));
  return v_result;
end;
$$;

create or replace function private.owner_cancel_refund(p_refund_id uuid,p_reason text,p_request_id uuid)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_refund public.payment_refunds%rowtype; v_actor uuid; v_cached jsonb; v_payload jsonb; v_result jsonb;
begin
  select * into v_refund from public.payment_refunds where id=p_refund_id;
  if not found then raise exception using errcode='P0002',message='Refund not found'; end if;
  v_actor:=private.assert_active_owner(v_refund.business_id);
  if length(btrim(coalesce(p_reason,'')))=0 then raise exception using errcode='22023',message='Refund cancellation reason is required'; end if;
  v_payload:=jsonb_build_object('refund_id',p_refund_id,'reason',p_reason);
  v_cached:=private.begin_idempotent_request(v_refund.business_id,'cancel_refund',p_request_id,v_payload);
  if v_cached is not null then return v_cached; end if;
  select * into v_refund from public.payment_refunds where business_id=v_refund.business_id and id=p_refund_id for update;
  if v_refund.status<>'pending' then raise exception using errcode='22023',message='Only pending refunds can be cancelled'; end if;
  update public.payment_refunds set status='cancelled' where business_id=v_refund.business_id and id=p_refund_id;
  v_result:=jsonb_build_object('refund_id',p_refund_id,'status','cancelled');
  perform private.finish_idempotent_request(v_refund.business_id,'cancel_refund',p_request_id,v_result);
  perform private.write_audit(v_refund.business_id,v_actor,'payment.refund_cancelled','payment_refund',p_refund_id,p_request_id,
    jsonb_build_object('reason',p_reason,'amount',v_refund.amount));
  return v_result;
end;
$$;

create or replace function private.owner_reverse_payment(p_payment_id uuid,p_reason text,p_request_id uuid)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_payment public.payments%rowtype; v_actor uuid; v_cached jsonb; v_payload jsonb; v_result jsonb;
begin
  select * into v_payment from public.payments where id=p_payment_id;
  if not found then raise exception using errcode='P0002',message='Payment not found'; end if;
  v_actor:=private.assert_active_owner(v_payment.business_id);
  if length(btrim(coalesce(p_reason,'')))=0 then raise exception using errcode='22023',message='Payment reversal reason is required'; end if;
  v_payload:=jsonb_build_object('payment_id',p_payment_id,'reason',p_reason);
  v_cached:=private.begin_idempotent_request(v_payment.business_id,'reverse_payment',p_request_id,v_payload);
  if v_cached is not null then return v_cached; end if;
  select * into v_payment from public.payments where business_id=v_payment.business_id and id=p_payment_id for update;
  if v_payment.status<>'posted' then raise exception using errcode='22023',message='Only posted payments can be reversed'; end if;
  if exists(select 1 from public.payment_refunds f where f.business_id=v_payment.business_id and f.payment_id=p_payment_id and f.status in ('pending','posted')) then
    raise exception using errcode='22023',message='Cancel pending refunds and resolve posted refunds before reversing the payment';
  end if;
  if exists(
    select 1 from public.payment_allocations a
    where a.business_id=v_payment.business_id and a.payment_id=p_payment_id
      and a.amount>coalesce((select sum(r.amount) from public.allocation_reversals r
        where r.business_id=a.business_id and r.allocation_id=a.id),0)
  ) then
    raise exception using errcode='22023',message='Reverse every remaining order allocation before reversing the payment';
  end if;
  update public.payments set status='reversed' where business_id=v_payment.business_id and id=p_payment_id;
  insert into public.payment_events(business_id,payment_id,event_type,actor_user_id,reason)
  values(v_payment.business_id,p_payment_id,'reversed',v_actor,btrim(p_reason));
  v_result:=jsonb_build_object('payment_id',p_payment_id,'status','reversed','amount',v_payment.amount);
  perform private.finish_idempotent_request(v_payment.business_id,'reverse_payment',p_request_id,v_result);
  perform private.write_audit(v_payment.business_id,v_actor,'payment.reversed','payment',p_payment_id,p_request_id,
    jsonb_build_object('reason',p_reason,'amount',v_payment.amount));
  return v_result;
end;
$$;

create or replace function public.owner_create_quotation_with_discount(
 p_business_id uuid,p_customer_id uuid,p_enquiry_id uuid,p_lines jsonb,p_order_discount bigint,
 p_expires_at timestamptz,p_customer_notes text,p_internal_notes text,p_request_id uuid
) returns jsonb language sql security invoker set search_path=''
as $$ select private.owner_create_quotation_with_discount($1,$2,$3,$4,$5,$6,$7,$8,$9); $$;

create or replace function public.owner_create_direct_order(
 p_business_id uuid,p_customer_id uuid,p_enquiry_id uuid,p_lines jsonb,p_order_discount bigint,
 p_customer_notes text,p_internal_notes text,p_request_id uuid
) returns jsonb language sql security invoker set search_path=''
as $$ select private.owner_create_direct_order($1,$2,$3,$4,$5,$6,$7,$8); $$;

create or replace function public.owner_cancel_refund(p_refund_id uuid,p_reason text,p_request_id uuid)
returns jsonb language sql security invoker set search_path=''
as $$ select private.owner_cancel_refund($1,$2,$3); $$;

create or replace function public.owner_reverse_payment(p_payment_id uuid,p_reason text,p_request_id uuid)
returns jsonb language sql security invoker set search_path=''
as $$ select private.owner_reverse_payment($1,$2,$3); $$;

revoke all on function private.owner_create_quotation_with_discount(uuid,uuid,uuid,jsonb,bigint,timestamptz,text,text,uuid),
 private.owner_create_direct_order(uuid,uuid,uuid,jsonb,bigint,text,text,uuid),
 private.owner_cancel_refund(uuid,text,uuid),private.owner_reverse_payment(uuid,text,uuid)
from public,anon,authenticated;
grant execute on function private.owner_create_quotation_with_discount(uuid,uuid,uuid,jsonb,bigint,timestamptz,text,text,uuid),
 private.owner_create_direct_order(uuid,uuid,uuid,jsonb,bigint,text,text,uuid),
 private.owner_cancel_refund(uuid,text,uuid),private.owner_reverse_payment(uuid,text,uuid)
to authenticated;

revoke all on function public.owner_create_quotation_with_discount(uuid,uuid,uuid,jsonb,bigint,timestamptz,text,text,uuid),
 public.owner_create_direct_order(uuid,uuid,uuid,jsonb,bigint,text,text,uuid),
 public.owner_cancel_refund(uuid,text,uuid),public.owner_reverse_payment(uuid,text,uuid)
from public,anon;
grant execute on function public.owner_create_quotation_with_discount(uuid,uuid,uuid,jsonb,bigint,timestamptz,text,text,uuid),
 public.owner_create_direct_order(uuid,uuid,uuid,jsonb,bigint,text,text,uuid),
 public.owner_cancel_refund(uuid,text,uuid),public.owner_reverse_payment(uuid,text,uuid)
to authenticated;

commit;
