-- Owner-controlled production scheduling, quality checks, handover and calendar dates.
-- This is a branch migration only; it does not seed production data.

alter table public.production_jobs
 add column if not exists production_status text not null default 'created',
 add column if not exists expected_start_at timestamptz,
 add column if not exists expected_completion_at timestamptz,
 add column if not exists actual_started_at timestamptz,
 add column if not exists actual_completed_at timestamptz,
 add column if not exists delivery_at timestamptz,
 add column if not exists assigned_to uuid references auth.users(id),
 add column if not exists delay_reason text,
 add column if not exists quality_check_passed boolean,
 add column if not exists quality_checked_at timestamptz,
 add column if not exists quality_checked_by uuid references auth.users(id),
 add column if not exists quality_check_notes text,
 add column if not exists quality_override_reason text,
 add column if not exists handover_at timestamptz,
 add column if not exists handover_method text,
 add column if not exists handover_recipient text,
 add column if not exists handover_by uuid references auth.users(id),
 add column if not exists handover_notes text;

alter table public.production_jobs drop constraint if exists production_jobs_production_status_check;
alter table public.production_jobs add constraint production_jobs_production_status_check
 check(production_status in(
  'created','awaiting_materials','ready_for_production','in_production',
  'quality_check','completed','ready_for_collection','delivered','cancelled'
 ));
alter table public.production_jobs drop constraint if exists production_jobs_handover_method_check;
alter table public.production_jobs add constraint production_jobs_handover_method_check
 check(handover_method is null or handover_method in('collection','delivery','other'));
alter table public.production_jobs drop constraint if exists production_jobs_schedule_order_check;
alter table public.production_jobs add constraint production_jobs_schedule_order_check
 check(
  expected_start_at is null or expected_completion_at is null
  or expected_start_at<=expected_completion_at
 );
alter table public.production_jobs add constraint production_jobs_delivery_schedule_check
 check(
  expected_completion_at is null or delivery_at is null
  or expected_completion_at<=delivery_at
 );

update public.production_jobs
set production_status=case stage
 when 'screens_prepared' then 'ready_for_production'
 when 'printing' then 'in_production'
 when 'finishing' then 'in_production'
 when 'quality_check' then 'quality_check'
 when 'ready' then 'ready_for_collection'
 when 'delivered' then 'delivered'
 when 'cancelled' then 'cancelled'
 else 'created'
end;

create index if not exists production_jobs_calendar_start_idx
 on public.production_jobs(business_id,expected_start_at);
create index if not exists production_jobs_calendar_completion_idx
 on public.production_jobs(business_id,expected_completion_at);
create index if not exists production_jobs_calendar_delivery_idx
 on public.production_jobs(business_id,delivery_at);

create or replace function public.owner_update_production_schedule(
 p_job_id uuid,
 p_expected_start_at timestamptz default null,
 p_expected_completion_at timestamptz default null,
 p_delivery_at timestamptz default null,
 p_assigned_to uuid default null,
 p_delay_reason text default null
) returns void
language plpgsql security definer set search_path=public,pg_temp
as $fn$
declare v_business uuid;
begin
 if auth.uid() is null then raise exception 'Authentication required'; end if;
 select business_id into v_business from public.production_jobs where id=p_job_id for update;
 if v_business is null or not exists(
  select 1 from public.business_memberships
  where business_id=v_business and user_id=auth.uid() and role='owner'
 ) then raise exception 'Production job not found'; end if;
 if p_expected_start_at is not null and p_expected_completion_at is not null
    and p_expected_start_at>p_expected_completion_at then
  raise exception 'Expected start must be before expected completion';
 end if;
 if p_expected_completion_at is not null and p_delivery_at is not null
    and p_expected_completion_at>p_delivery_at then
  raise exception 'Delivery date cannot be before expected completion';
 end if;
 if p_assigned_to is not null and not exists(
  select 1 from public.business_memberships
  where business_id=v_business and user_id=p_assigned_to and role in('owner','staff')
 ) then raise exception 'Assigned staff member must belong to this business'; end if;
 if nullif(btrim(p_delay_reason),'') is not null and length(btrim(p_delay_reason))<5 then
  raise exception 'Delay reason must contain at least 5 characters';
 end if;
 update public.production_jobs set
  expected_start_at=p_expected_start_at,
  expected_completion_at=p_expected_completion_at,
  delivery_at=p_delivery_at,
  assigned_to=p_assigned_to,
  delay_reason=nullif(btrim(p_delay_reason),'')
 where id=p_job_id and business_id=v_business;
 insert into public.audit_events(business_id,actor_user_id,event_type,entity_type,entity_id,details)
 values(v_business,auth.uid(),'production.schedule_updated','production_job',p_job_id,
  jsonb_build_object('expected_start_at',p_expected_start_at,
   'expected_completion_at',p_expected_completion_at,'delivery_at',p_delivery_at,
   'assigned_to',p_assigned_to,'delay_reason',nullif(btrim(p_delay_reason),'')));
