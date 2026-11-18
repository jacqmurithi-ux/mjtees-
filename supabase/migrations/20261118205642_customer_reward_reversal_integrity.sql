CREATE OR REPLACE FUNCTION private.owner_record_customer_reward(p_business_id uuid, p_customer_id uuid, p_rule_id uuid, p_order_id uuid, p_entry_type text, p_reward_kind text, p_amount bigint, p_reason text, p_reference text, p_reverses_entry_id uuid, p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare a uuid; i uuid; c jsonb; r jsonb; bal bigint; original_amount bigint; already_reversed bigint;
begin
 a:=private.assert_active_owner(p_business_id);
 if p_entry_type not in ('earned','bonus','redeemed','reversed','expired') or p_reward_kind not in ('points','credit','discount') or p_amount<=0 or length(btrim(coalesce(p_reason,''))) not between 1 and 500 or not exists(select 1 from public.customers where business_id=p_business_id and id=p_customer_id and archived_at is null) then raise exception using errcode='22023',message='Reward entry invalid'; end if;
 if p_entry_type='reversed' then
  select amount into original_amount from public.customer_reward_ledger where id=p_reverses_entry_id and business_id=p_business_id and customer_id=p_customer_id and reward_kind=p_reward_kind and entry_type in ('earned','bonus') for update;
  if original_amount is null then raise exception using errcode='22023',message='Valid original earned reward or bonus required'; end if;
  select coalesce(sum(amount),0) into already_reversed from public.customer_reward_ledger where reverses_entry_id=p_reverses_entry_id;
  if already_reversed+p_amount>original_amount then raise exception using errcode='22023',message='Reversal exceeds the remaining original reward amount'; end if;
 end if;
 select coalesce(sum(case when entry_type in ('earned','bonus') then amount else -amount end),0) into bal from public.customer_reward_ledger where business_id=p_business_id and customer_id=p_customer_id and reward_kind=p_reward_kind;
 if p_entry_type='redeemed' and bal<p_amount then raise exception using errcode='22023',message='Insufficient reward balance'; end if;
 c:=private.begin_idempotent_request(p_business_id,'record_customer_reward',p_request_id,jsonb_build_object('customer',p_customer_id,'rule',p_rule_id,'order',p_order_id,'type',p_entry_type,'kind',p_reward_kind,'amount',p_amount,'reason',p_reason,'reference',p_reference,'reverses',p_reverses_entry_id)); if c is not null then return c; end if;
 insert into public.customer_reward_ledger(business_id,customer_id,rule_id,order_id,entry_type,reward_kind,amount,reason,reference,reverses_entry_id,created_by) values(p_business_id,p_customer_id,p_rule_id,p_order_id,p_entry_type,p_reward_kind,p_amount,btrim(p_reason),nullif(btrim(p_reference),''),p_reverses_entry_id,a) returning id into i;
 r:=jsonb_build_object('reward_entry_id',i); perform private.finish_idempotent_request(p_business_id,'record_customer_reward',p_request_id,r); perform private.write_audit(p_business_id,a,'customer.reward_recorded','customer_reward',i,p_request_id,jsonb_build_object('customer_id',p_customer_id,'entry_type',p_entry_type,'reward_kind',p_reward_kind,'amount',p_amount)); return r;
end $function$

