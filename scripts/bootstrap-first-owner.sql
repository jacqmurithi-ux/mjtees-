\set ON_ERROR_STOP on

-- Supply these values in your trusted psql session. Never commit real IDs or credentials.
-- Example:
--   \set business_name 'MJ Printing & Branding'
--   \set trading_name 'MJ Tees'
--   \set business_slug 'mj-tees'
--   \set owner_user_id '00000000-0000-4000-8000-000000000000'
--   \set operator_user_id '00000000-0000-4000-8000-000000000000'
--   \set reason 'Verified first-owner provisioning'
--
-- Connect through a trusted administrative connection. Do not use the service-role key in a browser.

select set_config('mj.bootstrap_business_name', :'business_name', false);
select set_config('mj.bootstrap_trading_name', :'trading_name', false);
select set_config('mj.bootstrap_business_slug', :'business_slug', false);
select set_config('mj.bootstrap_owner_user_id', :'owner_user_id', false);
select set_config('mj.bootstrap_operator_user_id', :'operator_user_id', false);
select set_config('mj.bootstrap_reason', :'reason', false);

begin;

do $bootstrap$
declare
  v_name text := current_setting('mj.bootstrap_business_name');
  v_trading text := current_setting('mj.bootstrap_trading_name');
  v_slug text := current_setting('mj.bootstrap_business_slug');
  v_owner uuid := current_setting('mj.bootstrap_owner_user_id')::uuid;
  v_operator uuid := current_setting('mj.bootstrap_operator_user_id')::uuid;
  v_reason text := current_setting('mj.bootstrap_reason');
  v_business uuid;
begin
  if length(btrim(v_name)) not between 1 and 160
     or v_slug !~ '^[a-z0-9]+(?:-[a-z0-9]+)*$'
     or length(btrim(v_reason)) not between 1 and 500 then
    raise exception 'Invalid business name, slug or provisioning reason';
  end if;

  if not exists(select 1 from auth.users where id=v_owner) then
    raise exception 'The intended owner Auth user does not exist';
  end if;
  if not exists(select 1 from auth.users where id=v_operator) then
    raise exception 'The provisioning operator must be an identified Auth user';
  end if;
  if exists(select 1 from public.business_memberships where role='owner' and status='active') then
    raise exception 'An active owner already exists; bootstrap is permanently closed';
  end if;
  if exists(select 1 from private.business_bootstrap where completed_at is not null) then
    raise exception 'A completed owner bootstrap already exists';
  end if;

  insert into public.businesses(name,trading_name,slug,currency_code,timezone)
  values(btrim(v_name),nullif(btrim(v_trading),''),lower(btrim(v_slug)),'KES','Africa/Nairobi')
  returning id into v_business;

  insert into public.user_profiles(user_id)
  values(v_owner)
  on conflict(user_id) do nothing;

  insert into public.business_memberships(business_id,user_id,role,status,created_by)
  values(v_business,v_owner,'owner','active',v_operator);

  insert into private.business_bootstrap(business_id,completed_at,completed_by,target_user_id,reason)
  values(v_business,now(),v_operator,v_owner,btrim(v_reason));

  insert into public.document_counters(business_id,document_type,next_value,prefix)
  values
    (v_business,'quote',1,'MJQ'),
    (v_business,'order',1,'MJO'),
    (v_business,'payment',1,'MJP'),
    (v_business,'receipt',1,'MJR'),
    (v_business,'purchase',1,'MJB');

  insert into public.audit_events(business_id,actor_user_id,action,entity_type,entity_id,metadata)
  values(v_business,v_operator,'business.owner_provisioned','business',v_business,
    jsonb_build_object('owner_user_id',v_owner,'operator_user_id',v_operator,'reason',btrim(v_reason)));

  raise notice 'MJ Tees business and first owner provisioned. Business ID: %',v_business;
end;
$bootstrap$;

commit;
