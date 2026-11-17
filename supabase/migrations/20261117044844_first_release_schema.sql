-- MJ Printing & Branding — first-release schema foundation
-- Generated migration filename by Supabase CLI on 2026-11-17.
-- This migration is intentionally limited to schema, integrity constraints and read boundaries.
-- No owner is provisioned here. No live project is targeted by this file.
-- Operational write RPCs and Edge Function ingress must be added and tested before launch.

begin;

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

create extension if not exists pgcrypto with schema extensions;

create table public.businesses (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(btrim(name)) between 1 and 160),
  trading_name text,
  currency_code char(3) not null default 'KES' check (currency_code = 'KES'),
  timezone text not null default 'Africa/Nairobi',
  phone text,
  email text,
  address text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id)
);

create table public.user_profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  display_name text,
  phone text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.business_memberships (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  user_id uuid not null references auth.users(id) on delete restrict,
  role text not null check (role = 'owner'),
  status text not null default 'active' check (status in ('active','suspended')),
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id) on delete restrict,
  unique (business_id,user_id),
  unique (business_id,id)
);

create table public.audit_events (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  actor_user_id uuid references auth.users(id) on delete restrict,
  action text not null,
  entity_type text not null,
  entity_id uuid,
  request_id uuid,
  occurred_at timestamptz not null default now(),
  metadata jsonb not null default '{}'::jsonb check (jsonb_typeof(metadata) = 'object'),
  unique (business_id,id)
);

