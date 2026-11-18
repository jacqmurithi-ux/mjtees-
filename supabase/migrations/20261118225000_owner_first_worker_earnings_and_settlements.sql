-- Owner-first production worker earnings, settlement and temporary-labour allocation.
-- Earnings create exactly one linked production cost entry; payments settle earnings only.
-- No staff login or mandatory worker assignment is introduced.

begin;

create table public.production_workers (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  full_name text not null check (length(btrim(full_name)) between 1 and 160),
  phone text,
  worker_type text not null check (worker_type in ('temporary','permanent')),
  is_active boolean not null default true,
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (business_id,id)
);

create table public.production_worker_assignments (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  job_id uuid not null,
  worker_id uuid not null,
  earnings_method text not null check (earnings_method in ('fixed_amount','daily_rate','quantity_rate')),
  agreed_rate bigint not null check (agreed_rate > 0),
  rate_unit text not null check (length(btrim(rate_unit)) between 1 and 24),
  status text not null default 'assigned' check (status in ('assigned','working','completed','cancelled')),
  assigned_at timestamptz not null default now(),
  commenced_at timestamptz,
  commenced_by uuid references auth.users(id) on delete restrict,
  notes text,
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (business_id,job_id) references public.production_jobs(business_id,id) on delete restrict,
  foreign key (business_id,worker_id) references public.production_workers(business_id,id) on delete restrict,
  unique (business_id,id),
  check (
    (status='assigned' and commenced_at is null and commenced_by is null)
    or (status in ('working','completed') and commenced_at is not null and commenced_by is not null)
    or status='cancelled'
  ),
  check (
    (earnings_method='fixed_amount' and rate_unit='job')
    or (earnings_method='daily_rate' and rate_unit='day')
    or (earnings_method='quantity_rate' and rate_unit<>'job')
  )
);

create table public.production_worker_earnings (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  assignment_id uuid not null,
  job_id uuid not null,
  worker_id uuid not null,
  earnings_method text not null check (earnings_method in ('fixed_amount','daily_rate','quantity_rate')),
  agreed_rate bigint not null check (agreed_rate > 0),
  actual_quantity numeric(12,3) not null check (actual_quantity > 0),
  unit text not null,
  amount bigint not null check (amount > 0),
  description text not null check (length(btrim(description)) between 1 and 240),
  cost_entry_id uuid not null,
  confirmed_by uuid not null references auth.users(id) on delete restrict,
  confirmed_at timestamptz not null default now(),
  request_id uuid not null,
  foreign key (business_id,assignment_id) references public.production_worker_assignments(business_id,id) on delete restrict,
  foreign key (business_id,job_id) references public.production_jobs(business_id,id) on delete restrict,
  foreign key (business_id,worker_id) references public.production_workers(business_id,id) on delete restrict,
  foreign key (business_id,cost_entry_id) references public.production_cost_entries(business_id,id) on delete restrict,
  unique (business_id,id),
  unique (business_id,cost_entry_id),
  unique (business_id,request_id)
);

create unique index production_worker_fixed_earning_once_idx
  on public.production_worker_earnings(business_id,assignment_id)
  where earnings_method='fixed_amount';

create table public.production_worker_payments (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  worker_id uuid not null,
  amount bigint not null check (amount > 0),
  payment_method text not null check (payment_method in ('cash','mpesa','bank_transfer','other')),
  reference text,
  notes text,
  paid_at timestamptz not null default now(),
  status text not null default 'posted' check (status = 'posted'),
  recorded_by uuid not null references auth.users(id) on delete restrict,
  request_id uuid not null,
  created_at timestamptz not null default now(),
  foreign key (business_id,worker_id) references public.production_workers(business_id,id) on delete restrict,
  unique (business_id,id),
  unique (business_id,request_id)
);

create table public.production_worker_payment_allocations (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  payment_id uuid not null,
  earning_id uuid not null,
  amount bigint not null check (amount > 0),
  created_at timestamptz not null default now(),
  foreign key (business_id,payment_id) references public.production_worker_payments(business_id,id) on delete restrict,
  foreign key (business_id,earning_id) references public.production_worker_earnings(business_id,id) on delete restrict,
  unique (business_id,id),
  unique (business_id,payment_id,earning_id)
);

