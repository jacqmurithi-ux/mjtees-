
alter table public.customers add column if not exists customer_type text not null default 'individual', add column if not exists location text, add column if not exists registration_number text, add column if not exists preferred_contact_method text not null default 'phone', add column if not exists customer_status text not null default 'active', add column if not exists is_walk_in_profile boolean not null default false;
alter table public.customers add constraint customers_customer_type_check check(customer_type in ('individual','school','uniform_shop','business','organisation','chama','shg','cbo','walk_in')), add constraint customers_preferred_contact_check check(preferred_contact_method in ('phone','whatsapp','email','none')), add constraint customers_customer_status_check check(customer_status in ('active','inactive','blocked'));
create unique index if not exists customers_one_walk_in_profile_per_business on public.customers(business_id) where is_walk_in_profile and archived_at is null;
create index if not exists customers_type_status_idx on public.customers(business_id,customer_type,customer_status) where archived_at is null;
create index if not exists customers_phone_search_idx on public.customers(business_id,phone_normalized) where archived_at is null;
create table public.customer_contacts(id uuid primary key default gen_random_uuid(),business_id uuid not null,customer_id uuid not null,full_name text not null check(length(btrim(full_name)) between 1 and 180),position_title text,phone text,email text,is_primary boolean not null default false,can_place_orders boolean not null default false,can_approve_quotes boolean not null default false,can_collect_orders boolean not null default false,is_active boolean not null default true,created_at timestamptz not null default now(),updated_at timestamptz not null default now(),constraint customer_contacts_customer_fk foreign key(business_id,customer_id) references public.customers(business_id,id) on delete restrict,constraint customer_contacts_business_id_id_key unique(business_id,id));
create table public.customer_interactions(id uuid primary key default gen_random_uuid(),business_id uuid not null references public.businesses(id),customer_id uuid not null,interaction_type text not null check(interaction_type in ('call','whatsapp','email','meeting','follow_up','complaint','service_note','other')),subject text not null check(length(btrim(subject)) between 1 and 180),notes text,follow_up_at timestamptz,outcome text,created_by uuid not null references auth.users(id),created_at timestamptz not null default now(),constraint customer_interactions_customer_fk foreign key(business_id,customer_id) references public.customers(business_id,id));
create table public.customer_loyalty_rules(id uuid primary key default gen_random_uuid(),business_id uuid not null references public.businesses(id),name text not null check(length(btrim(name)) between 1 and 120),customer_type text not null check(customer_type in ('all','individual','school','uniform_shop','business','organisation','chama','shg','cbo','walk_in')),reward_event text not null check(reward_event in ('repeat_order','order_value','referral','group_volume','seasonal','manual')),reward_kind text not null check(reward_kind in ('points','credit','discount')),calculation_method text not null check(calculation_method in ('fixed','per_100')),reward_value bigint not null check(reward_value>0),minimum_order_amount bigint not null default 0 check(minimum_order_amount>=0),minimum_order_count integer not null default 0 check(minimum_order_count>=0),applies_to text not null default 'all' check(applies_to in ('all','printing','products','blanks')),is_active boolean not null default false,starts_on date,ends_on date,created_by uuid not null references auth.users(id),created_at timestamptz not null default now(),updated_at timestamptz not null default now(),unique(business_id,id),check(ends_on is null or starts_on is null or ends_on>=starts_on));
create table public.customer_reward_ledger(id uuid primary key default gen_random_uuid(),business_id uuid not null references public.businesses(id),customer_id uuid not null,rule_id uuid,order_id uuid,entry_type text not null check(entry_type in ('earned','bonus','redeemed','reversed','expired')),reward_kind text not null check(reward_kind in ('points','credit','discount')),amount bigint not null check(amount>0),reason text not null check(length(btrim(reason)) between 1 and 500),reference text,reverses_entry_id uuid,created_by uuid not null references auth.users(id),created_at timestamptz not null default now(),constraint customer_reward_customer_fk foreign key(business_id,customer_id) references public.customers(business_id,id),constraint customer_reward_rule_fk foreign key(business_id,rule_id) references public.customer_loyalty_rules(business_id,id),constraint customer_reward_order_fk foreign key(business_id,order_id) references public.orders(business_id,id),constraint customer_reward_reverse_fk foreign key(reverses_entry_id) references public.customer_reward_ledger(id),unique(business_id,reference));
create index customer_contacts_customer_idx on public.customer_contacts(business_id,customer_id,is_active);
create index customer_interactions_customer_idx on public.customer_interactions(business_id,customer_id,created_at desc);
create index customer_interactions_followup_idx on public.customer_interactions(business_id,follow_up_at) where follow_up_at is not null;
create index customer_loyalty_rules_active_idx on public.customer_loyalty_rules(business_id,is_active,customer_type);
create index customer_reward_customer_idx on public.customer_reward_ledger(business_id,customer_id,created_at desc);
create index customer_reward_order_idx on public.customer_reward_ledger(business_id,order_id) where order_id is not null;
alter table public.customer_contacts enable row level security; alter table public.customer_interactions enable row level security; alter table public.customer_loyalty_rules enable row level security; alter table public.customer_reward_ledger enable row level security;
create policy customer_contacts_owner_select on public.customer_contacts for select to authenticated using(private.is_active_owner(business_id));
create policy customer_interactions_owner_select on public.customer_interactions for select to authenticated using(private.is_active_owner(business_id));
create policy customer_loyalty_rules_owner_select on public.customer_loyalty_rules for select to authenticated using(private.is_active_owner(business_id));
create policy customer_reward_ledger_owner_select on public.customer_reward_ledger for select to authenticated using(private.is_active_owner(business_id));
revoke all on public.customer_contacts,public.customer_interactions,public.customer_loyalty_rules,public.customer_reward_ledger from anon,authenticated;
grant select on public.customer_contacts,public.customer_interactions,public.customer_loyalty_rules,public.customer_reward_ledger to authenticated;


