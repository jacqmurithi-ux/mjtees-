begin;
create extension if not exists pgtap with schema extensions;
select extensions.plan(28);

insert into auth.users(
 id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,
 created_at,updated_at,raw_app_meta_data,raw_user_meta_data
) values(
 '11111111-1111-4111-8111-111111111111',
 '00000000-0000-0000-0000-000000000000',
 'authenticated','authenticated','mj-e2e@example.test','',now(),
 now(),now(),'{"provider":"email","providers":["email"]}'::jsonb,'{}'::jsonb
) on conflict(id) do nothing;

select set_config('request.jwt.claim.sub','11111111-1111-4111-8111-111111111111',true);
set local role authenticated;

select extensions.is(public.owner_bootstrap_workspace()->>'business_name','MJ Printing & Branding','existing owner can bootstrap the new workspace');
select set_config('test.business_id',(public.owner_bootstrap_workspace()->>'business_id'),true);
select extensions.is((select count(*)::integer from public.business_memberships where business_id=current_setting('test.business_id')::uuid and user_id=auth.uid() and role='owner'),1,'bootstrap creates exactly one owner membership for the existing Auth user');
select extensions.is((select count(*)::integer from public.inventory_locations where business_id=current_setting('test.business_id')::uuid),2,'bootstrap creates both Shop 1 and Shop 2 inventory locations');
select extensions.ok(exists(select 1 from public.business_settings where business_id=current_setting('test.business_id')::uuid),'bootstrap creates business settings');
select extensions.ok(
 not has_table_privilege('authenticated','public.costing_profiles','INSERT') and
 not has_table_privilege('authenticated','public.quotations','INSERT') and
 not has_table_privilege('authenticated','public.quotation_lines','INSERT') and
 not has_table_privilege('authenticated','public.sales_invoices','INSERT') and
 not has_table_privilege('authenticated','public.sales_invoice_items','INSERT') and
 not has_table_privilege('authenticated','public.production_jobs','INSERT') and
 not has_table_privilege('authenticated','public.purchase_orders','INSERT') and
 not has_table_privilege('authenticated','public.payments','INSERT') and
 not has_table_privilege('authenticated','public.payment_allocations','INSERT') and
 not has_table_privilege('authenticated','public.expenses','INSERT') and
 not has_table_privilege('authenticated','public.audit_events','INSERT'),
 'direct inserts into financial and audit tables are blocked');

insert into public.customers(business_id,customer_name,customer_type,created_by)
select (public.owner_bootstrap_workspace()->>'business_id')::uuid,'Example Customer','individual',auth.uid();

select set_config('test.stock_id',public.owner_create_stock_item('shop_1','Generic test stock item','General','piece',10,2,0,'E2E-STOCK')::text,true);
select extensions.throws_ok(
 $$select public.owner_create_quotation((select id from public.customers where customer_name='Example Customer'),null,'Q-NO-PROFILE',current_date+7,'[{"description":"No profile","quantity":1,"unit_price":100,"direct_cost":10,"details":{}}]'::jsonb,false,null)$$,
 'P0001','An active versioned costing profile is required before pricing this quotation',
 'refuses to price without an active versioned costing profile');

select set_config('test.profile_id',public.owner_create_costing_profile(
 'Generic production service',
 '[{"name":"Outsourced printing labour","cost":600,"basis":"per_job"}]'::jsonb,
 600,true
)::text,true);
select extensions.ok((select is_active and version=1 and direct_cost=600 from public.costing_profiles where id=current_setting('test.profile_id')::uuid),'version one costing profile is active and stores its direct cost');

select set_config('test.cost_override_quote',public.owner_create_quotation(
 (select id from public.customers where customer_name='Example Customer'),current_setting('test.profile_id')::uuid,
 'Q-COST-BREAKDOWN',current_date+7,
 '[{"description":"Generic garment printing","quantity":16,"unit_price":700,"details":{"blank_cost_per_piece":450,"other_costs_total":800}}]'::jsonb,false,null
)::text,true);
select extensions.is((select direct_cost from public.quotation_lines where quotation_id=current_setting('test.cost_override_quote')::uuid),8000::numeric,'quote direct cost is blank cost per piece times quantity plus other direct costs');
select extensions.is((select round(((q.total-l.direct_cost)/l.direct_cost)*100,2) from public.quotations q join public.quotation_lines l on l.quotation_id=q.id where q.id=current_setting('test.cost_override_quote')::uuid),40.00::numeric,'contribution divided by direct cost produces the expected 40 percent margin');

select extensions.throws_ok(
 $$select public.owner_create_quotation((select id from public.customers where customer_name='Example Customer'),current_setting('test.profile_id')::uuid,'Q-TEST-LOW',current_date+7,'[{"description":"Low price test","quantity":2,"unit_price":100,"direct_cost":0,"details":{}}]'::jsonb,false,null)$$,
 'P0001','Quotation is below the 30% gross-margin floor. An authorised exception and reason are required.',
 'blocks quotations below the 30 percent floor without an exception');

