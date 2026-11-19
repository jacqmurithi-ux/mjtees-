-- Fresh MJ Printing & Branding schema. The existing Auth user is preserved.
create extension if not exists pgcrypto with schema extensions;
create schema if not exists private;

create table public.businesses(
 id uuid primary key default gen_random_uuid(),
 business_name text not null check(length(btrim(business_name)) between 2 and 160),
 business_slug text not null unique check(business_slug ~ '^[a-z0-9-]{2,80}$'),
 currency text not null default 'KES' check(currency='KES'),
 timezone text not null default 'Africa/Nairobi',
 vat_enabled boolean not null default false check(vat_enabled=false),
 created_by uuid not null references auth.users(id),
 created_at timestamptz not null default now()
);
create table public.business_memberships(
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null references public.businesses(id) on delete cascade,
 user_id uuid not null references auth.users(id) on delete cascade,
 role text not null default 'owner' check(role in('owner','staff')),
 permissions jsonb not null default '{}'::jsonb,
 created_at timestamptz not null default now(),
 unique(business_id,user_id)
);
create table public.business_settings(
 business_id uuid primary key references public.businesses(id) on delete cascade,
 brand_orange text not null default '#f47721',
 brand_blue text not null default '#1769aa',
 brand_green text not null default '#15945b',
 gross_margin_floor numeric(5,2) not null default 30 check(gross_margin_floor=30),
 full_cost_target_multiplier numeric(4,2) not null default 1.8 check(full_cost_target_multiplier=1.8),
 payment_methods text[] not null default array['cash','mpesa_paybill'] check(payment_methods=array['cash','mpesa_paybill'])
);
create table public.customers(
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null references public.businesses(id) on delete cascade,
 customer_name text not null check(length(btrim(customer_name)) between 2 and 180),
 customer_type text not null default 'individual' check(customer_type in('individual','business','school','team','group','reseller','other')),
 phone text,email text,notes text,
 created_by uuid not null references auth.users(id),
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now()
);
create index customers_business_created_idx on public.customers(business_id,created_at desc);
create table public.customer_contacts(
 id uuid primary key default gen_random_uuid(),business_id uuid not null references public.businesses(id) on delete cascade,
 customer_id uuid not null references public.customers(id) on delete cascade,contact_name text not null,phone text,email text,role_label text
);
create table public.customer_addresses(
 id uuid primary key default gen_random_uuid(),business_id uuid not null references public.businesses(id) on delete cascade,
 customer_id uuid not null references public.customers(id) on delete cascade,label text not null default 'Delivery',address_text text not null,is_default boolean not null default false
);
create table public.costing_profiles(
 id uuid primary key default gen_random_uuid(),business_id uuid not null references public.businesses(id) on delete cascade,
 profile_name text not null,version integer not null check(version>0),is_active boolean not null default false,
 components jsonb not null default '[]'::jsonb,direct_cost numeric(14,2) not null default 0 check(direct_cost>=0),
 margin_floor numeric(5,2) not null default 30 check(margin_floor=30),full_cost_target numeric(4,2) not null default 1.8 check(full_cost_target=1.8),
 created_at timestamptz not null default now(),unique(business_id,profile_name,version)
);
create unique index costing_one_active_profile on public.costing_profiles(business_id,profile_name) where is_active;
create table public.quotations(
 id uuid primary key default gen_random_uuid(),business_id uuid not null references public.businesses(id) on delete cascade,
 customer_id uuid not null references public.customers(id),quote_number text not null,
 status text not null default 'draft' check(status in('draft','sent','accepted','declined','expired','converted')),
 issue_date date not null default current_date,valid_until date,total numeric(14,2) not null default 0,
 costing_profile_id uuid references public.costing_profiles(id),created_by uuid not null references auth.users(id),
 created_at timestamptz not null default now(),unique(business_id,quote_number)
);
create table public.quotation_lines(
 id uuid primary key default gen_random_uuid(),business_id uuid not null references public.businesses(id) on delete cascade,
 quotation_id uuid not null references public.quotations(id) on delete cascade,description text not null,
 quantity numeric(14,3) not null check(quantity>0),unit_price numeric(14,2) not null check(unit_price>=0),
 direct_cost numeric(14,2) not null default 0 check(direct_cost>=0),line_total numeric(14,2) not null check(line_total>=0),
 details jsonb not null default '{}'::jsonb
);
create table public.sales_invoices(
 id uuid primary key default gen_random_uuid(),business_id uuid not null references public.businesses(id) on delete cascade,
 customer_id uuid not null references public.customers(id),invoice_number text not null,
 status text not null default 'draft' check(status in('draft','sent','partially_paid','paid','overdue','void')),
 issue_date date not null default current_date,due_date date,total numeric(14,2) not null default 0,
 amount_paid numeric(14,2) not null default 0,balance numeric(14,2) not null default 0,
 created_by uuid not null references auth.users(id),created_at timestamptz not null default now(),unique(business_id,invoice_number)
);
create table public.sales_invoice_items(
 id uuid primary key default gen_random_uuid(),business_id uuid not null references public.businesses(id) on delete cascade,
 invoice_id uuid not null references public.sales_invoices(id) on delete cascade,description text not null,
 quantity numeric(14,3) not null check(quantity>0),unit_price numeric(14,2) not null check(unit_price>=0),
 line_total numeric(14,2) not null check(line_total>=0),
 item_type text not null default 'service' check(item_type in('blank_product','printing_service','custom_production','other'))
);
create table public.production_jobs(
 id uuid primary key default gen_random_uuid(),business_id uuid not null references public.businesses(id) on delete cascade,
 invoice_id uuid references public.sales_invoices(id),quotation_id uuid references public.quotations(id),
 customer_id uuid not null references public.customers(id),job_number text not null,job_name text not null,
 stage text not null default 'awaiting_artwork' check(stage in('awaiting_artwork','artwork_proof','screens_prepared','printing','finishing','quality_check','ready','delivered','cancelled')),
 due_at timestamptz,delivered_at timestamptz,customer_supplied_items boolean not null default false,notes text,
 created_at timestamptz not null default now(),unique(business_id,job_number)
);
create table public.inventory_locations(
 id uuid primary key default gen_random_uuid(),business_id uuid not null references public.businesses(id) on delete cascade,
 location_code text not null check(location_code in('shop_1','shop_2')),location_name text not null,unique(business_id,location_code)
);
create table public.stock_items(
 id uuid primary key default gen_random_uuid(),business_id uuid not null references public.businesses(id) on delete cascade,
 location_id uuid not null references public.inventory_locations(id),sku text,item_name text not null,category text not null,
 unit text not null default 'piece',quantity_on_hand numeric(14,3) not null default 0 check(quantity_on_hand>=0),
 reorder_level numeric(14,3) not null default 0 check(reorder_level>=0),average_unit_cost numeric(14,2) not null default 0 check(average_unit_cost>=0),active boolean not null default true
);
create table public.stock_movements(
 id uuid primary key default gen_random_uuid(),business_id uuid not null references public.businesses(id) on delete cascade,
 stock_item_id uuid not null references public.stock_items(id),movement_type text not null check(movement_type in('opening','purchase','job_issue','transfer_in','transfer_out','adjustment','offcut_return')),
 quantity numeric(14,3) not null check(quantity<>0),unit_cost numeric(14,2) not null default 0 check(unit_cost>=0),
 created_by uuid not null references auth.users(id),created_at timestamptz not null default now()
);
create table public.suppliers(
 id uuid primary key default gen_random_uuid(),business_id uuid not null references public.businesses(id) on delete cascade,
 supplier_name text not null,phone text,email text,notes text
);
create table public.purchase_orders(
 id uuid primary key default gen_random_uuid(),business_id uuid not null references public.businesses(id) on delete cascade,
 supplier_id uuid not null references public.suppliers(id),po_number text not null,
 status text not null default 'draft' check(status in('draft','sent','part_received','received','cancelled')),
 total numeric(14,2) not null default 0,transport_cost numeric(14,2) not null default 0,created_at timestamptz not null default now(),unique(business_id,po_number)
);
create table public.purchase_order_lines(
 id uuid primary key default gen_random_uuid(),business_id uuid not null references public.businesses(id) on delete cascade,
 purchase_order_id uuid not null references public.purchase_orders(id) on delete cascade,item_description text not null,
 quantity numeric(14,3) not null check(quantity>0),unit_cost numeric(14,2) not null check(unit_cost>=0),received_quantity numeric(14,3) not null default 0
);
create table public.payments(
 id uuid primary key default gen_random_uuid(),business_id uuid not null references public.businesses(id) on delete cascade,
 customer_id uuid not null references public.customers(id),payment_number text not null,
 method text not null check(method in('cash','mpesa_paybill')),amount numeric(14,2) not null check(amount>0),
 reference_code text,received_at timestamptz not null default now(),received_by uuid not null references auth.users(id),unique(business_id,payment_number)
);
create table public.payment_allocations(
 id uuid primary key default gen_random_uuid(),business_id uuid not null references public.businesses(id) on delete cascade,
 payment_id uuid not null references public.payments(id),invoice_id uuid not null references public.sales_invoices(id),
 amount numeric(14,2) not null check(amount>0),allocated_at timestamptz not null default now(),unique(payment_id,invoice_id)
);
create table public.refunds(
 id uuid primary key default gen_random_uuid(),business_id uuid not null references public.businesses(id) on delete cascade,
 payment_id uuid not null references public.payments(id),amount numeric(14,2) not null check(amount>0),reason text not null,
 status text not null default 'pending' check(status in('pending','posted','rejected')),
 created_by uuid not null references auth.users(id),posted_by uuid references auth.users(id),created_at timestamptz not null default now(),posted_at timestamptz
);
create table public.expenses(
 id uuid primary key default gen_random_uuid(),business_id uuid not null references public.businesses(id) on delete cascade,
 expense_date date not null default current_date,category text not null,description text not null,
 amount numeric(14,2) not null check(amount>0),payment_method text not null check(payment_method in('cash','mpesa_paybill')),
 created_by uuid not null references auth.users(id),created_at timestamptz not null default now()
);
create table public.audit_events(
 id uuid primary key default gen_random_uuid(),business_id uuid not null references public.businesses(id) on delete cascade,
 actor_user_id uuid references auth.users(id),event_type text not null,entity_type text not null,entity_id uuid,
 details jsonb not null default '{}'::jsonb,created_at timestamptz not null default now()
);