end
$fn$;

create or replace function public.owner_set_production_status(
 p_job_id uuid,p_status text
) returns void
language plpgsql security definer set search_path=public,pg_temp
as $fn$
declare
 v_job public.production_jobs%rowtype;
 v_shortage boolean;
begin
 if auth.uid() is null then raise exception 'Authentication required'; end if;
 if p_status not in(
  'created','awaiting_materials','ready_for_production','in_production',
  'quality_check','completed','ready_for_collection','delivered','cancelled'
 ) then raise exception 'Unsupported production status'; end if;
 select * into v_job from public.production_jobs where id=p_job_id for update;
 if not found or not exists(
  select 1 from public.business_memberships
  where business_id=v_job.business_id and user_id=auth.uid() and role='owner'
 ) then raise exception 'Production job not found'; end if;
 if not (
  (v_job.production_status='created' and p_status in('awaiting_materials','ready_for_production','cancelled')) or
  (v_job.production_status='awaiting_materials' and p_status in('ready_for_production','cancelled')) or
  (v_job.production_status='ready_for_production' and p_status in('in_production','cancelled')) or
  (v_job.production_status='in_production' and p_status in('quality_check','cancelled')) or
  (v_job.production_status='quality_check' and p_status in('in_production','completed','cancelled')) or
  (v_job.production_status='completed' and p_status in('ready_for_collection','cancelled')) or
  (v_job.production_status='ready_for_collection' and p_status in('delivered','cancelled'))
 ) then raise exception 'Invalid production status transition'; end if;

 if p_status='ready_for_production' then
  select exists(
   select 1
   from public.production_job_materials m
   join public.stock_items s on s.id=m.stock_item_id and s.business_id=m.business_id
   where m.job_id=p_job_id and m.business_id=v_job.business_id
    and s.quantity_on_hand<greatest(m.planned_quantity-m.issued_quantity,0)
  ) into v_shortage;
  if v_shortage then raise exception 'Materials shortage: replenish or revise the material plan before production'; end if;
 end if;
 if v_job.production_status='quality_check' and p_status='in_production'
    and (coalesce(v_job.quality_check_passed,false) or nullif(btrim(v_job.quality_override_reason),'') is not null) then
  raise exception 'A passed or overridden quality check cannot return to production without a new authorised workflow';
 end if;
 if p_status='completed'
    and not coalesce(v_job.quality_check_passed,false)
    and length(btrim(coalesce(v_job.quality_override_reason,'')))<5 then
  raise exception 'Quality check must pass or have a recorded override reason';
 end if;
 if p_status='delivered' and v_job.handover_at is null then
  raise exception 'Record collection or delivery handover before closing the job';
 end if;

 update public.production_jobs set
  production_status=p_status,
  actual_started_at=case when p_status='in_production' then coalesce(actual_started_at,now()) else actual_started_at end,
  actual_completed_at=case when p_status='completed' then coalesce(actual_completed_at,now()) else actual_completed_at end,
  delivered_at=case when p_status='delivered' then now() else delivered_at end,
  quality_check_passed=case when p_status='quality_check' then null else quality_check_passed end,
  quality_checked_at=case when p_status='quality_check' then null else quality_checked_at end,
  quality_checked_by=case when p_status='quality_check' then null else quality_checked_by end,
  quality_check_notes=case when p_status='quality_check' then null else quality_check_notes end,
  quality_override_reason=case when p_status='quality_check' then null else quality_override_reason end
 where id=p_job_id and business_id=v_job.business_id;

 insert into public.audit_events(business_id,actor_user_id,event_type,entity_type,entity_id,details)
 values(v_job.business_id,auth.uid(),'production.status_changed','production_job',p_job_id,
  jsonb_build_object('from',v_job.production_status,'to',p_status));
