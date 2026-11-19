-- Restore the direct production cost field consumed by quotation conversion.
-- Existing invoice lines remain intact and receive a neutral zero baseline.
alter table public.sales_invoice_items
  add column if not exists direct_cost numeric(14,2) not null default 0
  check (direct_cost >= 0);

comment on column public.sales_invoice_items.direct_cost is
  'Direct production cost carried from the accepted quotation line; excludes unapproved overhead allocations.';

notify pgrst, 'reload schema';
