-- DTF foreign-key indexes and init-plan-safe owner read policies.
create index if not exists dtf_batches_supplier_idx on public.dtf_print_batches(supplier_id);
create index if not exists dtf_jobs_customer_fk_idx on public.dtf_print_jobs(customer_id);
create index if not exists dtf_jobs_invoice_fk_idx on public.dtf_print_jobs(invoice_id);
create index if not exists dtf_jobs_production_job_fk_idx on public.dtf_print_jobs(production_job_id);
create index if not exists dtf_jobs_quotation_fk_idx on public.dtf_print_jobs(quotation_id);

drop policy if exists dtf_batches_owner_read on public.dtf_print_batches;
create policy dtf_batches_owner_read on public.dtf_print_batches
for select to authenticated
using (exists (
 select 1 from public.business_memberships m
 where m.business_id=dtf_print_batches.business_id
 and m.user_id=(select auth.uid())
 and m.role='owner'
));

drop policy if exists dtf_jobs_owner_read on public.dtf_print_jobs;
create policy dtf_jobs_owner_read on public.dtf_print_jobs
for select to authenticated
using (exists (
 select 1 from public.business_memberships m
 where m.business_id=dtf_print_jobs.business_id
 and m.user_id=(select auth.uid())
 and m.role='owner'
));
