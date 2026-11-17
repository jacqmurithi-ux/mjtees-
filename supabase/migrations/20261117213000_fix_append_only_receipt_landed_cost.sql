-- Keep stock movements append-only: calculate landed cost before inserting the receipt movement.
drop trigger if exists goods_receipt_items_transport_after on public.goods_receipt_items;
drop function if exists private.apply_receipt_transport_to_inventory();

create or replace function private.owner_receive_purchase(
  p_business_id uuid, p_supplier_id uuid, p_purchase_order_id uuid,
  p_received_at timestamptz, p_lines jsonb, p_request_id uuid
) returns jsonb
language plpgsql security definer set search_path=''
as $function$
declare
  v_actor uuid; v_cached jsonb; v_payload jsonb; v_po public.purchase_orders%rowtype;
  v_receipt uuid; v_line jsonb; v_po_line public.purchase_order_items%rowtype; v_stock public.stock_items%rowtype;
  v_location uuid; v_accept numeric; v_reject numeric; v_received numeric; v_on_hand numeric;
  v_base_qty numeric; v_base_cost bigint; v_new_avg bigint; v_movement uuid; v_line_id uuid;
  v_count integer:=0; v_result jsonb; v_all_received boolean;
  v_line_transport bigint; v_prior_accepted numeric; v_prior_transport bigint;
  v_target_transport bigint; v_receipt_transport bigint; v_landed_unit_cost numeric;
