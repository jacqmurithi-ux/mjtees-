
-- Enforce the single approved profitability threshold at quotation issue time.
-- Gross margin = (final discounted selling amount - direct production cost)
--                / final discounted selling amount.
-- 30% floor => final selling amount >= ceil(direct cost / 0.70).
-- No overhead or tax allocation is introduced.

create or replace function private.enforce_quotation_margin_floor(
  p_business_id uuid,
  p_quotation_id uuid,
  p_actor uuid,
  p_request_id uuid,
  p_exception_reason text
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_selling_total bigint;
  v_direct_cost numeric;
  v_missing_costs integer;
  v_minimum_total bigint;
  v_reason text := nullif(btrim(p_exception_reason), '');
begin
  select q.total_amount
    into v_selling_total
  from public.quotations q
  where q.business_id = p_business_id
    and q.id = p_quotation_id
  for update;

  if not found then
    raise exception using errcode='P0002', message='Quotation not found';
  end if;

  select
    count(*) filter (
      where qi.cost_estimate_snapshot is null
        or not (qi.cost_estimate_snapshot ? 'estimated_total_cost')
        or nullif(qi.cost_estimate_snapshot->>'estimated_total_cost','') is null
    ),
    coalesce(sum((qi.cost_estimate_snapshot->>'estimated_total_cost')::numeric),0)
    into v_missing_costs, v_direct_cost
  from public.quotation_items qi
  where qi.business_id = p_business_id
    and qi.quotation_id = p_quotation_id;

  if v_missing_costs > 0 then
    raise exception using errcode='23514',
      message='Cannot issue quotation: one or more lines have no saved direct-cost estimate';
  end if;

  if v_direct_cost < 0 then
    raise exception using errcode='23514',
      message='Cannot issue quotation: direct production cost cannot be negative';
  end if;

  v_minimum_total := ceil(v_direct_cost / 0.70)::bigint;

  if v_selling_total < v_minimum_total then
    if v_reason is null then
      raise exception using errcode='23514',
        message='Quotation is below the 30% minimum gross margin. An owner approval reason is required.';
    end if;
    if length(v_reason) > 1000 then
      raise exception using errcode='22023',
        message='Owner approval reason must be 1,000 characters or fewer';
    end if;

    insert into public.owner_approvals(
      business_id, approval_type, entity_type, entity_id,
      reason, approved_by, request_id
    )
    values (
      p_business_id, 'quotation_margin_exception', 'quotation', p_quotation_id,
      v_reason, p_actor, p_request_id
    );

    perform private.write_audit(
      p_business_id, p_actor, 'quotation.margin_exception_approved',
      'quotation', p_quotation_id, p_request_id,
      jsonb_build_object(
        'direct_production_cost', v_direct_cost,
        'final_discounted_selling_total', v_selling_total,
        'minimum_30_percent_margin_total', v_minimum_total,
        'reason', v_reason
      )
    );
  end if;

  return jsonb_build_object(
    'direct_production_cost', v_direct_cost,
    'final_discounted_selling_total', v_selling_total,
    'minimum_30_percent_margin_total', v_minimum_total,
    'exception_approved', (v_selling_total < v_minimum_total)
  );
end;
$function$;

revoke all on function private.enforce_quotation_margin_floor(uuid,uuid,uuid,uuid,text) from public, anon, authenticated;

create or replace function private.owner_send_quotation(
  p_quotation_id uuid,
  p_expires_at timestamptz,
  p_request_id uuid,
  p_margin_exception_reason text
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_quote public.quotations%rowtype;
  v_actor uuid;
  v_cached jsonb;
  v_payload jsonb;
  v_token text;
  v_expiry timestamptz;
  v_hash bytea;
  v_result jsonb;
  v_margin jsonb;
begin
  select * into v_quote from public.quotations where id=p_quotation_id;
  if not found then
    raise exception using errcode='P0002', message='Quotation not found';
  end if;

  v_actor := private.assert_active_owner(v_quote.business_id);
  v_payload := jsonb_build_object(
    'quotation_id',p_quotation_id,
    'expires_at',p_expires_at,
    'margin_exception_reason',nullif(btrim(p_margin_exception_reason),'')
  );
  v_cached := private.begin_idempotent_request(v_quote.business_id,'send_quotation',p_request_id,v_payload);
  if v_cached is not null then return v_cached; end if;

  select * into v_quote
  from public.quotations
  where business_id=v_quote.business_id and id=p_quotation_id
  for update;

  if v_quote.status not in ('draft','sent') then
    raise exception using errcode='22023', message='Only draft or sent quotations can be sent';
  end if;

  -- This runs after all line and order discounts have been saved.
  v_margin := private.enforce_quotation_margin_floor(
    v_quote.business_id, p_quotation_id, v_actor, p_request_id, p_margin_exception_reason
  );

  v_expiry := coalesce(p_expires_at,v_quote.expires_at,now()+interval '14 days');
  if v_expiry<=now() then
    raise exception using errcode='22023', message='Quote expiry must be in the future';
  end if;

  v_token := gen_random_uuid()::text||gen_random_uuid()::text;
  v_hash := extensions.digest(convert_to(v_token,'UTF8'),'sha256');

  update private.quote_acceptance_tokens
  set expires_at=least(expires_at,now())
  where business_id=v_quote.business_id
    and quotation_id=p_quotation_id
    and used_at is null;

  insert into private.quote_acceptance_tokens(business_id,quotation_id,token_hash,expires_at)
  values(v_quote.business_id,p_quotation_id,v_hash,v_expiry);

  update public.quotations
  set status='sent',issued_at=coalesce(issued_at,now()),expires_at=v_expiry,updated_at=now()
  where business_id=v_quote.business_id and id=p_quotation_id;

  insert into public.quotation_events(business_id,quotation_id,event_type,actor_user_id,source)
  values(v_quote.business_id,p_quotation_id,'sent',v_actor,'owner');

  v_result := jsonb_build_object(
    'quotation_id',p_quotation_id,
    'quote_number',v_quote.quote_number,
    'acceptance_token',v_token,
    'expires_at',v_expiry,
    'total_amount',v_quote.total_amount,
    'margin_check',v_margin
  );

  perform private.finish_idempotent_request(v_quote.business_id,'send_quotation',p_request_id,v_result);
  perform private.write_audit(
    v_quote.business_id,v_actor,'quotation.sent','quotation',p_quotation_id,p_request_id,
    jsonb_build_object('expires_at',v_expiry,'margin_check',v_margin)
  );
  return v_result;
end;
$function$;

revoke all on function private.owner_send_quotation(uuid,timestamptz,uuid,text) from public, anon, authenticated;
grant execute on function private.owner_send_quotation(uuid,timestamptz,uuid,text) to authenticated, service_role;

-- Keep the old private signature for existing internal callers; it cannot approve an exception.
create or replace function private.owner_send_quotation(
  p_quotation_id uuid, p_expires_at timestamptz, p_request_id uuid
)
returns jsonb
language sql
security definer
set search_path to ''
as $function$
  select private.owner_send_quotation($1,$2,$3,null);
$function$;

-- Explicit public API overload for the owner-entered exception reason.
create or replace function public.owner_send_quotation(
  p_quotation_id uuid,
  p_expires_at timestamptz,
  p_request_id uuid,
  p_margin_exception_reason text
)
returns jsonb
language sql
set search_path to ''
as $function$
  select private.owner_send_quotation($1,$2,$3,$4);
$function$;

revoke all on function public.owner_send_quotation(uuid,timestamptz,uuid,text) from public, anon;
grant execute on function public.owner_send_quotation(uuid,timestamptz,uuid,text) to authenticated, service_role;

-- Direct-order path accepts the same explicit owner exception reason and passes it
-- to the same final-total check before the customer acceptance step.
create or replace function private.owner_create_direct_order(
  p_business_id uuid,
  p_customer_id uuid,
  p_enquiry_id uuid,
  p_lines jsonb,
  p_order_discount bigint,
  p_customer_notes text,
  p_internal_notes text,
  p_request_id uuid,
  p_margin_exception_reason text
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_actor uuid;
  v_cached jsonb;
  v_payload jsonb;
  v_quote jsonb;
  v_send jsonb;
  v_accept jsonb;
  v_result jsonb;
  v_quote_id uuid;
begin
  v_actor := private.assert_active_owner(p_business_id);
  v_payload := jsonb_build_object(
    'customer_id',p_customer_id,
    'enquiry_id',p_enquiry_id,
    'lines',p_lines,
    'order_discount',p_order_discount,
    'customer_notes',p_customer_notes,
    'internal_notes',p_internal_notes,
    'margin_exception_reason',nullif(btrim(p_margin_exception_reason),'')
  );
  v_cached := private.begin_idempotent_request(p_business_id,'create_direct_order',p_request_id,v_payload);
  if v_cached is not null then return v_cached; end if;

  v_quote := private.owner_create_quotation_with_discount(
    p_business_id,p_customer_id,p_enquiry_id,p_lines,p_order_discount,
    now()+interval '1 day',p_customer_notes,p_internal_notes,
    private.derived_request_uuid(p_request_id,'direct-order-quote')
  );
  v_quote_id := (v_quote->>'quotation_id')::uuid;

  v_send := private.owner_send_quotation(
    v_quote_id,now()+interval '1 day',
    private.derived_request_uuid(p_request_id,'direct-order-send'),
    p_margin_exception_reason
  );
  v_accept := private.accept_quotation_token(
    v_send->>'acceptance_token',
    private.derived_request_uuid(p_request_id,'direct-order-accept')
  );

  v_result := jsonb_build_object(
    'order_number',v_accept->>'order_number',
    'total_amount',v_accept->'total_amount',
    'currency_code','KES',
    'status','confirmed'
  );
  perform private.finish_idempotent_request(p_business_id,'create_direct_order',p_request_id,v_result);
  perform private.write_audit(
    p_business_id,v_actor,'order.created_directly','order',null,p_request_id,
    jsonb_build_object('order_number',v_accept->>'order_number','quotation_id',v_quote_id)
  );
  return v_result;
end;
$function$;

revoke all on function private.owner_create_direct_order(uuid,uuid,uuid,jsonb,bigint,text,text,uuid,text) from public, anon, authenticated;
grant execute on function private.owner_create_direct_order(uuid,uuid,uuid,jsonb,bigint,text,text,uuid,text) to authenticated, service_role;

-- Preserve the legacy private and public signatures; old calls receive no exception reason.
create or replace function private.owner_create_direct_order(
  p_business_id uuid,p_customer_id uuid,p_enquiry_id uuid,p_lines jsonb,
  p_order_discount bigint,p_customer_notes text,p_internal_notes text,p_request_id uuid
)
returns jsonb
language sql
security definer
set search_path to ''
as $function$
  select private.owner_create_direct_order($1,$2,$3,$4,$5,$6,$7,$8,null);
$function$;

create or replace function public.owner_create_direct_order(
  p_business_id uuid,p_customer_id uuid,p_enquiry_id uuid,p_lines jsonb,
  p_order_discount bigint,p_customer_notes text,p_internal_notes text,p_request_id uuid,
  p_margin_exception_reason text
)
returns jsonb
language sql
set search_path to ''
as $function$
  select private.owner_create_direct_order($1,$2,$3,$4,$5,$6,$7,$8,$9);
$function$;

revoke all on function public.owner_create_direct_order(uuid,uuid,uuid,jsonb,bigint,text,text,uuid,text) from public, anon;
grant execute on function public.owner_create_direct_order(uuid,uuid,uuid,jsonb,bigint,text,text,uuid,text) to authenticated, service_role;

-- Recreate the original public 8-argument wrapper unchanged in behaviour.
create or replace function public.owner_create_direct_order(
  p_business_id uuid,p_customer_id uuid,p_enquiry_id uuid,p_lines jsonb,
  p_order_discount bigint,p_customer_notes text,p_internal_notes text,p_request_id uuid
)
returns jsonb
language sql
set search_path to ''
as $function$
  select private.owner_create_direct_order($1,$2,$3,$4,$5,$6,$7,$8);
$function$;