end
$fn$;

create or replace function public.owner_record_production_quality_check(
 p_job_id uuid,p_passed boolean,p_notes text,p_override_reason text default null
) returns void
language plpgsql security definer set search_path=public,pg_temp
as $fn$
declare v_job public.production_jobs%rowtype;
begin
 if auth.uid() is null then raise exception 'Authentication required'; end if;
 if p_passed is null then raise exception 'Record whether the quality check passed or failed'; end if;
 if length(btrim(coalesce(p_notes,'')))<3 then raise exception 'Quality check notes are required'; end if;
 if not p_passed and nullif(btrim(p_override_reason),'') is not null and length(btrim(p_override_reason))<5 then
  raise exception 'Quality override reason must contain at least 5 characters';
 end if;
 select * into v_job from public.production_jobs where id=p_job_id for update;
 if not found or not exists(
  select 1 from public.business_memberships
  where business_id=v_job.business_id and user_id=auth.uid() and role='owner'
 ) then raise exception 'Production job not found'; end if;
 if v_job.production_status<>'quality_check' then raise exception 'Job must be in quality check before recording its result'; end if;
 update public.production_jobs set
  quality_check_passed=p_passed,quality_checked_at=now(),quality_checked_by=auth.uid(),
  quality_check_notes=btrim(p_notes),
  quality_override_reason=case when p_passed then null else nullif(btrim(p_override_reason),'') end
 where id=p_job_id and business_id=v_job.business_id;
 insert into public.audit_events(business_id,actor_user_id,event_type,entity_type,entity_id,details)
 values(v_job.business_id,auth.uid(),'production.quality_checked','production_job',p_job_id,
  jsonb_build_object('passed',p_passed,'notes',btrim(p_notes),
   'override_reason',case when p_passed then null else nullif(btrim(p_override_reason),'') end));
end
$fn$;

create or replace function public.owner_record_production_handover(
 p_job_id uuid,p_method text,p_recipient text,p_notes text
) returns void
language plpgsql security definer set search_path=public,pg_temp
as $fn$
declare v_job public.production_jobs%rowtype;
begin
 if auth.uid() is null then raise exception 'Authentication required'; end if;
 if p_method not in('collection','delivery','other') then raise exception 'Select a valid handover method'; end if;
 if length(btrim(coalesce(p_recipient,'')))<2 then raise exception 'Handover recipient is required'; end if;
 if length(btrim(coalesce(p_notes,'')))<3 then raise exception 'Handover notes or customer confirmation are required'; end if;
 select * into v_job from public.production_jobs where id=p_job_id for update;
 if not found or not exists(
  select 1 from public.business_memberships
  where business_id=v_job.business_id and user_id=auth.uid() and role='owner'
 ) then raise exception 'Production job not found'; end if;
 if v_job.production_status<>'ready_for_collection' then raise exception 'Job must be ready for collection or delivery before handover'; end if;
 update public.production_jobs set
  handover_at=now(),handover_method=p_method,handover_recipient=btrim(p_recipient),
  handover_by=auth.uid(),handover_notes=btrim(p_notes)
 where id=p_job_id and business_id=v_job.business_id;
 insert into public.audit_events(business_id,actor_user_id,event_type,entity_type,entity_id,details)
 values(v_job.business_id,auth.uid(),'production.handover_recorded','production_job',p_job_id,
  jsonb_build_object('method',p_method,'recipient',btrim(p_recipient),'notes',btrim(p_notes)));
end
$fn$;

revoke all on function public.owner_update_production_schedule(uuid,timestamptz,timestamptz,timestamptz,uuid,text) from public,anon;
revoke all on function public.owner_set_production_status(uuid,text) from public,anon;
revoke all on function public.owner_record_production_quality_check(uuid,boolean,text,text) from public,anon;
revoke all on function public.owner_record_production_handover(uuid,text,text,text) from public,anon;
grant execute on function public.owner_update_production_schedule(uuid,timestamptz,timestamptz,timestamptz,uuid,text) to authenticated;
grant execute on function public.owner_set_production_status(uuid,text) to authenticated;
grant execute on function public.owner_record_production_quality_check(uuid,boolean,text,text) to authenticated;
grant execute on function public.owner_record_production_handover(uuid,text,text,text) to authenticated;

notify pgrst,'reload schema';
