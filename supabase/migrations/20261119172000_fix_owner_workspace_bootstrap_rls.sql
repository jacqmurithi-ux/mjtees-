-- Fix first-owner bootstrap: the membership INSERT policy must not query its own RLS table.
drop policy if exists memberships_bootstrap_insert on public.business_memberships;
create policy memberships_bootstrap_insert
on public.business_memberships
for insert to authenticated
with check (
 user_id=(select auth.uid())
 and role='owner'
 and exists (
  select 1 from public.businesses b
  where b.id=business_memberships.business_id
    and b.created_by=(select auth.uid())
 )
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

-- Keep the RPC invoker-based; it now works through non-recursive, scoped bootstrap policies.
