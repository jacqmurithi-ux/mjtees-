-- Persist the selected customer delivery address on each delivery attempt.
-- Address text is snapshotted so later customer-profile edits do not rewrite history.
begin;

alter table public.deliveries
  add column customer_address_id uuid,
  add column destination_label text,
  add column destination_address_text text,
  add column destination_locality text,
  add column destination_phone text;

alter table public.deliveries
  add constraint deliveries_customer_address_fk
  foreign key (business_id, customer_address_id)
  references public.customer_addresses(business_id, id)
  on delete restrict;

create index deliveries_business_customer_address_idx
  on public.deliveries(business_id, customer_address_id)
  where customer_address_id is not null;

alter table public.orders
  add column customer_address_id uuid,
  add constraint orders_customer_address_fk
  foreign key (business_id, customer_address_id)
  references public.customer_addresses(business_id, id)
  on delete restrict;

create index orders_business_customer_address_idx
  on public.orders(business_id, customer_address_id)
  where customer_address_id is not null;

create or replace function private.owner_set_order_delivery_address(
  p_order_id uuid,p_customer_address_id uuid,p_request_id uuid
) returns jsonb
language plpgsql security definer set search_path=''
as $
declare
  v_order public.orders%rowtype;
  v_actor uuid;
  v_payload jsonb;
  v_cached jsonb;
  v_result jsonb;
begin
  select * into v_order from public.orders where id=p_order_id for update;
  if not found then raise exception using errcode='P0002',message='Order not found'; end if;
  v_actor:=private.assert_active_owner(v_order.business_id);
  if p_request_id is null then
    raise exception using errcode='22023',message='A request id is required';
  end if;
  if v_order.status in ('completed','cancelled') then
    raise exception using errcode='55000',message='A completed or cancelled order cannot change its delivery address';
  end if;
  if p_customer_address_id is not null and not exists(
    select 1 from public.customer_addresses a
    where a.business_id=v_order.business_id and a.id=p_customer_address_id
      and a.customer_id=v_order.customer_id
  ) then
    raise exception using errcode='22023',message='Delivery address must belong to the customer on this order';
  end if;
  v_payload:=jsonb_build_object('order_id',p_order_id,'customer_address_id',p_customer_address_id);
  v_cached:=private.begin_idempotent_request(v_order.business_id,'set_order_delivery_address',p_request_id,v_payload);
  if v_cached is not null then return v_cached; end if;
  update public.orders set customer_address_id=p_customer_address_id,updated_at=now()
  where business_id=v_order.business_id and id=p_order_id;
  v_result:=jsonb_build_object('order_id',p_order_id,'customer_address_id',p_customer_address_id);
  perform private.finish_idempotent_request(v_order.business_id,'set_order_delivery_address',p_request_id,v_result);
  perform private.write_audit(v_order.business_id,v_actor,'order.delivery_address_set','order',p_order_id,p_request_id,v_result);
  return v_result;
end;
$;

create or replace function public.owner_set_order_delivery_address(
  p_order_id uuid,p_customer_address_id uuid,p_request_id uuid
) returns jsonb language sql security invoker set search_path=''
as $ select private.owner_set_order_delivery_address($1,$2,$3); $;

revoke all on function private.owner_set_order_delivery_address(uuid,uuid,uuid) from public,anon,authenticated;
grant execute on function private.owner_set_order_delivery_address(uuid,uuid,uuid) to authenticated;
revoke all on function public.owner_set_order_delivery_address(uuid,uuid,uuid) from public,anon;
grant execute on function public.owner_set_order_delivery_address(uuid,uuid,uuid) to authenticated;

create or replace function private.owner_record_delivery(
  p_order_id uuid,p_method text,p_carrier text,p_tracking_reference text,
  p_customer_paid_charge bigint,p_recipient_name text,p_request_id uuid,
  p_customer_address_id uuid
) returns jsonb
language plpgsql security definer set search_path=''
as $$
declare
  v_order public.orders%rowtype;
  v_address public.customer_addresses%rowtype;
  v_actor uuid;
  v_cached jsonb;
  v_payload jsonb;
  v_id uuid;
  v_existing public.deliveries%rowtype;
  v_result jsonb;
