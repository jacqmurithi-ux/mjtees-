-- DTF mixed-customer supplier batches and paid supplier expense recognition.
create table if not exists public.dtf_print_batches (
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null references public.businesses(id) on delete cascade,
 batch_number text not null, supplier_name text,
 sheet_count integer not null check(sheet_count>0),
 media_width numeric, media_height numeric,
 media_unit text not null default 'inches' check(media_unit in ('inches','cm')),
 printing_charge numeric not null default 0 check(printing_charge>=0),
 transport_cost numeric not null default 0 check(transport_cost>=0),
 labour_cost numeric not null default 0 check(labour_cost>=0),
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
 allocated_labour_cost numeric not null default 0 check(allocated_labour_cost>=0),
 direct_cost numeric not null default 0 check(direct_cost>=0),
 suggested_unit_price numeric not null default 0 check(suggested_unit_price>=0),
 agreed_unit_price numeric check(agreed_unit_price is null or agreed_unit_price>=0),
 transaction_status text not null default 'unquoted' check(transaction_status in ('unquoted','quoted','quote_accepted','sold','in_production','completed','cancelled')),
 quotation_id uuid references public.quotations(id), invoice_id uuid references public.sales_invoices(id),
 production_job_id uuid references public.production_jobs(id), created_at timestamptz not null default now(),
 unique(batch_id,line_number)
);
alter table public.dtf_print_batches add column if not exists labour_cost numeric not null default 0 check(labour_cost>=0);
alter table public.dtf_print_jobs add column if not exists allocated_labour_cost numeric not null default 0 check(allocated_labour_cost>=0);
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
 u uuid:=auth.uid(); b uuid; biz uuid; no text; area_total numeric:=0; total_qty numeric:=0; print_total numeric:=0; press_total numeric:=0; labour_total numeric:=0;
 j jsonb; cust uuid; w numeric; h numeric; q integer; a numeric; n integer:=0; alloc_print numeric; alloc_press numeric; alloc_labour numeric; direct numeric;
 allocated_print numeric:=0; allocated_press numeric:=0; allocated_labour numeric:=0; batch_press_basis text; batch_press_rate numeric;
