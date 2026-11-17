begin;

create or replace function private.owner_update_order_schedule(
  p_order_id uuid,p_required_by date,p_promised_turnaround_hours integer,p_request_id uuid
) returns jsonb
language plpgsql security definer set search_path=''
as $$
declare
  v_order public.orders%rowtype;
  v_actor uuid;
  v_payload jsonb;
  v_cached jsonb;
  v_result jsonb;
begin
  if p_order_id is null or p_request_id is null
    or (p_promised_turnaround_hours is not null and p_promised_turnaround_hours not between 1 and 8760) then
    raise exception using errcode='22023',message='A valid order, request id and turnaround period are required';
  end if;
  select * into v_order from public.orders where id=p_order_id;
  if not found then raise exception using errcode='P0002',message='Order not found'; end if;
  v_actor:=private.assert_active_owner(v_order.business_id);
  v_payload:=jsonb_build_object('order_id',p_order_id,'required_by',p_required_by,
    'promised_turnaround_hours',p_promised_turnaround_hours);
  v_cached:=private.begin_idempotent_request(v_order.business_id,'update_order_schedule',p_request_id,v_payload);
  if v_cached is not null then return v_cached; end if;

  update public.orders set required_by=p_required_by,
    promised_turnaround_hours=p_promised_turnaround_hours,updated_at=now()
  where business_id=v_order.business_id and id=p_order_id;

  insert into public.order_events(business_id,order_id,event_type,from_status,to_status,actor_user_id,reason)
  values(v_order.business_id,p_order_id,'schedule_updated',v_order.status,v_order.status,v_actor,
    'Required date and/or promised turnaround updated');

  v_result:=jsonb_build_object('order_id',p_order_id,'required_by',p_required_by,
    'promised_turnaround_hours',p_promised_turnaround_hours,'status',v_order.status);
  perform private.finish_idempotent_request(v_order.business_id,'update_order_schedule',p_request_id,v_result);
  perform private.write_audit(v_order.business_id,v_actor,'order.schedule_updated','order',p_order_id,p_request_id,v_result);
  return v_result;
end;
$$;

create or replace function public.owner_update_order_schedule(
  p_order_id uuid,p_required_by date,p_promised_turnaround_hours integer,p_request_id uuid
) returns jsonb language sql security invoker set search_path=''
as $$ select private.owner_update_order_schedule($1,$2,$3,$4); $$;

revoke all on function private.owner_update_order_schedule(uuid,date,integer,uuid) from public,anon,authenticated;
grant execute on function private.owner_update_order_schedule(uuid,date,integer,uuid) to authenticated;
revoke all on function public.owner_update_order_schedule(uuid,date,integer,uuid) from public,anon;
grant execute on function public.owner_update_order_schedule(uuid,date,integer,uuid) to authenticated;

commit;
