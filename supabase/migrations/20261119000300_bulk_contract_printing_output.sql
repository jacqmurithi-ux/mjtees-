-- Bulk / contract printing production output ledger.
-- Orders remain the financial source of truth; this ledger records actual shop-floor output.
create table if not exists public.production_output_entries (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  job_id uuid not null,
  quantity_printed numeric(12,3) not null check (quantity_printed > 0),
  quantity_rejected numeric(12,3) not null default 0 check (quantity_rejected >= 0 and quantity_rejected <= quantity_printed),
  quantity_reworked numeric(12,3) not null default 0 check (quantity_reworked >= 0 and quantity_reworked <= quantity_printed),
  quantity_accepted numeric(12,3) generated always as (quantity_printed - quantity_rejected) stored,
  worker_type text not null default 'owner' check (worker_type in ('owner','staff','temporary')),
  worker_name text,
  labour_cost bigint not null default 0 check (labour_cost >= 0),
  occurred_at timestamptz not null default now(),
  notes text,
  actor_user_id uuid not null references auth.users(id) on delete restrict,
  request_id uuid not null,
  created_at timestamptz not null default now(),
  constraint production_output_entries_business_job_fk
    foreign key (business_id,job_id) references public.production_jobs(business_id,id) on delete restrict,
  constraint production_output_entries_worker_name_check
    check ((worker_type='owner') or length(btrim(coalesce(worker_name,''))) between 1 and 180),
  constraint production_output_entries_notes_check
    check (notes is null or length(notes)<=2000),
  constraint production_output_entries_request_unique unique (business_id,request_id)
);

create index if not exists production_output_entries_business_occurred_idx
  on public.production_output_entries(business_id,occurred_at desc);
create index if not exists production_output_entries_job_occurred_idx
  on public.production_output_entries(business_id,job_id,occurred_at desc);

alter table public.production_output_entries enable row level security;
revoke all on table public.production_output_entries from anon,authenticated,public;

create or replace function private.owner_record_production_output(
  p_job_id uuid,
  p_quantity_printed numeric,
  p_quantity_rejected numeric,
  p_quantity_reworked numeric,
  p_worker_type text,
  p_worker_name text,
  p_labour_cost bigint,
  p_occurred_at timestamptz,
  p_notes text,
  p_request_id uuid
) returns jsonb
language plpgsql security definer set search_path=''
as $$
declare
  v_job public.production_jobs%rowtype;
  v_actor uuid;
  v_cached jsonb;
  v_payload jsonb;
  v_accepted_before numeric;
  v_accepted_after numeric;
  v_entry_id uuid;
  v_result jsonb;
