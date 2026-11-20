alter table public.business_settings
  add column if not exists logo_url text;

create policy "Owners upload business logos"
on storage.objects for insert to authenticated
with check (
  bucket_id = 'website-media'
  and (storage.foldername(name))[1] ~ '^[0-9a-fA-F-]{36}$'
  and (storage.foldername(name))[2] = 'branding'
  and (storage.foldername(name))[3] = 'logo'
  and exists (
    select 1 from public.business_memberships m
    where m.business_id::text = (storage.foldername(name))[1]
      and m.user_id = (select auth.uid())
      and m.role = 'owner'
  )
);

create policy "Owners replace business logos"
on storage.objects for update to authenticated
using (
  bucket_id = 'website-media'
  and (storage.foldername(name))[1] ~ '^[0-9a-fA-F-]{36}$'
  and (storage.foldername(name))[2] = 'branding'
  and (storage.foldername(name))[3] = 'logo'
  and exists (
    select 1 from public.business_memberships m
    where m.business_id::text = (storage.foldername(name))[1]
      and m.user_id = (select auth.uid())
      and m.role = 'owner'
  )
)
with check (
  bucket_id = 'website-media'
  and (storage.foldername(name))[1] ~ '^[0-9a-fA-F-]{36}$'
  and (storage.foldername(name))[2] = 'branding'
  and (storage.foldername(name))[3] = 'logo'
  and exists (
    select 1 from public.business_memberships m
    where m.business_id::text = (storage.foldername(name))[1]
      and m.user_id = (select auth.uid())
      and m.role = 'owner'
  )
);

create policy "Owners delete business logos"
on storage.objects for delete to authenticated
using (
  bucket_id = 'website-media'
  and (storage.foldername(name))[1] ~ '^[0-9a-fA-F-]{36}$'
  and (storage.foldername(name))[2] = 'branding'
  and (storage.foldername(name))[3] = 'logo'
  and exists (
    select 1 from public.business_memberships m
    where m.business_id::text = (storage.foldername(name))[1]
      and m.user_id = (select auth.uid())
      and m.role = 'owner'
  )
);
