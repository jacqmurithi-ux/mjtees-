begin;

create or replace function private.owner_upsert_inventory_location(
 p_business_id uuid,p_location_id uuid,p_name text,p_code text,p_description text,p_request_id uuid
) returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_actor uuid;v_cached jsonb;v_payload jsonb;v_id uuid;v_created boolean;v_result jsonb;
begin
 v_actor:=private.assert_active_owner(p_business_id);
 if length(btrim(coalesce(p_name,''))) not between 1 and 100
   or length(btrim(coalesce(p_code,''))) not between 1 and 24
   or length(coalesce(p_description,''))>500 then
   raise exception using errcode='22023',message='Inventory location name, code or description is invalid';
 end if;
 v_payload:=jsonb_build_object('location_id',p_location_id,'name',p_name,'code',p_code,'description',p_description);
 v_cached:=private.begin_idempotent_request(p_business_id,'upsert_inventory_location',p_request_id,v_payload);
 if v_cached is not null then return v_cached; end if;
 if p_location_id is null then
  insert into public.inventory_locations(business_id,name,code,description)
  values(p_business_id,btrim(p_name),upper(btrim(p_code)),nullif(btrim(p_description),''))
  returning id into v_id;v_created:=true;
 else
  update public.inventory_locations set name=btrim(p_name),code=upper(btrim(p_code)),description=nullif(btrim(p_description),'')
  where business_id=p_business_id and id=p_location_id returning id into v_id;
  if v_id is null then raise exception using errcode='P0002',message='Inventory location not found';end if;
  v_created:=false;
 end if;
 v_result:=jsonb_build_object('location_id',v_id,'created',v_created);
 perform private.finish_idempotent_request(p_business_id,'upsert_inventory_location',p_request_id,v_result);
 perform private.write_audit(p_business_id,v_actor,case when v_created then 'inventory_location.created' else 'inventory_location.updated' end,
  'inventory_location',v_id,p_request_id,'{}'::jsonb);
 return v_result;
end;
$$;

create or replace function public.owner_upsert_inventory_location(
 p_business_id uuid,p_location_id uuid,p_name text,p_code text,p_description text,p_request_id uuid
) returns jsonb language sql security invoker set search_path=''
as $$ select private.owner_upsert_inventory_location($1,$2,$3,$4,$5,$6); $$;

revoke all on function private.owner_upsert_inventory_location(uuid,uuid,text,text,text,uuid) from public,anon,authenticated;
grant execute on function private.owner_upsert_inventory_location(uuid,uuid,text,text,text,uuid) to authenticated;
revoke all on function public.owner_upsert_inventory_location(uuid,uuid,text,text,text,uuid) from public,anon;
grant execute on function public.owner_upsert_inventory_location(uuid,uuid,text,text,text,uuid) to authenticated;

commit;
