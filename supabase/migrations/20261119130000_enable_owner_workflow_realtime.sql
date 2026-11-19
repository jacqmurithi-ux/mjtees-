-- Enable owner-scoped Realtime refresh for quotations, production and delivery progress.
-- Every table already has row-level security enabled; Realtime continues to enforce RLS.
do $migration$
declare
  v_table text;
begin
  if not exists(select 1 from pg_publication where pubname='supabase_realtime') then
    raise exception 'Supabase Realtime publication is not available';
  end if;

  foreach v_table in array array[
    'quotations',
    'orders',
    'order_items',
    'sales_invoices',
    'payments',
    'receipts',
    'sales_invoice_payment_allocations',
    'sales_customer_credit_entries',
    'production_jobs',
    'production_cost_entries',
    'production_output_entries',
    'quality_checks',
    'rework_events'
  ] loop
    if to_regclass(format('public.%I',v_table)) is null then
      raise exception 'Required Realtime table public.% is missing',v_table;
    end if;
    if not exists(
      select 1 from pg_publication_tables
      where pubname='supabase_realtime'
        and schemaname='public'
        and tablename=v_table
    ) then
      execute format('alter publication supabase_realtime add table public.%I',v_table);
    end if;
  end loop;
end;
$migration$;
