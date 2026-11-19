-- MJ Tees Sales foundation schema.
-- Additive only: existing customers, quotations, orders, stock, production and payments remain canonical.
-- VAT is intentionally excluded. All monetary values are KES integer shillings.
-- GitHub implementation only; this migration has not been applied to any database.

create table public.sales_price_tiers (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  code text not null check (code in ('retail','wholesale','reseller')),
  name text not null check (length(btrim(name)) between 1 and 80),
  description text,
  is_default boolean not null default false,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint sales_price_tiers_business_id_id_key unique (business_id,id),
  constraint sales_price_tiers_business_code_key unique (business_id,code)
);

create unique index sales_price_tiers_one_default_per_business
  on public.sales_price_tiers(business_id) where is_default;

insert into public.sales_price_tiers(business_id,code,name,description,is_default)
select b.id,v.code,v.name,v.description,(v.code='retail')
from public.businesses b
cross join (values
  ('retail','Retail','Standard customer pricing'),
  ('wholesale','Wholesale','Bulk and trade pricing'),
  ('reseller','Reseller','Uniform shop and reseller pricing')
) as v(code,name,description)
on conflict (business_id,code) do nothing;

create or replace function private.seed_sales_price_tiers_for_business()
returns trigger language plpgsql security definer set search_path=''
as $function$
begin
  insert into public.sales_price_tiers(business_id,code,name,description,is_default)
  values
    (new.id,'retail','Retail','Standard customer pricing',true),
    (new.id,'wholesale','Wholesale','Bulk and trade pricing',false),
    (new.id,'reseller','Reseller','Uniform shop and reseller pricing',false)
  on conflict (business_id,code) do nothing;
  return new;
end;
$function$;

create trigger businesses_seed_sales_price_tiers
  after insert on public.businesses
  for each row execute function private.seed_sales_price_tiers_for_business();

revoke all on function private.seed_sales_price_tiers_for_business() from public,anon,authenticated;

alter table public.customers add column sales_price_tier_id uuid;
alter table public.customers
  add constraint customers_sales_price_tier_fk
  foreign key (business_id,sales_price_tier_id)
  references public.sales_price_tiers(business_id,id) on delete restrict;

alter table public.quotations add column sales_price_tier_id uuid;
alter table public.quotations add column customer_contact_id uuid;
alter table public.quotations
  add constraint quotations_sales_price_tier_fk
  foreign key (business_id,sales_price_tier_id) references public.sales_price_tiers(business_id,id) on delete restrict;
alter table public.quotations
  add constraint quotations_customer_contact_fk
  foreign key (business_id,customer_contact_id) references public.customer_contacts(business_id,id) on delete restrict;

create table public.sales_product_tier_prices (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  price_tier_id uuid not null,
  catalogue_item_id uuid,
  stock_item_id uuid,
  unit_price bigint not null check (unit_price>=0),
  valid_from date,
  valid_until date,
  created_at timestamptz not null default now(),
  constraint sales_product_tier_prices_target_check
    check (num_nonnulls(catalogue_item_id,stock_item_id)=1),
  constraint sales_product_tier_prices_dates_check
    check (valid_until is null or valid_from is null or valid_until>=valid_from),
  constraint sales_product_tier_prices_business_id_id_key unique (business_id,id),
  constraint sales_product_tier_prices_tier_fk
    foreign key (business_id,price_tier_id) references public.sales_price_tiers(business_id,id) on delete restrict,
  constraint sales_product_tier_prices_catalogue_fk
    foreign key (business_id,catalogue_item_id) references public.catalogue_items(business_id,id) on delete restrict,
  constraint sales_product_tier_prices_stock_fk
    foreign key (business_id,stock_item_id) references public.stock_items(business_id,id) on delete restrict
);
create index sales_product_tier_prices_lookup_idx
  on public.sales_product_tier_prices(business_id,price_tier_id,catalogue_item_id,stock_item_id);