begin
  select * into v_job from public.production_jobs where id=p_job_id for update;
  if not found then raise exception using errcode='P0002',message='Production job not found'; end if;
  v_actor:=private.assert_active_owner(v_job.business_id);

  if p_request_id is null or p_quantity_printed is null or p_quantity_printed<=0
    or p_quantity_rejected is null or p_quantity_rejected<0 or p_quantity_rejected>p_quantity_printed
    or p_quantity_reworked is null or p_quantity_reworked<0 or p_quantity_reworked>p_quantity_printed
    or p_worker_type not in ('owner','staff','temporary')
    or (p_worker_type<>'owner' and length(btrim(coalesce(p_worker_name,''))) not between 1 and 180)
    or p_labour_cost is null or p_labour_cost<0
    or p_occurred_at is null or p_occurred_at>now()+interval '5 minutes'
    or p_worker_type is null or length(coalesce(p_notes,''))>2000 then
    raise exception using errcode='22023',message='Invalid production output entry or job is not active';
  end if;

  v_payload:=jsonb_build_object(
    'job_id',p_job_id,'quantity_printed',p_quantity_printed,
    'quantity_rejected',p_quantity_rejected,'quantity_reworked',p_quantity_reworked,
    'worker_type',p_worker_type,'worker_name',nullif(btrim(p_worker_name),''),
    'labour_cost',p_labour_cost,'occurred_at',p_occurred_at,'notes',p_notes
  );
  v_cached:=private.begin_idempotent_request(v_job.business_id,'record_production_output',p_request_id,v_payload);
  if v_cached is not null then return v_cached; end if;
  if v_job.status not in ('planned','in_progress','quality_check','rework') then
    raise exception using errcode='55000',message='Production job is not active';
  end if;

  select coalesce(sum(quantity_accepted),0) into v_accepted_before
    from public.production_output_entries where business_id=v_job.business_id and job_id=p_job_id;
  v_accepted_after:=v_accepted_before+(p_quantity_printed-p_quantity_rejected);
  if v_accepted_after>v_job.planned_quantity then
    raise exception using errcode='22023',message='Accepted output cannot exceed the order-line quantity. Record rejected pieces separately and print replacements.';
  end if;

  insert into public.production_output_entries(
    business_id,job_id,quantity_printed,quantity_rejected,quantity_reworked,
    worker_type,worker_name,labour_cost,occurred_at,notes,actor_user_id,request_id
  ) values (
    v_job.business_id,p_job_id,p_quantity_printed,p_quantity_rejected,p_quantity_reworked,
    p_worker_type,nullif(btrim(p_worker_name),''),p_labour_cost,p_occurred_at,
    nullif(btrim(p_notes),''),v_actor,p_request_id
  ) returning id into v_entry_id;

  if p_labour_cost>0 then
    insert into public.production_cost_entries(
      business_id,job_id,cost_type,description,quantity,unit,unit_rate,amount,occurred_at,actor_user_id
    ) values (
      v_job.business_id,p_job_id,'labour',
      case when p_worker_type='owner' then 'Production labour · owner' else 'Production labour · '||btrim(p_worker_name) end,
      1,'batch',p_labour_cost,p_labour_cost,p_occurred_at,v_actor
    );
  end if;

  update public.production_jobs
    set status=case when v_accepted_after>=planned_quantity then 'quality_check' else 'in_progress' end,
        started_at=coalesce(started_at,p_occurred_at)
    where business_id=v_job.business_id and id=p_job_id;

  update public.orders o set status='in_production',updated_at=now()
    where o.business_id=v_job.business_id
      and o.id=(select oi.order_id from public.order_items oi where oi.business_id=v_job.business_id and oi.id=v_job.order_item_id)
      and o.status='confirmed';

  v_result:=jsonb_build_object(
    'entry_id',v_entry_id,'job_id',p_job_id,
    'quantity_printed',p_quantity_printed,
    'quantity_accepted',p_quantity_printed-p_quantity_rejected,
    'quantity_rejected',p_quantity_rejected,
    'quantity_reworked',p_quantity_reworked,
    'accepted_total',v_accepted_after,
    'planned_quantity',v_job.planned_quantity
  );
  perform private.finish_idempotent_request(v_job.business_id,'record_production_output',p_request_id,v_result);
  perform private.write_audit(v_job.business_id,v_actor,'production.output_recorded','production_output_entry',v_entry_id,p_request_id,v_result);
  return v_result;
end;
$$;

create or replace function private.owner_list_production_output(p_business_id uuid)
returns jsonb language plpgsql security definer set search_path=''
as $
declare v_actor uuid; v_result jsonb;
begin
  v_actor:=private.assert_active_owner(p_business_id);
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',e.id,'job_id',e.job_id,'quantity_printed',e.quantity_printed,
    'quantity_accepted',e.quantity_accepted,'quantity_rejected',e.quantity_rejected,
    'quantity_reworked',e.quantity_reworked,'worker_type',e.worker_type,
    'worker_name',e.worker_name,'labour_cost',e.labour_cost,
    'occurred_at',e.occurred_at,'notes',e.notes
  ) order by e.occurred_at desc),'[]'::jsonb)
  into v_result
  from (
    select * from public.production_output_entries
    where business_id=p_business_id
    order by occurred_at desc
    limit 1000
  ) e;
  return v_result;
end;
$;
revoke all on function private.owner_list_production_output(uuid) from public,anon;
grant execute on function private.owner_list_production_output(uuid) to authenticated;

create or replace function public.owner_list_production_output(p_business_id uuid)
returns jsonb language sql set search_path=''
as $ select private.owner_list_production_output($1); $;
revoke all on function public.owner_list_production_output(uuid) from public,anon;
grant execute on function public.owner_list_production_output(uuid) to authenticated;

revoke all on function private.owner_record_production_output(uuid,numeric,numeric,numeric,text,text,bigint,timestamptz,text,uuid) from public,anon;
grant execute on function private.owner_record_production_output(uuid,numeric,numeric,numeric,text,text,bigint,timestamptz,text,uuid) to authenticated;

