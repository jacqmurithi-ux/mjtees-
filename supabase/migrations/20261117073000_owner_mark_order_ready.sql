begin;

-- Allow owner to mark an order ready when it has no production work, or when
-- every required production job has completed with passing inspection.
create or replace function private.owner_mark_order_ready(
  p_order_id uuid,p_reason text,p_request_id uuid
) returns jsonb
language plpgsql security definer set search_path=''
as $$
declare
  v_order public.orders%rowtype;
  v_actor uuid;
  v_cached jsonb;
  v_payload jsonb;
  v_result jsonb;
begin
  select * into v_order from public.orders where id=p_order_id;
  if not found then raise exception using errcode='P0002',message='Order not found'; end if;
  v_actor:=private.assert_active_owner(v_order.business_id);
  if length(btrim(coalesce(p_reason,'')))=0 or p_request_id is null then
    raise exception using errcode='22023',message='A readiness reason and request id are required';
  end if;
  v_payload:=jsonb_build_object('order_id',p_order_id,'reason',p_reason);
  v_cached:=private.begin_idempotent_request(v_order.business_id,'mark_order_ready',p_request_id,v_payload);
  if v_cached is not null then return v_cached; end if;
  select * into v_order from public.orders
    where business_id=v_order.business_id and id=p_order_id for update;
  if v_order.status not in ('confirmed','in_production') then
    raise exception using errcode='22023',message='Only confirmed or in-production orders can be marked ready';
  end if;
  if not exists(select 1 from public.order_items oi where oi.business_id=v_order.business_id and oi.order_id=p_order_id) then
    raise exception using errcode='23514',message='An order must contain at least one order line';
  end if;
  if exists(
    select 1 from public.order_items oi
    where oi.business_id=v_order.business_id and oi.order_id=p_order_id
      and oi.sale_mode='value_added' and oi.production_method_id is not null
      and not exists(select 1 from public.production_jobs j
        where j.business_id=oi.business_id and j.order_item_id=oi.id and j.status='completed')
  ) then
    raise exception using errcode='22023',message='Every value-added line with a production method must have a completed production job';
  end if;
  if exists(
    select 1 from public.production_jobs j
    join public.order_items oi on oi.business_id=j.business_id and oi.id=j.order_item_id
    where j.business_id=v_order.business_id and oi.order_id=p_order_id
      and (j.status<>'completed' or coalesce((
        select q.result from public.quality_checks q
        where q.business_id=j.business_id and q.job_id=j.id
        order by q.checked_at desc,q.id desc limit 1
      ),'fail')<>'pass')
  ) then
    raise exception using errcode='22023',message='All production jobs must be completed with a latest passing quality check';
  end if;
  if exists(
    select 1 from public.quality_checks q
    join public.production_jobs j on j.business_id=q.business_id and j.id=q.job_id
    join public.order_items oi on oi.business_id=j.business_id and oi.id=j.order_item_id
    where q.business_id=v_order.business_id and oi.order_id=p_order_id and q.result='fail'
      and not exists(select 1 from public.rework_events r
        where r.business_id=q.business_id and r.quality_check_id=q.id and r.closed_at is not null)
  ) then
    raise exception using errcode='22023',message='Every failed quality check must have a closed rework record';
  end if;
  update public.orders set status='ready',updated_at=now()
  where business_id=v_order.business_id and id=p_order_id;
  insert into public.order_events(business_id,order_id,event_type,from_status,to_status,actor_user_id,reason)
  values(v_order.business_id,p_order_id,'marked_ready',v_order.status,'ready',v_actor,btrim(p_reason));
  v_result:=jsonb_build_object('order_id',p_order_id,'status','ready');
  perform private.finish_idempotent_request(v_order.business_id,'mark_order_ready',p_request_id,v_result);
  perform private.write_audit(v_order.business_id,v_actor,'order.marked_ready','order',p_order_id,p_request_id,
    jsonb_build_object('from_status',v_order.status,'reason',p_reason));
  return v_result;
end;
$$;

create or replace function public.owner_mark_order_ready(p_order_id uuid,p_reason text,p_request_id uuid)
returns jsonb language sql security invoker set search_path=''
as $$ select private.owner_mark_order_ready($1,$2,$3); $$;

revoke all on function private.owner_mark_order_ready(uuid,text,uuid) from public,anon,authenticated;
grant execute on function private.owner_mark_order_ready(uuid,text,uuid) to authenticated;
revoke all on function public.owner_mark_order_ready(uuid,text,uuid) from public,anon;
grant execute on function public.owner_mark_order_ready(uuid,text,uuid) to authenticated;

commit;