create table public.temporary_labour_allocations (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  job_id uuid not null,
  order_item_id uuid not null,
  eligible_printing_revenue bigint not null check (eligible_printing_revenue >= 0),
  allocation_rate numeric(5,2) not null default 20.00 check (allocation_rate=20.00),
  allocation_amount numeric(18,2) not null check (allocation_amount >= 0),
  triggered_by_assignment_id uuid not null,
  commenced_at timestamptz not null,
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  foreign key (business_id,job_id) references public.production_jobs(business_id,id) on delete restrict,
  foreign key (business_id,order_item_id) references public.order_items(business_id,id) on delete restrict,
  foreign key (business_id,triggered_by_assignment_id) references public.production_worker_assignments(business_id,id) on delete restrict,
  unique (business_id,id),
  unique (business_id,job_id),
  unique (business_id,order_item_id)
);

create table public.temporary_labour_adjustments (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  allocation_id uuid not null,
  previous_eligible_printing_revenue bigint not null check (previous_eligible_printing_revenue >= 0),
  revised_eligible_printing_revenue bigint not null check (revised_eligible_printing_revenue >= 0),
  revenue_delta bigint not null,
  allocation_rate numeric(5,2) not null check (allocation_rate=20.00),
  adjustment_amount numeric(18,2) not null,
  reason text not null check (length(btrim(reason)) between 1 and 500),
  approved_by uuid not null references auth.users(id) on delete restrict,
  request_id uuid not null,
  created_at timestamptz not null default now(),
  foreign key (business_id,allocation_id) references public.temporary_labour_allocations(business_id,id) on delete restrict,
  unique (business_id,id),
  unique (business_id,request_id)
);

create index production_worker_assignments_job_idx
  on public.production_worker_assignments(business_id,job_id,assigned_at desc);
create index production_worker_assignments_worker_idx
  on public.production_worker_assignments(business_id,worker_id,assigned_at desc);
create index production_worker_earnings_worker_idx
  on public.production_worker_earnings(business_id,worker_id,confirmed_at desc);
create index production_worker_payment_allocations_earning_idx
  on public.production_worker_payment_allocations(business_id,earning_id);
create index temporary_labour_adjustments_allocation_idx
  on public.temporary_labour_adjustments(business_id,allocation_id,created_at);

alter table public.production_workers enable row level security;
alter table public.production_worker_assignments enable row level security;
alter table public.production_worker_earnings enable row level security;
alter table public.production_worker_payments enable row level security;
alter table public.production_worker_payment_allocations enable row level security;
alter table public.temporary_labour_allocations enable row level security;
alter table public.temporary_labour_adjustments enable row level security;

create policy production_workers_owner_select on public.production_workers
  for select to authenticated using (private.is_active_owner(business_id));
create policy production_worker_assignments_owner_select on public.production_worker_assignments
  for select to authenticated using (private.is_active_owner(business_id));
create policy production_worker_earnings_owner_select on public.production_worker_earnings
  for select to authenticated using (private.is_active_owner(business_id));
create policy production_worker_payments_owner_select on public.production_worker_payments
  for select to authenticated using (private.is_active_owner(business_id));
create policy production_worker_payment_allocations_owner_select on public.production_worker_payment_allocations
  for select to authenticated using (private.is_active_owner(business_id));
create policy temporary_labour_allocations_owner_select on public.temporary_labour_allocations
  for select to authenticated using (private.is_active_owner(business_id));
create policy temporary_labour_adjustments_owner_select on public.temporary_labour_adjustments
  for select to authenticated using (private.is_active_owner(business_id));

revoke all on public.production_workers,public.production_worker_assignments,
  public.production_worker_earnings,public.production_worker_payments,
  public.production_worker_payment_allocations,public.temporary_labour_allocations,
  public.temporary_labour_adjustments from anon,authenticated;
grant select on public.production_workers,public.production_worker_assignments,
  public.production_worker_earnings,public.production_worker_payments,
  public.production_worker_payment_allocations,public.temporary_labour_allocations,
  public.temporary_labour_adjustments to authenticated;

create or replace function private.owner_upsert_production_worker(
  p_business_id uuid,p_worker_id uuid,p_full_name text,p_phone text,p_worker_type text,p_request_id uuid
)
returns jsonb language plpgsql security definer set search_path=''
as $function$
declare
  v_actor uuid; v_cached jsonb; v_payload jsonb; v_worker uuid; v_result jsonb;