begin
 if u is null then raise exception 'Authentication required'; end if;
 select business_id into biz from public.business_memberships where user_id=u and role='owner' order by created_at limit 1;
 if biz is null then raise exception 'Owner workspace required'; end if;
 if jsonb_typeof(p_batch)<>'object' or jsonb_typeof(p_jobs)<>'array' or jsonb_array_length(p_jobs)=0 then raise exception 'Batch and jobs are required'; end if;
 no:=nullif(btrim(p_batch->>'batch_number'),'');
 if no is null then raise exception 'Batch number required'; end if;
 if nullif(p_batch->>'supplier_id','') is null or not exists(select 1 from public.suppliers s where s.id=(p_batch->>'supplier_id')::uuid and s.business_id=biz) then raise exception 'Select a valid supplier in this workspace'; end if;
 print_total:=coalesce((p_batch->>'printing_charge')::numeric,0)+coalesce((p_batch->>'transport_cost')::numeric,0);
 press_total:=coalesce((p_batch->>'heat_press_total')::numeric,0);
 labour_total:=coalesce((p_batch->>'labour_cost')::numeric,0);
 batch_press_basis:=coalesce(p_batch->>'heat_press_basis','piece');
 batch_press_rate:=coalesce((p_batch->>'heat_press_rate')::numeric,0);
 if batch_press_basis not in ('piece','batch') or batch_press_rate<0 then raise exception 'Invalid heat-press costing basis or rate'; end if;
 for j in select value from jsonb_array_elements(p_jobs) loop
  cust:=nullif(j->>'customer_id','')::uuid;
  if cust is null or not exists(select 1 from public.customers c where c.id=cust and c.business_id=biz) then raise exception 'Every job requires a customer in this workspace'; end if;
  w:=(j->>'width_inches')::numeric; h:=(j->>'height_inches')::numeric; q:=(j->>'quantity')::integer;
  if w<=0 or h<=0 or q<=0 then raise exception 'Invalid job dimensions or quantity'; end if;
  area_total:=area_total+w*h*q; total_qty:=total_qty+q;
 end loop;
 if area_total<=0 or print_total<0 or press_total<0 or labour_total<0 then raise exception 'Invalid batch totals'; end if;
 if batch_press_basis='piece' and abs(press_total-(batch_press_rate*total_qty))>0.01 then
  raise exception 'Per-piece heat-press total does not match the job quantities and rate';
 end if;
 if batch_press_basis='batch' and abs(press_total-batch_press_rate)>0.01 then
  raise exception 'Batch heat-press total does not match the entered batch rate';
 end if;
 insert into public.dtf_print_batches(business_id,batch_number,supplier_name,supplier_id,supplier_order_reference,sheet_count,media_width,media_height,media_unit,printing_charge,transport_cost,labour_cost,heat_press_basis,heat_press_rate,heat_press_total,total_print_area_sq_in,created_by)
 values(biz,no,nullif(p_batch->>'supplier_name',''),(p_batch->>'supplier_id')::uuid,nullif(p_batch->>'supplier_order_reference',''),greatest(1,coalesce((p_batch->>'sheet_count')::integer,1)),nullif(p_batch->>'media_width','')::numeric,nullif(p_batch->>'media_height','')::numeric,coalesce(p_batch->>'media_unit','inches'),coalesce((p_batch->>'printing_charge')::numeric,0),coalesce((p_batch->>'transport_cost')::numeric,0),labour_total,coalesce(p_batch->>'heat_press_basis','piece'),coalesce((p_batch->>'heat_press_rate')::numeric,0),press_total,area_total,u) returning id into b;
 for j in select value from jsonb_array_elements(p_jobs) loop
  n:=n+1; cust:=(j->>'customer_id')::uuid; w:=(j->>'width_inches')::numeric; h:=(j->>'height_inches')::numeric; q:=(j->>'quantity')::integer; a:=w*h*q;
  if n=jsonb_array_length(p_jobs) then
   alloc_print:=round(print_total-allocated_print,2);
   alloc_press:=round(press_total-allocated_press,2);
   alloc_labour:=round(labour_total-allocated_labour,2);
  else
   alloc_print:=round(print_total*a/area_total,2);
   alloc_press:=case when batch_press_basis='piece' then round(batch_press_rate*q,2) else round(press_total*q/total_qty,2) end;
   alloc_labour:=round(labour_total*q/total_qty,2);
  end if;
  allocated_print:=allocated_print+alloc_print;
  allocated_press:=allocated_press+alloc_press;
  allocated_labour:=allocated_labour+alloc_labour;
  direct:=alloc_print+alloc_press+alloc_labour;
  if nullif(j->>'agreed_unit_price','') is not null and
     (j->>'agreed_unit_price')::numeric+0.000001 < direct/q/0.7 then
   raise exception 'DTF job agreed price is below the 30%% gross-margin floor';
  end if;
  insert into public.dtf_print_jobs(business_id,batch_id,line_number,customer_id,job_reference,sticker_type,width_inches,height_inches,quantity,area_sq_in,allocated_print_transport_cost,allocated_heat_press_cost,allocated_labour_cost,direct_cost,suggested_unit_price,agreed_unit_price)
  values(biz,b,n,cust,nullif(j->>'job_reference',''),coalesce(nullif(j->>'sticker_type',''),'DTF sticker'),w,h,q,a,alloc_print,alloc_press,alloc_labour,direct,ceil(direct/q/0.7),nullif(j->>'agreed_unit_price','')::numeric);
 end loop;
 insert into public.audit_events(business_id,actor_user_id,event_type,entity_type,entity_id,details)
 values(biz,u,'dtf.batch_created','dtf_print_batch',b,jsonb_build_object('job_count',n,'total_print_area_sq_in',area_total,'supplier_transport',print_total,'heat_press_total',press_total));
 return jsonb_build_object('batch_id',b,'batch_number',no,'job_count',n,'total_print_area_sq_in',area_total,'allocated_cost',print_total+press_total+labour_total);
end $$;
revoke all on function public.owner_create_dtf_batch(jsonb,jsonb) from public,anon;
grant execute on function public.owner_create_dtf_batch(jsonb,jsonb) to authenticated;


