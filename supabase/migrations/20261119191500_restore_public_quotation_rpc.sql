-- Restore the public PostgREST entry point for quotation creation.
-- The implementation remains private and SECURITY DEFINER; this invoker wrapper
-- preserves the established owner authorization and server-side pricing rules.
create or replace function public.owner_create_quotation(
 p_customer_id uuid,
 p_costing_profile_id uuid,
 p_quote_number text,
 p_valid_until date,
 p_lines jsonb,
 p_allow_below_floor boolean default false,
 p_exception_reason text default null
) returns uuid
language sql
security invoker
set search_path=public,private,pg_temp
as $function$
 select private.owner_create_quotation_impl(
  p_customer_id,p_costing_profile_id,p_quote_number,p_valid_until,p_lines,
  p_allow_below_floor,p_exception_reason
 );
$function$;

revoke all on function public.owner_create_quotation(uuid,uuid,text,date,jsonb,boolean,text) from public,anon;
grant execute on function public.owner_create_quotation(uuid,uuid,text,date,jsonb,boolean,text) to authenticated;

notify pgrst, 'reload schema';
