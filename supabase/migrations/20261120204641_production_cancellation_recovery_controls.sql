alter table public.production_jobs
  add column if not exists cancellation_reason text,
  add column if not exists cancelled_at timestamptz,
  add column if not exists cancelled_by uuid references auth.users(id);

create or replace function public.owner_set_production_status(p_job_id uuid,p_status text)
returns void
language plpgsql
security definer
set search_path to 'public','pg_temp'
as $function$
declare
 v_job public.production_jobs%rowtype;
 v_shortage boolean;
begin
 if auth.uid() is null then raise exception 'Authentication required'; end if;
 if p_status not in ('created','awaiting_materials','ready_for_production','in_production','quality_check','completed','ready_for_collection','delivered') then
   raise exception 'Unsupported production status. Use the separate cancellation action to cancel a job.';
 end if;
 select * into v_job from public.production_jobs where id=p_job_id for update;
 if not found or not exists(select 1 from public.business_memberships where business_id=v_job.business_id and user_id=auth.uid() and role='owner') then
   raise exception 'Production job not found';
 end if;
 if not (
  (v_job.production_status='created' and p_status in ('awaiting_materials','ready_for_production')) or
  (v_job.production_status='awaiting_materials' and p_status='ready_for_production') or
  (v_job.production_status='ready_for_production' and p_status='in_production') or
  (v_job.production_status='in_production' and p_status='quality_check') or
  (v_job.production_status='quality_check' and p_status in ('in_production','completed')) or
  (v_job.production_status='completed' and p_status='ready_for_collection') or
  (v_job.production_status='ready_for_collection' and p_status='delivered')
 ) then raise exception 'Invalid production status transition'; end if;
 if p_status='ready_for_production' then
  select exists(
   select 1 from public.production_job_materials m
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
 if p_status='completed' and not coalesce(v_job.quality_check_passed,false)
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
 values(v_job.business_id,auth.uid(),'production.status_changed','production_job',p_job_id,jsonb_build_object('from',v_job.production_status,'to',p_status));
end
$function$;

create or replace function public.owner_cancel_production_job(p_job_id uuid,p_job_number text,p_reason text)
returns void
language plpgsql
security definer
set search_path to 'public','pg_temp'
as $function$
declare v_job public.production_jobs%rowtype;
begin
 if auth.uid() is null then raise exception 'Authentication required'; end if;
 if length(btrim(coalesce(p_reason,'')))<8 then raise exception 'Cancellation reason must contain at least 8 characters'; end if;
 select * into v_job from public.production_jobs where id=p_job_id for update;
 if not found or not exists(select 1 from public.business_memberships where business_id=v_job.business_id and user_id=auth.uid() and role='owner') then
  raise exception 'Production job not found';
 end if;
 if btrim(coalesce(p_job_number,''))<>v_job.job_number then raise exception 'The confirmed job number does not match this production job'; end if;
 if v_job.production_status in ('cancelled','delivered') then raise exception 'This job cannot be cancelled from its current status'; end if;
 update public.production_jobs set production_status='cancelled',cancellation_reason=btrim(p_reason),cancelled_at=now(),cancelled_by=auth.uid()
 where id=p_job_id and business_id=v_job.business_id;
 insert into public.audit_events(business_id,actor_user_id,event_type,entity_type,entity_id,details)
 values(v_job.business_id,auth.uid(),'production.job_cancelled','production_job',p_job_id,
  jsonb_build_object('job_number',v_job.job_number,'from',v_job.production_status,'to','cancelled','reason',btrim(p_reason),'invoice_id',v_job.invoice_id,'accounting_unchanged',true));
end
$function$;

create or replace function public.owner_recover_cancelled_production_job(p_job_id uuid,p_job_number text,p_reason text)
returns void
language plpgsql
security definer
set search_path to 'public','pg_temp'
as $function$
declare v_job public.production_jobs%rowtype; v_previous_status text;
begin
 if auth.uid() is null then raise exception 'Authentication required'; end if;
 if length(btrim(coalesce(p_reason,'')))<8 then raise exception 'Recovery reason must contain at least 8 characters'; end if;
 select * into v_job from public.production_jobs where id=p_job_id for update;
 if not found or not exists(select 1 from public.business_memberships where business_id=v_job.business_id and user_id=auth.uid() and role='owner') then
  raise exception 'Production job not found';
 end if;
 if btrim(coalesce(p_job_number,''))<>v_job.job_number then raise exception 'The confirmed job number does not match this production job'; end if;
 if v_job.production_status<>'cancelled' then raise exception 'Only a cancelled production job can be recovered'; end if;
 select details->>'from' into v_previous_status
 from public.audit_events
 where business_id=v_job.business_id and entity_type='production_job' and entity_id=p_job_id
  and event_type in ('production.job_cancelled','production.status_changed')
  and details->>'to'='cancelled'
 order by created_at desc,id desc limit 1;
 if v_previous_status is null or v_previous_status not in ('created','awaiting_materials','ready_for_production','in_production','quality_check','completed','ready_for_collection') then
  raise exception 'No valid pre-cancellation status is available in the audit history';
 end if;
 if v_previous_status='completed' and not coalesce(v_job.quality_check_passed,false) and length(btrim(coalesce(v_job.quality_override_reason,'')))<5 then
  raise exception 'Cannot recover to Completed without a passed quality check or recorded override';
 end if;
 if v_previous_status='ready_for_collection' and v_job.actual_completed_at is null then
  raise exception 'Cannot recover to Ready for Collection without a recorded completion';
 end if;
 update public.production_jobs set production_status=v_previous_status,cancellation_reason=null,cancelled_at=null,cancelled_by=null
 where id=p_job_id and business_id=v_job.business_id;
 insert into public.audit_events(business_id,actor_user_id,event_type,entity_type,entity_id,details)
 values(v_job.business_id,auth.uid(),'production.job_recovered','production_job',p_job_id,
  jsonb_build_object('job_number',v_job.job_number,'from','cancelled','to',v_previous_status,'reason',btrim(p_reason),'invoice_id',v_job.invoice_id,'accounting_unchanged',true));
end
$function$;

revoke all on function public.owner_set_production_status(uuid,text) from public,anon;
grant execute on function public.owner_set_production_status(uuid,text) to authenticated,service_role;
revoke all on function public.owner_cancel_production_job(uuid,text,text) from public,anon;
grant execute on function public.owner_cancel_production_job(uuid,text,text) to authenticated,service_role;
revoke all on function public.owner_recover_cancelled_production_job(uuid,text,text) from public,anon;
grant execute on function public.owner_recover_cancelled_production_job(uuid,text,text) to authenticated,service_role;

revoke insert,update,delete,truncate,references,trigger on table public.audit_events from anon,authenticated;