do $$ declare t text;begin
 foreach t in array array['businesses','business_memberships','business_settings','customers','customer_contacts','customer_addresses','costing_profiles','quotations','quotation_lines','sales_invoices','sales_invoice_items','production_jobs','inventory_locations','stock_items','stock_movements','suppliers','purchase_orders','purchase_order_lines','payments','payment_allocations','refunds','expenses','audit_events']
 loop execute format('alter table public.%I enable row level security',t);end loop;
end $$;
create policy businesses_read_member on public.businesses for select to authenticated using(exists(select 1 from public.business_memberships m where m.business_id=id and m.user_id=(select auth.uid())));
create policy businesses_bootstrap_insert on public.businesses for insert to authenticated with check(created_by=(select auth.uid()) and not exists(select 1 from public.business_memberships));
create policy memberships_read_self on public.business_memberships for select to authenticated using(user_id=(select auth.uid()));
create policy memberships_bootstrap_insert on public.business_memberships for insert to authenticated with check(user_id=(select auth.uid()) and role='owner' and not exists(select 1 from public.business_memberships));
do $$ declare t text;begin
 foreach t in array array['business_settings','customers','customer_contacts','customer_addresses','costing_profiles','inventory_locations']
 loop execute format('create policy %I on public.%I for all to authenticated using(business_id in(select business_id from public.business_memberships where user_id=(select auth.uid()) and role=''owner'')) with check(business_id in(select business_id from public.business_memberships where user_id=(select auth.uid()) and role=''owner''))',t||'_owner_access',t);end loop;
 foreach t in array array['quotations','quotation_lines','sales_invoices','sales_invoice_items','production_jobs','stock_items','stock_movements','suppliers','purchase_orders','purchase_order_lines','payments','payment_allocations','refunds','expenses','audit_events']
 loop execute format('create policy %I on public.%I for select to authenticated using(business_id in(select business_id from public.business_memberships where user_id=(select auth.uid())))',t||'_member_read',t);end loop;