-- Create a quotation for one customer job without combining other batch customers.
create or replace function public.owner_quote_dtf_batch_job(p_job_id uuid,p_quote_number text,p_valid_until date)
returns uuid language plpgsql security definer set search_path=public,private,pg_temp as $$
declare u uuid:=auth.uid(); biz uuid; j public.dtf_print_jobs%rowtype; b public.dtf_print_batches%rowtype; qid uuid; details jsonb; unit_price numeric;
begin
 select business_id into biz from public.business_memberships where user_id=u and role='owner' order by created_at limit 1;
 if biz is null then raise exception 'Owner workspace required'; end if;
 select * into j from public.dtf_print_jobs where id=p_job_id and business_id=biz for update;
 if not found then raise exception 'DTF job not found'; end if;
 if j.transaction_status not in ('unquoted') then raise exception 'Only unquoted DTF jobs can be quoted'; end if;
 select * into b from public.dtf_print_batches where id=j.batch_id and business_id=biz;
 unit_price:=coalesce(j.agreed_unit_price,j.suggested_unit_price);
 if unit_price+0.000001 < j.direct_cost/j.quantity/0.7 then raise exception 'DTF job price is below the 30% gross-margin floor'; end if;
 details:=jsonb_build_object('module','dtf_costing','source','mixed_supplier_batch','batch_id',b.id,'job_id',j.id,'sticker_type',j.sticker_type,'width_inches',j.width_inches,'height_inches',j.height_inches,'quantity',j.quantity,'allocated_print_transport_cost',j.allocated_print_transport_cost,'allocated_heat_press_cost',j.allocated_heat_press_cost,'allocated_labour_cost',j.allocated_labour_cost,'direct_cost_total',j.direct_cost,'direct_cost_per_piece',j.direct_cost/j.quantity);
 qid:=public.owner_create_dtf_quotation(j.customer_id,p_quote_number,p_valid_until,j.quantity,unit_price,j.direct_cost/j.quantity,details,false,null);
 update public.dtf_print_jobs set quotation_id=qid,transaction_status='quoted' where id=j.id;
 return qid;
end $$;

-- Record a Quick Sale for one customer job through the existing canonical accounting RPC.
create or replace function public.owner_sell_dtf_batch_job(p_job_id uuid,p_invoice_number text,p_due_date date,p_payment_amount numeric default 0,p_payment_method text default null,p_payment_reference text default null,p_payment_number text default null)
returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
declare u uuid:=auth.uid(); biz uuid; j public.dtf_print_jobs%rowtype; b public.dtf_print_batches%rowtype; result jsonb; details jsonb; price numeric;
begin
 select business_id into biz from public.business_memberships where user_id=u and role='owner' order by created_at limit 1;
 if biz is null then raise exception 'Owner workspace required'; end if;
 select * into j from public.dtf_print_jobs where id=p_job_id and business_id=biz for update;
 if not found then raise exception 'DTF job not found'; end if;
 if j.transaction_status not in ('unquoted','quoted','quote_accepted') then raise exception 'DTF job is already sold or closed'; end if;
 select * into b from public.dtf_print_batches where id=j.batch_id and business_id=biz;
 price:=coalesce(j.agreed_unit_price,j.suggested_unit_price);
 if price+0.000001 < j.direct_cost/j.quantity/0.7 then raise exception 'DTF job price is below the 30% gross-margin floor'; end if;
 details:=jsonb_build_object('module','dtf_costing','source','mixed_supplier_batch','batch_id',b.id,'job_id',j.id,'stickers',jsonb_build_array(jsonb_build_object('label',j.sticker_type,'width_inches',j.width_inches,'height_inches',j.height_inches,'quantity',j.quantity)),'allocated_print_transport_cost',j.allocated_print_transport_cost,'allocated_heat_press_cost',j.allocated_heat_press_cost,'allocated_labour_cost',j.allocated_labour_cost,'direct_cost_total',j.direct_cost,'direct_cost_per_piece',j.direct_cost/j.quantity,'garments','[]'::jsonb);
 result:=public.owner_create_dtf_quick_sale(j.customer_id,p_invoice_number,p_due_date,j.sticker_type,j.quantity,price,j.direct_cost/j.quantity,details,'[]'::jsonb,false,null,p_payment_number,p_payment_method,coalesce(p_payment_amount,0),p_payment_reference);
 update public.dtf_print_jobs set invoice_id=(result->>'invoice_id')::uuid,transaction_status='sold' where id=j.id;
 return result||jsonb_build_object('dtf_batch_id',b.id,'dtf_job_id',j.id);
