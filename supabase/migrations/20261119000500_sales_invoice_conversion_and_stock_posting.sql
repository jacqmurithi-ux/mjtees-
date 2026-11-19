-- MJ Tees Sales: accepted quotation -> issued invoice + stock posting.
-- All writes are owner-authorised, atomic and idempotent. No hosted database is changed by this file.
begin;

alter table public.sales_invoices
  add column deposit_required_amount bigint not null default 0
  check (deposit_required_amount >= 0 and deposit_required_amount <= total_amount);

create unique index sales_invoice_items_one_source_line
  on public.sales_invoice_items(business_id,invoice_id,source_order_item_id)
  where source_order_item_id is not null;

create table public.sales_invoice_stock_issues (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  invoice_id uuid not null,
  invoice_item_id uuid not null,
  stock_item_id uuid not null,
  location_id uuid not null,
  quantity numeric(12,3) not null check (quantity > 0),
  unit_cost_snapshot bigint not null check (unit_cost_snapshot >= 0),
  stock_movement_id uuid not null,
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  constraint sales_invoice_stock_issues_invoice_fk
    foreign key (business_id,invoice_id) references public.sales_invoices(business_id,id) on delete restrict,
  constraint sales_invoice_stock_issues_invoice_item_fk
    foreign key (business_id,invoice_item_id) references public.sales_invoice_items(business_id,id) on delete restrict,
  constraint sales_invoice_stock_issues_stock_item_fk
    foreign key (business_id,stock_item_id) references public.stock_items(business_id,id) on delete restrict,
  constraint sales_invoice_stock_issues_location_fk
    foreign key (business_id,location_id) references public.inventory_locations(business_id,id) on delete restrict,
  constraint sales_invoice_stock_issues_movement_fk
    foreign key (business_id,stock_movement_id) references public.stock_movements(business_id,id) on delete restrict,
  constraint sales_invoice_stock_issues_one_per_invoice_item unique (business_id,invoice_item_id),
  constraint sales_invoice_stock_issues_one_per_movement unique (business_id,stock_movement_id)
);
create index sales_invoice_stock_issues_invoice_idx
  on public.sales_invoice_stock_issues(business_id,invoice_id,created_at);

alter table public.sales_invoice_stock_issues enable row level security;
revoke all on table public.sales_invoice_stock_issues from public,anon,authenticated;
grant select on table public.sales_invoice_stock_issues to authenticated;
create policy sales_invoice_stock_issues_owner_select
  on public.sales_invoice_stock_issues for select to authenticated
  using (private.is_active_owner(business_id));

create trigger sales_invoice_stock_issues_no_mutation
  before update or delete on public.sales_invoice_stock_issues
  for each row execute function private.guard_sales_append_only();

create or replace function private.next_sales_document_number(
  p_business_id uuid,p_document_type text
) returns text
language plpgsql security definer set search_path=''
as $$
declare v_number bigint; v_prefix text;
begin
  if p_document_type not in ('invoice','credit_note') then
    raise exception using errcode='22023',message='Unsupported Sales document type';
  end if;
  v_prefix:=case p_document_type when 'invoice' then 'INV' else 'CN' end;
  insert into public.document_counters(business_id,document_type,next_value,prefix)
  values(p_business_id,p_document_type,2,v_prefix)
  on conflict (business_id,document_type)
  do update set next_value=public.document_counters.next_value+1,
                prefix=excluded.prefix,updated_at=now()
  returning next_value-1 into v_number;
  return v_prefix||'-'||lpad(v_number::text,4,'0');
end;
$$;

create or replace function private.owner_convert_accepted_quote_to_invoice(
  p_business_id uuid,
  p_quotation_id uuid,
  p_payment_terms text,
  p_due_date date,
  p_stock_location_id uuid,
  p_allow_oversell boolean,
  p_oversell_reason text,
  p_request_id uuid
) returns jsonb
language plpgsql security definer set search_path=''
as $$
declare
  v_actor uuid;
  v_quote public.quotations%rowtype;
  v_customer public.customers%rowtype;
  v_order public.orders%rowtype;
  v_existing_invoice public.sales_invoices%rowtype;
  v_order_count integer;
  v_invoice_id uuid;
  v_invoice_number text;
  v_due_date date;
  v_cached jsonb;
  v_payload jsonb;
  v_result jsonb;
  v_line record;
  v_invoice_item_id uuid;
  v_stock public.stock_items%rowtype;
  v_on_hand numeric(12,3);
  v_other_reserved numeric(12,3);
  v_new_on_hand numeric(12,3);
  v_movement_id uuid;
  v_issue_id uuid;
  v_stock_issues jsonb:='[]'::jsonb;
  v_low_stock_items jsonb:='[]'::jsonb;
  v_has_stock boolean;