CREATE OR REPLACE FUNCTION private.owner_get_or_create_walk_in_customer(p_business_id uuid, p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare a uuid; i uuid; c jsonb; r jsonb;
begin a:=private.assert_active_owner(p_business_id); c:=private.begin_idempotent_request(p_business_id,'get_walk_in_customer',p_request_id,'{}'::jsonb); if c is not null then return c; end if;
 select id into i from public.customers where business_id=p_business_id and is_walk_in_profile and archived_at is null;
 if i is null then insert into public.customers(business_id,display_name,customer_type,preferred_contact_method,customer_status,is_walk_in_profile,created_by) values(p_business_id,'Walk-in customer','walk_in','none','active',true,a) returning id into i; end if;
 r:=jsonb_build_object('customer_id',i); perform private.finish_idempotent_request(p_business_id,'get_walk_in_customer',p_request_id,r); return r; end $function$


CREATE OR REPLACE FUNCTION private.owner_record_customer_interaction(p_business_id uuid, p_customer_id uuid, p_interaction_type text, p_subject text, p_notes text, p_follow_up_at timestamp with time zone, p_outcome text, p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare a uuid; i uuid; c jsonb; r jsonb;
begin
 a:=private.assert_active_owner(p_business_id);
 if p_interaction_type not in ('call','whatsapp','email','meeting','follow_up','complaint','service_note','other') or length(btrim(coalesce(p_subject,''))) not between 1 and 180 or length(coalesce(p_notes,''))>4000 or not exists(select 1 from public.customers where business_id=p_business_id and id=p_customer_id and archived_at is null) then raise exception using errcode='22023',message='Interaction details are invalid'; end if;
 c:=private.begin_idempotent_request(p_business_id,'record_customer_interaction',p_request_id,jsonb_build_object('customer',p_customer_id,'type',p_interaction_type,'subject',p_subject,'notes',p_notes,'followup',p_follow_up_at)); if c is not null then return c; end if;
 insert into public.customer_interactions(business_id,customer_id,interaction_type,subject,notes,follow_up_at,outcome,created_by) values(p_business_id,p_customer_id,p_interaction_type,btrim(p_subject),p_notes,p_follow_up_at,p_outcome,a) returning id into i;
 r:=jsonb_build_object('interaction_id',i); perform private.finish_idempotent_request(p_business_id,'record_customer_interaction',p_request_id,r); perform private.write_audit(p_business_id,a,'customer.interaction_recorded','customer_interaction',i,p_request_id,jsonb_build_object('customer_id',p_customer_id)); return r;
end $function$


CREATE OR REPLACE FUNCTION private.owner_record_customer_reward(p_business_id uuid, p_customer_id uuid, p_rule_id uuid, p_order_id uuid, p_entry_type text, p_reward_kind text, p_amount bigint, p_reason text, p_reference text, p_reverses_entry_id uuid, p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare a uuid; i uuid; c jsonb; r jsonb; bal bigint;
begin
 a:=private.assert_active_owner(p_business_id);
 if p_entry_type not in ('earned','bonus','redeemed','reversed','expired') or p_reward_kind not in ('points','credit','discount') or p_amount<=0 or length(btrim(coalesce(p_reason,''))) not between 1 and 500 or not exists(select 1 from public.customers where business_id=p_business_id and id=p_customer_id and archived_at is null) then raise exception using errcode='22023',message='Reward entry invalid'; end if;
 if p_entry_type='reversed' and (p_reverses_entry_id is null or not exists(select 1 from public.customer_reward_ledger where id=p_reverses_entry_id and business_id=p_business_id and customer_id=p_customer_id and reward_kind=p_reward_kind and entry_type in ('earned','bonus'))) then raise exception using errcode='22023',message='Valid original reward required for reversal'; end if;
 select coalesce(sum(case when entry_type in ('earned','bonus') then amount else -amount end),0) into bal from public.customer_reward_ledger where business_id=p_business_id and customer_id=p_customer_id and reward_kind=p_reward_kind;
 if p_entry_type='redeemed' and bal<p_amount then raise exception using errcode='22023',message='Insufficient reward balance'; end if;
 c:=private.begin_idempotent_request(p_business_id,'record_customer_reward',p_request_id,jsonb_build_object('customer',p_customer_id,'rule',p_rule_id,'order',p_order_id,'type',p_entry_type,'kind',p_reward_kind,'amount',p_amount,'reason',p_reason,'reference',p_reference,'reverses',p_reverses_entry_id)); if c is not null then return c; end if;
 insert into public.customer_reward_ledger(business_id,customer_id,rule_id,order_id,entry_type,reward_kind,amount,reason,reference,reverses_entry_id,created_by) values(p_business_id,p_customer_id,p_rule_id,p_order_id,p_entry_type,p_reward_kind,p_amount,btrim(p_reason),nullif(btrim(p_reference),''),p_reverses_entry_id,a) returning id into i;
 r:=jsonb_build_object('reward_entry_id',i); perform private.finish_idempotent_request(p_business_id,'record_customer_reward',p_request_id,r); perform private.write_audit(p_business_id,a,'customer.reward_recorded','customer_reward',i,p_request_id,jsonb_build_object('customer_id',p_customer_id,'entry_type',p_entry_type,'reward_kind',p_reward_kind,'amount',p_amount)); return r;
end $function$


CREATE OR REPLACE FUNCTION private.owner_save_customer_profile(p_business_id uuid, p_customer_id uuid, p_display_name text, p_business_name text, p_customer_type text, p_phone text, p_email text, p_location text, p_registration_number text, p_preferred_contact_method text, p_customer_status text, p_notes text, p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare a uuid; i uuid; c jsonb; r jsonb;
begin
 a:=private.assert_active_owner(p_business_id);
 if length(btrim(coalesce(p_display_name,''))) not between 1 and 180 or p_customer_type not in ('individual','school','uniform_shop','business','organisation','chama','shg','cbo','walk_in') or p_preferred_contact_method not in ('phone','whatsapp','email','none') or p_customer_status not in ('active','inactive','blocked') or length(coalesce(p_business_name,''))>180 or length(coalesce(p_phone,''))>40 or length(coalesce(p_email,''))>254 or length(coalesce(p_location,''))>300 or length(coalesce(p_registration_number,''))>100 or length(coalesce(p_notes,''))>4000 then raise exception using errcode='22023',message='Customer profile fields are invalid'; end if;
 if p_email is not null and p_email !~* '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then raise exception using errcode='22023',message='Invalid email'; end if;
 c:=private.begin_idempotent_request(p_business_id,'save_customer_profile',p_request_id,jsonb_build_object('id',p_customer_id,'name',p_display_name,'type',p_customer_type,'phone',p_phone,'email',p_email,'location',p_location,'status',p_customer_status));
 if c is not null then return c; end if;
 if p_customer_id is null then insert into public.customers(business_id,display_name,business_name,phone,phone_normalized,email,notes,created_by,customer_type,location,registration_number,preferred_contact_method,customer_status) values(p_business_id,btrim(p_display_name),nullif(btrim(p_business_name),''),nullif(btrim(p_phone),''),nullif(regexp_replace(coalesce(p_phone,''),'[^0-9+]','','g'),''),nullif(lower(btrim(p_email)),''),p_notes,a,p_customer_type,nullif(btrim(p_location),''),nullif(btrim(p_registration_number),''),p_preferred_contact_method,p_customer_status) returning id into i;
 else update public.customers set display_name=btrim(p_display_name),business_name=nullif(btrim(p_business_name),''),phone=nullif(btrim(p_phone),''),phone_normalized=nullif(regexp_replace(coalesce(p_phone,''),'[^0-9+]','','g'),''),email=nullif(lower(btrim(p_email)),''),notes=p_notes,customer_type=p_customer_type,location=nullif(btrim(p_location),''),registration_number=nullif(btrim(p_registration_number),''),preferred_contact_method=p_preferred_contact_method,customer_status=p_customer_status,updated_at=now() where business_id=p_business_id and id=p_customer_id and archived_at is null and not is_walk_in_profile returning id into i; if i is null then raise exception using errcode='P0002',message='Customer not found'; end if; end if;
 r:=jsonb_build_object('customer_id',i); perform private.finish_idempotent_request(p_business_id,'save_customer_profile',p_request_id,r); perform private.write_audit(p_business_id,a,case when p_customer_id is null then 'customer.created' else 'customer.updated' end,'customer',i,p_request_id,jsonb_build_object('customer_type',p_customer_type)); return r;
end $function$


CREATE OR REPLACE FUNCTION private.owner_upsert_customer_contact(p_business_id uuid, p_contact_id uuid, p_customer_id uuid, p_full_name text, p_position_title text, p_phone text, p_email text, p_is_primary boolean, p_can_place_orders boolean, p_can_approve_quotes boolean, p_can_collect_orders boolean, p_is_active boolean, p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare a uuid; i uuid; c jsonb; r jsonb;
begin
 a:=private.assert_active_owner(p_business_id);
 if length(btrim(coalesce(p_full_name,''))) not between 1 and 180 or length(coalesce(p_position_title,''))>120 or length(coalesce(p_phone,''))>40 or length(coalesce(p_email,''))>254 or not exists(select 1 from public.customers where business_id=p_business_id and id=p_customer_id and archived_at is null) then raise exception using errcode='22023',message='Contact details or customer are invalid'; end if;
 c:=private.begin_idempotent_request(p_business_id,'upsert_customer_contact',p_request_id,jsonb_build_object('id',p_contact_id,'customer',p_customer_id,'name',p_full_name,'phone',p_phone,'email',p_email,'primary',p_is_primary,'active',p_is_active)); if c is not null then return c; end if;
 if p_is_primary then update public.customer_contacts set is_primary=false,updated_at=now() where business_id=p_business_id and customer_id=p_customer_id and is_primary; end if;
 if p_contact_id is null then insert into public.customer_contacts(business_id,customer_id,full_name,position_title,phone,email,is_primary,can_place_orders,can_approve_quotes,can_collect_orders,is_active) values(p_business_id,p_customer_id,btrim(p_full_name),nullif(btrim(p_position_title),''),nullif(btrim(p_phone),''),nullif(lower(btrim(p_email)),''),p_is_primary,p_can_place_orders,p_can_approve_quotes,p_can_collect_orders,p_is_active) returning id into i;
 else update public.customer_contacts set customer_id=p_customer_id,full_name=btrim(p_full_name),position_title=nullif(btrim(p_position_title),''),phone=nullif(btrim(p_phone),''),email=nullif(lower(btrim(p_email)),''),is_primary=p_is_primary,can_place_orders=p_can_place_orders,can_approve_quotes=p_can_approve_quotes,can_collect_orders=p_can_collect_orders,is_active=p_is_active,updated_at=now() where business_id=p_business_id and id=p_contact_id returning id into i; if i is null then raise exception using errcode='P0002',message='Contact not found'; end if; end if;
 r:=jsonb_build_object('contact_id',i); perform private.finish_idempotent_request(p_business_id,'upsert_customer_contact',p_request_id,r); perform private.write_audit(p_business_id,a,'customer.contact_saved','customer_contact',i,p_request_id,jsonb_build_object('customer_id',p_customer_id)); return r;
end $function$


CREATE OR REPLACE FUNCTION private.owner_upsert_customer_loyalty_rule(p_business_id uuid, p_rule_id uuid, p_name text, p_customer_type text, p_reward_event text, p_reward_kind text, p_calculation_method text, p_reward_value bigint, p_minimum_order_amount bigint, p_minimum_order_count integer, p_applies_to text, p_is_active boolean, p_starts_on date, p_ends_on date, p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare a uuid; i uuid; c jsonb; r jsonb;
begin
 a:=private.assert_active_owner(p_business_id);
 if length(btrim(coalesce(p_name,''))) not between 1 and 120 or p_customer_type not in ('all','individual','school','uniform_shop','business','organisation','chama','shg','cbo','walk_in') or p_reward_event not in ('repeat_order','order_value','referral','group_volume','seasonal','manual') or p_reward_kind not in ('points','credit','discount') or p_calculation_method not in ('fixed','per_100') or p_reward_value<=0 or p_minimum_order_amount<0 or p_minimum_order_count<0 or p_applies_to not in ('all','printing','products','blanks') then raise exception using errcode='22023',message='Loyalty rule invalid'; end if;
 c:=private.begin_idempotent_request(p_business_id,'upsert_customer_loyalty_rule',p_request_id,jsonb_build_object('id',p_rule_id,'name',p_name,'type',p_customer_type,'event',p_reward_event,'kind',p_reward_kind,'value',p_reward_value,'active',p_is_active)); if c is not null then return c; end if;
 if p_rule_id is null then insert into public.customer_loyalty_rules(business_id,name,customer_type,reward_event,reward_kind,calculation_method,reward_value,minimum_order_amount,minimum_order_count,applies_to,is_active,starts_on,ends_on,created_by) values(p_business_id,btrim(p_name),p_customer_type,p_reward_event,p_reward_kind,p_calculation_method,p_reward_value,p_minimum_order_amount,p_minimum_order_count,p_applies_to,p_is_active,p_starts_on,p_ends_on,a) returning id into i;
 else update public.customer_loyalty_rules set name=btrim(p_name),customer_type=p_customer_type,reward_event=p_reward_event,reward_kind=p_reward_kind,calculation_method=p_calculation_method,reward_value=p_reward_value,minimum_order_amount=p_minimum_order_amount,minimum_order_count=p_minimum_order_count,applies_to=p_applies_to,is_active=p_is_active,starts_on=p_starts_on,ends_on=p_ends_on,updated_at=now() where business_id=p_business_id and id=p_rule_id returning id into i; if i is null then raise exception using errcode='P0002',message='Loyalty rule not found'; end if; end if;
 r:=jsonb_build_object('rule_id',i); perform private.finish_idempotent_request(p_business_id,'upsert_customer_loyalty_rule',p_request_id,r); perform private.write_audit(p_business_id,a,'customer.loyalty_rule_saved','customer_loyalty_rule',i,p_request_id,'{}'::jsonb); return r;
end $function$

