-- Daily production batches and immutable garment quantity-state movements.
-- New jobs require quantity reconciliation at completion. Existing jobs retain their
-- pre-migration completion path to avoid inventing historical garment movements.

begin;

alter table public.production_jobs
  add column quantity_tracking_required boolean not null default false;
alter table public.production_jobs
  alter column quantity_tracking_required set default true;

create table public.production_batches (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  job_id uuid not null,
  batch_number integer not null check (batch_number > 0),
  production_date date not null,
  status text not null default 'open' check (status in ('open','closed')),
  notes text,
  opened_by uuid not null references auth.users(id) on delete restrict,
  opened_at timestamptz not null default now(),
  closed_by uuid references auth.users(id) on delete restrict,
  closed_at timestamptz,
  close_notes text,
  foreign key (business_id,job_id) references public.production_jobs(business_id,id) on delete restrict,
  unique (business_id,id),
  unique (business_id,job_id,batch_number),
  check (
    (status='open' and closed_by is null and closed_at is null)
    or (status='closed' and closed_by is not null and closed_at is not null)
  )
);

create table public.production_quantity_movements (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  job_id uuid not null,
  batch_id uuid not null,
  movement_type text not null check (movement_type in (
    'received','additional_received','replacement_received',
    'started','accepted','rework','rework_from_accepted','rework_passed','rejected','rework_rejected'
  )),
  from_state text check (from_state is null or from_state in ('pending','in_production','accepted','rework','rejected')),
  to_state text not null check (to_state in ('pending','in_production','accepted','rework','rejected')),
  quantity numeric(12,3) not null check (quantity > 0),
  reason text,
  actor_user_id uuid not null references auth.users(id) on delete restrict,
  request_id uuid not null,
  occurred_at timestamptz not null default now(),
  foreign key (business_id,job_id) references public.production_jobs(business_id,id) on delete restrict,
  foreign key (business_id,batch_id) references public.production_batches(business_id,id) on delete restrict,
  unique (business_id,id),
  unique (business_id,request_id),
  check (
    (movement_type in ('received','additional_received','replacement_received')
      and from_state is null and to_state='pending')
    or (movement_type='started' and from_state='pending' and to_state='in_production')
    or (movement_type='accepted' and from_state='in_production' and to_state='accepted')
    or (movement_type='rework' and from_state='in_production' and to_state='rework')
    or (movement_type='rework_from_accepted' and from_state='accepted' and to_state='rework')
    or (movement_type='rework_passed' and from_state='rework' and to_state='accepted')
    or (movement_type='rejected' and from_state='in_production' and to_state='rejected')
    or (movement_type='rework_rejected' and from_state='rework' and to_state='rejected')
  )
);

create index production_batches_job_date_idx
  on public.production_batches(business_id,job_id,production_date desc,batch_number desc);
create index production_quantity_movements_job_state_idx
  on public.production_quantity_movements(business_id,job_id,occurred_at);
create index production_quantity_movements_batch_idx
  on public.production_quantity_movements(business_id,batch_id,occurred_at);

alter table public.production_batches enable row level security;
alter table public.production_quantity_movements enable row level security;

create policy production_batches_owner_select on public.production_batches
  for select to authenticated using (private.is_active_owner(business_id));
create policy production_quantity_movements_owner_select on public.production_quantity_movements
  for select to authenticated using (private.is_active_owner(business_id));

revoke all on public.production_batches,public.production_quantity_movements from anon,authenticated;
grant select on public.production_batches,public.production_quantity_movements to authenticated;

create or replace function private.owner_create_production_batch(
  p_job_id uuid,p_production_date date,p_notes text,p_request_id uuid
)
returns jsonb language plpgsql security definer set search_path=''
as $function$
declare
  v_job public.production_jobs%rowtype; v_actor uuid; v_cached jsonb; v_payload jsonb;
  v_batch uuid; v_number integer; v_result jsonb;