begin
  v_actor:=private.assert_active_owner(p_business_id);

  if p_quotation_id is null or p_payment_terms is null or p_payment_terms not in ('due_on_receipt','net_7','net_14','net_30')
     or p_request_id is null or p_allow_oversell is null
     or length(coalesce(p_oversell_reason,''))>500
     or (p_allow_oversell and length(btrim(coalesce(p_oversell_reason,'')))=0) then
    raise exception using errcode='22023',message='Invalid Sales invoice conversion details';
  end if;

  v_payload:=jsonb_build_object(
    'quotation_id',p_quotation_id,'payment_terms',p_payment_terms,'due_date',p_due_date,
    'stock_location_id',p_stock_location_id,'allow_oversell',p_allow_oversell,
    'oversell_reason',nullif(btrim(p_oversell_reason),'')
  );
  v_cached:=private.begin_idempotent_request(p_business_id,'convert_quote_to_sales_invoice',p_request_id,v_payload);
  if v_cached is not null then return v_cached; end if;

  select * into v_quote
  from public.quotations
  where business_id=p_business_id and id=p_quotation_id
  for update;
  if not found then
    raise exception using errcode='P0002',message='Quotation not found';
  end if;

  select * into v_customer
  from public.customers
  where business_id=p_business_id and id=v_quote.customer_id and archived_at is null;
  if not found then
    raise exception using errcode='22023',message='Quotation customer is inactive or unavailable';
  end if;

  if v_quote.customer_contact_id is not null and not exists (
    select 1 from public.customer_contacts cc
    where cc.business_id=p_business_id and cc.id=v_quote.customer_contact_id
      and cc.customer_id=v_quote.customer_id and cc.is_active
  ) then
    raise exception using errcode='22023',message='Quotation contact is no longer active for this customer';
  end if;

  select count(*) into v_order_count
  from public.orders
  where business_id=p_business_id and quotation_id=p_quotation_id;
  if v_order_count<>1 then
    raise exception using errcode='23514',message='Accepted quotation must have exactly one linked order';
  end if;

  select * into v_order
  from public.orders
  where business_id=p_business_id and quotation_id=p_quotation_id
  for update;

  select * into v_existing_invoice
  from public.sales_invoices
  where business_id=p_business_id and order_id=v_order.id;
  if found then
    v_result:=jsonb_build_object(
      'invoice_id',v_existing_invoice.id,
      'invoice_number',v_existing_invoice.invoice_number,
      'status',v_existing_invoice.status,
      'total_amount',v_existing_invoice.total_amount,
      'due_date',v_existing_invoice.due_date,
      'already_created',true
    );
    perform private.finish_idempotent_request(p_business_id,'convert_quote_to_sales_invoice',p_request_id,v_result);
    return v_result;
  end if;

  if v_quote.status<>'accepted' then
    raise exception using errcode='22023',message='Only an accepted quotation can be converted to an invoice';
  end if;
  if v_order.status='cancelled' then
    raise exception using errcode='22023',message='A cancelled order cannot be invoiced';
  end if;

  v_due_date:=coalesce(p_due_date,
    case p_payment_terms
      when 'net_7' then current_date+7
      when 'net_14' then current_date+14
      when 'net_30' then current_date+30
      else current_date
    end
  );
  if v_due_date<current_date then
    raise exception using errcode='22023',message='Invoice due date cannot be before its issue date';
  end if;

  select exists(
    select 1 from public.order_items oi
    where oi.business_id=p_business_id and oi.order_id=v_order.id
      and oi.sale_mode='blank' and oi.stock_item_id is not null
      and not oi.customer_supplies_item
  ) into v_has_stock;

  if v_has_stock then
    if p_stock_location_id is null or not exists (
      select 1 from public.inventory_locations il
      where il.business_id=p_business_id and il.id=p_stock_location_id and il.is_active
    ) then
      raise exception using errcode='22023',message='Choose an active stock location before issuing this invoice';
    end if;
  end if;

  v_invoice_number:=private.next_sales_document_number(p_business_id,'invoice');
  insert into public.sales_invoices(
    business_id,order_id,quotation_id,sales_price_tier_id,customer_contact_id,
    invoice_number,status,issue_date,due_date,payment_terms,currency_code,
    subtotal_amount,discount_amount,total_amount,deposit_required_amount,
    customer_notes,internal_notes,created_by,issued_at
  )
  values(
    p_business_id,v_order.id,p_quotation_id,
    coalesce(v_quote.sales_price_tier_id,v_customer.sales_price_tier_id,(
      select spt.id from public.sales_price_tiers spt
      where spt.business_id=p_business_id and spt.code='retail' and spt.is_default and spt.is_active
    )),
    v_quote.customer_contact_id,
    v_invoice_number,'draft',null,v_due_date,p_payment_terms,'KES',
    v_order.subtotal_amount,v_order.discount_amount,v_order.total_amount,
    v_quote.deposit_required_amount,v_quote.customer_notes,v_quote.internal_notes,v_actor,null
  )
  returning id into v_invoice_id;

  for v_line in
    select oi.*,si.id as joined_stock_id,si.sku as stock_sku,si.name as stock_name,
      si.variant_attributes as stock_variant_attributes,pm.code as method_code,pm.name as method_name
    from public.order_items oi
    left join public.stock_items si
      on si.business_id=oi.business_id and si.id=oi.stock_item_id
    left join public.production_methods pm on pm.id=oi.production_method_id
    where oi.business_id=p_business_id and oi.order_id=v_order.id
    order by oi.created_at,oi.id
  loop
    insert into public.sales_invoice_items(
      business_id,invoice_id,source_order_item_id,description,sale_type,
      variant_snapshot,decoration_snapshot,quantity,unit,unit_price,line_discount,line_total
    )
    values(
      p_business_id,v_invoice_id,v_line.id,v_line.description,
      case
        when v_line.sale_mode='blank' then 'blank'
        when lower(coalesce(v_line.production_specification->>'sale_type',''))='print_on_demand'
          then 'print_on_demand'
        else 'decorated'
      end,
      case when v_line.joined_stock_id is not null then
        jsonb_build_object('sku',v_line.stock_sku,'name',v_line.stock_name,'attributes',v_line.stock_variant_attributes)
      else coalesce(v_line.production_specification->'variant_snapshot','{}'::jsonb) end,
      jsonb_build_object(
        'production_method_id',v_line.production_method_id,
        'production_method_code',v_line.method_code,
        'production_method_name',v_line.method_name,
        'specification',coalesce(v_line.production_specification,'{}'::jsonb)
      ),
      v_line.quantity,v_line.unit,v_line.unit_price,v_line.line_discount,v_line.line_total
    )
    returning id into v_invoice_item_id;

    if v_line.sale_mode='blank' and v_line.stock_item_id is not null and not v_line.customer_supplies_item then
      select * into v_stock
      from public.stock_items
      where business_id=p_business_id and id=v_line.stock_item_id and is_active
      for update;
      if not found then
        raise exception using errcode='22023',message='A stock item on this order is inactive or unavailable';
      end if;
      if v_line.unit<>v_stock.base_unit then
        raise exception using errcode='23514',message='Stock sale unit does not match the stock item base unit';
      end if;

      perform pg_advisory_xact_lock(hashtextextended(
        p_business_id::text||v_stock.id::text||p_stock_location_id::text,0
      ));
      select coalesce(sum(sm.quantity),0) into v_on_hand
      from public.stock_movements sm
      where sm.business_id=p_business_id and sm.stock_item_id=v_stock.id
        and sm.location_id=p_stock_location_id;

      select coalesce(sum(sr.reserved_quantity-sr.released_quantity),0) into v_other_reserved
      from public.stock_reservations sr
      where sr.business_id=p_business_id and sr.stock_item_id=v_stock.id
        and sr.location_id=p_stock_location_id and sr.status='active'
        and sr.order_item_id<>v_line.id;

      if v_line.quantity>v_on_hand-v_other_reserved then
        if v_other_reserved>0 then
          raise exception using errcode='22023',message='Sale would consume stock reserved for another production order';
        end if;
        if not p_allow_oversell then
          raise exception using errcode='22023',message='Insufficient stock; confirm the oversell override to continue';
        end if;
      end if;

      insert into public.stock_movements(
        business_id,stock_item_id,location_id,movement_type,quantity,unit_cost_snapshot,
        source_type,source_id,reason,actor_user_id,request_id
      )
      values(
        p_business_id,v_stock.id,p_stock_location_id,'issue',-v_line.quantity,v_stock.current_average_unit_cost,
        'sales_invoice_item',v_invoice_item_id,
        case when v_line.quantity>v_on_hand-v_other_reserved
          then 'Owner-confirmed oversell: '||btrim(p_oversell_reason)
          else 'Stock sale on invoice '||v_invoice_number end,
        v_actor,private.derived_request_uuid(p_request_id,'sales-invoice-stock-'||v_line.id::text)
      )
      returning id into v_movement_id;

      insert into public.sales_invoice_stock_issues(
        business_id,invoice_id,invoice_item_id,stock_item_id,location_id,
        quantity,unit_cost_snapshot,stock_movement_id,created_by
      )
      values(
        p_business_id,v_invoice_id,v_invoice_item_id,v_stock.id,p_stock_location_id,
        v_line.quantity,v_stock.current_average_unit_cost,v_movement_id,v_actor
      )
      returning id into v_issue_id;

      -- Consume this order line's own reservation; other orders' reservations remain protected.
      with reservations as (
        select sr.id,sr.reserved_quantity-sr.released_quantity as remaining,
          coalesce(sum(sr.reserved_quantity-sr.released_quantity) over(
            order by sr.created_at,sr.id rows between unbounded preceding and 1 preceding
          ),0) as prior_remaining
        from public.stock_reservations sr
        where sr.business_id=p_business_id and sr.order_item_id=v_line.id
          and sr.stock_item_id=v_stock.id and sr.location_id=p_stock_location_id
          and sr.status='active' and sr.released_quantity<sr.reserved_quantity
      )
      update public.stock_reservations sr set
        released_quantity=sr.released_quantity+greatest(0,least(reservations.remaining,v_line.quantity-reservations.prior_remaining)),
        status=case
          when sr.released_quantity+greatest(0,least(reservations.remaining,v_line.quantity-reservations.prior_remaining))>=sr.reserved_quantity
            then 'consumed' else 'active' end,
        released_at=case
          when sr.released_quantity+greatest(0,least(reservations.remaining,v_line.quantity-reservations.prior_remaining))>=sr.reserved_quantity
            then now() else null end
      from reservations
      where sr.id=reservations.id
        and greatest(0,least(reservations.remaining,v_line.quantity-reservations.prior_remaining))>0;

      v_new_on_hand:=v_on_hand-v_line.quantity;
      v_stock_issues:=v_stock_issues||jsonb_build_array(jsonb_build_object(
        'invoice_item_id',v_invoice_item_id,'stock_item_id',v_stock.id,
        'location_id',p_stock_location_id,'quantity',v_line.quantity,
        'stock_movement_id',v_movement_id,'on_hand_after',v_new_on_hand
      ));
      if v_new_on_hand<=v_stock.reorder_level then
        v_low_stock_items:=v_low_stock_items||jsonb_build_array(jsonb_build_object(
          'stock_item_id',v_stock.id,'sku',v_stock.sku,'name',v_stock.name,
          'on_hand_after',v_new_on_hand,'reorder_level',v_stock.reorder_level
        ));
      end if;
    end if;
  end loop;

  update public.sales_invoices
  set status='sent',issue_date=current_date,issued_at=now(),updated_at=now()
  where business_id=p_business_id and id=v_invoice_id;

  update public.quotations
  set status='converted',updated_at=now()
  where business_id=p_business_id and id=p_quotation_id and status='accepted';

  insert into public.quotation_events(business_id,quotation_id,event_type,actor_user_id,source,reason)
  values(p_business_id,p_quotation_id,'converted',v_actor,'owner',
    'Issued invoice '||v_invoice_number);

  v_result:=jsonb_build_object(
    'invoice_id',v_invoice_id,'invoice_number',v_invoice_number,'status','sent',
    'total_amount',v_order.total_amount,'currency_code','KES','due_date',v_due_date,
    'deposit_required_amount',v_quote.deposit_required_amount,
    'stock_issues',v_stock_issues,'low_stock_items',v_low_stock_items
  );
  perform private.finish_idempotent_request(p_business_id,'convert_quote_to_sales_invoice',p_request_id,v_result);
  perform private.write_audit(p_business_id,v_actor,'sales.invoice_issued','sales_invoice',v_invoice_id,p_request_id,
    jsonb_build_object('quotation_id',p_quotation_id,'order_id',v_order.id,
      'invoice_number',v_invoice_number,'total_amount',v_order.total_amount,
      'stock_issue_count',jsonb_array_length(v_stock_issues),
      'oversell_confirmed',p_allow_oversell,'oversell_reason',nullif(btrim(p_oversell_reason),'')));
  return v_result;
end;
$$;

create or replace function public.owner_convert_accepted_quote_to_invoice(
  p_business_id uuid,p_quotation_id uuid,p_payment_terms text,p_due_date date,
  p_stock_location_id uuid,p_allow_oversell boolean,p_oversell_reason text,p_request_id uuid
) returns jsonb
language sql security invoker set search_path=''
as $$
  select private.owner_convert_accepted_quote_to_invoice(
    $1,$2,$3,$4,$5,$6,$7,$8
  );
$$;

revoke all on function private.next_sales_document_number(uuid,text) from public,anon,authenticated;
revoke all on function private.owner_convert_accepted_quote_to_invoice(uuid,uuid,text,date,uuid,boolean,text,uuid)
  from public,anon,authenticated;
grant execute on function private.owner_convert_accepted_quote_to_invoice(uuid,uuid,text,date,uuid,boolean,text,uuid)
  to authenticated;

revoke all on function public.owner_convert_accepted_quote_to_invoice(uuid,uuid,text,date,uuid,boolean,text,uuid)
  from public,anon;
grant execute on function public.owner_convert_accepted_quote_to_invoice(uuid,uuid,text,date,uuid,boolean,text,uuid)
  to authenticated;

commit;
