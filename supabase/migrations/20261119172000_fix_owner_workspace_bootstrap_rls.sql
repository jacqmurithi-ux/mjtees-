-- Fix first-owner bootstrap without recursive RLS policy evaluation.
-- SECURITY DEFINER is restricted to this non-exposed helper and checks the caller explicitly.
create or replace function private.can_bootstrap_owner_membership(p_business_id uuid)
returns boolean
language sql
stable
security definer
set search_path=public,pg_temp
as $$
 select (select auth.uid()) is not null
  and exists (
   select 1 from public.businesses b
   where b.id=p_business_id
     and b.created_by=(select auth.uid())
  );
$$;
revoke all on function private.can_bootstrap_owner_membership(uuid) from public,anon;
grant execute on function private.can_bootstrap_owner_membership(uuid) to authenticated;

drop policy if exists memberships_bootstrap_insert on public.business_memberships;
create policy memberships_bootstrap_insert
on public.business_memberships
for insert to authenticated
with check (
 user_id=(select auth.uid())
 and role='owner'
 and private.can_bootstrap_owner_membership(business_id)
);

-- Correct the member lookup predicate (the prior predicate compared two columns of m).
drop policy if exists businesses_read_member on public.businesses;
create policy businesses_read_member
on public.businesses
for select to authenticated
using (
 exists (
  select 1 from public.business_memberships m
  where m.business_id=businesses.id
    and m.user_id=(select auth.uid())
 )
);