end $$;
revoke all on function public.owner_quote_dtf_batch_job(uuid,text,date) from public,anon;
grant execute on function public.owner_quote_dtf_batch_job(uuid,text,date) to authenticated;
revoke all on function public.owner_sell_dtf_batch_job(uuid,text,date,numeric,text,text,text) from public,anon;
grant execute on function public.owner_sell_dtf_batch_job(uuid,text,date,numeric,text,text,text) to authenticated;


-- Supplier cost recognition: unpaid DTF orders remain obligations; each actual
-- payment is posted once to Finance > Expenses / Supplies.
alter table public.dtf_print_batches add column if not exists supplier_id uuid references public.suppliers(id);
alter table public.dtf_print_batches add column if not exists supplier_order_reference text;
alter table public.supplier_payments add column if not exists dtf_batch_id uuid references public.dtf_print_batches(id);
alter table public.expenses add column if not exists source_type text;
alter table public.expenses add column if not exists source_id uuid;
create unique index if not exists expenses_source_unique on public.expenses(source_type,source_id) where source_type is not null and source_id is not null;
create index if not exists supplier_payments_dtf_batch_idx on public.supplier_payments(dtf_batch_id);
create unique index if not exists supplier_payments_business_payment_number_uidx on public.supplier_payments(business_id,payment_number);

create or replace function public.owner_record_dtf_supplier_payment(
 p_batch_id uuid,p_payment_number text,p_method text,p_amount numeric,p_reference_code text default null
) returns uuid language plpgsql security definer set search_path=public,private,pg_temp as $$
declare u uuid:=auth.uid(); biz uuid; b public.dtf_print_batches%rowtype; supplier_due numeric; paid numeric; payment_id uuid; expense_id uuid;
begin
 select business_id into biz from public.business_memberships where user_id=u and role='owner' order by created_at limit 1;
 if biz is null then raise exception 'Owner workspace required'; end if;
 select * into b from public.dtf_print_batches where id=p_batch_id and business_id=biz for update;
 if not found then raise exception 'DTF supplier batch not found'; end if;
 if b.supplier_id is null then raise exception 'Select the supplier for this DTF batch before recording payment'; end if;
 if p_method not in ('cash','mpesa_paybill') or p_amount is null or p_amount<=0 or length(btrim(coalesce(p_payment_number,'')))=0 then raise exception 'Enter a valid payment number, method and positive amount'; end if;
 select coalesce(sum(amount),0) into paid from public.supplier_payments where business_id=biz and dtf_batch_id=b.id;
 supplier_due:=b.printing_charge+b.transport_cost-paid;
 if p_amount>greatest(0,supplier_due) then raise exception 'Payment exceeds outstanding DTF supplier order balance'; end if;
 insert into public.supplier_payments(business_id,supplier_id,dtf_batch_id,payment_number,method,amount,reference_code,paid_by)
 values(biz,b.supplier_id,b.id,btrim(p_payment_number),p_method,p_amount,nullif(btrim(p_reference_code),''),u) returning id into payment_id;
 insert into public.expenses(business_id,expense_date,category,description,amount,payment_method,created_by,source_type,source_id)
 values(biz,current_date,'Supplies','DTF supplier order '||b.batch_number||' — payment '||btrim(p_payment_number),p_amount,p_method,u,'dtf_supplier_payment',payment_id)
 returning id into expense_id;
 insert into public.audit_events(business_id,actor_user_id,event_type,entity_type,entity_id,details)
 values(biz,u,'dtf.supplier_payment_recorded','dtf_supplier_payment',payment_id,jsonb_build_object('batch_id',b.id,'expense_id',expense_id,'amount',p_amount,'category','Supplies','outstanding_after_payment',supplier_due-p_amount));
 return payment_id;
end $$;
revoke all on function public.owner_record_dtf_supplier_payment(uuid,text,text,numeric,text) from public,anon;
grant execute on function public.owner_record_dtf_supplier_payment(uuid,text,text,numeric,text) to authenticated;
