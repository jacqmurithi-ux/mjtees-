-- Reconstructed policy consolidation from the live website_content RLS catalog.
-- Original migration source was not present in repository history.
-- Final policy definitions match the currently applied live policy set.
-- This file is for clean local migration replay; do not re-apply to hosted production.

begin;

drop policy if exists "Public can read published website content" on public.website_content;
drop policy if exists "Owners can manage website content" on public.website_content;

create policy "Public can read published website content"
  on public.website_content for select
  to anon
  using (is_published = true);

create policy "Public and owners can read website content"
  on public.website_content for select
  to authenticated
  using (
    is_published = true
    or exists (
      select 1 from public.business_memberships m
      where m.business_id = website_content.business_id
        and m.user_id = (select auth.uid())
        and m.role = 'owner'
        and m.status = 'active'
    )
  );

create policy "Owners can create their website content"
  on public.website_content for insert
  to authenticated
  with check (
    exists (
      select 1 from public.business_memberships m
      where m.business_id = website_content.business_id
        and m.user_id = (select auth.uid())
        and m.role = 'owner'
        and m.status = 'active'
    )
  );

create policy "Owners can update their website content"
  on public.website_content for update
  to authenticated
  using (
    exists (
      select 1 from public.business_memberships m
      where m.business_id = website_content.business_id
        and m.user_id = (select auth.uid())
        and m.role = 'owner'
        and m.status = 'active'
    )
  )
  with check (
    exists (
      select 1 from public.business_memberships m
      where m.business_id = website_content.business_id
        and m.user_id = (select auth.uid())
        and m.role = 'owner'
        and m.status = 'active'
    )
  );

create policy "Owners can delete their website content"
  on public.website_content for delete
  to authenticated
  using (
    exists (
      select 1 from public.business_memberships m
      where m.business_id = website_content.business_id
        and m.user_id = (select auth.uid())
        and m.role = 'owner'
        and m.status = 'active'
    )
  );

commit;