begin
  select * into v_job from public.production_jobs where id=p_job_id;
  if not found then raise exception using errcode='P0002',message='Production job not found'; end if;
  v_actor:=private.assert_active_owner(v_job.business_id);
  if p_request_id is null or p_production_date is null then
    raise exception using errcode='22023',message='Production date and request ID are required';
  end if;
  v_payload:=jsonb_build_object('job_id',p_job_id,'production_date',p_production_date,'notes',p_notes);
  v_cached:=private.begin_idempotent_request(v_job.business_id,'create_production_batch',p_request_id,v_payload);
  if v_cached is not null then return v_cached; end if;

  select * into v_job from public.production_jobs
  where business_id=v_job.business_id and id=p_job_id for update;
  if v_job.status in ('completed','cancelled') then
    raise exception using errcode='22023',message='Cannot create a batch for a closed production job';
  end if;
  select coalesce(max(batch_number),0)+1 into v_number
  from public.production_batches where business_id=v_job.business_id and job_id=p_job_id;

  insert into public.production_batches(
    business_id,job_id,batch_number,production_date,notes,opened_by
  ) values (
    v_job.business_id,p_job_id,v_number,p_production_date,nullif(btrim(p_notes),''),v_actor
  ) returning id into v_batch;

  v_result:=jsonb_build_object('batch_id',v_batch,'batch_number',v_number,'status','open');
  perform private.finish_idempotent_request(v_job.business_id,'create_production_batch',p_request_id,v_result);
  perform private.write_audit(v_job.business_id,v_actor,'production.batch_created','production_batch',v_batch,p_request_id,
    jsonb_build_object('job_id',p_job_id,'batch_number',v_number,'production_date',p_production_date));
  return v_result;
end;
$function$;

create or replace function private.owner_record_production_quantity_movement(
  p_job_id uuid,p_batch_id uuid,p_movement_type text,p_quantity numeric,p_reason text,p_request_id uuid
)
returns jsonb language plpgsql security definer set search_path=''
as $function$
declare
  v_job public.production_jobs%rowtype; v_batch public.production_batches%rowtype;
  v_actor uuid; v_cached jsonb; v_payload jsonb; v_from text; v_to text;
  v_available numeric; v_received numeric; v_movement uuid; v_result jsonb;
begin
  select * into v_job from public.production_jobs where id=p_job_id;
  if not found then raise exception using errcode='P0002',message='Production job not found'; end if;
  v_actor:=private.assert_active_owner(v_job.business_id);
  if p_request_id is null or p_quantity is null or p_quantity<=0
    or p_movement_type not in ('received','additional_received','replacement_received','started',
      'accepted','rework','rework_from_accepted','rework_passed','rejected','rework_rejected') then
    raise exception using errcode='22023',message='Valid movement type, positive quantity and request ID are required';
  end if;
  if p_movement_type in ('additional_received','replacement_received')
    and length(btrim(coalesce(p_reason,'')))=0 then
    raise exception using errcode='22023',message='Additional or replacement quantities require an owner reason';
  end if;

  v_payload:=jsonb_build_object('job_id',p_job_id,'batch_id',p_batch_id,
    'movement_type',p_movement_type,'quantity',p_quantity,'reason',p_reason);
  v_cached:=private.begin_idempotent_request(v_job.business_id,'record_production_quantity_movement',p_request_id,v_payload);
  if v_cached is not null then return v_cached; end if;

  select * into v_job from public.production_jobs
  where business_id=v_job.business_id and id=p_job_id for update;
  if v_job.status in ('completed','cancelled') then
    raise exception using errcode='22023',message='Cannot record quantities on a closed production job';
  end if;
  select * into v_batch from public.production_batches
  where business_id=v_job.business_id and id=p_batch_id and job_id=p_job_id for update;
  if not found or v_batch.status<>'open' then
    raise exception using errcode='22023',message='An open batch belonging to this production job is required';
  end if;

  case p_movement_type
    when 'received' then v_from:=null; v_to:='pending';
    when 'additional_received' then v_from:=null; v_to:='pending';
    when 'replacement_received' then v_from:=null; v_to:='pending';
    when 'started' then v_from:='pending'; v_to:='in_production';
    when 'accepted' then v_from:='in_production'; v_to:='accepted';
    when 'rework' then v_from:='in_production'; v_to:='rework';
    when 'rework_from_accepted' then v_from:='accepted'; v_to:='rework';
    when 'rework_passed' then v_from:='rework'; v_to:='accepted';
    when 'rejected' then v_from:='in_production'; v_to:='rejected';
    when 'rework_rejected' then v_from:='rework'; v_to:='rejected';
  end case;

  if p_movement_type in ('accepted','rework_passed') and not exists (
    select 1 from public.quality_checks q
    where q.business_id=v_job.business_id and q.job_id=p_job_id and q.result='pass'
      and q.id=(select q2.id from public.quality_checks q2
        where q2.business_id=v_job.business_id and q2.job_id=p_job_id
        order by q2.checked_at desc,q2.id desc limit 1)
  ) then
    raise exception using errcode='23514',message='A latest passing quality check is required before accepting quantities';
  end if;
  if p_movement_type in ('rework','rework_from_accepted','rejected','rework_rejected') and not exists (
    select 1 from public.quality_checks q
    where q.business_id=v_job.business_id and q.job_id=p_job_id and q.result='fail'
      and q.id=(select q2.id from public.quality_checks q2
        where q2.business_id=v_job.business_id and q2.job_id=p_job_id
        order by q2.checked_at desc,q2.id desc limit 1)
  ) then
    raise exception using errcode='23514',message='A latest failed quality check is required before moving quantities to rework or rejection';
  end if;

  if v_from is null then
    select coalesce(sum(quantity),0) into v_received
    from public.production_quantity_movements
    where business_id=v_job.business_id and job_id=p_job_id
      and from_state is null and to_state='pending';
    if p_movement_type='received' and v_received+p_quantity>v_job.planned_quantity then
      raise exception using errcode='23514',
        message='Received quantity exceeds planned quantity; record an authorized additional or replacement quantity with a reason';
    end if;
  else
    select coalesce(sum(case when to_state=v_from then quantity else 0 end),0)
      - coalesce(sum(case when from_state=v_from then quantity else 0 end),0)
    into v_available
    from public.production_quantity_movements
    where business_id=v_job.business_id and job_id=p_job_id;
    if v_available<p_quantity then
      raise exception using errcode='23514',message='Movement quantity exceeds the available quantity in the source state';
    end if;
  end if;

  insert into public.production_quantity_movements(
    business_id,job_id,batch_id,movement_type,from_state,to_state,quantity,reason,actor_user_id,request_id
  ) values (
    v_job.business_id,p_job_id,p_batch_id,p_movement_type,v_from,v_to,p_quantity,
    nullif(btrim(p_reason),''),v_actor,p_request_id
  ) returning id into v_movement;

  if v_job.status='planned' and p_movement_type in ('received','additional_received','replacement_received') then
    update public.production_jobs set status='in_progress' where business_id=v_job.business_id and id=p_job_id;
  end if;

  v_result:=jsonb_build_object('movement_id',v_movement,'movement_type',p_movement_type,
    'from_state',v_from,'to_state',v_to,'quantity',p_quantity);
  perform private.finish_idempotent_request(v_job.business_id,'record_production_quantity_movement',p_request_id,v_result);
  perform private.write_audit(v_job.business_id,v_actor,'production.quantity_moved','production_job',p_job_id,p_request_id,
    jsonb_build_object('batch_id',p_batch_id,'movement_id',v_movement,'movement_type',p_movement_type,
      'from_state',v_from,'to_state',v_to,'quantity',p_quantity,'reason',p_reason));
  return v_result;
