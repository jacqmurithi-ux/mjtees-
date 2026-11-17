begin;

create or replace function private.owner_set_stock_opening_cost(
 p_stock_item_id uuid,p_unit_cost bigint,p_request_id uuid
) returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_item public.stock_items%rowtype;v_actor uuid;v_cached jsonb;v_payload jsonb;v_result jsonb;
begin
 select * into v_item from public.stock_items where id=p_stock_item_id for update;
 if not found then raise exception using errcode='P0002',message='Stock item not found';end if;
 v_actor:=private.assert_active_owner(v_item.business_id);
 if p_unit_cost is null or p_unit_cost<0 then raise exception using errcode='22023',message='Opening unit cost cannot be negative';end if;
 v_payload:=jsonb_build_object('stock_item_id',p_stock_item_id,'unit_cost',p_unit_cost);
 v_cached:=private.begin_idempotent_request(v_item.business_id,'set_stock_opening_cost',p_request_id,v_payload);
 if v_cached is not null then return v_cached;end if;
 if exists(select 1 from public.stock_movements where business_id=v_item.business_id and stock_item_id=p_stock_item_id)
   or v_item.current_average_unit_cost<>0 then
   raise exception using errcode='22023',message='Opening cost can only be set before any stock movements or prior cost is recorded';
 end if;
 update public.stock_items set current_average_unit_cost=p_unit_cost,updated_at=now()
 where business_id=v_item.business_id and id=p_stock_item_id;
 v_result:=jsonb_build_object('stock_item_id',p_stock_item_id,'current_average_unit_cost',p_unit_cost);
 perform private.finish_idempotent_request(v_item.business_id,'set_stock_opening_cost',p_request_id,v_result);
 perform private.write_audit(v_item.business_id,v_actor,'stock.opening_cost_set','stock_item',p_stock_item_id,p_request_id,
   jsonb_build_object('unit_cost',p_unit_cost));
 return v_result;
end;
$$;

create or replace function public.owner_set_stock_opening_cost(p_stock_item_id uuid,p_unit_cost bigint,p_request_id uuid)
returns jsonb language sql security invoker set search_path=''
as $$ select private.owner_set_stock_opening_cost($1,$2,$3); $$;

revoke all on function private.owner_set_stock_opening_cost(uuid,bigint,uuid) from public,anon,authenticated;
grant execute on function private.owner_set_stock_opening_cost(uuid,bigint,uuid) to authenticated;
revoke all on function public.owner_set_stock_opening_cost(uuid,bigint,uuid) from public,anon;
grant execute on function public.owner_set_stock_opening_cost(uuid,bigint,uuid) to authenticated;

commit;
