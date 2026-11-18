-- MJ Tees — vinyl physical-piece inventory foundation
-- Version: 20261118172905
-- Applied directly to the live MJ Tees Supabase project.
-- Scope: schema foundation only. No stock conversion, no ledger writes, no frontend wiring.
-- Dimensions are stored as integer micrometres; UI input/display remains centimetres.
-- Physical stock remains empty until existing vinyl stock is physically measured and reconciled.

create table public.vinyl_cutting_settings (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id),
  production_method_id uuid not null references public.production_methods(id),
  version integer not null check (version > 0),
  machine_label text,
  machine_identifier text,
  kerf_um bigint check (kerf_um is null or kerf_um >= 0),
  settings jsonb not null default '{}'::jsonb check (jsonb_typeof(settings) = 'object'),
  effective_from timestamptz not null,
  effective_to timestamptz,
  approved_by uuid references auth.users(id),
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  check (effective_to is null or effective_to > effective_from),
  unique (business_id, production_method_id, version),
  unique (business_id, id)
);

create table public.vinyl_cut_operations (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id),
  job_id uuid not null,
  production_method_id uuid not null references public.production_methods(id),
  request_id uuid not null,
  status text not null default 'started'
    check (status in ('started','completed','cancelled')),
  machine_label text,
  machine_identifier text,
  kerf_um bigint check (kerf_um is null or kerf_um >= 0),
  settings_version integer,
  settings_snapshot jsonb not null default '{}'::jsonb
    check (jsonb_typeof(settings_snapshot) = 'object'),
  operator_user_id uuid not null references auth.users(id),
  started_at timestamptz not null default now(),
  completed_at timestamptz,
  created_at timestamptz not null default now(),
  unique (business_id, id),
  unique (business_id, request_id),
  foreign key (business_id, job_id)
    references public.production_jobs(business_id, id),
  check (
    (status = 'completed' and completed_at is not null)
    or (status <> 'completed' and completed_at is null)
  )
);

create table public.vinyl_material_pieces (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id),
  stock_item_id uuid not null,
  location_id uuid not null,
  parent_piece_id uuid,
  source_issue_id uuid,
  source_cut_operation_id uuid,
  piece_code text not null,
  width_um bigint not null check (width_um > 0),
  length_um bigint not null check (length_um > 0),
  area_um2 numeric(30,0) generated always as
    (width_um::numeric * length_um::numeric) stored,
  status text not null default 'available'
    check (status in ('available','reserved','issued','split','consumed','written_off')),
  condition text not null default 'usable'
    check (condition in ('usable','damaged','unusable')),
  eligibility text not null default 'eligible'
    check (eligibility in ('eligible','restricted','ineligible')),
  origin_type text not null
    check (origin_type in ('opening_balance','purchase_receipt','production_offcut','manual_reconciliation')),
  cost_value_kes numeric(18,9) not null check (cost_value_kes >= 0),
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (business_id, id),
  unique (business_id, piece_code),
  foreign key (business_id, stock_item_id)
    references public.stock_items(business_id, id),
  foreign key (business_id, location_id)
    references public.inventory_locations(business_id, id),
  foreign key (business_id, parent_piece_id)
    references public.vinyl_material_pieces(business_id, id),
  foreign key (business_id, source_issue_id)
    references public.production_material_issues(business_id, id),
  foreign key (business_id, source_cut_operation_id)
    references public.vinyl_cut_operations(business_id, id),
  check (parent_piece_id is null or parent_piece_id <> id)
);

create table public.vinyl_cut_inputs (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id),
  operation_id uuid not null,
  piece_id uuid not null,
  sequence_no integer not null check (sequence_no > 0),
  input_width_um bigint not null check (input_width_um > 0),
  input_length_um bigint not null check (input_length_um > 0),
  orientation_degrees smallint not null default 0
    check (orientation_degrees in (0,90)),
  created_at timestamptz not null default now(),
  unique (business_id, id),
  unique (business_id, operation_id, id),
  unique (business_id, operation_id, sequence_no),
  unique (business_id, operation_id, piece_id),
  foreign key (business_id, operation_id)
    references public.vinyl_cut_operations(business_id, id),
  foreign key (business_id, piece_id)
    references public.vinyl_material_pieces(business_id, id)
);

create table public.vinyl_cut_results (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id),
  operation_id uuid not null,
  input_id uuid not null,
  sequence_no integer not null check (sequence_no > 0),
  result_type text not null
    check (result_type in ('product','offcut','waste','kerf')),
  piece_id uuid,
  width_um bigint not null check (width_um > 0),
  length_um bigint not null check (length_um > 0),
  area_um2 numeric(30,0) generated always as
    (width_um::numeric * length_um::numeric) stored,
  created_at timestamptz not null default now(),
  unique (business_id, id),
  unique (business_id, operation_id, sequence_no),
  foreign key (business_id, operation_id)
    references public.vinyl_cut_operations(business_id, id),
  foreign key (business_id, operation_id, input_id)
    references public.vinyl_cut_inputs(business_id, operation_id, id),
  foreign key (business_id, piece_id)
    references public.vinyl_material_pieces(business_id, id),
  check (
    (result_type in ('product','offcut') and piece_id is not null)
    or (result_type in ('waste','kerf') and piece_id is null)
  )
);