create table public.sales_decoration_price_rules (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  production_method_id uuid not null references public.production_methods(id) on delete restrict,
  price_tier_id uuid,
  charge_type text not null
    check (charge_type in ('setup_per_design','per_colour','per_location','quantity_break')),
  print_location text
    check (print_location is null or print_location in ('front','back','left_sleeve','right_sleeve','cap_front','mug_wrap','other')),
  quantity_min integer not null default 1 check (quantity_min>0),
  quantity_max integer check (quantity_max is null or quantity_max>=quantity_min),
  amount bigint not null check (amount>=0),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint sales_decoration_price_rules_tier_fk
    foreign key (business_id,price_tier_id) references public.sales_price_tiers(business_id,id) on delete restrict,
  constraint sales_decoration_price_rules_shape_check check (
    (charge_type='setup_per_design' and print_location is null and quantity_min=1 and quantity_max is null)
    or (charge_type='per_colour' and print_location is null and quantity_min=1 and quantity_max is null)
    or (charge_type='per_location' and print_location is not null and quantity_min=1 and quantity_max is null)
    or (charge_type='quantity_break' and print_location is null)
  )
);
create index sales_decoration_price_rules_lookup_idx
  on public.sales_decoration_price_rules(business_id,production_method_id,price_tier_id,charge_type,quantity_min);

-- A deposit requirement is a quotation condition, not a payment or revenue.
alter table public.quotations
  add column deposit_required_amount bigint not null default 0
  check (deposit_required_amount>=0 and deposit_required_amount<=total_amount);

-- Invoice snapshots are linked to the existing operational order.
create table public.sales_invoices (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  order_id uuid not null,
  quotation_id uuid,
  sales_price_tier_id uuid,
  customer_contact_id uuid,
  invoice_number text not null check (invoice_number ~ '^INV-[0-9]{4,}$'),
  status text not null default 'draft'
    check (status in ('draft','sent','partially_paid','paid','overdue','void')),
  issue_date date,
  due_date date,
  payment_terms text not null default 'due_on_receipt'
    check (payment_terms in ('due_on_receipt','net_7','net_14','net_30')),
  currency_code char(3) not null default 'KES' check (currency_code='KES'),
  subtotal_amount bigint not null default 0 check (subtotal_amount>=0),
  discount_amount bigint not null default 0 check (discount_amount>=0),
  total_amount bigint not null default 0 check (total_amount>=0 and total_amount=subtotal_amount-discount_amount),
  customer_notes text,
  internal_notes text,
  issued_at timestamptz,
  voided_at timestamptz,
  void_reason text,
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint sales_invoices_business_id_id_key unique (business_id,id),
  constraint sales_invoices_business_number_key unique (business_id,invoice_number),
  constraint sales_invoices_business_order_key unique (business_id,order_id),
  constraint sales_invoices_order_fk
    foreign key (business_id,order_id) references public.orders(business_id,id) on delete restrict,
  constraint sales_invoices_quote_fk
    foreign key (business_id,quotation_id) references public.quotations(business_id,id) on delete restrict,
  constraint sales_invoices_sales_price_tier_fk
    foreign key (business_id,sales_price_tier_id) references public.sales_price_tiers(business_id,id) on delete restrict,
  constraint sales_invoices_customer_contact_fk
    foreign key (business_id,customer_contact_id) references public.customer_contacts(business_id,id) on delete restrict,
  constraint sales_invoices_issue_dates_check
    check ((status='draft' and issue_date is null and issued_at is null)
       or (status<>'draft' and issue_date is not null and issued_at is not null)),
  constraint sales_invoices_void_check
    check ((status='void' and voided_at is not null and length(btrim(coalesce(void_reason,'')))>0)
       or (status<>'void' and voided_at is null and void_reason is null))
);
create index sales_invoices_business_issue_date_idx
  on public.sales_invoices(business_id,issue_date desc);
create index sales_invoices_business_status_due_idx
  on public.sales_invoices(business_id,status,due_date);

create table public.sales_invoice_items (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  invoice_id uuid not null,
  source_order_item_id uuid,
  description text not null check (length(btrim(description)) between 1 and 500),
  sale_type text not null check (sale_type in ('blank','decorated','print_on_demand')),
  variant_snapshot jsonb not null default '{}'::jsonb check (jsonb_typeof(variant_snapshot)='object'),
  decoration_snapshot jsonb not null default '{}'::jsonb check (jsonb_typeof(decoration_snapshot)='object'),
  quantity numeric(12,3) not null check (quantity>0),
  unit text not null,
  unit_price bigint not null check (unit_price>=0),
  line_discount bigint not null default 0 check (line_discount>=0),
  line_total bigint not null check (line_total>=0),
  created_at timestamptz not null default now(),
  constraint sales_invoice_items_business_id_id_key unique (business_id,id),
  constraint sales_invoice_items_business_invoice_fk
    foreign key (business_id,invoice_id) references public.sales_invoices(business_id,id) on delete restrict,
  constraint sales_invoice_items_source_order_line_fk
    foreign key (business_id,source_order_item_id) references public.order_items(business_id,id) on delete restrict,
  constraint sales_invoice_items_total_check
    check (line_discount<=round(quantity*unit_price)
       and line_total=round(quantity*unit_price)::bigint-line_discount)
);
create index sales_invoice_items_invoice_idx
  on public.sales_invoice_items(business_id,invoice_id);

