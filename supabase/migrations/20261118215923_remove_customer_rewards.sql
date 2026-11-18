-- Remove customer rewards and loyalty functionality.
-- Customer profiles, contacts, interactions, addresses and order history remain intact.
-- Production reward tables were verified empty before this migration was prepared.

drop trigger if exists award_customer_rewards_after_order_completion on public.orders;

drop function if exists public.owner_record_customer_reward(uuid,uuid,uuid,uuid,text,text,bigint,text,text,uuid,uuid);
drop function if exists public.owner_upsert_customer_loyalty_rule(uuid,uuid,text,text,text,text,text,bigint,bigint,integer,text,boolean,date,date,uuid);

drop function if exists private.award_customer_rewards_on_order_completion();
drop function if exists private.owner_record_customer_reward(uuid,uuid,uuid,uuid,text,text,bigint,text,text,uuid,uuid);
drop function if exists private.owner_upsert_customer_loyalty_rule(uuid,uuid,text,text,text,text,text,bigint,bigint,integer,text,boolean,date,date,uuid);

drop table if exists public.customer_reward_ledger;
drop table if exists public.customer_loyalty_rules;
