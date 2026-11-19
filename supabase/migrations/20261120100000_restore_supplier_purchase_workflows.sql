-- Restore owner-scoped supplier and purchasing operations and bind each purchase line
-- to the exact stock item it receives. Existing ledger rows are preserved.
alter table public.purchase_order_lines
  add column if not exists stock_item_id uuid;

-- Backfill only unambiguous historical item-name matches. Ambiguous or unmatched
-- historical rows remain unlinked rather than guessing which stock item they mean.
update public.purchase_order_lines pol
set stock_item_id = matches.stock_item_id
from (
  select pol2.id, min(si.id::text)::uuid as stock_item_id
  from public.purchase_order_lines pol2
  join public.purchase_orders po on po.id = pol2.purchase_order_id
  join public.stock_items si
    on si.business_id = pol2.business_id
   and lower(btrim(si.item_name)) = lower(btrim(pol2.item_description))
  group by pol2.id
  having count(*) = 1
) matches
where pol.id = matches.id
  and pol.stock_item_id is null;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.purchase_order_lines'::regclass
      and conname = 'purchase_order_lines_stock_item_id_fkey'
  ) then
    alter table public.purchase_order_lines
      add constraint purchase_order_lines_stock_item_id_fkey
      foreign key (stock_item_id) references public.stock_items(id);
  end if;
end $$;

create or replace function public.owner_create_supplier(
  p_supplier_name text,
  p_phone text default null,
  p_email text default null,
  p_notes text default null
) returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_business uuid;
  v_id uuid;
begin
  select business_id into v_business
  from public.business_memberships
  where user_id = auth.uid() and role = 'owner'
  limit 1;

  if auth.uid() is null or v_business is null then
    raise exception 'Owner workspace required';
  end if;
  if length(btrim(coalesce(p_supplier_name, ''))) < 2 then
    raise exception 'Supplier name must contain at least 2 characters';
  end if;

  insert into public.suppliers(business_id, supplier_name, phone, email, notes)
  values (
    v_business,
    btrim(p_supplier_name),
    nullif(btrim(p_phone), ''),
    nullif(btrim(p_email), ''),
    nullif(btrim(p_notes), '')
  )
  returning id into v_id;

  insert into public.audit_events(
    business_id, actor_user_id, event_type, entity_type, entity_id, details
  ) values (
    v_business, auth.uid(), 'supplier.created', 'supplier', v_id,
    jsonb_build_object('supplier_name', btrim(p_supplier_name))
  );

  return v_id;
end
$fn$;

create or replace function public.owner_create_purchase_order(
  p_supplier_id uuid,
  p_po_number text,
  p_transport_cost numeric,
  p_lines jsonb
) returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_business uuid;
  v_total numeric(14,2) := 0;
  v_line jsonb;
  v_stock uuid;
  v_qty numeric(14,3);
  v_cost numeric(14,2);
  v_po uuid;
  v_line_count integer := 0;
begin
  select business_id into v_business
  from public.business_memberships
  where user_id = auth.uid() and role = 'owner'
  limit 1;

  if auth.uid() is null or v_business is null then
    raise exception 'Owner workspace required';
  end if;
  if not exists (
    select 1 from public.suppliers
    where id = p_supplier_id and business_id = v_business
  ) then
    raise exception 'Supplier not found';
  end if;
  if length(btrim(coalesce(p_po_number, ''))) < 2
     or p_transport_cost is null or p_transport_cost < 0
     or jsonb_typeof(p_lines) <> 'array'
     or jsonb_array_length(p_lines) = 0 then
    raise exception 'Enter a purchase number, non-negative transport cost and at least one purchase line';
  end if;
  if exists (
    select 1
    from jsonb_array_elements(p_lines) e
    group by e.value->>'stock_item_id'
    having count(*) > 1
  ) then
    raise exception 'Add each stock item once per purchase order';
  end if;

  for v_line in select value from jsonb_array_elements(p_lines)
  loop
    v_stock := (v_line->>'stock_item_id')::uuid;
    v_qty := (v_line->>'quantity')::numeric;
    v_cost := (v_line->>'unit_cost')::numeric;

    if v_stock is null or v_qty is null or v_qty <= 0
       or v_cost is null or v_cost < 0
       or not exists (
         select 1 from public.stock_items
         where id = v_stock and business_id = v_business and active
       ) then
      raise exception 'Each purchase line needs an active stock item, positive quantity and non-negative unit cost';
    end if;

    v_total := v_total + (v_qty * v_cost);
    v_line_count := v_line_count + 1;
  end loop;

  insert into public.purchase_orders(
    business_id, supplier_id, po_number, status, total, transport_cost
  ) values (
    v_business, p_supplier_id, btrim(p_po_number), 'sent', v_total, p_transport_cost
  ) returning id into v_po;

  for v_line in select value from jsonb_array_elements(p_lines)
  loop
    v_stock := (v_line->>'stock_item_id')::uuid;
    v_qty := (v_line->>'quantity')::numeric;
    v_cost := (v_line->>'unit_cost')::numeric;

    insert into public.purchase_order_lines(
      business_id, purchase_order_id, stock_item_id, item_description, quantity, unit_cost
    )
    select v_business, v_po, s.id, s.item_name, v_qty, v_cost
    from public.stock_items s
    where s.id = v_stock and s.business_id = v_business and s.active;
  end loop;

  insert into public.audit_events(
    business_id, actor_user_id, event_type, entity_type, entity_id, details
  ) values (
    v_business, auth.uid(), 'purchasing.purchase_order_created', 'purchase_order', v_po,
    jsonb_build_object(
      'supplier_id', p_supplier_id,
      'po_number', btrim(p_po_number),
      'line_count', v_line_count,
      'total', v_total,
      'transport_cost', p_transport_cost
    )
  );

  return v_po;