create table public.vinyl_piece_reservations (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id),
  piece_id uuid not null,
  job_id uuid not null,
  operation_id uuid,
  status text not null default 'active'
    check (status in ('active','released','consumed','cancelled')),
  request_id uuid not null,
  reserved_by uuid not null references auth.users(id),
  reserved_at timestamptz not null default now(),
  released_at timestamptz,
  unique (business_id, id),
  foreign key (business_id, piece_id)
    references public.vinyl_material_pieces(business_id, id),
  foreign key (business_id, job_id)
    references public.production_jobs(business_id, id),
  foreign key (business_id, operation_id)
    references public.vinyl_cut_operations(business_id, id),
  check (
    (status = 'active' and released_at is null)
    or (status <> 'active' and released_at is not null)
  )
);

create table public.vinyl_piece_movements (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id),
  piece_id uuid not null,
  event_type text not null
    check (event_type in ('received','reserved','released','issued','split','offcut_created','consumed','moved','written_off','reconciled')),
  from_status text,
  to_status text,
  from_location_id uuid,
  to_location_id uuid,
  related_piece_id uuid,
  operation_id uuid,
  reservation_id uuid,
  request_id uuid not null,
  actor_user_id uuid not null references auth.users(id),
  reason text,
  metadata jsonb not null default '{}'::jsonb
    check (jsonb_typeof(metadata) = 'object'),
  occurred_at timestamptz not null default now(),
  foreign key (business_id, piece_id)
    references public.vinyl_material_pieces(business_id, id),
  foreign key (business_id, related_piece_id)
    references public.vinyl_material_pieces(business_id, id),
  foreign key (business_id, operation_id)
    references public.vinyl_cut_operations(business_id, id),
  foreign key (business_id, reservation_id)
    references public.vinyl_piece_reservations(business_id, id),
  foreign key (business_id, from_location_id)
    references public.inventory_locations(business_id, id),
  foreign key (business_id, to_location_id)
    references public.inventory_locations(business_id, id)
);

create index vinyl_material_pieces_available_idx
  on public.vinyl_material_pieces(business_id, stock_item_id, location_id, width_um, length_um)
  where status = 'available';
create index vinyl_material_pieces_parent_idx
  on public.vinyl_material_pieces(business_id, parent_piece_id)
  where parent_piece_id is not null;
create index vinyl_cut_operations_job_idx
  on public.vinyl_cut_operations(business_id, job_id, started_at desc);
create index vinyl_piece_movements_piece_idx
  on public.vinyl_piece_movements(business_id, piece_id, occurred_at desc);
create unique index vinyl_piece_one_active_reservation_idx
  on public.vinyl_piece_reservations(business_id, piece_id)
  where status = 'active';

create trigger vinyl_piece_movements_immutable
  before update or delete on public.vinyl_piece_movements
  for each row execute function private.reject_ledger_mutation();

alter table public.vinyl_cutting_settings enable row level security;
alter table public.vinyl_cut_operations enable row level security;
alter table public.vinyl_material_pieces enable row level security;
alter table public.vinyl_cut_inputs enable row level security;
alter table public.vinyl_cut_results enable row level security;
alter table public.vinyl_piece_reservations enable row level security;
alter table public.vinyl_piece_movements enable row level security;

create policy vinyl_cutting_settings_owner_select
  on public.vinyl_cutting_settings for select to authenticated
  using (private.is_active_owner(business_id));
create policy vinyl_cut_operations_owner_select
  on public.vinyl_cut_operations for select to authenticated
  using (private.is_active_owner(business_id));
create policy vinyl_material_pieces_owner_select
  on public.vinyl_material_pieces for select to authenticated
  using (private.is_active_owner(business_id));
create policy vinyl_cut_inputs_owner_select
  on public.vinyl_cut_inputs for select to authenticated
  using (private.is_active_owner(business_id));
create policy vinyl_cut_results_owner_select
  on public.vinyl_cut_results for select to authenticated
  using (private.is_active_owner(business_id));
create policy vinyl_piece_reservations_owner_select
  on public.vinyl_piece_reservations for select to authenticated
  using (private.is_active_owner(business_id));
create policy vinyl_piece_movements_owner_select
  on public.vinyl_piece_movements for select to authenticated
  using (private.is_active_owner(business_id));

revoke all on public.vinyl_cutting_settings, public.vinyl_cut_operations,
  public.vinyl_material_pieces, public.vinyl_cut_inputs, public.vinyl_cut_results,
  public.vinyl_piece_reservations, public.vinyl_piece_movements
  from anon, authenticated;
grant select on public.vinyl_cutting_settings, public.vinyl_cut_operations,
  public.vinyl_material_pieces, public.vinyl_cut_inputs, public.vinyl_cut_results,
  public.vinyl_piece_reservations, public.vinyl_piece_movements
  to authenticated;