end;
$function$;

create or replace function private.owner_close_production_batch(
  p_batch_id uuid,p_close_notes text,p_request_id uuid
)
returns jsonb language plpgsql security definer set search_path=''
as $function$
declare
  v_batch public.production_batches%rowtype; v_actor uuid; v_cached jsonb; v_payload jsonb; v_result jsonb;
begin
  select * into v_batch from public.production_batches where id=p_batch_id;
  if not found then raise exception using errcode='P0002',message='Production batch not found'; end if;
  v_actor:=private.assert_active_owner(v_batch.business_id);
  if p_request_id is null then raise exception using errcode='22023',message='Request ID is required'; end if;
  v_payload:=jsonb_build_object('batch_id',p_batch_id,'close_notes',p_close_notes);
  v_cached:=private.begin_idempotent_request(v_batch.business_id,'close_production_batch',p_request_id,v_payload);
  if v_cached is not null then return v_cached; end if;

  select * into v_batch from public.production_batches
  where business_id=v_batch.business_id and id=p_batch_id for update;
  if v_batch.status<>'open' then
    raise exception using errcode='22023',message='Production batch is already closed';
  end if;
  if not exists(select 1 from public.production_quantity_movements
    where business_id=v_batch.business_id and batch_id=p_batch_id) then
    raise exception using errcode='22023',message='A batch needs at least one quantity movement before it can close';
  end if;

  update public.production_batches
  set status='closed',closed_by=v_actor,closed_at=now(),close_notes=nullif(btrim(p_close_notes),'')
  where business_id=v_batch.business_id and id=p_batch_id;

  v_result:=jsonb_build_object('batch_id',p_batch_id,'status','closed');
  perform private.finish_idempotent_request(v_batch.business_id,'close_production_batch',p_request_id,v_result);
  perform private.write_audit(v_batch.business_id,v_actor,'production.batch_closed','production_batch',p_batch_id,p_request_id,
    jsonb_build_object('job_id',v_batch.job_id,'close_notes',p_close_notes));
  return v_result;
end;
$function$;