end
$fn$;

create or replace function public.owner_record_supplier_payment(
  p_supplier_id uuid,
  p_purchase_order_id uuid,
  p_payment_number text,
  p_method text,
  p_amount numeric,
  p_reference_code text default null
) returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_business uuid;
  v_supplier_due numeric(14,2);
  v_order_due numeric(14,2);
  v_id uuid;
begin
  select business_id into v_business
  from public.business_memberships
  where user_id = auth.uid() and role = 'owner'
  limit 1;

  if auth.uid() is null or v_business is null
     or not exists (
       select 1 from public.suppliers
       where id = p_supplier_id and business_id = v_business
     ) then
    raise exception 'Supplier not found';
  end if;
  if p_method not in ('cash', 'mpesa_paybill')
     or p_amount is null or p_amount <= 0
     or length(btrim(coalesce(p_payment_number, ''))) = 0 then
    raise exception 'Enter a valid payment number, method and positive amount';
  end if;
  if p_purchase_order_id is not null and not exists (
    select 1 from public.purchase_orders
    where id = p_purchase_order_id and supplier_id = p_supplier_id
      and business_id = v_business and status <> 'cancelled'
  ) then
    raise exception 'Purchase order does not belong to this supplier or is cancelled';
  end if;

  select coalesce(sum(po.total + po.transport_cost), 0)
         - coalesce((
           select sum(sp.amount) from public.supplier_payments sp
           where sp.business_id = v_business and sp.supplier_id = p_supplier_id
         ), 0)
  into v_supplier_due
  from public.purchase_orders po
  where po.business_id = v_business
    and po.supplier_id = p_supplier_id
    and po.status <> 'cancelled';

  if p_purchase_order_id is not null then
    select po.total + po.transport_cost
           - coalesce((
             select sum(sp.amount) from public.supplier_payments sp
             where sp.business_id = v_business
               and sp.supplier_id = p_supplier_id
               and sp.purchase_order_id = p_purchase_order_id
           ), 0)
    into v_order_due
    from public.purchase_orders po
    where po.id = p_purchase_order_id
      and po.business_id = v_business
      and po.supplier_id = p_supplier_id
      and po.status <> 'cancelled';

    v_supplier_due := least(v_supplier_due, v_order_due);
  end if;

  if p_amount > greatest(0, coalesce(v_supplier_due, 0)) then
    raise exception 'Supplier payment exceeds outstanding balance';
  end if;

  insert into public.supplier_payments(
    business_id, supplier_id, purchase_order_id, payment_number,
    method, amount, reference_code, paid_by
  ) values (
    v_business, p_supplier_id, p_purchase_order_id, btrim(p_payment_number),
    p_method, p_amount, nullif(btrim(p_reference_code), ''), auth.uid()
  ) returning id into v_id;

  insert into public.audit_events(
    business_id, actor_user_id, event_type, entity_type, entity_id, details
  ) values (
    v_business, auth.uid(), 'supplier.payment_recorded', 'supplier_payment', v_id,
    jsonb_build_object(
      'supplier_id', p_supplier_id,
      'purchase_order_id', p_purchase_order_id,
      'amount', p_amount,
      'method', p_method
    )
  );

  return v_id;