select set_config('test.exception_quote_id',public.owner_create_quotation(
 (select id from public.customers where customer_name='Example Customer'),current_setting('test.profile_id')::uuid,
 'Q-TEST-EXCEPTION',current_date+7,
 '[{"description":"Approved below-floor test","quantity":50,"unit_price":5,"direct_cost":0,"details":{}}]'::jsonb,
 true,'Approved contract exception'
)::text,true);
select extensions.ok((select below_floor_approved_by=auth.uid() and below_floor_exception_reason='Approved contract exception' from public.quotations where id=current_setting('test.exception_quote_id')::uuid),'below-floor exception records owner approver and reason');

select set_config('test.quote_id',public.owner_create_quotation(
 (select id from public.customers where customer_name='Example Customer'),current_setting('test.profile_id')::uuid,
 'Q-TEST-E2E',current_date+7,
 '[{"description":"Generic production service for customer-supplied items","quantity":2,"unit_price":500,"direct_cost":0,"details":{"item_type":"printing_service","customer_supplied_items":true}}]'::jsonb,
 false,null
)::text,true);

select extensions.is((select total from public.quotations where id=current_setting('test.quote_id')::uuid),1000::numeric,'test quotation total is KES 1,000');
select extensions.is((select round(((total-(select sum(direct_cost) from public.quotation_lines where quotation_id=q.id))/total)*100,2) from public.quotations q where id=current_setting('test.quote_id')::uuid),66.67::numeric,'test contribution divided by direct cost is 66.67 percent');

select public.owner_set_quotation_status(current_setting('test.quote_id')::uuid,'sent');
select public.owner_set_quotation_status(current_setting('test.quote_id')::uuid,'accepted');
select set_config('test.converted',public.owner_convert_quote_to_invoice(current_setting('test.quote_id')::uuid,'INV-TEST-E2E','JOB-TEST-E2E',current_date+14)::text,true);
select set_config('test.invoice_id',(current_setting('test.converted')::jsonb->>'invoice_id'),true);
select set_config('test.job_id',(current_setting('test.converted')::jsonb->>'job_id'),true);

select extensions.is((select balance from public.sales_invoices where id=current_setting('test.invoice_id')::uuid),1000::numeric,'credit invoice remains fully outstanding before payment');
select extensions.ok((select customer_supplied_items from public.production_jobs where id=current_setting('test.job_id')::uuid),'production job records customer-supplied garments');
select extensions.is((select quantity_on_hand from public.stock_items where id=current_setting('test.stock_id')::uuid),10::numeric,'customer-owned items do not reduce MJ stock');

select public.owner_set_production_stage(current_setting('test.job_id')::uuid,'artwork_proof');
select public.owner_set_production_stage(current_setting('test.job_id')::uuid,'screens_prepared');
select public.owner_set_production_stage(current_setting('test.job_id')::uuid,'printing');
select public.owner_set_production_stage(current_setting('test.job_id')::uuid,'finishing');
select public.owner_set_production_stage(current_setting('test.job_id')::uuid,'quality_check');
select public.owner_set_production_stage(current_setting('test.job_id')::uuid,'ready');
select public.owner_set_production_stage(current_setting('test.job_id')::uuid,'delivered');
select extensions.ok((select delivered_at is not null from public.production_jobs where id=current_setting('test.job_id')::uuid),'production delivery is timestamped');
select extensions.ok((select due_at is not null from public.production_jobs where id=current_setting('test.job_id')::uuid),'production due date is carried from the invoice terms');

select extensions.throws_ok(
 $select public.owner_record_payment(current_setting('test.invoice_id')::uuid,'PAY-TEST-OVER','cash',1001,null)$,
 'P0001','Invalid payment method or amount exceeds invoice balance',
 'rejects a customer payment greater than the outstanding invoice balance');
select public.owner_record_payment(current_setting('test.invoice_id')::uuid,'PAY-TEST-E2E','mpesa_paybill',1000,'E2E-TEST-REF');
select extensions.is((select balance from public.sales_invoices where id=current_setting('test.invoice_id')::uuid),0::numeric,'payment clears invoice balance');
select extensions.is((select status from public.sales_invoices where id=current_setting('test.invoice_id')::uuid),'paid','invoice status changes to paid');

select extensions.is((public.owner_operational_report()->>'invoiced_sales')::numeric,1000::numeric,'report includes invoiced sales');
select extensions.is((public.owner_operational_report()->>'payments_received')::numeric,1000::numeric,'report includes received payment');
select extensions.is((public.owner_operational_report()->>'direct_production_cost')::numeric,600::numeric,'report carries costing profile direct cost into invoice');
select extensions.is((public.owner_operational_report()->>'gross_profit')::numeric,400::numeric,'gross profit before other direct costs is KES 400');
select extensions.is((public.owner_operational_report()->>'gross_margin_percent')::numeric,66.67::numeric,'report calculates contribution divided by direct cost');
select extensions.is((public.owner_operational_report()->>'outstanding_receivables')::numeric,0::numeric,'report clears paid receivable');
select extensions.is((public.owner_operational_report()->>'delivered_jobs')::integer,1,'report includes delivered production job');

select * from extensions.finish();
rollback;
