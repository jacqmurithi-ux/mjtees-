-- Pending feature-branch migration; do not apply without explicit production approval.
create table if not exists public.dtf_print_batches (
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null references public.businesses(id) on delete cascade,
 batch_number text not null, supplier_name text,
 sheet_count integer not null check(sheet_count>0),
 media_width numeric, media_height numeric,
 media_unit text not null default 'inches' check(media_unit in ('inches','cm')),
 printing_charge numeric not null default 0 check(printing_charge>=0),
 transport_cost numeric not null default 0 check(transport_cost>=0),
 heat_press_basis text not null check(heat_press_basis in ('piece','batch')),
 heat_press_rate numeric not null default 0 check(heat_press_rate>=0),
 heat_press_total numeric not null default 0 check(heat_press_total>=0),
 total_print_area_sq_in numeric not null check(total_print_area_sq_in>0),
 status text not null default 'recorded' check(status in ('recorded','sent_to_supplier','received','completed','cancelled')),
 created_by uuid not null, created_at timestamptz not null default now(),
 unique(business_id,batch_number)
);
create table if not exists public.dtf_print_jobs (
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null references public.businesses(id) on delete cascade,
 batch_id uuid not null references public.dtf_print_batches(id) on delete cascade,
 line_number integer not null, customer_id uuid not null references public.customers(id),
 job_reference text, sticker_type text not null,
 width_inches numeric not null check(width_inches>0), height_inches numeric not null check(height_inches>0),
 quantity integer not null check(quantity>0), area_sq_in numeric not null check(area_sq_in>0),
 allocated_print_transport_cost numeric not null default 0 check(allocated_print_transport_cost>=0),
 allocated_heat_press_cost numeric not null default 0 check(allocated_heat_press_cost>=0),
 direct_cost numeric not null default 0 check(direct_cost>=0),
 suggested_unit_price numeric not null default 0 check(suggested_unit_price>=0),
 agreed_unit_price numeric check(agreed_unit_price is null or agreed_unit_price>=0),
 transaction_status text not null default 'unquoted' check(transaction_status in ('unquoted','quoted','quote_accepted','sold','in_production','completed','cancelled')),
 quotation_id uuid references public.quotations(id), invoice_id uuid references public.sales_invoices(id),
 production_job_id uuid references public.production_jobs(id), created_at timestamptz not null default now(),
 unique(batch_id,line_number)
);
create index if not exists dtf_batches_business_idx on public.dtf_print_batches(business_id,created_at desc);
create index if not exists dtf_jobs_batch_idx on public.dtf_print_jobs(batch_id,line_number);
create index if not exists dtf_jobs_customer_idx on public.dtf_print_jobs(business_id,customer_id,created_at desc);
alter table public.dtf_print_batches enable row level security;
alter table public.dtf_print_jobs enable row level security;
create policy dtf_batches_owner_read on public.dtf_print_batches for select to authenticated using(exists(select 1 from public.business_memberships m where m.business_id=dtf_print_batches.business_id and m.user_id=auth.uid() and m.role='owner'));
create policy dtf_jobs_owner_read on public.dtf_print_jobs for select to authenticated using(exists(select 1 from public.business_memberships m where m.business_id=dtf_print_jobs.business_id and m.user_id=auth.uid() and m.role='owner'));
revoke all on public.dtf_print_batches,public.dtf_print_jobs from anon,authenticated;
grant select on public.dtf_print_batches,public.dtf_print_jobs to authenticated;
create or replace function public.owner_create_dtf_batch(p_batch jsonb,p_jobs jsonb)
returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
declare
 u uuid:=auth.uid(); b uuid; biz uuid; no text; area_total numeric:=0; total_qty numeric:=0; print_total numeric:=0; press_total numeric:=0;
 j jsonb; cust uuid; w numeric; h numeric; q integer; a numeric; n integer:=0; alloc_print numeric; alloc_press numeric; direct numeric;