end $$;
grant usage on schema public to authenticated;
grant select,insert,update,delete on table public.businesses,public.business_memberships,public.business_settings,public.customers,public.customer_contacts,public.customer_addresses,public.costing_profiles,public.quotations,public.quotation_lines,public.sales_invoices,public.sales_invoice_items,public.production_jobs,public.inventory_locations,public.stock_items,public.stock_movements,public.suppliers,public.purchase_orders,public.purchase_order_lines,public.payments,public.payment_allocations,public.refunds,public.expenses,public.audit_events to authenticated;

create or replace function public.owner_bootstrap_workspace() returns jsonb
language plpgsql security invoker set search_path=public,pg_temp as $$
declare b public.businesses%rowtype;
begin
 if (select auth.uid()) is null then raise exception 'Authentication required';end if;
 select x.* into b from public.businesses x join public.business_memberships m on m.business_id=x.id where m.user_id=(select auth.uid()) limit 1;
 if not found then
  insert into public.businesses(business_name,business_slug,created_by) values('MJ Printing & Branding','mj-tees',(select auth.uid())) returning * into b;
  insert into public.business_memberships(business_id,user_id,role) values(b.id,(select auth.uid()),'owner');
  insert into public.business_settings(business_id) values(b.id);
  insert into public.inventory_locations(business_id,location_code,location_name) values(b.id,'shop_1','Shop 1 — Apparel, vinyl & stickers'),(b.id,'shop_2','Shop 2 — Inks, screens & consumables');
 end if;
 return jsonb_build_object('business_id',b.id,'business_name',b.business_name,'business_slug',b.business_slug,'currency',b.currency,'timezone',b.timezone);