begin
  v_actor:=private.assert_active_owner(p_business_id);
  if p_request_id is null or p_full_name is null or length(btrim(p_full_name)) not between 1 and 160
    or p_worker_type not in ('temporary','permanent') then
    raise exception using errcode='22023',message='Valid worker name, type and request ID are required';
  end if;
  v_payload:=jsonb_build_object('worker_id',p_worker_id,'full_name',btrim(p_full_name),
    'phone',nullif(btrim(p_phone),''),'worker_type',p_worker_type);
  v_cached:=private.begin_idempotent_request(p_business_id,'upsert_production_worker',p_request_id,v_payload);
  if v_cached is not null then return v_cached; end if;

  if p_worker_id is null then
    insert into public.production_workers(business_id,full_name,phone,worker_type,created_by)
    values(p_business_id,btrim(p_full_name),nullif(btrim(p_phone),''),p_worker_type,v_actor)
    returning id into v_worker;
  else
    update public.production_workers
    set full_name=btrim(p_full_name),phone=nullif(btrim(p_phone),''),worker_type=p_worker_type,updated_at=now()
    where business_id=p_business_id and id=p_worker_id and is_active
    returning id into v_worker;
    if v_worker is null then raise exception using errcode='P0002',message='Active production worker not found'; end if;
  end if;

  v_result:=jsonb_build_object('worker_id',v_worker,'worker_type',p_worker_type);
  perform private.finish_idempotent_request(p_business_id,'upsert_production_worker',p_request_id,v_result);
  perform private.write_audit(p_business_id,v_actor,'production.worker_saved','production_worker',v_worker,p_request_id,
    jsonb_build_object('worker_type',p_worker_type));
  return v_result;
end;
$function$;

create or replace function private.owner_assign_production_worker(
  p_job_id uuid,p_worker_id uuid,p_earnings_method text,p_agreed_rate bigint,p_rate_unit text,p_notes text,p_request_id uuid
)
returns jsonb language plpgsql security definer set search_path=''
as $function$
declare
  v_job public.production_jobs%rowtype; v_worker public.production_workers%rowtype;
  v_actor uuid; v_cached jsonb; v_payload jsonb; v_assignment uuid; v_result jsonb;
begin
  select * into v_job from public.production_jobs where id=p_job_id for update;
  if not found then raise exception using errcode='P0002',message='Production job not found'; end if;
  v_actor:=private.assert_active_owner(v_job.business_id);
  if p_request_id is null or p_earnings_method not in ('fixed_amount','daily_rate','quantity_rate')
    or p_agreed_rate is null or p_agreed_rate<=0 or p_rate_unit is null or length(btrim(p_rate_unit)) not between 1 and 24 then
    raise exception using errcode='22023',message='Valid earnings method, rate, unit and request ID are required';
  end if;
  select * into v_worker from public.production_workers
  where business_id=v_job.business_id and id=p_worker_id and is_active;
  if not found then raise exception using errcode='P0002',message='Active production worker not found'; end if;
  if (p_earnings_method='fixed_amount' and p_rate_unit<>'job')
    or (p_earnings_method='daily_rate' and p_rate_unit<>'day')
    or (p_earnings_method='quantity_rate' and p_rate_unit='job') then
    raise exception using errcode='22023',message='Rate unit does not match the selected earnings method';
  end if;
  if v_job.status in ('completed','cancelled') then
    raise exception using errcode='22023',message='Cannot assign a worker to a closed production job';
  end if;
  v_payload:=jsonb_build_object('job_id',p_job_id,'worker_id',p_worker_id,'earnings_method',p_earnings_method,
    'agreed_rate',p_agreed_rate,'rate_unit',btrim(p_rate_unit),'notes',p_notes);
  v_cached:=private.begin_idempotent_request(v_job.business_id,'assign_production_worker',p_request_id,v_payload);
  if v_cached is not null then return v_cached; end if;

  insert into public.production_worker_assignments(
    business_id,job_id,worker_id,earnings_method,agreed_rate,rate_unit,notes,created_by
  ) values(
    v_job.business_id,p_job_id,p_worker_id,p_earnings_method,p_agreed_rate,btrim(p_rate_unit),
    nullif(btrim(p_notes),''),v_actor
  ) returning id into v_assignment;

  v_result:=jsonb_build_object('assignment_id',v_assignment,'worker_id',p_worker_id,'status','assigned');
  perform private.finish_idempotent_request(v_job.business_id,'assign_production_worker',p_request_id,v_result);
  perform private.write_audit(v_job.business_id,v_actor,'production.worker_assigned','production_job',p_job_id,p_request_id,
    jsonb_build_object('assignment_id',v_assignment,'worker_id',p_worker_id,'worker_type',v_worker.worker_type,
      'earnings_method',p_earnings_method,'agreed_rate',p_agreed_rate,'rate_unit',p_rate_unit));
  return v_result;
