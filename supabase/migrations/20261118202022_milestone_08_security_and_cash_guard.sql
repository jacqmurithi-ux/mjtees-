alter function public.owner_get_daily_operations_summary(uuid,date) security invoker;

create or replace function private.owner_record_cash_movement(
  p_business_id uuid,p_business_date date,p_movement_type text,p_amount bigint,
  p_source_account text,p_destination_account text,p_reference text,p_notes text,p_request_id uuid
) returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_actor uuid; v_cached jsonb; v_payload jsonb; v_id uuid; v_direction text; v_result jsonb;
begin
  v_actor:=private.assert_active_owner(p_business_id);
  if p_business_date is null or p_business_date>(now() at time zone 'Africa/Nairobi')::date
    or p_movement_type not in ('till_top_up','bank_deposit','owner_withdrawal','other_cash_in','other_cash_out')
    or p_amount is null or p_amount<=0 or length(btrim(coalesce(p_notes,''))) not between 1 and 2000
    or p_request_id is null then
    raise exception using errcode='22023',message='Invalid cash movement details';
  end if;
  if exists(select 1 from public.daily_closings where business_id=p_business_id and business_date=p_business_date and status='closed') then
    raise exception using errcode='55000',message='This cash day is closed; record a current-day correction instead';
  end if;
  v_direction:=case when p_movement_type in ('till_top_up','other_cash_in') then 'in' else 'out' end;
  v_payload:=jsonb_build_object('business_date',p_business_date,'movement_type',p_movement_type,'amount',p_amount,
    'source_account',p_source_account,'destination_account',p_destination_account,'reference',p_reference,'notes',p_notes);
  v_cached:=private.begin_idempotent_request(p_business_id,'record_cash_movement',p_request_id,v_payload);
  if v_cached is not null then return v_cached; end if;
  insert into public.cash_movements(business_id,business_date,movement_type,direction,amount,source_account,destination_account,reference,notes,created_by,request_id)
  values(p_business_id,p_business_date,p_movement_type,v_direction,p_amount,nullif(btrim(p_source_account),''),nullif(btrim(p_destination_account),''),
    nullif(btrim(p_reference),''),btrim(p_notes),v_actor,p_request_id)
  returning id into v_id;
  v_result:=jsonb_build_object('cash_movement_id',v_id,'direction',v_direction,'amount',p_amount);
  perform private.finish_idempotent_request(p_business_id,'record_cash_movement',p_request_id,v_result);
  perform private.write_audit(p_business_id,v_actor,'cash_movement.recorded','cash_movement',v_id,p_request_id,v_result);
  return v_result;
end;
$$;