end
$fn$;

create or replace function public.owner_receive_purchase_order_line(
  p_line_id uuid,
  p_received_quantity numeric
) returns void
language plpgsql
security definer
set search_path = public, private, pg_temp
as $fn$
declare
  v_line public.purchase_order_lines%rowtype;
  v_order public.purchase_orders%rowtype;
  v_stock public.stock_items%rowtype;
  v_landed_unit_cost numeric(14,4);
  v_total_received numeric(14,3);
  v_total_ordered numeric(14,3);
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;

  select * into v_line
  from public.purchase_order_lines
  where id = p_line_id
  for update;
  if not found or not exists (
    select 1 from public.business_memberships
    where business_id = v_line.business_id
      and user_id = auth.uid() and role = 'owner'
  ) then
    raise exception 'Purchase line not found';
  end if;

  select * into v_order
  from public.purchase_orders
  where id = v_line.purchase_order_id
    and business_id = v_line.business_id
  for update;
  if not found then raise exception 'Purchase order not found'; end if;
  if v_order.status in ('cancelled', 'received')
     or p_received_quantity is null or p_received_quantity <= 0
     or v_line.received_quantity + p_received_quantity > v_line.quantity then
    raise exception 'Invalid or excess goods receipt';
  end if;
  if v_line.stock_item_id is null then
    raise exception 'This historical purchase line is not linked to a stock item; resolve it before receiving';
  end if;

  select * into v_stock
  from public.stock_items
  where id = v_line.stock_item_id
    and business_id = v_line.business_id
  for update;
  if not found or not v_stock.active then
    raise exception 'Active stock item not found';
  end if;

  v_landed_unit_cost := v_line.unit_cost +
    case when v_order.total > 0
      then (v_order.transport_cost * (v_line.quantity * v_line.unit_cost / v_order.total)) / v_line.quantity
      else 0
    end;

  perform private.apply_stock_movement(
    v_line.business_id, v_stock.id, p_received_quantity,
    v_landed_unit_cost, 'purchase'
  );

  update public.purchase_order_lines
  set received_quantity = received_quantity + p_received_quantity
  where id = v_line.id and business_id = v_line.business_id;

  select coalesce(sum(received_quantity), 0), coalesce(sum(quantity), 0)
  into v_total_received, v_total_ordered
  from public.purchase_order_lines
  where purchase_order_id = v_order.id
    and business_id = v_order.business_id;

  update public.purchase_orders
  set status = case
    when v_total_received >= v_total_ordered then 'received'
    else 'part_received'
  end
  where id = v_order.id and business_id = v_order.business_id;

  insert into public.audit_events(
    business_id, actor_user_id, event_type, entity_type, entity_id, details
  ) values (
    v_line.business_id, auth.uid(), 'purchasing.goods_received',
    'purchase_order_line', v_line.id,
    jsonb_build_object(
      'purchase_order_id', v_order.id,
      'stock_item_id', v_stock.id,
      'received_quantity', p_received_quantity,
      'landed_unit_cost', v_landed_unit_cost
    )
  );
end
$fn$;

create or replace function public.owner_supplier_price_alerts()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_business uuid;
  v_result jsonb;