end $$;
revoke all on function public.owner_bootstrap_workspace() from public,anon;
grant execute on function public.owner_bootstrap_workspace() to authenticated;

create or replace function public.owner_dashboard_summary() returns jsonb
language sql stable security invoker set search_path=public,pg_temp as $$
 with mine as(select business_id from public.business_memberships where user_id=(select auth.uid()) limit 1)
 select jsonb_build_object(
 'sales_this_month',coalesce((select sum(total) from public.sales_invoices i,mine m where i.business_id=m.business_id and i.status not in('draft','void') and i.issue_date>=date_trunc('month',current_date)::date),0),
 'outstanding_amount',coalesce((select sum(balance) from public.sales_invoices i,mine m where i.business_id=m.business_id and i.status not in('draft','void') and balance>0),0),
 'active_jobs',coalesce((select count(*) from public.production_jobs j,mine m where j.business_id=m.business_id and j.stage not in('delivered','cancelled')),0),
 'low_stock_items',coalesce((select count(*) from public.stock_items s,mine m where s.business_id=m.business_id and s.active and s.quantity_on_hand<=s.reorder_level),0));
$$;
revoke all on function public.owner_dashboard_summary() from public,anon;
grant execute on function public.owner_dashboard_summary() to authenticated;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('mj-job-artwork','mj-job-artwork',false,52428800,array['image/png','image/jpeg','image/webp','application/pdf','image/svg+xml'])
on conflict(id) do update set public=false,file_size_limit=52428800,allowed_mime_types=excluded.allowed_mime_types;
create policy mj_artwork_read on storage.objects for select to authenticated using(bucket_id='mj-job-artwork' and split_part(name,'/',1) in(select business_id::text from public.business_memberships where user_id=(select auth.uid())));
create policy mj_artwork_insert on storage.objects for insert to authenticated with check(bucket_id='mj-job-artwork' and split_part(name,'/',1) in(select business_id::text from public.business_memberships where user_id=(select auth.uid())));
create policy mj_artwork_update on storage.objects for update to authenticated using(bucket_id='mj-job-artwork' and split_part(name,'/',1) in(select business_id::text from public.business_memberships where user_id=(select auth.uid()))) with check(bucket_id='mj-job-artwork' and split_part(name,'/',1) in(select business_id::text from public.business_memberships where user_id=(select auth.uid())));
create policy mj_artwork_delete on storage.objects for delete to authenticated using(bucket_id='mj-job-artwork' and split_part(name,'/',1) in(select business_id::text from public.business_memberships where user_id=(select auth.uid())));
