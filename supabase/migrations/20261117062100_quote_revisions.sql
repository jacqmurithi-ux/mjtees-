begin;

create or replace function private.owner_create_quotation_revision(
  p_original_quotation_id uuid,p_lines jsonb,p_expires_at timestamptz,
  p_customer_notes text,p_internal_notes text,p_request_id uuid
) returns jsonb
language plpgsql security definer set search_path=''
as $$
declare
  v_original public.quotations%rowtype;
  v_actor uuid;
  v_cached jsonb;
  v_payload jsonb;
  v_created jsonb;
  v_new_id uuid;
  v_result jsonb;
begin
  if p_original_quotation_id is null or p_request_id is null then
    raise exception using errcode='22023',message='Original quotation and request id are required';
  end if;
  select * into v_original from public.quotations where id=p_original_quotation_id;
  if not found then raise exception using errcode='P0002',message='Original quotation not found'; end if;
  v_actor:=private.assert_active_owner(v_original.business_id);
  if v_original.status not in ('draft','sent','declined','expired') then
    raise exception using errcode='22023',message='Only an unaccepted quotation can be revised';
  end if;
  v_payload:=jsonb_build_object('original_quotation_id',p_original_quotation_id,'lines',p_lines,
    'expires_at',p_expires_at,'customer_notes',p_customer_notes,'internal_notes',p_internal_notes);
  v_cached:=private.begin_idempotent_request(v_original.business_id,'create_quotation_revision',p_request_id,v_payload);
  if v_cached is not null then return v_cached; end if;

  v_created:=private.owner_create_quotation(v_original.business_id,v_original.customer_id,
    v_original.enquiry_id,p_lines,p_expires_at,p_customer_notes,p_internal_notes,p_request_id);
  v_new_id:=(v_created->>'quotation_id')::uuid;
  update public.quotations set revision_of=p_original_quotation_id,updated_at=now()
  where business_id=v_original.business_id and id=v_new_id;
  insert into public.quotation_events(business_id,quotation_id,event_type,actor_user_id,source,reason)
  values(v_original.business_id,v_new_id,'revised',v_actor,'owner','Revision of quotation '||v_original.quote_number);

  v_result:=v_created||jsonb_build_object('revision_of',p_original_quotation_id);
  perform private.finish_idempotent_request(v_original.business_id,'create_quotation_revision',p_request_id,v_result);
  perform private.write_audit(v_original.business_id,v_actor,'quotation.revised','quotation',v_new_id,p_request_id,
    jsonb_build_object('revision_of',p_original_quotation_id,'original_quote_number',v_original.quote_number));
  return v_result;
end;
$$;

create or replace function public.owner_create_quotation_revision(
  p_original_quotation_id uuid,p_lines jsonb,p_expires_at timestamptz,
  p_customer_notes text,p_internal_notes text,p_request_id uuid
) returns jsonb language sql security invoker set search_path=''
as $$ select private.owner_create_quotation_revision($1,$2,$3,$4,$5,$6); $$;

revoke all on function private.owner_create_quotation_revision(uuid,jsonb,timestamptz,text,text,uuid) from public,anon,authenticated;
grant execute on function private.owner_create_quotation_revision(uuid,jsonb,timestamptz,text,text,uuid) to authenticated;
revoke all on function public.owner_create_quotation_revision(uuid,jsonb,timestamptz,text,text,uuid) from public,anon;
grant execute on function public.owner_create_quotation_revision(uuid,jsonb,timestamptz,text,text,uuid) to authenticated;

commit;
