-- Restore the audit fields required by the existing quotation pricing RPC.
-- Nullable additive columns preserve all existing quotation records.
alter table public.quotations
  add column if not exists below_floor_exception_reason text,
  add column if not exists below_floor_approved_by uuid references auth.users(id);

comment on column public.quotations.below_floor_exception_reason is
  'Reason recorded when an owner authorises a quotation below the 30 percent gross-margin floor.';
comment on column public.quotations.below_floor_approved_by is
  'Authenticated owner who authorised the below-floor quotation exception.';
