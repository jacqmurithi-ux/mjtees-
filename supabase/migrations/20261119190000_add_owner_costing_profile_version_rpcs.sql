-- Add owner-only, append-only version management for costing profiles.
create or replace function public.owner_create_costing_profile(
 p_profile_name text,
 p_components jsonb,
 p_direct_cost numeric,
 p_activate boolean default true
) returns uuid
language plpgsql
security definer
set search_path=public,pg_temp
as $fn$
declare
 v_business uuid;
 v_name text;
 v_version integer;
 v_id uuid;
begin
 v_name:=btrim(coalesce(p_profile_name,''));
 if length(v_name)<2 then raise exception 'A costing profile name is required'; end if;
 if p_direct_cost is null or p_direct_cost<0 then raise exception 'Direct production cost must be zero or greater'; end if;
 if p_components is null or jsonb_typeof(p_components)<>'array' then raise exception 'Cost components must be supplied as a list'; end if;
 if not exists(select 1 from jsonb_array_elements(p_components) c
  where coalesce(length(btrim(c->>'name')),0)=0
    or coalesce((c->>'cost')::numeric,-1)<0) then
  null;
 else
  raise exception 'Each cost component needs a name and a non-negative cost';
 end if;
 select business_id into v_business
 from public.business_memberships
 where user_id=auth.uid() and role='owner'
 order by created_at asc
 limit 1;
 if v_business is null then raise exception 'Owner workspace required'; end if;
 perform pg_advisory_xact_lock(hashtext(v_business::text),hashtext(lower(v_name)));
 select coalesce(max(version),0)+1 into v_version
 from public.costing_profiles
 where business_id=v_business and lower(profile_name)=lower(v_name);
 if coalesce(p_activate,true) then
  update public.costing_profiles set is_active=false
  where business_id=v_business and is_active=true;
 end if;
 insert into public.costing_profiles(
  business_id,profile_name,version,is_active,components,direct_cost,margin_floor,full_cost_target
 ) values(
  v_business,v_name,v_version,coalesce(p_activate,true),p_components,p_direct_cost,30,1.8
 ) returning id into v_id;
 insert into public.audit_events(business_id,actor_user_id,event_type,entity_type,entity_id,details)
 values(v_business,auth.uid(),'costing_profile.created','costing_profile',v_id,
  jsonb_build_object('profile_name',v_name,'version',v_version,'direct_cost',p_direct_cost,'activated',coalesce(p_activate,true)));
 return v_id;
end
$fn$;

create or replace function public.owner_activate_costing_profile(p_profile_id uuid)
returns void
language plpgsql
security definer
set search_path=public,pg_temp
as $fn$
declare v_business uuid;
begin
 select business_id into v_business
 from public.business_memberships
 where user_id=auth.uid() and role='owner'
 order by created_at asc
 limit 1;
 if v_business is null then raise exception 'Owner workspace required'; end if;
 perform 1 from public.costing_profiles
 where id=p_profile_id and business_id=v_business for update;
 if not found then raise exception 'Costing profile version not found'; end if;
 update public.costing_profiles set is_active=false
 where business_id=v_business and is_active=true;
 update public.costing_profiles set is_active=true
 where id=p_profile_id and business_id=v_business;
 insert into public.audit_events(business_id,actor_user_id,event_type,entity_type,entity_id,details)
 values(v_business,auth.uid(),'costing_profile.activated','costing_profile',p_profile_id,'{}'::jsonb);
end
$fn$;

alter table public.costing_profiles enable row level security;
revoke all on table public.costing_profiles from anon,authenticated;
grant select on table public.costing_profiles to authenticated;
revoke all on function public.owner_create_costing_profile(text,jsonb,numeric,boolean) from public,anon;
revoke all on function public.owner_activate_costing_profile(uuid) from public,anon;
grant execute on function public.owner_create_costing_profile(text,jsonb,numeric,boolean) to authenticated;
grant execute on function public.owner_activate_costing_profile(uuid) to authenticated;