-- Keep the existing payment ledger; add methods and references needed by Sales.
alter table public.payments add column external_reference text;
alter table public.payments drop constraint payments_method_check;
alter table public.payments add constraint payments_method_check
  check (method in ('cash','mpesa_manual','bank_transfer','cheque'));
alter table public.payments drop constraint payments_check;
alter table public.payments add constraint payments_check check (
  ((method in ('cash','bank_transfer','cheque'))
    and status in ('posted','reversed') and mpesa_reference is null)
  or
  (method='mpesa_manual' and mpesa_reference is not null
    and ((status='pending_verification' and verified_at is null)
      or status in ('posted','rejected','reversed')))
);
alter table public.payments add constraint payments_external_reference_length_check
  check (external_reference is null or length(external_reference)<=160);

-- A single payment can be allocated across one or more invoices.
create table public.sales_invoice_payment_allocations (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  invoice_id uuid not null,
  payment_id uuid not null,
  amount bigint not null check (amount>0),
  allocated_at timestamptz not null default now(),
  allocated_by uuid not null references auth.users(id) on delete restrict,
  request_id uuid not null,
  constraint sales_invoice_payment_allocations_invoice_fk
    foreign key (business_id,invoice_id) references public.sales_invoices(business_id,id) on delete restrict,
  constraint sales_invoice_payment_allocations_payment_fk
    foreign key (business_id,payment_id) references public.payments(business_id,id) on delete restrict,
  constraint sales_invoice_payment_allocations_request_unique unique (business_id,request_id)
);
create index sales_invoice_payment_allocations_invoice_idx
  on public.sales_invoice_payment_allocations(business_id,invoice_id,allocated_at);
create index sales_invoice_payment_allocations_payment_idx
  on public.sales_invoice_payment_allocations(business_id,payment_id);

-- Positive credit entries add customer credit; negative entries consume it.
create table public.sales_customer_credit_entries (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  customer_id uuid not null,
  entry_type text not null check (entry_type in ('overpayment','credit_note','apply_to_invoice','refund','adjustment')),
  amount bigint not null check (amount<>0),
  payment_id uuid,
  invoice_id uuid,
  credit_note_id uuid,
  description text not null check (length(btrim(description)) between 1 and 500),
  occurred_at timestamptz not null default now(),
  actor_user_id uuid not null references auth.users(id) on delete restrict,
  request_id uuid not null,
  constraint sales_customer_credit_customer_fk
    foreign key (business_id,customer_id) references public.customers(business_id,id) on delete restrict,
  constraint sales_customer_credit_payment_fk
    foreign key (business_id,payment_id) references public.payments(business_id,id) on delete restrict,
  constraint sales_customer_credit_invoice_fk
    foreign key (business_id,invoice_id) references public.sales_invoices(business_id,id) on delete restrict,
  constraint sales_customer_credit_request_unique unique (business_id,request_id)
);
create index sales_customer_credit_customer_idx
  on public.sales_customer_credit_entries(business_id,customer_id,occurred_at);

create table public.sales_credit_notes (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  customer_id uuid not null,
  invoice_id uuid not null,
  credit_note_number text not null check (credit_note_number ~ '^CN-[0-9]{4,}$'),
  status text not null default 'draft' check (status in ('draft','issued','void')),
  reason text not null check (length(btrim(reason)) between 1 and 1000),
  subtotal_amount bigint not null default 0 check (subtotal_amount>=0),
  discount_amount bigint not null default 0 check (discount_amount>=0),
  total_amount bigint not null default 0 check (total_amount=subtotal_amount-discount_amount and total_amount>=0),
  issued_at timestamptz,
  voided_at timestamptz,
  void_reason text,
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  constraint sales_credit_notes_business_id_id_key unique (business_id,id),
  constraint sales_credit_notes_number_key unique (business_id,credit_note_number),
  constraint sales_credit_notes_customer_fk
    foreign key (business_id,customer_id) references public.customers(business_id,id) on delete restrict,
  constraint sales_credit_notes_invoice_fk
    foreign key (business_id,invoice_id) references public.sales_invoices(business_id,id) on delete restrict,
  constraint sales_credit_notes_issue_check
    check ((status='draft' and issued_at is null) or (status<>'draft' and issued_at is not null)),
  constraint sales_credit_notes_void_check
    check ((status='void' and voided_at is not null and length(btrim(coalesce(void_reason,'')))>0)
       or (status<>'void' and voided_at is null and void_reason is null))
);