begin
  select business_id into v_business
  from public.business_memberships
  where user_id = auth.uid() and role = 'owner'
  limit 1;
  if auth.uid() is null or v_business is null then
    raise exception 'Owner workspace required';
  end if;

  with ranked as (
    select po.supplier_id, s.supplier_name,
      coalesce(pol.stock_item_id, si.id) as stock_item_id,
      pol.id as line_id, pol.unit_cost, po.created_at,
      coalesce(si.item_name, pol.item_description) as item_name,
      row_number() over (
        partition by po.supplier_id, coalesce(pol.stock_item_id, si.id)
        order by po.created_at desc, po.po_number desc, pol.id desc
      ) as rn
    from public.purchase_order_lines pol
    join public.purchase_orders po on po.id = pol.purchase_order_id
    join public.suppliers s on s.id = po.supplier_id
    left join public.stock_items si on si.id = pol.stock_item_id
      and si.business_id = po.business_id
    where po.business_id = v_business
      and po.status <> 'cancelled'
      and (pol.stock_item_id is not null or (
        select count(*) from public.stock_items sx
        where sx.business_id = po.business_id
          and lower(btrim(sx.item_name)) = lower(btrim(pol.item_description))
      ) = 1)
  ), pairs as (
    select a.supplier_id, a.supplier_name, a.stock_item_id, a.item_name,
      b.line_id as previous_line_id, a.line_id as latest_line_id,
      b.unit_cost as previous_cost, a.unit_cost as latest_cost,
      a.created_at,
      round(((a.unit_cost - b.unit_cost) / nullif(b.unit_cost, 0)) * 100, 2) as change_percent
    from ranked a
    join ranked b on b.supplier_id = a.supplier_id
      and b.stock_item_id = a.stock_item_id and b.rn = 2
    where a.rn = 1 and a.unit_cost <> b.unit_cost
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'supplier_id', p.supplier_id,
    'supplier_name', p.supplier_name,
    'stock_item_id', p.stock_item_id,
    'item_name', p.item_name,
    'previous_line_id', p.previous_line_id,
    'latest_line_id', p.latest_line_id,
    'previous_cost', p.previous_cost,
    'latest_cost', p.latest_cost,
    'change_percent', p.change_percent,
    'created_at', p.created_at,
    'reviewed', exists (
      select 1 from public.supplier_price_reviews r
      where r.business_id = v_business
        and r.previous_line_id = p.previous_line_id
        and r.latest_line_id = p.latest_line_id
    )
  ) order by p.created_at desc), '[]'::jsonb)
  into v_result from pairs p;

  return v_result;
end
$fn$;

create or replace function public.owner_review_supplier_price_change(
  p_supplier_id uuid,
  p_stock_item_id uuid,
  p_previous_line_id uuid,
  p_latest_line_id uuid
) returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_business uuid;
begin
  select business_id into v_business
  from public.business_memberships
  where user_id = auth.uid() and role = 'owner'
  limit 1;
  if auth.uid() is null or v_business is null then
    raise exception 'Owner workspace required';
  end if;

  if not exists (
    select 1
    from public.purchase_order_lines a
    join public.purchase_orders pa on pa.id = a.purchase_order_id
    join public.purchase_order_lines b on b.id = p_latest_line_id
    join public.purchase_orders pb on pb.id = b.purchase_order_id
    where a.id = p_previous_line_id
      and pa.supplier_id = p_supplier_id
      and pb.supplier_id = p_supplier_id
      and pa.business_id = v_business
      and pb.business_id = v_business
      and coalesce(a.stock_item_id, (
        select si.id from public.stock_items si
        where si.business_id = v_business
          and lower(btrim(si.item_name)) = lower(btrim(a.item_description))
        limit 1
      )) = p_stock_item_id
      and coalesce(b.stock_item_id, (
        select si.id from public.stock_items si
        where si.business_id = v_business
          and lower(btrim(si.item_name)) = lower(btrim(b.item_description))
        limit 1
      )) = p_stock_item_id
  ) then
    raise exception 'Price change record not found';
  end if;

  insert into public.supplier_price_reviews(
    business_id, supplier_id, stock_item_id,
    previous_line_id, latest_line_id, reviewed_by
  ) values (
    v_business, p_supplier_id, p_stock_item_id,
    p_previous_line_id, p_latest_line_id, auth.uid()
  ) on conflict do nothing;
end
$fn$;

revoke all on function public.owner_create_supplier(text,text,text,text) from public, anon;
revoke all on function public.owner_create_purchase_order(uuid,text,numeric,jsonb) from public, anon;
revoke all on function public.owner_receive_purchase_order_line(uuid,numeric) from public, anon;
revoke all on function public.owner_record_supplier_payment(uuid,uuid,text,text,numeric,text) from public, anon;
revoke all on function public.owner_supplier_price_alerts() from public, anon;
revoke all on function public.owner_review_supplier_price_change(uuid,uuid,uuid,uuid) from public, anon;

grant execute on function public.owner_create_supplier(text,text,text,text) to authenticated;
grant execute on function public.owner_create_purchase_order(uuid,text,numeric,jsonb) to authenticated;
grant execute on function public.owner_receive_purchase_order_line(uuid,numeric) to authenticated;
grant execute on function public.owner_record_supplier_payment(uuid,uuid,text,text,numeric,text) to authenticated;
grant execute on function public.owner_supplier_price_alerts() to authenticated;
grant execute on function public.owner_review_supplier_price_change(uuid,uuid,uuid,uuid) to authenticated;

notify pgrst, 'reload schema';