create or replace function public.owner_record_production_output(
  p_job_id uuid,p_quantity_printed numeric,p_quantity_rejected numeric,p_quantity_reworked numeric,
  p_worker_type text,p_worker_name text,p_labour_cost bigint,p_occurred_at timestamptz,
  p_notes text,p_request_id uuid
) returns jsonb language sql set search_path=''
as $$ select private.owner_record_production_output($1,$2,$3,$4,$5,$6,$7,$8,$9,$10); $$;
revoke all on function public.owner_record_production_output(uuid,numeric,numeric,numeric,text,text,bigint,timestamptz,text,uuid) from public,anon;
grant execute on function public.owner_record_production_output(uuid,numeric,numeric,numeric,text,text,bigint,timestamptz,text,uuid) to authenticated;

create or replace function private.owner_get_bulk_printing_daily_summary(p_business_id uuid,p_business_date date)
returns jsonb language plpgsql security definer set search_path=''
as $
declare v_actor uuid; v_start timestamptz; v_end timestamptz; v_result jsonb;
begin
  v_actor:=private.assert_active_owner(p_business_id);
  if p_business_date is null then raise exception using errcode='22023',message='Business date is required'; end if;
  v_start:=p_business_date::timestamp at time zone 'Africa/Nairobi';
  v_end:=(p_business_date+1)::timestamp at time zone 'Africa/Nairobi';
  select jsonb_build_object(
    'business_date',p_business_date,
    'order_value',(select coalesce(sum(o.total_amount),0) from public.orders o
      where o.business_id=p_business_id and o.received_at>=v_start and o.received_at<v_end and o.status<>'cancelled'),
    'orders_received',(select count(*) from public.orders o
      where o.business_id=p_business_id and o.received_at>=v_start and o.received_at<v_end and o.status<>'cancelled'),
    'daily_printed',(select coalesce(sum(e.quantity_printed),0) from public.production_output_entries e
      where e.business_id=p_business_id and e.occurred_at>=v_start and e.occurred_at<v_end),
    'daily_accepted',(select coalesce(sum(e.quantity_accepted),0) from public.production_output_entries e
      where e.business_id=p_business_id and e.occurred_at>=v_start and e.occurred_at<v_end),
    'daily_rejected',(select coalesce(sum(e.quantity_rejected),0) from public.production_output_entries e
      where e.business_id=p_business_id and e.occurred_at>=v_start and e.occurred_at<v_end),
    'daily_reworked',(select coalesce(sum(e.quantity_reworked),0) from public.production_output_entries e
      where e.business_id=p_business_id and e.occurred_at>=v_start and e.occurred_at<v_end),
    'all_time_printed',(select coalesce(sum(e.quantity_printed),0) from public.production_output_entries e where e.business_id=p_business_id),
    'all_time_accepted',(select coalesce(sum(e.quantity_accepted),0) from public.production_output_entries e where e.business_id=p_business_id),
    'all_time_rejected',(select coalesce(sum(e.quantity_rejected),0) from public.production_output_entries e where e.business_id=p_business_id)
  ) into v_result;
  return v_result;
end;
$;
revoke all on function private.owner_get_bulk_printing_daily_summary(uuid,date) from public,anon;
grant execute on function private.owner_get_bulk_printing_daily_summary(uuid,date) to authenticated;

create or replace function public.owner_get_bulk_printing_daily_summary(p_business_id uuid,p_business_date date)
returns jsonb language sql set search_path=''
as $ select private.owner_get_bulk_printing_daily_summary($1,$2); $;
revoke all on function public.owner_get_bulk_printing_daily_summary(uuid,date) from public,anon;
grant execute on function public.owner_get_bulk_printing_daily_summary(uuid,date) to authenticated;

-- Output is append-only. Corrections are new entries, never edits to the original record.
create or replace function private.guard_production_output_append_only()
returns trigger language plpgsql set search_path=''
as $$
begin
  raise exception using errcode='55000',message='Production output entries are append-only; record a correcting entry instead';
end;
$$;
drop trigger if exists production_output_entries_append_only on public.production_output_entries;
create trigger production_output_entries_append_only
  before update or delete on public.production_output_entries
  for each row execute function private.guard_production_output_append_only();
