-- Automatic customer rewards at the order handover/completion boundary.
-- Redemption and all ledger mutations remain owner-authorised, atomic and audited.

create or replace function private.owner_record_customer_reward(
  p_business_id uuid,
  p_customer_id uuid,
  p_rule_id uuid,
  p_order_id uuid,
  p_entry_type text,
  p_reward_kind text,
  p_amount bigint,
  p_reason text,
  p_reference text,
  p_reverses_entry_id uuid,
  p_request_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_actor uuid;
  v_entry_id uuid;
  v_cached jsonb;
  v_result jsonb;
  v_balance bigint;
  v_original_amount bigint;
  v_already_reversed bigint;
begin
  v_actor := private.assert_active_owner(p_business_id);
  if p_request_id is null
    or p_entry_type not in ('earned','bonus','redeemed','reversed','expired')
    or p_reward_kind not in ('points','credit','discount')
    or p_amount is null or p_amount <= 0
    or length(btrim(coalesce(p_reason,''))) not between 1 and 500 then
    raise exception using errcode='22023',message='Reward entry invalid';
  end if;

  -- Serialise every reward mutation for this customer. This prevents two
  -- simultaneous redemptions from spending the same available balance.
  perform 1 from public.customers
    where business_id=p_business_id and id=p_customer_id and archived_at is null
    for update;
  if not found then
    raise exception using errcode='22023',message='Active customer not found';
  end if;

  if p_order_id is not null and not exists(
    select 1 from public.orders
    where business_id=p_business_id and id=p_order_id and customer_id=p_customer_id
  ) then
    raise exception using errcode='22023',message='Reward order must belong to this customer';
  end if;

  if p_rule_id is not null and not exists(
    select 1 from public.customer_loyalty_rules
    where business_id=p_business_id and id=p_rule_id and is_active
      and (customer_type='all' or customer_type=(
        select customer_type from public.customers
        where business_id=p_business_id and id=p_customer_id
      ))
      and reward_kind=p_reward_kind
  ) then
    raise exception using errcode='22023',message='Reward rule must be active and match customer category and reward type';
  end if;

  v_cached := private.begin_idempotent_request(
    p_business_id,'record_customer_reward',p_request_id,
    jsonb_build_object('customer',p_customer_id,'rule',p_rule_id,'order',p_order_id,
      'type',p_entry_type,'kind',p_reward_kind,'amount',p_amount,'reason',p_reason,
      'reference',p_reference,'reverses',p_reverses_entry_id)
  );
  if v_cached is not null then return v_cached; end if;

  if p_entry_type='reversed' then
    select amount into v_original_amount
    from public.customer_reward_ledger
    where id=p_reverses_entry_id and business_id=p_business_id
      and customer_id=p_customer_id and reward_kind=p_reward_kind
      and entry_type in ('earned','bonus')
    for update;
    if v_original_amount is null then
      raise exception using errcode='22023',message='Valid original earned reward or bonus required';
    end if;
    select coalesce(sum(amount),0) into v_already_reversed
    from public.customer_reward_ledger where reverses_entry_id=p_reverses_entry_id;
    if v_already_reversed+p_amount>v_original_amount then
      raise exception using errcode='22023',message='Reversal exceeds the remaining original reward amount';
    end if;
  end if;

  select coalesce(sum(case when entry_type in ('earned','bonus') then amount else -amount end),0)
    into v_balance
  from public.customer_reward_ledger
  where business_id=p_business_id and customer_id=p_customer_id and reward_kind=p_reward_kind;

  if p_entry_type='redeemed' and v_balance<p_amount then
    raise exception using errcode='22023',message='Insufficient reward balance';
  end if;

  insert into public.customer_reward_ledger(
    business_id,customer_id,rule_id,order_id,entry_type,reward_kind,amount,
    reason,reference,reverses_entry_id,created_by
  ) values (
    p_business_id,p_customer_id,p_rule_id,p_order_id,p_entry_type,p_reward_kind,p_amount,
    btrim(p_reason),nullif(btrim(p_reference),''),p_reverses_entry_id,v_actor
  ) returning id into v_entry_id;

  v_result:=jsonb_build_object('reward_entry_id',v_entry_id);
  perform private.finish_idempotent_request(p_business_id,'record_customer_reward',p_request_id,v_result);
  perform private.write_audit(p_business_id,v_actor,'customer.reward_recorded',
    'customer_reward',v_entry_id,p_request_id,
    jsonb_build_object('customer_id',p_customer_id,'entry_type',p_entry_type,
      'reward_kind',p_reward_kind,'amount',p_amount,'order_id',p_order_id));
  return v_result;
end;
$function$;

create or replace function private.award_customer_rewards_on_order_completion()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_actor uuid;
  v_customer public.customers%rowtype;
  v_rule public.customer_loyalty_rules%rowtype;
  v_order_count integer;
  v_eligible boolean;
  v_amount bigint;
  v_entry_id uuid;
begin
  if old.status is not distinct from new.status or new.status <> 'completed' then
    return new;
  end if;

  v_actor := private.assert_active_owner(new.business_id);
  select * into v_customer
  from public.customers
  where business_id=new.business_id and id=new.customer_id
    and archived_at is null and customer_status='active'
    and customer_type <> 'walk_in'
  for update;

  if not found then return new; end if;

  select count(*)::integer into v_order_count
  from public.orders
  where business_id=new.business_id and customer_id=new.customer_id
    and status='completed' and id <> new.id;

  for v_rule in
    select * from public.customer_loyalty_rules
    where business_id=new.business_id and is_active
      and (customer_type='all' or customer_type=v_customer.customer_type)
      and reward_event in ('repeat_order','order_value')
      and (starts_on is null or starts_on<=current_date)
      and (ends_on is null or ends_on>=current_date)
    order by created_at,id
  loop
    v_eligible := new.total_amount >= v_rule.minimum_order_amount
      and case when v_rule.reward_event='repeat_order'
        then v_order_count >= greatest(v_rule.minimum_order_count,1)
        else v_order_count+1 >= greatest(v_rule.minimum_order_count,1)
      end;

    if v_eligible and v_rule.applies_to <> 'all' then
      select exists(
        select 1
        from public.order_items oi
        left join public.catalogue_items ci
          on ci.business_id=oi.business_id and ci.id=oi.catalogue_item_id
        where oi.business_id=new.business_id and oi.order_id=new.id
          and case v_rule.applies_to
            when 'printing' then oi.sale_mode='value_added'
            when 'blanks' then oi.sale_mode='blank'
            when 'products' then ci.item_type='product'
            else false
          end
      ) into v_eligible;
      v_eligible := v_eligible
        and new.total_amount >= v_rule.minimum_order_amount
        and case when v_rule.reward_event='repeat_order'
          then v_order_count >= greatest(v_rule.minimum_order_count,1)
          else v_order_count+1 >= greatest(v_rule.minimum_order_count,1)
        end;
    end if;

    if not v_eligible then continue; end if;

    v_amount := case v_rule.calculation_method
      when 'per_100' then floor(new.total_amount::numeric/100)*v_rule.reward_value
      else v_rule.reward_value
    end;
    if v_amount <= 0 then continue; end if;

    insert into public.customer_reward_ledger(
      business_id,customer_id,rule_id,order_id,entry_type,reward_kind,
      amount,reason,reference,created_by
    ) values (
      new.business_id,new.customer_id,v_rule.id,new.id,'earned',v_rule.reward_kind,
      v_amount,'Automatic reward: '||v_rule.name,
      'auto-order:'||new.id::text||':'||v_rule.id::text,v_actor
    )
    on conflict do nothing
    returning id into v_entry_id;

    if v_entry_id is not null then
      perform private.write_audit(new.business_id,v_actor,'customer.reward_automatically_awarded',
        'customer_reward',v_entry_id,gen_random_uuid(),
        jsonb_build_object('customer_id',new.customer_id,'order_id',new.id,
          'rule_id',v_rule.id,'reward_kind',v_rule.reward_kind,'amount',v_amount,
          'completion_event','order_handover'));
    end if;
    v_entry_id := null;
  end loop;

  return new;
end;
$function$;

drop trigger if exists award_customer_rewards_after_order_completion on public.orders;
create trigger award_customer_rewards_after_order_completion
after update of status on public.orders
for each row
when (old.status is distinct from new.status and new.status='completed')
execute function private.award_customer_rewards_on_order_completion();

revoke all on function private.award_customer_rewards_on_order_completion() from public,anon,authenticated;