begin
 if u is null then raise exception 'Authentication required'; end if;
 select business_id into biz from public.business_memberships where user_id=u and role='owner' order by created_at limit 1;
 if biz is null then raise exception 'Owner workspace required'; end if;
 if jsonb_typeof(p_batch)<>'object' or jsonb_typeof(p_jobs)<>'array' or jsonb_array_length(p_jobs)=0 then raise exception 'Batch and jobs are required'; end if;
 no:=nullif(btrim(p_batch->>'batch_number'),'');
 if no is null then raise exception 'Batch number required'; end if;
 print_total:=coalesce((p_batch->>'printing_charge')::numeric,0)+coalesce((p_batch->>'transport_cost')::numeric,0);
 press_total:=coalesce((p_batch->>'heat_press_total')::numeric,0);
 for j in select value from jsonb_array_elements(p_jobs) loop
  cust:=nullif(j->>'customer_id','')::uuid;
  if cust is null or not exists(select 1 from public.customers c where c.id=cust and c.business_id=biz) then raise exception 'Every job requires a customer in this workspace'; end if;
  w:=(j->>'width_inches')::numeric; h:=(j->>'height_inches')::numeric; q:=(j->>'quantity')::integer;
  if w<=0 or h<=0 or q<=0 then raise exception 'Invalid job dimensions or quantity'; end if;
  area_total:=area_total+w*h*q; total_qty:=total_qty+q;
 end loop;
 if area_total<=0 or print_total<0 or press_total<0 then raise exception 'Invalid batch totals'; end if;
 insert into public.dtf_print_batches(business_id,batch_number,supplier_name,sheet_count,media_width,media_height,media_unit,printing_charge,transport_cost,heat_press_basis,heat_press_rate,heat_press_total,total_print_area_sq_in,created_by)
 values(biz,no,nullif(p_batch->>'supplier_name',''),greatest(1,coalesce((p_batch->>'sheet_count')::integer,1)),nullif(p_batch->>'media_width','')::numeric,nullif(p_batch->>'media_height','')::numeric,coalesce(p_batch->>'media_unit','inches'),coalesce((p_batch->>'printing_charge')::numeric,0),coalesce((p_batch->>'transport_cost')::numeric,0),coalesce(p_batch->>'heat_press_basis','piece'),coalesce((p_batch->>'heat_press_rate')::numeric,0),press_total,area_total,u) returning id into b;
 for j in select value from jsonb_array_elements(p_jobs) loop
  n:=n+1; cust:=(j->>'customer_id')::uuid; w:=(j->>'width_inches')::numeric; h:=(j->>'height_inches')::numeric; q:=(j->>'quantity')::integer; a:=w*h*q;
  alloc_print:=round(print_total*a/area_total,2);
  alloc_press:=case when n=jsonb_array_length(p_jobs) then press_total-(select coalesce(sum(allocated_heat_press_cost),0) from public.dtf_print_jobs where batch_id=b) when coalesce(p_batch->>'heat_press_basis','piece')='piece' then round(coalesce((p_batch->>'heat_press_rate')::numeric,0)*q,2) else round(press_total*q/total_qty,2) end;
  direct:=coalesce((j->>'direct_cost')::numeric,alloc_print+alloc_press);
  insert into public.dtf_print_jobs(business_id,batch_id,line_number,customer_id,job_reference,sticker_type,width_inches,height_inches,quantity,area_sq_in,allocated_print_transport_cost,allocated_heat_press_cost,direct_cost,suggested_unit_price,agreed_unit_price)
  values(biz,b,n,cust,nullif(j->>'job_reference',''),coalesce(nullif(j->>'sticker_type',''),'DTF sticker'),w,h,q,a,alloc_print,alloc_press,direct,coalesce((j->>'suggested_unit_price')::numeric,ceil(direct/q/0.7)),nullif(j->>'agreed_unit_price','')::numeric);
 end loop;
 insert into public.audit_events(business_id,actor_user_id,event_type,entity_type,entity_id,details)
 values(biz,u,'dtf.batch_created','dtf_print_batch',b,jsonb_build_object('job_count',n,'total_print_area_sq_in',area_total,'supplier_transport',print_total,'heat_press_total',press_total));
 return jsonb_build_object('batch_id',b,'batch_number',no,'job_count',n,'total_print_area_sq_in',area_total,'allocated_cost',print_total+press_total);
end $$;
revoke all on function public.owner_create_dtf_batch(jsonb,jsonb) from public,anon;
grant execute on function public.owner_create_dtf_batch(jsonb,jsonb) to authenticated;