create table public.sales_credit_note_items (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  credit_note_id uuid not null,
  invoice_item_id uuid,
  description text not null check (length(btrim(description)) between 1 and 500),
  quantity numeric(12,3) not null check (quantity>0),
  unit_price bigint not null check (unit_price>=0),
  amount bigint not null check (amount>=0),
  created_at timestamptz not null default now(),
  constraint sales_credit_note_items_business_credit_fk
    foreign key (business_id,credit_note_id) references public.sales_credit_notes(business_id,id) on delete restrict,
  constraint sales_credit_note_items_invoice_item_fk
    foreign key (business_id,invoice_item_id) references public.sales_invoice_items(business_id,id) on delete restrict
);
alter table public.sales_customer_credit_entries
  add constraint sales_customer_credit_credit_note_fk
  foreign key (business_id,credit_note_id) references public.sales_credit_notes(business_id,id) on delete restrict;
alter table public.payment_refunds add column sales_credit_note_id uuid;
alter table public.payment_refunds
  add constraint payment_refunds_sales_credit_note_fk
  foreign key (business_id,sales_credit_note_id) references public.sales_credit_notes(business_id,id) on delete restrict;

-- Job-specific artwork, proof history, colour separations and individual garment sizing.
create table public.sales_job_size_breakdown (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  job_id uuid not null,
  person_name text not null check (length(btrim(person_name)) between 1 and 180),
  jersey_number text,
  size text not null check (length(btrim(size)) between 1 and 40),
  colour text,
  quantity numeric(12,3) not null default 1 check (quantity>0),
  notes text,
  created_at timestamptz not null default now(),
  constraint sales_job_size_breakdown_job_fk
    foreign key (business_id,job_id) references public.production_jobs(business_id,id) on delete restrict
);
create index sales_job_size_breakdown_job_idx
  on public.sales_job_size_breakdown(business_id,job_id);

create table public.sales_job_artworks (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  job_id uuid not null,
  storage_path text not null check (length(btrim(storage_path)) between 1 and 1000),
  file_name text not null check (length(btrim(file_name)) between 1 and 255),
  version integer not null check (version>0),
  proof_status text not null default 'pending'
    check (proof_status in ('pending','sent','approved','rejected','superseded')),
  sent_at timestamptz,
  approved_at timestamptz,
  approved_by_contact_id uuid,
  notes text,
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  constraint sales_job_artworks_business_id_id_key unique (business_id,id),
  constraint sales_job_artworks_job_fk
    foreign key (business_id,job_id) references public.production_jobs(business_id,id) on delete restrict,
  constraint sales_job_artworks_contact_fk
    foreign key (business_id,approved_by_contact_id) references public.customer_contacts(business_id,id) on delete restrict,
  constraint sales_job_artworks_job_version_key unique (business_id,job_id,version)
);

create table public.sales_job_colour_separations (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  job_id uuid not null,
  artwork_id uuid,
  colour_name text not null check (length(btrim(colour_name)) between 1 and 100),
  ink_reference text,
  screen_reference text,
  print_location text not null
    check (print_location in ('front','back','left_sleeve','right_sleeve','cap_front','mug_wrap','other')),
  sequence_no integer not null default 1 check (sequence_no>0),
  notes text,
  created_at timestamptz not null default now(),
  constraint sales_job_colour_separations_business_id_id_key unique (business_id,id),
  constraint sales_job_colour_separations_job_fk
    foreign key (business_id,job_id) references public.production_jobs(business_id,id) on delete restrict,
  constraint sales_job_colour_separations_artwork_fk
    foreign key (business_id,artwork_id) references public.sales_job_artworks(business_id,id) on delete restrict
);
create index sales_job_colour_separations_job_idx
  on public.sales_job_colour_separations(business_id,job_id,sequence_no);