begin
  select * into v_order from public.orders where id=p_order_id;
  if not found then raise exception using errcode='P0002',message='Order not found'; end if;
  v_actor:=private.assert_active_owner(v_order.business_id);
  if v_order.status<>'ready' or p_method is null or p_method not in ('collection','courier')
    or p_customer_paid_charge is null or p_customer_paid_charge<0
    or length(btrim(coalesce(p_recipient_name,''))) not between 1 and 180
    or (p_method='courier' and length(btrim(coalesce(p_carrier,'')))=0) then
    raise exception using errcode='22023',message='Order must be ready and delivery details must be valid';
  end if;
  if p_customer_address_id is not null then
    select * into v_address from public.customer_addresses
    where business_id=v_order.business_id and id=p_customer_address_id
      and customer_id=v_order.customer_id;
    if not found then
      raise exception using errcode='22023',message='Delivery address must belong to the customer on this order';
    end if;
  end if;
  v_payload:=jsonb_build_object('order_id',p_order_id,'method',p_method,'carrier',p_carrier,
    'tracking_reference',p_tracking_reference,'customer_paid_charge',p_customer_paid_charge,
    'recipient_name',p_recipient_name,'customer_address_id',p_customer_address_id);
  v_cached:=private.begin_idempotent_request(v_order.business_id,'record_delivery',p_request_id,v_payload);
  if v_cached is not null then return v_cached; end if;
  select * into v_existing from public.deliveries
  where business_id=v_order.business_id and order_id=p_order_id and handed_over_at is null
    and failed_at is null and attempt_status in ('prepared','dispatched')
  order by created_at desc,id desc limit 1 for update;
  if found then
    if v_existing.method<>p_method then
      raise exception using errcode='22023',message='An active delivery exists with a different method';
    end if;
    update public.deliveries set carrier=nullif(btrim(p_carrier),''),
      tracking_reference=nullif(btrim(p_tracking_reference),''),
      customer_paid_charge=p_customer_paid_charge,recipient_name=btrim(p_recipient_name),
      customer_address_id=p_customer_address_id,
      destination_label=v_address.label,
      destination_address_text=v_address.address_text,
      destination_locality=v_address.locality,
      destination_phone=v_address.phone,
      dispatched_at=case when p_method='courier' then coalesce(dispatched_at,now()) else null end,
      updated_at=now()
    where business_id=v_order.business_id and id=v_existing.id returning id into v_id;
  else
    insert into public.deliveries(
      business_id,order_id,method,carrier,tracking_reference,customer_paid_charge,
      recipient_name,dispatched_at,customer_address_id,destination_label,
      destination_address_text,destination_locality,destination_phone
    ) values (
      v_order.business_id,p_order_id,p_method,nullif(btrim(p_carrier),''),
      nullif(btrim(p_tracking_reference),''),p_customer_paid_charge,btrim(p_recipient_name),
      case when p_method='courier' then now() else null end,p_customer_address_id,
      v_address.label,v_address.address_text,v_address.locality,v_address.phone
    ) returning id into v_id;
  end if;
  v_result:=jsonb_build_object('delivery_id',v_id,'method',p_method,
    'customer_paid_charge',p_customer_paid_charge,'customer_address_id',p_customer_address_id);
  perform private.finish_idempotent_request(v_order.business_id,'record_delivery',p_request_id,v_result);
  perform private.write_audit(v_order.business_id,v_actor,'delivery.recorded','delivery',v_id,p_request_id,
    jsonb_build_object('customer_paid_charge',p_customer_paid_charge,'method',p_method,
      'customer_address_id',p_customer_address_id));
  return v_result;
end;
$$;

create or replace function public.owner_record_delivery(
  p_order_id uuid,p_method text,p_carrier text,p_tracking_reference text,
  p_customer_paid_charge bigint,p_recipient_name text,p_request_id uuid,
  p_customer_address_id uuid
) returns jsonb language sql security invoker set search_path=''
as $$ select private.owner_record_delivery($1,$2,$3,$4,$5,$6,$7,$8); $$;

revoke all on function private.owner_record_delivery(uuid,text,text,text,bigint,text,uuid,uuid) from public,anon,authenticated;
grant execute on function private.owner_record_delivery(uuid,text,text,text,bigint,text,uuid,uuid) to authenticated;
revoke all on function public.owner_record_delivery(uuid,text,text,text,bigint,text,uuid,uuid) from public,anon;
grant execute on function public.owner_record_delivery(uuid,text,text,text,bigint,text,uuid,uuid) to authenticated;

commit;
