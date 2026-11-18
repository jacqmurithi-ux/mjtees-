CREATE OR REPLACE FUNCTION private.owner_upsert_customer_address(p_business_id uuid, p_address_id uuid, p_customer_id uuid, p_label text, p_recipient_name text, p_phone text, p_address_text text, p_locality text, p_is_default boolean, p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare a uuid;i uuid;c jsonb;r jsonb;
begin
 a:=private.assert_active_owner(p_business_id);
 if length(btrim(coalesce(p_address_text,''))) not between 1 and 500 or length(coalesce(p_label,''))>80 or length(coalesce(p_recipient_name,''))>180 or length(coalesce(p_phone,''))>40 or length(coalesce(p_locality,''))>180 or not exists(select 1 from public.customers where business_id=p_business_id and id=p_customer_id and archived_at is null) then raise exception using errcode='22023',message='Address details invalid'; end if;
 c:=private.begin_idempotent_request(p_business_id,'upsert_customer_address',p_request_id,jsonb_build_object('id',p_address_id,'customer',p_customer_id,'address',p_address_text,'default',p_is_default)); if c is not null then return c; end if;
 if p_is_default then update public.customer_addresses set is_default=false,updated_at=now() where business_id=p_business_id and customer_id=p_customer_id and is_default; end if;
 if p_address_id is null then insert into public.customer_addresses(business_id,customer_id,label,recipient_name,phone,address_text,locality,is_default) values(p_business_id,p_customer_id,nullif(btrim(p_label),''),nullif(btrim(p_recipient_name),''),nullif(btrim(p_phone),''),btrim(p_address_text),nullif(btrim(p_locality),''),p_is_default) returning id into i;
 else update public.customer_addresses set customer_id=p_customer_id,label=nullif(btrim(p_label),''),recipient_name=nullif(btrim(p_recipient_name),''),phone=nullif(btrim(p_phone),''),address_text=btrim(p_address_text),locality=nullif(btrim(p_locality),''),is_default=p_is_default,updated_at=now() where business_id=p_business_id and id=p_address_id returning id into i; if i is null then raise exception using errcode='P0002',message='Address not found'; end if; end if;
 r:=jsonb_build_object('address_id',i); perform private.finish_idempotent_request(p_business_id,'upsert_customer_address',p_request_id,r); perform private.write_audit(p_business_id,a,'customer.address_saved','customer_address',i,p_request_id,jsonb_build_object('customer_id',p_customer_id)); return r;
end $function$;

CREATE OR REPLACE FUNCTION public.owner_upsert_customer_address(p_business_id uuid, p_address_id uuid, p_customer_id uuid, p_label text, p_recipient_name text, p_phone text, p_address_text text, p_locality text, p_is_default boolean, p_request_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 SET search_path TO ''
AS $function$ select private.owner_upsert_customer_address($1,$2,$3,$4,$5,$6,$7,$8,$9,$10); $function$;

revoke all on function public.owner_upsert_customer_address(uuid,uuid,uuid,text,text,text,text,text,boolean,uuid) from public,anon;
grant execute on function public.owner_upsert_customer_address(uuid,uuid,uuid,text,text,text,text,text,boolean,uuid) to authenticated;