create or replace function private.guard_production_job_quantity_completion()
returns trigger
language plpgsql
security definer
set search_path=''
as $function$
declare
  v_received numeric; v_pending numeric; v_in_production numeric;
  v_accepted numeric; v_rework numeric; v_rejected numeric;
begin
  if new.status='completed' and old.status is distinct from 'completed'
    and new.quantity_tracking_required then

    if exists(
      select 1 from public.production_batches b
      where b.business_id=new.business_id and b.job_id=new.id and b.status='open'
    ) then
      raise exception using errcode='23514',message='Close every production batch before completing the job';
    end if;

    select
      coalesce(sum(case when from_state is null and to_state='pending' then quantity else 0 end),0),
      coalesce(sum(case when to_state='pending' then quantity else 0 end),0)
        - coalesce(sum(case when from_state='pending' then quantity else 0 end),0),
      coalesce(sum(case when to_state='in_production' then quantity else 0 end),0)
        - coalesce(sum(case when from_state='in_production' then quantity else 0 end),0),
      coalesce(sum(case when to_state='accepted' then quantity else 0 end),0)
        - coalesce(sum(case when from_state='accepted' then quantity else 0 end),0),
      coalesce(sum(case when to_state='rework' then quantity else 0 end),0)
        - coalesce(sum(case when from_state='rework' then quantity else 0 end),0),
      coalesce(sum(case when to_state='rejected' then quantity else 0 end),0)
        - coalesce(sum(case when from_state='rejected' then quantity else 0 end),0)
    into v_received,v_pending,v_in_production,v_accepted,v_rework,v_rejected
    from public.production_quantity_movements
    where business_id=new.business_id and job_id=new.id;

    if v_received<new.planned_quantity then
      raise exception using errcode='23514',message='Received quantity is below the planned production quantity';
    end if;
    if v_pending<>0 or v_in_production<>0 or v_rework<>0 then
      raise exception using errcode='23514',message='Pending, in-production and rework quantities must be resolved before completion';
    end if;
    if v_accepted+v_rejected<>v_received then
      raise exception using errcode='23514',message='Accepted plus rejected quantities must reconcile to total received quantity';
    end if;
    if v_accepted<=0 then
      raise exception using errcode='23514',message='At least one accepted garment is required before completing the production job';
    end if;
  end if;
  return new;
end;
$function$;

create trigger production_job_quantity_completion_guard
before update of status on public.production_jobs
for each row execute function private.guard_production_job_quantity_completion();

create trigger production_quantity_movements_immutable
before update or delete on public.production_quantity_movements
for each row execute function private.reject_ledger_mutation();

create or replace function public.owner_create_production_batch(
  p_job_id uuid,p_production_date date,p_notes text,p_request_id uuid
) returns jsonb language sql security invoker set search_path=''
as $function$ select private.owner_create_production_batch($1,$2,$3,$4); $function$;

create or replace function public.owner_record_production_quantity_movement(
  p_job_id uuid,p_batch_id uuid,p_movement_type text,p_quantity numeric,p_reason text,p_request_id uuid
) returns jsonb language sql security invoker set search_path=''
as $function$ select private.owner_record_production_quantity_movement($1,$2,$3,$4,$5,$6); $function$;

create or replace function public.owner_close_production_batch(
  p_batch_id uuid,p_close_notes text,p_request_id uuid
) returns jsonb language sql security invoker set search_path=''
as $function$ select private.owner_close_production_batch($1,$2,$3); $function$;

revoke all on function private.owner_create_production_batch(uuid,date,text,uuid),
  private.owner_record_production_quantity_movement(uuid,uuid,text,numeric,text,uuid),
  private.owner_close_production_batch(uuid,text,uuid),
  private.guard_production_job_quantity_completion()
from public,anon,authenticated;
grant usage on schema private to authenticated;
grant execute on function private.owner_create_production_batch(uuid,date,text,uuid),
  private.owner_record_production_quantity_movement(uuid,uuid,text,numeric,text,uuid),
  private.owner_close_production_batch(uuid,text,uuid)
to authenticated;

revoke all on function public.owner_create_production_batch(uuid,date,text,uuid),
  public.owner_record_production_quantity_movement(uuid,uuid,text,numeric,text,uuid),
  public.owner_close_production_batch(uuid,text,uuid)
from public,anon;
grant execute on function public.owner_create_production_batch(uuid,date,text,uuid),
  public.owner_record_production_quantity_movement(uuid,uuid,text,numeric,text,uuid),
  public.owner_close_production_batch(uuid,text,uuid)
to authenticated;

commit;
