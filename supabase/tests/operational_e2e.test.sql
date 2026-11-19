begin;
create extension if not exists pgtap with schema extensions;
select extensions.plan(17);

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

insert into public.customers(business_id,customer_name,customer_type,created_by)
select (public.owner_bootstrap_workspace()->>'business_id')::uuid,'Baraka Uniform Supplies','school',auth.uid();

select set_config('test.stock_id',public.owner_create_stock_item('shop_1','Blank school T-shirts','Apparel','piece',10,2,0,'BARAKA-BLANK-TEE')::text,true);
select extensions.throws_ok(
 $$select public.owner_create_quotation((select id from public.customers where customer_name='Baraka Uniform Supplies'),null,'Q-NO-PROFILE',current_date+7,'[{"description":"No profile","quantity":1,"unit_price":100,"direct_cost":10,"details":{}}]'::jsonb,false,null)$$,
 'P0001','An active versioned costing profile is required before pricing this quotation',
 'refuses to price without an active versioned costing profile');

select set_config('test.profile_id',public.owner_create_costing_profile(
 'Screen printing — customer supplied garments',
 '[{"name":"Outsourced printing labour","cost":200,"basis":"per_job"}]'::jsonb,
 200,true
)::text,true);
select extensions.ok((select is_active and version=1 and direct_cost=200 from public.costing_profiles where id=current_setting('test.profile_id')::uuid),'version one costing profile is active and stores its direct cost');

select extensions.throws_ok(
 $$select public.owner_create_quotation((select id from public.customers where customer_name='Baraka Uniform Supplies'),current_setting('test.profile_id')::uuid,'Q-BARAKA-LOW',current_date+7,'[{"description":"Low price test","quantity":50,"unit_price":5,"direct_cost":200,"details":{}}]'::jsonb,false,null)$$,
 'P0001','Quotation is below the 30% gross-margin floor. An authorised exception and reason are required.',
 'blocks quotations below the 30 percent floor without an exception');

select set_config('test.exception_quote_id',public.owner_create_quotation(
 (select id from public.customers where customer_name='Baraka Uniform Supplies'),current_setting('test.profile_id')::uuid,
 'Q-BARAKA-EXCEPTION',current_date+7,
 '[{"description":"Approved below-floor test","quantity":50,"unit_price":5,"direct_cost":200,"details":{}}]'::jsonb,
 true,'Approved contract exception'
)::text,true);
select extensions.ok((select below_floor_approved_by=auth.uid() and below_floor_exception_reason='Approved contract exception' from public.quotations where id=current_setting('test.exception_quote_id')::uuid),'below-floor exception records owner approver and reason');

select set_config('test.quote_id',public.owner_create_quotation(
 (select id from public.customers where customer_name='Baraka Uniform Supplies'),current_setting('test.profile_id')::uuid,
 'Q-BARAKA-E2E',current_date+7,
 '[{"description":"Screen printing on customer-supplied school T-shirts","quantity":50,"unit_price":30,"direct_cost":200,"details":{"item_type":"printing_service","customer_supplied_items":true}}]'::jsonb,
 false,null
)::text,true);

select extensions.is((select total from public.quotations where id=current_setting('test.quote_id')::uuid),1500::numeric,'Baraka quotation total is KES 1,500');
select extensions.is((select round(((total-(select sum(direct_cost) from public.quotation_lines where quotation_id=q.id))/total)*100,2) from public.quotations q where id=current_setting('test.quote_id')::uuid),86.67::numeric,'Baraka gross margin is 86.67 percent');

select public.owner_set_quotation_status(current_setting('test.quote_id')::uuid,'sent');
select public.owner_set_quotation_status(current_setting('test.quote_id')::uuid,'accepted');
select set_config('test.converted',public.owner_convert_quote_to_invoice(current_setting('test.quote_id')::uuid,'INV-BARAKA-E2E','JOB-BARAKA-E2E',current_date+14)::text,true);
select set_config('test.invoice_id',(current_setting('test.converted')::jsonb->>'invoice_id'),true);
select set_config('test.job_id',(current_setting('test.converted')::jsonb->>'job_id'),true);

select extensions.is((select balance from public.sales_invoices where id=current_setting('test.invoice_id')::uuid),1500::numeric,'credit invoice remains fully outstanding before payment');
select extensions.ok((select customer_supplied_items from public.production_jobs where id=current_setting('test.job_id')::uuid),'production job records customer-supplied garments');
select extensions.is((select quantity_on_hand from public.stock_items where id=current_setting('test.stock_id')::uuid),10::numeric,'customer garments do not reduce MJ apparel stock');

select public.owner_set_production_stage(current_setting('test.job_id')::uuid,'artwork_proof');
select public.owner_set_production_stage(current_setting('test.job_id')::uuid,'screens_prepared');
select public.owner_set_production_stage(current_setting('test.job_id')::uuid,'printing');
select public.owner_set_production_stage(current_setting('test.job_id')::uuid,'finishing');
select public.owner_set_production_stage(current_setting('test.job_id')::uuid,'quality_check');
select public.owner_set_production_stage(current_setting('test.job_id')::uuid,'ready');
select public.owner_set_production_stage(current_setting('test.job_id')::uuid,'delivered');
select extensions.ok((select delivered_at is not null from public.production_jobs where id=current_setting('test.job_id')::uuid),'production delivery is timestamped');

select public.owner_record_payment(current_setting('test.invoice_id')::uuid,'PAY-BARAKA-E2E','mpesa_paybill',1500,'E2E-TEST-REF');
select extensions.is((select balance from public.sales_invoices where id=current_setting('test.invoice_id')::uuid),0::numeric,'payment clears invoice balance');
select extensions.is((select status from public.sales_invoices where id=current_setting('test.invoice_id')::uuid),'paid','invoice status changes to paid');

select extensions.is((public.owner_operational_report()->>'invoiced_sales')::numeric,1500::numeric,'report includes invoiced sales');
select extensions.is((public.owner_operational_report()->>'payments_received')::numeric,1500::numeric,'report includes received payment');
select extensions.is((public.owner_operational_report()->>'outstanding_receivables')::numeric,0::numeric,'report clears paid receivable');
select extensions.is((public.owner_operational_report()->>'delivered_jobs')::integer,1,'report includes delivered production job');

select * from extensions.finish();
rollback;
