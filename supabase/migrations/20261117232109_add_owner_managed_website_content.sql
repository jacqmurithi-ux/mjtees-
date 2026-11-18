-- Reconstructed migration baseline for the already-applied website-content schema.
-- Original migration source was not present in repository history.
-- Reconstructed from the live table, trigger, constraints and ownership policies.
-- This file is for clean local migration replay; do not re-apply to hosted production.

begin;

create table public.website_content (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null unique references public.businesses(id) on delete cascade,
  content jsonb not null default '{}'::jsonb
    check (jsonb_typeof(content) = 'object'),
  is_published boolean not null default false,
  published_at timestamptz,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null
);

create or replace function public.set_website_content_updated_at()
returns trigger
language plpgsql
set search_path to ''
as $function$
begin
  new.updated_at = now();
  new.updated_by = auth.uid();
  if new.is_published and not old.is_published then
    new.published_at = now();
  end if;
  return new;
end;
$function$;

create trigger set_website_content_updated_at
before update on public.website_content
for each row execute function public.set_website_content_updated_at();

alter table public.website_content enable row level security;

create policy "Public can read published website content"
  on public.website_content for select
  to anon, authenticated
  using (is_published = true);

create policy "Owners can manage website content"
  on public.website_content for all
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

commit;
