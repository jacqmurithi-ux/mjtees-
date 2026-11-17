-- MJ Tees — constrained public enquiry ingress and database rate limits.
-- Supabase CLI generated filename. This migration does not deploy the Edge Function.
begin;

alter table public.businesses add column if not exists slug text;
create unique index if not exists businesses_slug_uq on public.businesses(lower(slug)) where slug is not null;
create index if not exists enquiries_business_created_idx on public.enquiries(business_id,created_at desc);

create table private.public_enquiry_rate_limits (
  business_id uuid not null references public.businesses(id) on delete restrict,
  dimension text not null check (dimension in ('ip','contact')),
  value_hash text not null check (value_hash ~ '^[0-9a-f]{64}$'),
  window_start timestamptz not null,
  hit_count integer not null check (hit_count > 0),
  updated_at timestamptz not null default now(),
  primary key (business_id,dimension,value_hash,window_start)
);
alter table private.public_enquiry_rate_limits enable row level security;
revoke all on private.public_enquiry_rate_limits from public,anon,authenticated,service_role;

create or replace function private.submit_public_enquiry(
  p_business_slug text,p_contact_name text,p_phone text,p_email text,
  p_requested_service text,p_description text,p_quantity numeric,p_desired_by date,
  p_customer_supplies_item boolean,p_artwork_drive_url text,
  p_ip_hash text,p_contact_hash text,p_request_id uuid
) returns jsonb
language plpgsql security definer set search_path=''
as $$
declare
  v_business public.businesses%rowtype;
  v_window timestamptz;
  v_hits integer;
  v_reference text;
  v_enquiry uuid;
  v_cached jsonb;
  v_payload jsonb;
  v_result jsonb;
  v_dimension text;
  v_hash text;
  v_limit integer;
begin
  if p_business_slug is null or p_business_slug !~ '^[a-z0-9]+(?:-[a-z0-9]+)*$'
     or length(p_business_slug)>80
     or p_contact_name is null or length(btrim(p_contact_name)) not between 1 and 120
     or p_requested_service is null or length(btrim(p_requested_service)) not between 1 and 160
     or p_description is null or length(btrim(p_description)) not between 1 and 4000
     or (nullif(btrim(coalesce(p_phone,'')),'') is null and nullif(btrim(coalesce(p_email,'')),'') is null)
     or length(coalesce(p_phone,''))>40 or length(coalesce(p_email,''))>254
     or (p_quantity is not null and (p_quantity<=0 or p_quantity>100000))
     or (p_desired_by is not null and p_desired_by<current_date)
     or p_ip_hash is null or p_ip_hash !~ '^[0-9a-f]{64}$'
     or p_contact_hash is null or p_contact_hash !~ '^[0-9a-f]{64}$'
     or p_request_id is null then
    raise exception using errcode='22023',message='Invalid enquiry payload';
  end if;
  if p_email is not null and p_email !~* '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then
    raise exception using errcode='22023',message='Invalid email';
  end if;
  if p_artwork_drive_url is not null and (
    length(p_artwork_drive_url)>2048 or
    p_artwork_drive_url !~* '^https://(drive\.google\.com|docs\.google\.com)/'
  ) then
    raise exception using errcode='22023',message='Artwork link must be a Google Drive URL';
  end if;

  select * into v_business from public.businesses
  where lower(slug)=lower(p_business_slug) and is_active;
  if not found then raise exception using errcode='P0002',message='Business not found'; end if;

  v_payload:=jsonb_build_object(
    'contact_name',p_contact_name,'phone',p_phone,'email',p_email,'requested_service',p_requested_service,
    'description',p_description,'quantity',p_quantity,'desired_by',p_desired_by,
    'customer_supplies_item',coalesce(p_customer_supplies_item,false),'artwork_drive_url',p_artwork_drive_url,
    'ip_hash',p_ip_hash,'contact_hash',p_contact_hash
  );
  v_cached:=private.begin_idempotent_request(v_business.id,'submit_public_enquiry',p_request_id,v_payload);
  if v_cached is not null then return v_cached; end if;

  v_window:=to_timestamp(floor(extract(epoch from clock_timestamp())/900)*900);
  foreach v_dimension in array array['ip','contact'] loop
    v_hash:=case when v_dimension='ip' then p_ip_hash else p_contact_hash end;
    v_limit:=case when v_dimension='ip' then 10 else 5 end;
    insert into private.public_enquiry_rate_limits as current_limit
      (business_id,dimension,value_hash,window_start,hit_count,updated_at)
    values(v_business.id,v_dimension,v_hash,v_window,1,clock_timestamp())
    on conflict (business_id,dimension,value_hash,window_start)
    do update set hit_count=current_limit.hit_count+1,updated_at=clock_timestamp()
      where current_limit.hit_count < v_limit
    returning hit_count into v_hits;
    if not found then
      v_result:=jsonb_build_object('rate_limited',true);
      perform private.finish_idempotent_request(v_business.id,'submit_public_enquiry',p_request_id,v_result);
      return v_result;
    end if;
  end loop;

  v_reference:='ENQ-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,12));
  insert into public.enquiries(
    business_id,public_reference,contact_name,phone,email,requested_service,description,
    quantity,desired_by,customer_supplies_item,artwork_drive_url,status
  ) values (
    v_business.id,v_reference,btrim(p_contact_name),nullif(btrim(p_phone),''),nullif(lower(btrim(p_email)),''),
    btrim(p_requested_service),btrim(p_description),p_quantity,p_desired_by,
    coalesce(p_customer_supplies_item,false),p_artwork_drive_url,'new'
  ) returning id into v_enquiry;

  v_result:=jsonb_build_object('ok',true,'public_reference',v_reference,'message','Enquiry received');
  perform private.finish_idempotent_request(v_business.id,'submit_public_enquiry',p_request_id,v_result);
  perform private.write_audit(v_business.id,null,'enquiry.received','enquiry',v_enquiry,p_request_id,
    jsonb_build_object('public_reference',v_reference,'source','public_edge_function'));
  return v_result;
end;
$$;

create or replace function public.submit_public_enquiry(
  p_business_slug text,p_contact_name text,p_phone text,p_email text,
  p_requested_service text,p_description text,p_quantity numeric,p_desired_by date,
  p_customer_supplies_item boolean,p_artwork_drive_url text,
  p_ip_hash text,p_contact_hash text,p_request_id uuid
) returns jsonb
language sql security invoker set search_path=''
as $$
  select private.submit_public_enquiry($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13);
$$;

grant usage on schema private to service_role;
revoke all on function private.submit_public_enquiry(text,text,text,text,text,text,numeric,date,boolean,text,text,text,uuid)
  from public,anon,authenticated;
grant execute on function private.submit_public_enquiry(text,text,text,text,text,text,numeric,date,boolean,text,text,text,uuid)
  to service_role;
revoke all on function public.submit_public_enquiry(text,text,text,text,text,text,numeric,date,boolean,text,text,text,uuid)
  from public,anon,authenticated;
grant execute on function public.submit_public_enquiry(text,text,text,text,text,text,numeric,date,boolean,text,text,text,uuid)
  to service_role;

commit;