end;
$function$;

create or replace function private.owner_confirm_worker_commencement(
  p_assignment_id uuid,p_request_id uuid
)
returns jsonb language plpgsql security definer set search_path=''
as $function$
declare
  v_assignment public.production_worker_assignments%rowtype;
  v_worker public.production_workers%rowtype;
  v_job public.production_jobs%rowtype;
  v_actor uuid; v_cached jsonb; v_payload jsonb; v_revenue bigint;
  v_allocation_id uuid; v_result jsonb;
begin
  select * into v_assignment from public.production_worker_assignments where id=p_assignment_id;
  if not found then raise exception using errcode='P0002',message='Worker assignment not found'; end if;
  v_actor:=private.assert_active_owner(v_assignment.business_id);
  v_payload:=jsonb_build_object('assignment_id',p_assignment_id);
  v_cached:=private.begin_idempotent_request(v_assignment.business_id,'confirm_worker_commencement',p_request_id,v_payload);
  if v_cached is not null then return v_cached; end if;

  select * into v_assignment from public.production_worker_assignments
  where business_id=v_assignment.business_id and id=p_assignment_id for update;
  if v_assignment.status<>'assigned' then
    raise exception using errcode='22023',message='Only an assigned worker can be confirmed as commenced';
  end if;
  select * into v_worker from public.production_workers
  where business_id=v_assignment.business_id and id=v_assignment.worker_id;
  select * into v_job from public.production_jobs
  where business_id=v_assignment.business_id and id=v_assignment.job_id for update;
  if v_job.status not in ('in_progress','quality_check','rework') then
    raise exception using errcode='22023',message='Production job must be active before worker commencement';
  end if;

  if v_worker.worker_type='temporary' then
    if not exists (
      select 1 from public.order_items oi
      where oi.business_id=v_assignment.business_id
        and oi.id=v_job.order_item_id
        and oi.price_components_snapshot is not null
    ) then
      raise exception using errcode='23514',
        message='Classify garment-supply and printing prices before temporary labour commences';
    end if;
    v_revenue:=private.order_item_eligible_printing_revenue(v_job.order_item_id);
  end if;

  update public.production_worker_assignments
  set status='working',commenced_at=now(),commenced_by=v_actor,updated_at=now()
  where business_id=v_assignment.business_id and id=p_assignment_id;

  if v_worker.worker_type='temporary' then
    insert into public.temporary_labour_allocations(
      business_id,job_id,order_item_id,eligible_printing_revenue,allocation_rate,
      allocation_amount,triggered_by_assignment_id,commenced_at,created_by
    ) values (
      v_assignment.business_id,v_job.id,v_job.order_item_id,v_revenue,20.00,
      round(v_revenue::numeric*0.20,2),p_assignment_id,now(),v_actor
    )
    on conflict (business_id,order_item_id) do nothing
    returning id into v_allocation_id;

    if v_allocation_id is null then
      select id into v_allocation_id from public.temporary_labour_allocations
      where business_id=v_assignment.business_id and order_item_id=v_job.order_item_id;
    end if;
  end if;

  v_result:=jsonb_build_object('assignment_id',p_assignment_id,'status','working',
    'commenced_at',now(),'temporary_labour_allocation_id',v_allocation_id);
  perform private.finish_idempotent_request(v_assignment.business_id,'confirm_worker_commencement',p_request_id,v_result);
  perform private.write_audit(v_assignment.business_id,v_actor,'production.worker_commenced','production_worker_assignment',
    p_assignment_id,p_request_id,jsonb_build_object('worker_type',v_worker.worker_type,'allocation_id',v_allocation_id));
  return v_result;
end;
$function$;