-- Extend existing per-business counters for invoice and credit-note numbering.
alter table public.document_counters drop constraint document_counters_document_type_check;
alter table public.document_counters add constraint document_counters_document_type_check
  check (document_type in ('quote','order','payment','receipt','purchase','invoice','credit_note'));

-- New Sales tables are owner-readable through owner RPCs; no direct client table writes.
do $$
declare t text;
begin
  foreach t in array array[
    'sales_price_tiers','sales_product_tier_prices','sales_decoration_price_rules','sales_invoices','sales_invoice_items',
    'sales_invoice_payment_allocations','sales_customer_credit_entries','sales_credit_notes',
    'sales_credit_note_items','sales_job_size_breakdown','sales_job_artworks','sales_job_colour_separations'
  ] loop
    execute format('alter table public.%I enable row level security',t);
    execute format('revoke all on table public.%I from anon,authenticated,public',t);
    execute format('grant select on table public.%I to authenticated',t);
    execute format(
      'create policy %I on public.%I for select to authenticated using (private.is_active_owner(business_id))',
      t||'_owner_select',t
    );
  end loop;
end;
$$;

create or replace function private.guard_sales_append_only()
returns trigger language plpgsql set search_path=''
as $$
begin
  raise exception using errcode='55000',message='Sales ledger entries are append-only; post a correcting entry instead';
end;
$$;

create or replace function private.guard_sales_invoice_line_mutation()
returns trigger language plpgsql set search_path=''
as $$
declare v_status text; v_business_id uuid; v_invoice_id uuid;
begin
  if tg_op='INSERT' then
    v_business_id:=new.business_id; v_invoice_id:=new.invoice_id;
  else
    v_business_id:=old.business_id; v_invoice_id:=old.invoice_id;
  end if;
  select status into v_status from public.sales_invoices
  where business_id=v_business_id and id=v_invoice_id;
  if v_status is distinct from 'draft' then
    raise exception using errcode='55000',message='Issued invoice lines are immutable; void the invoice and issue a corrected document';
  end if;
  if tg_op='DELETE' then return old; end if;
  return new;
end;
$$;

create or replace function private.guard_sales_credit_note_line_mutation()
returns trigger language plpgsql set search_path=''
as $$
declare v_status text; v_business_id uuid; v_credit_note_id uuid;
begin
  if tg_op='INSERT' then
    v_business_id:=new.business_id; v_credit_note_id:=new.credit_note_id;
  else
    v_business_id:=old.business_id; v_credit_note_id:=old.credit_note_id;
  end if;
  select status into v_status from public.sales_credit_notes
  where business_id=v_business_id and id=v_credit_note_id;
  if v_status is distinct from 'draft' then
    raise exception using errcode='55000',message='Issued credit note lines are immutable; void the credit note and issue a corrected document';
  end if;
  if tg_op='DELETE' then return old; end if;
  return new;
end;
$$;

create or replace function private.guard_sales_document_delete()
returns trigger language plpgsql set search_path=''
as $$
begin
  if old.status <> 'draft' then
    raise exception using errcode='55000',message='Finalised sales documents cannot be deleted; void them and retain the audit trail';
  end if;
  return old;
end;
$$;

create trigger sales_invoice_payment_allocations_no_mutation
  before update or delete on public.sales_invoice_payment_allocations
  for each row execute function private.guard_sales_append_only();
create trigger sales_customer_credit_entries_no_mutation
  before update or delete on public.sales_customer_credit_entries
  for each row execute function private.guard_sales_append_only();
create trigger sales_invoice_lines_immutable_after_issue
  before insert or update or delete on public.sales_invoice_items
  for each row execute function private.guard_sales_invoice_line_mutation();
create trigger sales_credit_note_lines_immutable_after_issue
  before insert or update or delete on public.sales_credit_note_items
  for each row execute function private.guard_sales_credit_note_line_mutation();
create trigger sales_invoices_retain_finalised
  before delete on public.sales_invoices
  for each row execute function private.guard_sales_document_delete();
create trigger sales_credit_notes_retain_finalised
  before delete on public.sales_credit_notes
  for each row execute function private.guard_sales_document_delete();

revoke all on function private.guard_sales_append_only() from public,anon,authenticated;
revoke all on function private.guard_sales_invoice_line_mutation() from public,anon,authenticated;
revoke all on function private.guard_sales_credit_note_line_mutation() from public,anon,authenticated;
revoke all on function private.guard_sales_document_delete() from public,anon,authenticated;
