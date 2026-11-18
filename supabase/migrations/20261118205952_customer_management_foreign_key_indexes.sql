create index if not exists customer_addresses_customer_idx on public.customer_addresses(business_id,customer_id);
create index if not exists customer_interactions_created_by_idx on public.customer_interactions(created_by);
create index if not exists customer_loyalty_rules_created_by_idx on public.customer_loyalty_rules(created_by);
create index if not exists customer_reward_ledger_created_by_idx on public.customer_reward_ledger(created_by);
create index if not exists customer_reward_ledger_reverses_idx on public.customer_reward_ledger(reverses_entry_id) where reverses_entry_id is not null;
create index if not exists customer_reward_ledger_rule_idx on public.customer_reward_ledger(business_id,rule_id) where rule_id is not null;
create index if not exists orders_business_customer_idx on public.orders(business_id,customer_id);
create index if not exists quotations_business_customer_idx on public.quotations(business_id,customer_id);