create or replace function private.owner_confirm_worker_earnings(
  p_assignment_id uuid,p_actual_quantity numeric,p_description text,p_request_id uuid
)
returns jsonb language plpgsql security definer set search_path=''
as $function$
declare
  v_assignment public.production_worker_assignments%rowtype;
  v_worker public.production_workers%rowtype;
  v_job public.production_jobs%rowtype;
  v_actor uuid; v_cached jsonb; v_payload jsonb; v_amount bigint;
  v_cost_entry uuid; v_earning uuid; v_result jsonb;
begin
  select * into v_assignment from public.production_worker_assignments where id=p_assignment_id;
  if not found then raise exception using errcode='P0002',message='Worker assignment not found'; end if;
  v_actor:=private.assert_active_owner(v_assignment.business_id);
  if p_request_id is null or p_actual_quantity is null or p_actual_quantity<=0
    or length(btrim(coalesce(p_description,''))) not between 1 and 240 then
    raise exception using errcode='22023',message='Valid actual work quantity, description and request ID are required';
  end if;

  v_payload:=jsonb_build_object('assignment_id',p_assignment_id,'actual_quantity',p_actual_quantity,
    'description',btrim(p_description));
  v_cached:=private.begin_idempotent_request(v_assignment.business_id,'confirm_worker_earnings',p_request_id,v_payload);
  if v_cached is not null then return v_cached; end if;

  select * into v_assignment from public.production_worker_assignments
  where business_id=v_assignment.business_id and id=p_assignment_id for update;
  if v_assignment.status<>'working' then
    raise exception using errcode='22023',message='Worker must have commenced work before earnings can be confirmed';
  end if;
  select * into v_job from public.production_jobs
  where business_id=v_assignment.business_id and id=v_assignment.job_id for update;
  if v_job.status not in ('in_progress','quality_check','rework') then
    raise exception using errcode='22023',message='Cannot confirm earnings against a closed production job';
  end if;
  select * into v_worker from public.production_workers
  where business_id=v_assignment.business_id and id=v_assignment.worker_id;
  if v_worker.worker_type='temporary' and v_assignment.commenced_at is null then
    raise exception using errcode='23514',message='Temporary worker commencement must be confirmed first';
  end if;
  if v_assignment.earnings_method='fixed_amount' and p_actual_quantity<>1 then
    raise exception using errcode='22023',message='Fixed job earnings use an actual quantity of 1 job';
  end if;

  v_amount:=round(p_actual_quantity*v_assignment.agreed_rate)::bigint;
  if v_amount<=0 then raise exception using errcode='22023',message='Confirmed worker earnings must be positive'; end if;

  insert into public.production_cost_entries(
    business_id,job_id,cost_type,description,quantity,unit,unit_rate,amount,actor_user_id
  ) values (
    v_assignment.business_id,v_assignment.job_id,'labour',
    'Worker earnings: '||btrim(p_description),p_actual_quantity,v_assignment.rate_unit,
    v_assignment.agreed_rate,v_amount,v_actor
  ) returning id into v_cost_entry;

  insert into public.production_worker_earnings(
    business_id,assignment_id,job_id,worker_id,earnings_method,agreed_rate,
    actual_quantity,unit,amount,description,cost_entry_id,confirmed_by,request_id
  ) values (
    v_assignment.business_id,p_assignment_id,v_assignment.job_id,v_assignment.worker_id,
    v_assignment.earnings_method,v_assignment.agreed_rate,p_actual_quantity,v_assignment.rate_unit,
    v_amount,btrim(p_description),v_cost_entry,v_actor,p_request_id
  ) returning id into v_earning;

  v_result:=jsonb_build_object('earning_id',v_earning,'cost_entry_id',v_cost_entry,'amount',v_amount,
    'status','confirmed','worker_id',v_assignment.worker_id);
  perform private.finish_idempotent_request(v_assignment.business_id,'confirm_worker_earnings',p_request_id,v_result);
  perform private.write_audit(v_assignment.business_id,v_actor,'production.worker_earnings_confirmed',
    'production_worker_earning',v_earning,p_request_id,
    jsonb_build_object('job_id',v_assignment.job_id,'cost_entry_id',v_cost_entry,'amount',v_amount));
  return v_result;
end;
$function$;

