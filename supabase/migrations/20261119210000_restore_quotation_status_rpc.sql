-- Restore the owner quotation status RPC expected by the sales workspace.
create or replace function public.owner_set_quotation_status(
  p_quote_id uuid,
  p_status text
) returns void
language plpgsql
security definer
set search_path=public,pg_temp
as $function$
declare
  v_business_id uuid;
  v_old_status text;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  if p_status not in ('sent','accepted') then
    raise exception 'Unsupported quotation status transition';
  end if;

  select business_id,status
    into v_business_id,v_old_status
    from public.quotations
    where id=p_quote_id
    for update;

  if v_business_id is null or not exists (
    select 1 from public.business_memberships
    where business_id=v_business_id
      and user_id=auth.uid()
      and role='owner'
  ) then
    raise exception 'Quotation not found';
  end if;

  if not (
    (v_old_status='draft' and p_status='sent')
    or (v_old_status='sent' and p_status='accepted')
  ) then
    raise exception 'Invalid quotation status transition';
  end if;

  update public.quotations
    set status=p_status
    where id=p_quote_id and business_id=v_business_id;

  insert into public.audit_events(
    business_id,actor_user_id,event_type,entity_type,entity_id,details
  ) values (
    v_business_id,auth.uid(),'quotation.status_changed','quotation',p_quote_id,
    jsonb_build_object('from',v_old_status,'to',p_status)
  );
end
$function$;

revoke all on function public.owner_set_quotation_status(uuid,text) from public,anon;
grant execute on function public.owner_set_quotation_status(uuid,text) to authenticated;