begin
  v_actor:=private.assert_active_owner(p_business_id);
  if p_supplier_id is null or p_received_at is null or p_received_at>now()+interval '5 minutes'
    or p_lines is null or jsonb_typeof(p_lines) is distinct from 'array' or jsonb_array_length(p_lines) not between 1 and 100 then
    raise exception using errcode='22023',message='Invalid goods receipt details';
  end if;
  v_payload:=jsonb_build_object('supplier_id',p_supplier_id,'purchase_order_id',p_purchase_order_id,'received_at',p_received_at,'lines',p_lines);
  v_cached:=private.begin_idempotent_request(p_business_id,'receive_purchase',p_request_id,v_payload);
  if v_cached is not null then return v_cached; end if;
  select * into v_po from public.purchase_orders where business_id=p_business_id and id=p_purchase_order_id for update;
  if not found or v_po.supplier_id<>p_supplier_id or v_po.status not in ('ordered','part_received') then
    raise exception using errcode='22023',message='Purchase order must belong to supplier and be ordered or part received';
  end if;
  insert into public.goods_receipts(business_id,purchase_order_id,received_by,received_at)
  values(p_business_id,p_purchase_order_id,v_actor,p_received_at) returning id into v_receipt;

  for v_line in select value from jsonb_array_elements(p_lines) loop
    if not (v_line ? 'purchase_order_item_id' and v_line ? 'location_id' and v_line ? 'accepted_quantity'
      and v_line ? 'rejected_quantity' and v_line ? 'actual_unit_cost') then
      raise exception using errcode='22023',message='Goods receipt line is missing required fields';
    end if;
    select * into v_po_line from public.purchase_order_items
      where business_id=p_business_id and id=(v_line->>'purchase_order_item_id')::uuid
        and purchase_order_id=p_purchase_order_id for update;
    if not found then raise exception using errcode='22023',message='Purchase order item does not belong to this purchase order'; end if;
    select * into v_stock from public.stock_items where business_id=p_business_id and id=v_po_line.stock_item_id for update;
    v_location:=(v_line->>'location_id')::uuid;
    if not exists(select 1 from public.inventory_locations where business_id=p_business_id and id=v_location and is_active) then
      raise exception using errcode='22023',message='Goods receipt location is invalid';
    end if;
    v_accept:=(v_line->>'accepted_quantity')::numeric;
    v_reject:=(v_line->>'rejected_quantity')::numeric;
    v_base_cost:=(v_line->>'actual_unit_cost')::bigint;
    if v_accept is null or v_reject is null or v_base_cost is null or v_accept<0 or v_reject<0 or v_accept+v_reject<=0 or v_base_cost<0 then
      raise exception using errcode='22023',message='Invalid accepted/rejected quantity or unit cost';
    end if;
    select coalesce(sum(gri.accepted_quantity+gri.rejected_quantity),0) into v_received
    from public.goods_receipt_items gri where gri.business_id=p_business_id and gri.purchase_order_item_id=v_po_line.id;
    if v_received+v_accept+v_reject>v_po_line.ordered_quantity then
      raise exception using errcode='22023',message='Goods received exceed ordered quantity';
    end if;

    -- Determine this receipt's freight share before creating the immutable movement.
    select transport_cost_allocated into v_line_transport
    from public.purchase_order_items where business_id=p_business_id and id=v_po_line.id;
    select coalesce(sum(accepted_quantity),0),coalesce(sum(transport_cost_allocated),0)
      into v_prior_accepted,v_prior_transport
    from public.goods_receipt_items
    where business_id=p_business_id and purchase_order_item_id=v_po_line.id;
    if v_accept>0 then
      v_target_transport:=round(v_line_transport*(v_prior_accepted+v_accept)/nullif(v_po_line.ordered_quantity,0))::bigint;
      v_receipt_transport:=greatest(0,v_target_transport-v_prior_transport);
      v_landed_unit_cost:=(v_line->>'actual_unit_cost')::numeric+v_receipt_transport::numeric/v_accept;
    else
      v_receipt_transport:=0;
      v_landed_unit_cost:=(v_line->>'actual_unit_cost')::numeric;
    end if;

    v_base_qty:=v_accept*v_po_line.purchase_to_base_factor;
    v_movement:=null;
    if v_accept>0 then
      v_base_cost:=round(v_landed_unit_cost/v_po_line.purchase_to_base_factor)::bigint;
      select coalesce(sum(m.quantity),0) into v_on_hand from public.stock_movements m
      where m.business_id=p_business_id and m.stock_item_id=v_stock.id;
      if v_on_hand<0 then raise exception using errcode='23514',message='Stock on hand cannot be negative during weighted-average receipt'; end if;
      if v_on_hand+v_base_qty>0 then
        v_new_avg:=round((v_on_hand*v_stock.current_average_unit_cost+v_base_qty*v_base_cost)/(v_on_hand+v_base_qty))::bigint;
      else v_new_avg:=v_base_cost; end if;
      update public.stock_items set current_average_unit_cost=v_new_avg,updated_at=now()
      where business_id=p_business_id and id=v_stock.id;
      insert into public.stock_movements(business_id,stock_item_id,location_id,movement_type,quantity,unit_cost_snapshot,
        source_type,source_id,reason,actor_user_id,request_id)
      values(p_business_id,v_stock.id,v_location,'receipt',v_base_qty,v_base_cost,
        'goods_receipt',v_receipt,'Accepted supplier goods received',v_actor,
        private.derived_request_uuid(p_request_id,'receipt-'||v_po_line.id::text))
      returning id into v_movement;
    end if;
    insert into public.goods_receipt_items(business_id,goods_receipt_id,purchase_order_item_id,stock_item_id,location_id,
      accepted_quantity,rejected_quantity,purchase_unit,purchase_to_base_factor,actual_unit_cost,stock_movement_id)
    values(p_business_id,v_receipt,v_po_line.id,v_stock.id,v_location,v_accept,v_reject,
      v_po_line.purchase_unit,v_po_line.purchase_to_base_factor,(v_line->>'actual_unit_cost')::bigint,v_movement)
    returning id into v_line_id;
    v_count:=v_count+1;
  end loop;

  select not exists(
    select 1 from public.purchase_order_items poi
    where poi.business_id=p_business_id and poi.purchase_order_id=p_purchase_order_id
      and coalesce((select sum(gri.accepted_quantity+gri.rejected_quantity) from public.goods_receipt_items gri
        where gri.business_id=poi.business_id and gri.purchase_order_item_id=poi.id),0)<poi.ordered_quantity
  ) into v_all_received;
  update public.purchase_orders set status=case when v_all_received then 'received' else 'part_received' end,updated_at=now()
  where business_id=p_business_id and id=p_purchase_order_id;
  v_result:=jsonb_build_object('goods_receipt_id',v_receipt,'purchase_order_id',p_purchase_order_id,
    'status',case when v_all_received then 'received' else 'part_received' end,'line_count',v_count);
  perform private.finish_idempotent_request(p_business_id,'receive_purchase',p_request_id,v_result);
  perform private.write_audit(p_business_id,v_actor,'purchase.received','goods_receipt',v_receipt,p_request_id,
    jsonb_build_object('purchase_order_id',p_purchase_order_id,'line_count',v_count));
  return v_result;
end;
$function$;

create or replace function public.owner_receive_purchase(
  p_business_id uuid, p_supplier_id uuid, p_purchase_order_id uuid,
  p_received_at timestamptz, p_lines jsonb, p_request_id uuid
) returns jsonb language sql set search_path=''
as $function$
  select private.owner_receive_purchase($1,$2,$3,$4,$5,$6);
$function$;