create or replace function private.owner_record_worker_payment(
  p_business_id uuid,p_worker_id uuid,p_amount bigint,p_payment_method text,
  p_reference text,p_notes text,p_paid_at timestamptz,p_allocations jsonb,p_request_id uuid
)
returns jsonb language plpgsql security definer set search_path=''
as $function$
declare
  v_actor uuid; v_cached jsonb; v_payload jsonb; v_payment uuid;
  v_alloc record; v_earning public.production_worker_earnings%rowtype;
  v_alloc_amount bigint; v_paid bigint; v_alloc_total bigint:=0;
  v_result jsonb; v_count integer:=0;
begin
  v_actor:=private.assert_active_owner(p_business_id);
  if p_request_id is null or p_amount is null or p_amount<=0
    or p_payment_method not in ('cash','mpesa','bank_transfer','other')
    or p_allocations is null or jsonb_typeof(p_allocations) is distinct from 'array'
    or jsonb_array_length(p_allocations) not between 1 and 100
    or not exists(select 1 from public.production_workers where business_id=p_business_id and id=p_worker_id and is_active) then
    raise exception using errcode='22023',message='Valid worker, payment details and earning allocations are required';
  end if;

  v_payload:=jsonb_build_object('worker_id',p_worker_id,'amount',p_amount,'payment_method',p_payment_method,
    'reference',p_reference,'notes',p_notes,'paid_at',p_paid_at,'allocations',p_allocations);
  v_cached:=private.begin_idempotent_request(p_business_id,'record_worker_payment',p_request_id,v_payload);
  if v_cached is not null then return v_cached; end if;

  if exists (
    select 1 from jsonb_array_elements(p_allocations) x(value)
    group by x.value->>'earning_id' having count(*)>1
  ) then
    raise exception using errcode='22023',message='An earning may appear only once in a payment allocation';
  end if;

  for v_alloc in select value from jsonb_array_elements(p_allocations) order by value->>'earning_id' loop
    v_earning:=null;
    select * into v_earning from public.production_worker_earnings
    where business_id=p_business_id and id=(v_alloc.value->>'earning_id')::uuid
      and worker_id=p_worker_id
    for update;
    if not found then raise exception using errcode='P0002',message='Worker earning not found'; end if;
    v_alloc_amount:=(v_alloc.value->>'amount')::bigint;
    if v_alloc_amount is null or v_alloc_amount<=0 then
      raise exception using errcode='22023',message='Each worker payment allocation must be positive';
    end if;
    select coalesce(sum(a.amount),0) into v_paid
    from public.production_worker_payment_allocations a
    join public.production_worker_payments p
      on p.business_id=a.business_id and p.id=a.payment_id
    where a.business_id=p_business_id and a.earning_id=v_earning.id and p.status='posted';
    if v_alloc_amount>v_earning.amount-v_paid then
      raise exception using errcode='23514',message='Worker payment exceeds the outstanding earning balance';
    end if;
    v_alloc_total:=v_alloc_total+v_alloc_amount;
    v_count:=v_count+1;
  end loop;

  if v_alloc_total<>p_amount then
    raise exception using errcode='23514',message='Payment amount must equal the sum of its earning allocations';
  end if;

  insert into public.production_worker_payments(
    business_id,worker_id,amount,payment_method,reference,notes,paid_at,recorded_by,request_id
  ) values (
    p_business_id,p_worker_id,p_amount,p_payment_method,nullif(btrim(p_reference),''),
    nullif(btrim(p_notes),''),coalesce(p_paid_at,now()),v_actor,p_request_id
  ) returning id into v_payment;

  for v_alloc in select value from jsonb_array_elements(p_allocations) order by value->>'earning_id' loop
    insert into public.production_worker_payment_allocations(
      business_id,payment_id,earning_id,amount
    ) values (
      p_business_id,v_payment,(v_alloc.value->>'earning_id')::uuid,(v_alloc.value->>'amount')::bigint
    );
  end loop;

  v_result:=jsonb_build_object('payment_id',v_payment,'amount',p_amount,'allocated_amount',v_alloc_total,
    'worker_id',p_worker_id,'status','posted');
  perform private.finish_idempotent_request(p_business_id,'record_worker_payment',p_request_id,v_result);
  perform private.write_audit(p_business_id,v_actor,'production.worker_payment_recorded',
    'production_worker_payment',v_payment,p_request_id,
    jsonb_build_object('worker_id',p_worker_id,'amount',p_amount,'allocation_count',v_count));
  return v_result;