create table public.service_categories (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  name text not null check (length(btrim(name)) between 1 and 120),
  slug text not null check (slug ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$'),
  description text,
  costing_method text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (business_id,id),
  unique (business_id,slug)
);

create table public.catalogue_items (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  category_id uuid,
  name text not null check (length(btrim(name)) between 1 and 160),
  slug text not null check (slug ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$'),
  item_type text not null check (item_type in ('product','service')),
  description text,
  public_starting_price bigint check (public_starting_price >= 0),
  is_published boolean not null default false,
  is_active boolean not null default true,
  display_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (business_id,id),
  unique (business_id,slug),
  foreign key (business_id,category_id) references public.service_categories(business_id,id) on delete restrict
);

create table public.enquiries (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  public_reference text not null unique,
  contact_name text not null,
  phone text,
  email text,
  requested_service text not null,
  description text not null,
  quantity numeric(12,3) check (quantity is null or quantity > 0),
  desired_by date,
  customer_supplies_item boolean not null default false,
  artwork_drive_url text,
  status text not null default 'new' check (status in ('new','reviewing','quoted','closed','spam')),
  created_at timestamptz not null default now(),
  reviewed_at timestamptz,
  reviewed_by uuid references auth.users(id) on delete restrict,
  check (phone is not null or email is not null),
  unique (business_id,id)
);

create table public.customers (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  display_name text not null check (length(btrim(display_name)) between 1 and 180),
  business_name text,
  phone text,
  phone_normalized text,
  email text,
  notes text,
  archived_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid not null references auth.users(id) on delete restrict,
  unique (business_id,id)
);
create index customers_phone_idx on public.customers(business_id,phone_normalized);

create table public.customer_addresses (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  customer_id uuid not null,
  label text,
  recipient_name text,
  phone text,
  address_text text not null,
  locality text,
  is_default boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (business_id,customer_id) references public.customers(business_id,id) on delete restrict,
  unique (business_id,id)
);

create table public.pricing_rules (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  category_id uuid,
  catalogue_item_id uuid,
  name text not null,
  cost_basis text not null,
  markup_method text not null check (markup_method in ('percentage_on_cost','margin_on_price','fixed_amount','manual')),
  markup_value numeric(12,4),
  effective_from date not null,
  effective_to date,
  is_active boolean not null default true,
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  check (effective_to is null or effective_to >= effective_from),
  foreign key (business_id,category_id) references public.service_categories(business_id,id) on delete restrict,
  foreign key (business_id,catalogue_item_id) references public.catalogue_items(business_id,id) on delete restrict,
  unique (business_id,id)
);

create table public.quotations (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  quote_number text not null,
  customer_id uuid not null,
  enquiry_id uuid,
  revision_of uuid,
  status text not null default 'draft' check (status in ('draft','sent','accepted','declined','expired','converted','cancelled')),
  issued_at timestamptz,
  expires_at timestamptz,
  accepted_at timestamptz,
  currency_code char(3) not null default 'KES' check (currency_code = 'KES'),
  subtotal_amount bigint not null default 0 check (subtotal_amount >= 0),
  discount_amount bigint not null default 0 check (discount_amount >= 0),
  total_amount bigint not null default 0 check (total_amount >= 0 and total_amount = subtotal_amount - discount_amount),
  customer_notes text,
  internal_notes text,
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (business_id,customer_id) references public.customers(business_id,id) on delete restrict,
  foreign key (business_id,enquiry_id) references public.enquiries(business_id,id) on delete restrict,
  foreign key (business_id,revision_of) references public.quotations(business_id,id) on delete restrict,
  unique (business_id,id),
  unique (business_id,quote_number)
);

create table public.production_methods (
  id uuid primary key default gen_random_uuid(),
  code text not null unique check (code ~ '^[a-z][a-z0-9_]*$'),
  name text not null,
  configuration jsonb not null default '{}'::jsonb check (jsonb_typeof(configuration) = 'object'),
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.quotation_items (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  quotation_id uuid not null,
  catalogue_item_id uuid,
  category_id uuid,
  description text not null,
  quantity numeric(12,3) not null check (quantity > 0),
  unit text not null,
  unit_price bigint not null check (unit_price >= 0),
  line_discount bigint not null default 0 check (line_discount >= 0),
  line_total bigint not null check (line_total >= 0),
  customer_supplies_item boolean not null default false,
  sale_mode text not null check (sale_mode in ('blank','value_added')),
  production_method_id uuid references public.production_methods(id) on delete restrict,
  production_specification jsonb,
  pricing_snapshot jsonb,
  cost_estimate_snapshot jsonb,
  created_at timestamptz not null default now(),
  foreign key (business_id,quotation_id) references public.quotations(business_id,id) on delete restrict,
  foreign key (business_id,catalogue_item_id) references public.catalogue_items(business_id,id) on delete restrict,
  foreign key (business_id,category_id) references public.service_categories(business_id,id) on delete restrict,
  unique (business_id,id),
  check (line_discount <= quantity * unit_price)
);

create table public.quotation_events (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  quotation_id uuid not null,
  event_type text not null check (event_type in ('created','sent','viewed','accepted','declined','expired','revised','converted','cancelled')),
  actor_user_id uuid references auth.users(id) on delete restrict,
  source text not null check (source in ('owner','customer_link','system')),
  reason text,
  occurred_at timestamptz not null default now(),
  foreign key (business_id,quotation_id) references public.quotations(business_id,id) on delete restrict,
  unique (business_id,id)
);

create table public.orders (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  order_number text not null,
  customer_id uuid not null,
  quotation_id uuid,
  status text not null default 'confirmed' check (status in ('confirmed','in_production','quality_check','ready','completed','cancelled')),
  currency_code char(3) not null default 'KES' check (currency_code = 'KES'),
  subtotal_amount bigint not null check (subtotal_amount >= 0),
  discount_amount bigint not null default 0 check (discount_amount >= 0),
  total_amount bigint not null check (total_amount >= 0 and total_amount = subtotal_amount - discount_amount),
  received_at timestamptz not null default now(),
  required_by date,
  promised_turnaround_hours integer check (promised_turnaround_hours is null or promised_turnaround_hours > 0),
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (business_id,customer_id) references public.customers(business_id,id) on delete restrict,
  foreign key (business_id,quotation_id) references public.quotations(business_id,id) on delete restrict,
  unique (business_id,id),
  unique (business_id,order_number)
);

create table public.order_items (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  order_id uuid not null,
  description text not null,
  quantity numeric(12,3) not null check (quantity > 0),
  unit text not null,
  unit_price bigint not null check (unit_price >= 0),
  line_discount bigint not null default 0 check (line_discount >= 0),
  line_total bigint not null check (line_total >= 0),
  category_id uuid,
  customer_supplies_item boolean not null default false,
  sale_mode text not null check (sale_mode in ('blank','value_added')),
  production_method_id uuid references public.production_methods(id) on delete restrict,
  production_specification jsonb,
  estimated_unit_cost bigint check (estimated_unit_cost is null or estimated_unit_cost >= 0),
  actual_unit_cost bigint check (actual_unit_cost is null or actual_unit_cost >= 0),
  estimated_total_cost bigint check (estimated_total_cost is null or estimated_total_cost >= 0),
  actual_total_cost bigint check (actual_total_cost is null or actual_total_cost >= 0),
  cost_breakdown_snapshot jsonb,
  cost_calculation_version text,
  created_at timestamptz not null default now(),
  foreign key (business_id,order_id) references public.orders(business_id,id) on delete restrict,
  foreign key (business_id,category_id) references public.service_categories(business_id,id) on delete restrict,
  unique (business_id,id),
  check (line_discount <= quantity * unit_price)
);

create table public.order_item_discount_allocations (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  order_id uuid not null,
  order_item_id uuid not null,
  discount_source text not null check (discount_source in ('line_discount','order_discount')),
  pre_discount_line_amount bigint not null check (pre_discount_line_amount >= 0),
  allocated_discount_amount bigint not null check (allocated_discount_amount >= 0),
  allocation_version text not null,
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id) on delete restrict,
  foreign key (business_id,order_id) references public.orders(business_id,id) on delete restrict,
  foreign key (business_id,order_item_id) references public.order_items(business_id,id) on delete restrict,
  unique (business_id,id)
);

create table public.order_events (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  order_id uuid not null,
  event_type text not null,
  from_status text,
  to_status text,
  actor_user_id uuid references auth.users(id) on delete restrict,
  reason text,
  occurred_at timestamptz not null default now(),
  foreign key (business_id,order_id) references public.orders(business_id,id) on delete restrict,
  unique (business_id,id)
);

create table public.payments (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  payment_number text not null,
  method text not null check (method in ('cash','mpesa_manual')),
  status text not null check (status in ('pending_verification','posted','rejected','reversed')),
  amount bigint not null check (amount > 0),
  currency_code char(3) not null default 'KES' check (currency_code = 'KES'),
  received_at timestamptz not null,
  payer_name text,
  payer_phone text,
  mpesa_reference text,
  mpesa_reference_normalized text,
  intended_order_id uuid,
  idempotency_key uuid not null,
  received_by uuid not null references auth.users(id) on delete restrict,
  verified_by uuid references auth.users(id) on delete restrict,
  verified_at timestamptz,
  notes text,
  created_at timestamptz not null default now(),
  foreign key (business_id,intended_order_id) references public.orders(business_id,id) on delete restrict,
  unique (business_id,id),
  unique (business_id,payment_number),
  unique (business_id,idempotency_key),
  check ((method = 'cash' and status = 'posted' and mpesa_reference is null) or
         (method = 'mpesa_manual' and mpesa_reference is not null and
          ((status = 'pending_verification' and verified_at is null) or status in ('posted','rejected','reversed'))))
);
create unique index payments_mpesa_reference_uq on public.payments(business_id,mpesa_reference_normalized)
where method = 'mpesa_manual' and mpesa_reference_normalized is not null;

create table public.payment_allocations (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  payment_id uuid not null,
  order_id uuid not null,
  amount bigint not null check (amount > 0),
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  foreign key (business_id,payment_id) references public.payments(business_id,id) on delete restrict,
  foreign key (business_id,order_id) references public.orders(business_id,id) on delete restrict,
  unique (business_id,id)
);

create table public.allocation_reversals (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  allocation_id uuid not null,
  amount bigint not null check (amount > 0),
  reason text not null check (length(btrim(reason)) > 0),
  reversed_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  foreign key (business_id,allocation_id) references public.payment_allocations(business_id,id) on delete restrict,
  unique (business_id,id)
);

create table public.payment_refunds (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  payment_id uuid not null,
  order_id uuid,
  allocation_id uuid,
  source_bucket text not null check (source_bucket in ('allocated','unallocated')),
  amount bigint not null check (amount > 0),
  status text not null check (status in ('pending','posted','cancelled')),
  reason text not null check (length(btrim(reason)) > 0),
  refund_method text not null check (refund_method in ('cash','mpesa')),
  external_reference text,
  created_by uuid not null references auth.users(id) on delete restrict,
  posted_by uuid references auth.users(id) on delete restrict,
  posted_at timestamptz,
  created_at timestamptz not null default now(),
  foreign key (business_id,payment_id) references public.payments(business_id,id) on delete restrict,
  foreign key (business_id,order_id) references public.orders(business_id,id) on delete restrict,
  foreign key (business_id,allocation_id) references public.payment_allocations(business_id,id) on delete restrict,
  unique (business_id,id),
  check ((source_bucket = 'allocated' and allocation_id is not null and order_id is not null) or
         (source_bucket = 'unallocated' and allocation_id is null and order_id is null)),
  check ((status = 'posted' and posted_at is not null and posted_by is not null) or status <> 'posted')
);

create table public.payment_events (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  payment_id uuid not null,
  event_type text not null check (event_type in ('created','verified','rejected','reversed','refund_posted','allocation_reversed')),
  actor_user_id uuid references auth.users(id) on delete restrict,
  reason text,
  metadata jsonb not null default '{}'::jsonb check (jsonb_typeof(metadata) = 'object'),
  occurred_at timestamptz not null default now(),
  foreign key (business_id,payment_id) references public.payments(business_id,id) on delete restrict,
  unique (business_id,id)
);

create table public.receipts (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  receipt_number text not null,
  payment_id uuid not null,
  customer_name_snapshot text not null,
  amount bigint not null check (amount > 0),
  currency_code char(3) not null default 'KES' check (currency_code = 'KES'),
  issued_at timestamptz not null default now(),
  issued_by uuid not null references auth.users(id) on delete restrict,
  foreign key (business_id,payment_id) references public.payments(business_id,id) on delete restrict,
  unique (business_id,id),
  unique (business_id,receipt_number),
  unique (business_id,payment_id)
);

create table public.document_counters (
  business_id uuid not null references public.businesses(id) on delete restrict,
  document_type text not null check (document_type in ('quote','order','payment','receipt','purchase')),
  next_value bigint not null default 1 check (next_value > 0),
  prefix text not null,
  updated_at timestamptz not null default now(),
  primary key (business_id,document_type)
);

create table public.inventory_locations (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  name text not null,
  code text not null,
  description text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (business_id,id),
  unique (business_id,code)
);

create table public.suppliers (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  display_name text not null,
  contact_name text,
  phone text,
  email text,
  notes text,
  archived_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (business_id,id)
);

create table public.stock_items (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  parent_stock_item_id uuid,
  sku text not null,
  name text not null,
  variant_attributes jsonb not null default '{}'::jsonb check (jsonb_typeof(variant_attributes) = 'object'),
  stock_kind text not null check (stock_kind in ('blank_product','material','consumable','packaging')),
  base_unit text not null,
  purchase_unit text not null,
  purchase_to_base_factor numeric(12,6) not null check (purchase_to_base_factor > 0),
  roll_width_mm numeric(12,3),
  usable_width_mm numeric(12,3),
  costing_method text not null default 'weighted_average' check (costing_method = 'weighted_average'),
  current_average_unit_cost bigint not null default 0 check (current_average_unit_cost >= 0),
  reorder_level numeric(12,3) not null default 0 check (reorder_level >= 0),
  default_supplier_id uuid,
  is_active boolean not null default true,
  archived_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (business_id,parent_stock_item_id) references public.stock_items(business_id,id) on delete restrict,
  foreign key (business_id,default_supplier_id) references public.suppliers(business_id,id) on delete restrict,
  unique (business_id,id),
  unique (business_id,sku),
  check ((roll_width_mm is null and usable_width_mm is null) or
         (roll_width_mm > 0 and usable_width_mm > 0 and usable_width_mm <= roll_width_mm))
);

create table public.stock_movements (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  stock_item_id uuid not null,
  location_id uuid not null,
  movement_type text not null check (movement_type in ('opening','receipt','issue','return','adjustment','transfer_in','transfer_out')),
  quantity numeric(12,3) not null check (quantity <> 0),
  unit_cost_snapshot bigint not null check (unit_cost_snapshot >= 0),
  source_type text not null,
  source_id uuid,
  stock_transfer_id uuid,
  reason text,
  actor_user_id uuid not null references auth.users(id) on delete restrict,
  request_id uuid not null,
  occurred_at timestamptz not null default now(),
  foreign key (business_id,stock_item_id) references public.stock_items(business_id,id) on delete restrict,
  foreign key (business_id,location_id) references public.inventory_locations(business_id,id) on delete restrict,
  unique (business_id,id),
  unique (business_id,request_id),
  check ((movement_type in ('opening','receipt','return','transfer_in') and quantity > 0) or
         (movement_type in ('issue','transfer_out') and quantity < 0) or movement_type = 'adjustment')
);
create index stock_movements_balance_idx on public.stock_movements(business_id,stock_item_id,location_id,occurred_at);

create table public.stock_reservations (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  order_item_id uuid not null,
  stock_item_id uuid not null,
  location_id uuid not null,
  reserved_quantity numeric(12,3) not null check (reserved_quantity > 0),
  released_quantity numeric(12,3) not null default 0 check (released_quantity >= 0 and released_quantity <= reserved_quantity),
  status text not null default 'active' check (status in ('active','released','consumed','cancelled')),
  created_at timestamptz not null default now(),
  released_at timestamptz,
  foreign key (business_id,order_item_id) references public.order_items(business_id,id) on delete restrict,
  foreign key (business_id,stock_item_id) references public.stock_items(business_id,id) on delete restrict,
  foreign key (business_id,location_id) references public.inventory_locations(business_id,id) on delete restrict,
  unique (business_id,id)
);

create table public.stock_transfers (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  stock_item_id uuid not null,
  source_location_id uuid not null,
  destination_location_id uuid not null,
  quantity numeric(12,3) not null check (quantity > 0),
  unit_cost_snapshot bigint not null check (unit_cost_snapshot >= 0),
  request_id uuid not null,
  actor_user_id uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  foreign key (business_id,stock_item_id) references public.stock_items(business_id,id) on delete restrict,
  foreign key (business_id,source_location_id) references public.inventory_locations(business_id,id) on delete restrict,
  foreign key (business_id,destination_location_id) references public.inventory_locations(business_id,id) on delete restrict,
  unique (business_id,id),
  unique (business_id,request_id),
  check (source_location_id <> destination_location_id)
);

create table public.purchase_orders (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  supplier_id uuid not null,
  purchase_number text not null,
  status text not null default 'draft' check (status in ('draft','ordered','part_received','received','cancelled')),
  notes text,
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (business_id,supplier_id) references public.suppliers(business_id,id) on delete restrict,
  unique (business_id,id),
  unique (business_id,purchase_number)
);

create table public.purchase_order_items (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  purchase_order_id uuid not null,
  stock_item_id uuid not null,
  ordered_quantity numeric(12,3) not null check (ordered_quantity > 0),
  purchase_unit text not null,
  purchase_to_base_factor numeric(12,6) not null check (purchase_to_base_factor > 0),
  unit_price bigint not null check (unit_price >= 0),
  line_total bigint not null check (line_total >= 0),
  created_at timestamptz not null default now(),
  foreign key (business_id,purchase_order_id) references public.purchase_orders(business_id,id) on delete restrict,
  foreign key (business_id,stock_item_id) references public.stock_items(business_id,id) on delete restrict,
  unique (business_id,id)
);

create table public.goods_receipts (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  purchase_order_id uuid not null,
  received_by uuid not null references auth.users(id) on delete restrict,
  received_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  foreign key (business_id,purchase_order_id) references public.purchase_orders(business_id,id) on delete restrict,
  unique (business_id,id)
);

create table public.goods_receipt_items (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  goods_receipt_id uuid not null,
  purchase_order_item_id uuid not null,
  stock_item_id uuid not null,
  location_id uuid not null,
  accepted_quantity numeric(12,3) not null check (accepted_quantity >= 0),
  rejected_quantity numeric(12,3) not null default 0 check (rejected_quantity >= 0),
  purchase_unit text not null,
  purchase_to_base_factor numeric(12,6) not null check (purchase_to_base_factor > 0),
  actual_unit_cost bigint not null check (actual_unit_cost >= 0),
  stock_movement_id uuid,
  foreign key (business_id,goods_receipt_id) references public.goods_receipts(business_id,id) on delete restrict,
  foreign key (business_id,purchase_order_item_id) references public.purchase_order_items(business_id,id) on delete restrict,
  foreign key (business_id,stock_item_id) references public.stock_items(business_id,id) on delete restrict,
  foreign key (business_id,location_id) references public.inventory_locations(business_id,id) on delete restrict,
  unique (business_id,id)
);

create table public.product_costing_profiles (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  catalogue_item_id uuid,
  category_id uuid,
  sale_mode text not null check (sale_mode in ('blank','value_added')),
  production_method_id uuid references public.production_methods(id) on delete restrict,
  version integer not null check (version > 0),
  effective_from timestamptz not null default now(),
  effective_to timestamptz,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  foreign key (business_id,catalogue_item_id) references public.catalogue_items(business_id,id) on delete restrict,
  foreign key (business_id,category_id) references public.service_categories(business_id,id) on delete restrict,
  unique (business_id,id),
  check (catalogue_item_id is not null or category_id is not null),
  check (effective_to is null or effective_to > effective_from)
);

create table public.costing_components (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  profile_id uuid not null,
  component_type text not null check (component_type in ('blank_item','meter_material','area_material','consumable','machine_time','labour_time','outsourced_service','setup','packaging','other')),
  stock_item_id uuid,
  unit text not null,
  driver_type text not null check (driver_type in ('per_piece','per_order','per_metre','per_square_metre','per_minute','per_hour','fixed_setup','manual')),
  factor numeric(12,4) not null default 1 check (factor >= 0),
  expected_waste_percent numeric(7,4) not null default 0 check (expected_waste_percent >= 0 and expected_waste_percent <= 100),
  fixed_cost bigint not null default 0 check (fixed_cost >= 0),
  created_at timestamptz not null default now(),
  foreign key (business_id,profile_id) references public.product_costing_profiles(business_id,id) on delete restrict,
  foreign key (business_id,stock_item_id) references public.stock_items(business_id,id) on delete restrict,
  unique (business_id,id)
);

create table public.production_jobs (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  order_item_id uuid not null,
  production_method_id uuid not null references public.production_methods(id) on delete restrict,
  status text not null default 'planned' check (status in ('planned','in_progress','quality_check','rework','completed','cancelled')),
  planned_quantity numeric(12,3) not null check (planned_quantity > 0),
  started_at timestamptz,
  due_at timestamptz,
  completed_at timestamptz,
  estimated_cost_total bigint check (estimated_cost_total is null or estimated_cost_total >= 0),
  actual_cost_total bigint check (actual_cost_total is null or actual_cost_total >= 0),
  calculation_version text,
  notes text,
  created_at timestamptz not null default now(),
  foreign key (business_id,order_item_id) references public.order_items(business_id,id) on delete restrict,
  unique (business_id,id)
);

create table public.production_material_issues (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  job_id uuid not null,
  stock_item_id uuid not null,
  location_id uuid not null,
  quantity_issued numeric(12,3) not null check (quantity_issued > 0),
  unit_cost_snapshot bigint not null check (unit_cost_snapshot >= 0),
  extended_cost bigint not null check (extended_cost >= 0),
  stock_movement_id uuid not null,
  issued_at timestamptz not null default now(),
  actor_user_id uuid not null references auth.users(id) on delete restrict,
  foreign key (business_id,job_id) references public.production_jobs(business_id,id) on delete restrict,
  foreign key (business_id,stock_item_id) references public.stock_items(business_id,id) on delete restrict,
  foreign key (business_id,location_id) references public.inventory_locations(business_id,id) on delete restrict,
  foreign key (business_id,stock_movement_id) references public.stock_movements(business_id,id) on delete restrict,
  unique (business_id,id),
  unique (business_id,stock_movement_id)
);

create table public.production_waste (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  job_id uuid not null,
  issue_id uuid not null,
  quantity numeric(12,3) not null check (quantity > 0),
  waste_type text not null,
  reason text not null,
  created_at timestamptz not null default now(),
  foreign key (business_id,job_id) references public.production_jobs(business_id,id) on delete restrict,
  foreign key (business_id,issue_id) references public.production_material_issues(business_id,id) on delete restrict,
  unique (business_id,id)
);

create table public.production_offcut_returns (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  job_id uuid not null,
  issue_id uuid not null,
  quantity numeric(12,3) not null check (quantity > 0),
  destination_location_id uuid not null,
  stock_movement_id uuid not null,
  condition text not null check (condition in ('usable','damaged')),
  returned_at timestamptz not null default now(),
  foreign key (business_id,job_id) references public.production_jobs(business_id,id) on delete restrict,
  foreign key (business_id,issue_id) references public.production_material_issues(business_id,id) on delete restrict,
  foreign key (business_id,destination_location_id) references public.inventory_locations(business_id,id) on delete restrict,
  foreign key (business_id,stock_movement_id) references public.stock_movements(business_id,id) on delete restrict,
  unique (business_id,id),
  unique (business_id,stock_movement_id)
);

create table public.production_cost_entries (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  job_id uuid not null,
  cost_type text not null check (cost_type in ('labour','machine','setup','outsourced','other')),
  description text not null,
  quantity numeric(12,3) not null check (quantity > 0),
  unit text not null,
  unit_rate bigint not null check (unit_rate >= 0),
  amount bigint not null check (amount >= 0),
  occurred_at timestamptz not null default now(),
  actor_user_id uuid not null references auth.users(id) on delete restrict,
  foreign key (business_id,job_id) references public.production_jobs(business_id,id) on delete restrict,
  unique (business_id,id)
);

create table public.quality_checks (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  job_id uuid not null,
  result text not null check (result in ('pass','fail')),
  inspection_mode text not null check (inspection_mode in ('second_person','self')),
  inspector_user_id uuid not null references auth.users(id) on delete restrict,
  checked_at timestamptz not null default now(),
  notes text,
  foreign key (business_id,job_id) references public.production_jobs(business_id,id) on delete restrict,
  unique (business_id,id)
);

create table public.rework_events (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  job_id uuid not null,
  quality_check_id uuid not null,
  reason text not null,
  opened_at timestamptz not null default now(),
  closed_at timestamptz,
  additional_cost_snapshot bigint not null default 0 check (additional_cost_snapshot >= 0),
  notes text,
  foreign key (business_id,job_id) references public.production_jobs(business_id,id) on delete restrict,
  foreign key (business_id,quality_check_id) references public.quality_checks(business_id,id) on delete restrict,
  unique (business_id,id)
);

create table public.artwork_references (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  order_item_id uuid not null,
  drive_url text not null,
  drive_file_id text,
  filename text,
  version_label text not null,
  source text not null,
  approval_status text not null default 'pending' check (approval_status in ('pending','approved','rejected','superseded')),
  approved_by uuid references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (business_id,order_item_id) references public.order_items(business_id,id) on delete restrict,
  unique (business_id,id)
);

create table public.expense_categories (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  name text not null,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (business_id,id),
  unique (business_id,name)
);

create table public.expenses (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  category_id uuid not null,
  amount bigint not null check (amount > 0),
  expense_date date not null,
  payee text not null,
  payment_method text not null,
  receipt_reference text,
  notes text,
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  foreign key (business_id,category_id) references public.expense_categories(business_id,id) on delete restrict,
  unique (business_id,id)
);

create table public.deliveries (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  order_id uuid not null,
  method text not null check (method in ('collection','courier')),
  carrier text,
  tracking_reference text,
  customer_paid_charge bigint not null default 0 check (customer_paid_charge >= 0),
  recipient_name text,
  dispatched_at timestamptz,
  handed_over_at timestamptz,
  created_at timestamptz not null default now(),
  foreign key (business_id,order_id) references public.orders(business_id,id) on delete restrict,
  unique (business_id,id)
);

create table public.owner_approvals (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  approval_type text not null,
  entity_type text not null,
  entity_id uuid not null,
  reason text not null check (length(btrim(reason)) > 0),
  approved_by uuid not null references auth.users(id) on delete restrict,
  approved_at timestamptz not null default now(),
  request_id uuid not null,
  unique (business_id,id),
  unique (business_id,request_id)
);

create table private.quote_acceptance_tokens (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  quotation_id uuid not null,
  token_hash bytea not null unique,
  expires_at timestamptz not null,
  used_at timestamptz,
  created_at timestamptz not null default now(),
  foreign key (business_id,quotation_id) references public.quotations(business_id,id) on delete restrict
);

create table private.business_bootstrap (
  business_id uuid primary key references public.businesses(id) on delete restrict,
  completed_at timestamptz,
  completed_by uuid references auth.users(id) on delete restrict,
  target_user_id uuid references auth.users(id) on delete restrict,
  reason text,
  created_at timestamptz not null default now(),
  check ((completed_at is null and completed_by is null and target_user_id is null) or
         (completed_at is not null and completed_by is not null and target_user_id is not null and reason is not null))
);

-- Lookup helper: policies can see only rows belonging to an active owner membership.
create or replace function private.is_active_owner(p_business_id uuid)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public, auth
as $$
  select exists (
    select 1 from public.business_memberships m
    where m.business_id = p_business_id
      and m.user_id = (select auth.uid())
      and m.role = 'owner'
      and m.status = 'active'
  );
$$;
revoke all on function private.is_active_owner(uuid) from public, anon;
grant usage on schema private to authenticated;
grant execute on function private.is_active_owner(uuid) to authenticated;

-- RLS is enabled for every public business table. Reads are owner-only; all writes
-- remain closed until narrowly scoped transactional RPCs are introduced.
do $$
declare
  t text;
begin
  foreach t in array array[
    'businesses','business_memberships','audit_events','service_categories','catalogue_items',
    'enquiries','customers','customer_addresses','pricing_rules','quotations','quotation_items',
    'quotation_events','orders','order_items','order_item_discount_allocations','order_events',
    'payments','payment_allocations','allocation_reversals','payment_refunds','payment_events',
    'receipts','document_counters','inventory_locations','suppliers','stock_items','stock_movements',
    'stock_reservations','stock_transfers','purchase_orders','purchase_order_items','goods_receipts',
    'goods_receipt_items','product_costing_profiles','costing_components','production_jobs',
    'production_material_issues','production_waste','production_offcut_returns','production_cost_entries',
    'quality_checks','rework_events','artwork_references','expense_categories','expenses','deliveries',
    'owner_approvals'
  ]
  loop
    execute format('alter table public.%I enable row level security',t);
    execute format('revoke all on table public.%I from anon, authenticated',t);
    execute format('grant select on table public.%I to authenticated',t);
    execute format(
      'create policy %I on public.%I for select to authenticated using (private.is_active_owner(business_id))',
      t || '_owner_select',t
    );
  end loop;
end $$;

-- Profiles are user-scoped and contain no authorization fields.
alter table public.user_profiles enable row level security;
revoke all on public.user_profiles from anon, authenticated;
grant select on public.user_profiles to authenticated;
grant update (display_name,phone) on public.user_profiles to authenticated;
create policy user_profiles_select_self on public.user_profiles
for select to authenticated using (user_id = (select auth.uid()));
create policy user_profiles_update_self on public.user_profiles
for update to authenticated using (user_id = (select auth.uid()))
with check (user_id = (select auth.uid()));

-- Public catalogue projection exposes only published descriptive fields.
create or replace view public.public_catalogue
with (security_invoker = true)
as
select c.id, c.business_id, c.name, c.slug, c.item_type, c.description,
       c.public_starting_price, c.display_order,
       s.name as category_name, s.slug as category_slug
from public.catalogue_items c
left join public.service_categories s
  on s.business_id = c.business_id and s.id = c.category_id
where c.is_published = true and c.is_active = true
  and (s.id is null or (s.is_active = true));
revoke all on public.public_catalogue from public, anon, authenticated;
grant select on public.public_catalogue to anon, authenticated;

-- Public role has no direct table access. Authenticated owner reads are enabled above.
-- No membership bootstrap, public enquiry write, financial posting, stock mutation,
-- order conversion, or handover function is exposed by this migration.

commit;