end;
$function$;

create or replace function private.owner_adjust_temporary_labour_allocation(
  p_allocation_id uuid,p_revised_eligible_printing_revenue bigint,p_reason text,p_request_id uuid
)
returns jsonb language plpgsql security definer set search_path=''
as $function$
declare
  v_allocation public.temporary_labour_allocations%rowtype;
  v_actor uuid; v_cached jsonb; v_payload jsonb; v_previous bigint;
  v_adjustment numeric(18,2); v_adjustment_id uuid; v_result jsonb;
begin
  select * into v_allocation from public.temporary_labour_allocations where id=p_allocation_id;
  if not found then raise exception using errcode='P0002',message='Temporary-labour allocation not found'; end if;
  v_actor:=private.assert_active_owner(v_allocation.business_id);
  if p_request_id is null or p_revised_eligible_printing_revenue is null
    or p_revised_eligible_printing_revenue<0 or length(btrim(coalesce(p_reason,''))) not between 1 and 500 then
    raise exception using errcode='22023',message='Revised eligible printing revenue and reason are required';
  end if;

  v_payload:=jsonb_build_object('allocation_id',p_allocation_id,
    'revised_eligible_printing_revenue',p_revised_eligible_printing_revenue,'reason',btrim(p_reason));
  v_cached:=private.begin_idempotent_request(v_allocation.business_id,'adjust_temporary_labour_allocation',p_request_id,v_payload);
  if v_cached is not null then return v_cached; end if;

  select * into v_allocation from public.temporary_labour_allocations
  where business_id=v_allocation.business_id and id=p_allocation_id for update;

  select v_allocation.eligible_printing_revenue+coalesce(sum(a.revenue_delta),0)
  into v_previous
  from public.temporary_labour_adjustments a
  where a.business_id=v_allocation.business_id and a.allocation_id=p_allocation_id;

  v_adjustment:=round((p_revised_eligible_printing_revenue-v_previous)::numeric*0.20,2);
  insert into public.temporary_labour_adjustments(
    business_id,allocation_id,previous_eligible_printing_revenue,revised_eligible_printing_revenue,
    revenue_delta,allocation_rate,adjustment_amount,reason,approved_by,request_id
  ) values (
    v_allocation.business_id,p_allocation_id,v_previous,p_revised_eligible_printing_revenue,
    p_revised_eligible_printing_revenue-v_previous,20.00,v_adjustment,btrim(p_reason),v_actor,p_request_id
  ) returning id into v_adjustment_id;

  v_result:=jsonb_build_object('adjustment_id',v_adjustment_id,
    'previous_eligible_printing_revenue',v_previous,
    'revised_eligible_printing_revenue',p_revised_eligible_printing_revenue,
    'revenue_delta',p_revised_eligible_printing_revenue-v_previous,
    'adjustment_amount',v_adjustment,'allocation_rate',20.00);
  perform private.finish_idempotent_request(v_allocation.business_id,'adjust_temporary_labour_allocation',p_request_id,v_result);
  perform private.write_audit(v_allocation.business_id,v_actor,'production.temporary_labour_allocation_adjusted',
    'temporary_labour_allocation',p_allocation_id,p_request_id,
    jsonb_build_object('adjustment_id',v_adjustment_id,'adjustment_amount',v_adjustment,'reason',btrim(p_reason)));
  return v_result;
end;
$function$;

-- Append-only financial evidence and allocation history.
create trigger production_worker_earnings_immutable
  before update or delete on public.production_worker_earnings
  for each row execute function private.reject_ledger_mutation();
create trigger production_worker_payments_immutable
  before update or delete on public.production_worker_payments
  for each row execute function private.reject_ledger_mutation();
create trigger production_worker_payment_allocations_immutable
  before update or delete on public.production_worker_payment_allocations
  for each row execute function private.reject_ledger_mutation();
create trigger temporary_labour_allocations_immutable
  before update or delete on public.temporary_labour_allocations
  for each row execute function private.reject_ledger_mutation();
create trigger temporary_labour_adjustments_immutable
  before update or delete on public.temporary_labour_adjustments
  for each row execute function private.reject_ledger_mutation();

-- Thin invoker wrappers; privileged work remains in private owner-checked functions.
create or replace function public.owner_upsert_production_worker(
  p_business_id uuid,p_worker_id uuid,p_full_name text,p_phone text,p_worker_type text,p_request_id uuid
) returns jsonb language sql security invoker set search_path=''
as $function$ select private.owner_upsert_production_worker($1,$2,$3,$4,$5,$6); $function$;

create or replace function public.owner_assign_production_worker(
  p_job_id uuid,p_worker_id uuid,p_earnings_method text,p_agreed_rate bigint,p_rate_unit text,p_notes text,p_request_id uuid
) returns jsonb language sql security invoker set search_path=''
as $function$ select private.owner_assign_production_worker($1,$2,$3,$4,$5,$6,$7); $function$;

create or replace function public.owner_confirm_worker_commencement(p_assignment_id uuid,p_request_id uuid)
returns jsonb language sql security invoker set search_path=''
as $function$ select private.owner_confirm_worker_commencement($1,$2); $function$;

create or replace function public.owner_confirm_worker_earnings(
  p_assignment_id uuid,p_actual_quantity numeric,p_description text,p_request_id uuid
) returns jsonb language sql security invoker set search_path=''
as $function$ select private.owner_confirm_worker_earnings($1,$2,$3,$4); $function$;

create or replace function public.owner_record_worker_payment(
  p_business_id uuid,p_worker_id uuid,p_amount bigint,p_payment_method text,
  p_reference text,p_notes text,p_paid_at timestamptz,p_allocations jsonb,p_request_id uuid
) returns jsonb language sql security invoker set search_path=''
as $function$ select private.owner_record_worker_payment($1,$2,$3,$4,$5,$6,$7,$8,$9); $function$;

create or replace function public.owner_adjust_temporary_labour_allocation(
  p_allocation_id uuid,p_revised_eligible_printing_revenue bigint,p_reason text,p_request_id uuid
) returns jsonb language sql security invoker set search_path=''
as $function$ select private.owner_adjust_temporary_labour_allocation($1,$2,$3,$4); $function$;

revoke all on function private.owner_upsert_production_worker(uuid,uuid,text,text,text,uuid),
  private.owner_assign_production_worker(uuid,uuid,text,bigint,text,text,uuid),
  private.owner_confirm_worker_commencement(uuid,uuid),
  private.owner_confirm_worker_earnings(uuid,numeric,text,uuid),
  private.owner_record_worker_payment(uuid,uuid,bigint,text,text,text,timestamptz,jsonb,uuid),
  private.owner_adjust_temporary_labour_allocation(uuid,bigint,text,uuid)
from public,anon,authenticated;
grant usage on schema private to authenticated;
grant execute on function private.owner_upsert_production_worker(uuid,uuid,text,text,text,uuid),
  private.owner_assign_production_worker(uuid,uuid,text,bigint,text,text,uuid),
  private.owner_confirm_worker_commencement(uuid,uuid),
  private.owner_confirm_worker_earnings(uuid,numeric,text,uuid),
  private.owner_record_worker_payment(uuid,uuid,bigint,text,text,text,timestamptz,jsonb,uuid),
  private.owner_adjust_temporary_labour_allocation(uuid,bigint,text,uuid)
to authenticated;

revoke all on function public.owner_upsert_production_worker(uuid,uuid,text,text,text,uuid),
  public.owner_assign_production_worker(uuid,uuid,text,bigint,text,text,uuid),
  public.owner_confirm_worker_commencement(uuid,uuid),
  public.owner_confirm_worker_earnings(uuid,numeric,text,uuid),
  public.owner_record_worker_payment(uuid,uuid,bigint,text,text,text,timestamptz,jsonb,uuid),
  public.owner_adjust_temporary_labour_allocation(uuid,bigint,text,uuid)
from public,anon;
grant execute on function public.owner_upsert_production_worker(uuid,uuid,text,text,text,uuid),
  public.owner_assign_production_worker(uuid,uuid,text,bigint,text,text,uuid),
  public.owner_confirm_worker_commencement(uuid,uuid),
  public.owner_confirm_worker_earnings(uuid,numeric,text,uuid),
  public.owner_record_worker_payment(uuid,uuid,bigint,text,text,text,timestamptz,jsonb,uuid),
  public.owner_adjust_temporary_labour_allocation(uuid,bigint,text,uuid)
to authenticated;

commit;
