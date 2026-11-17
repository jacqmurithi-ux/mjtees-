begin;
create extension if not exists pgtap with schema extensions;
select plan(32);

-- Isolated synthetic fixtures; all changes are rolled back at the end.
insert into auth.users(id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
values
('11111111-1111-4111-8111-111111111111','authenticated','authenticated','mj-owner-test@example.invalid','',now(),
 '{"provider":"email","providers":["email"]}'::jsonb,'{}'::jsonb,now(),now()),
('22222222-2222-4222-8222-222222222222','authenticated','authenticated','mj-outsider-test@example.invalid','',now(),
 '{"provider":"email","providers":["email"]}'::jsonb,'{}'::jsonb,now(),now());

insert into public.businesses(id,name) values('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','MJ Test Business');
insert into public.business_memberships(business_id,user_id,role,status)
values('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','11111111-1111-4111-8111-111111111111','owner','active');

insert into public.customers(id,business_id,display_name,created_by)
values('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','Test Customer','11111111-1111-4111-8111-111111111111');

insert into public.orders(id,business_id,order_number,customer_id,status,subtotal_amount,discount_amount,total_amount,created_by)
values('cccccccc-cccc-4ccc-8ccc-cccccccccccc','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','TEST-ORDER-1',
 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','confirmed',1000,0,1000,'11111111-1111-4111-8111-111111111111');
insert into public.inventory_locations(id,business_id,name,code)
values
 ('dddddddd-dddd-4ddd-8ddd-dddddddddddd','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','Main store','MAIN'),
 ('ffffffff-ffff-4fff-8fff-ffffffffffff','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','Materials store','MATERIALS');
insert into public.stock_items(id,business_id,sku,name,stock_kind,base_unit,purchase_unit,purchase_to_base_factor,
  roll_width_mm,usable_width_mm,current_average_unit_cost)
values('eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','VINYL-TEST','Hot peel vinyl',
  'material','m','m',1,500,480,50);
insert into public.order_items(id,business_id,order_id,description,quantity,unit,unit_price,line_discount,line_total,
  sale_mode,production_method_id)
values('99999999-9999-4999-8999-999999999999','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
 'cccccccc-cccc-4ccc-8ccc-cccccccccccc','Custom vinyl shirt',1,'piece',1000,0,1000,'value_added',
 (select id from public.production_methods where code='vinyl_cut'));

-- Exercise the public wrappers as a normal authenticated owner, not postgres.
set local role authenticated;
select set_config('request.jwt.claim.sub','11111111-1111-4111-8111-111111111111',true);

select is(
  (public.owner_upsert_customer('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',null,'RPC Customer',null,'0712345678',null,null,
    '10000000-0000-4000-8000-000000000001')->>'created')::boolean,
  true,'Owner can create a customer through the RPC'
);

select is(
  public.owner_upsert_customer('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',null,'RPC Customer',null,'0712345678',null,null,
    '10000000-0000-4000-8000-000000000001')->>'customer_id',
  (select id::text from public.customers where business_id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' and display_name='RPC Customer'),
  'Retry returns the original customer result'
);

select throws_ok(
  $$$select public.owner_upsert_customer('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',null,'Different Payload',null,null,null,null,
    '10000000-0000-4000-8000-000000000001')$$,
  '22023',null,'Reusing an idempotency key with different payload is rejected'
);

select is(
  public.owner_record_payment('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','cccccccc-cccc-4ccc-8ccc-cccccccccccc',
    'cash',400,now(),'Test payer','0712345678',null,null,'20000000-0000-4000-8000-000000000001')->>'status',
  'posted','Cash payment posts atomically'
);

select is(
  (public.owner_get_order_balance('cccccccc-cccc-4ccc-8ccc-cccccccccccc')->>'balance_due')::bigint,
  600::bigint,'Cash payment allocates and reduces order balance'
);

select is(
  public.owner_record_payment('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','cccccccc-cccc-4ccc-8ccc-cccccccccccc',
    'mpesa_manual',200,now(),'Test payer','0712345678','QWERTY123456',null,'20000000-0000-4000-8000-000000000002')->>'status',
  'pending_verification','Manual M-Pesa evidence remains pending'
);

select is(
  (public.owner_get_order_balance('cccccccc-cccc-4ccc-8ccc-cccccccccccc')->>'balance_due')::bigint,
  600::bigint,'Pending M-Pesa does not reduce the order balance'
);

select is(
  public.owner_verify_mpesa_payment(
    (select id from public.payments where idempotency_key='20000000-0000-4000-8000-000000000002'),
    'verified','Reference checked against statement','30000000-0000-4000-8000-000000000001')->>'status',
  'posted','Verified M-Pesa is posted and allocated to its original order'
);

select is(
  (public.owner_get_order_balance('cccccccc-cccc-4ccc-8ccc-cccccccccccc')->>'balance_due')::bigint,
  400::bigint,'Verified M-Pesa reduces the balance'
);

select is(
  public.owner_record_refund(
    (select id from public.payments where idempotency_key='20000000-0000-4000-8000-000000000001'),
    (select id from public.payment_allocations where payment_id=(select id from public.payments where idempotency_key='20000000-0000-4000-8000-000000000001')),
    'allocated',100,'Customer refund test','cash',null,'40000000-0000-4000-8000-000000000001')->>'status',
  'pending','Refund request is pending and reserves allocation capacity'
);

select is(
  (public.owner_get_order_balance('cccccccc-cccc-4ccc-8ccc-cccccccccccc')->>'balance_due')::bigint,
  400::bigint,'Pending refund does not change paid balance'
);

select is(
  public.owner_post_refund(
    (select id from public.payment_refunds where business_id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' order by created_at desc limit 1),
    '40000000-0000-4000-8000-000000000002')->>'status',
  'posted','Posting refund changes the ledger exactly once'
);


select is(
  (public.owner_adjust_stock('eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee','dddddddd-dddd-4ddd-8ddd-dddddddddddd',
    10,'opening_balance','Opening count','50000000-0000-4000-8000-000000000001')->>'on_hand')::numeric,
  10::numeric,'Opening balance creates the initial on-hand quantity'
);

select is(
  public.owner_transfer_stock('eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee','dddddddd-dddd-4ddd-8ddd-dddddddddddd',
    'ffffffff-ffff-4fff-8fff-ffffffffffff',2,'Move vinyl to production area',
    '50000000-0000-4000-8000-000000000002')->>'quantity',
  '2','Stock transfer creates paired movements'
);
set constraints all immediate;
select is(
  (select count(*) from public.stock_movements where stock_transfer_id=
    (select id from public.stock_transfers where request_id='50000000-0000-4000-8000-000000000002')),
  2::bigint,'Transfer has exactly two stock movements'
);

select is(
  public.owner_start_production_job('99999999-9999-4999-8999-999999999999','vinyl_cut','{}'::jsonb,
    '50000000-0000-4000-8000-000000000003')->>'status',
  'planned','Value-added order line starts its production job'
);

select is(
  (public.owner_issue_job_material(
    (select id from public.production_jobs where order_item_id='99999999-9999-4999-8999-999999999999'),
    'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee','dddddddd-dddd-4ddd-8ddd-dddddddddddd',
    3,'Vinyl issued to job','50000000-0000-4000-8000-000000000004')->>'extended_cost')::bigint,
  150::bigint,'Material issue snapshots weighted-average cost'
);

select is(
  (public.owner_record_job_waste(
    (select id from public.production_jobs where order_item_id='99999999-9999-4999-8999-999999999999'),
    (select id from public.production_material_issues where job_id=(select id from public.production_jobs where order_item_id='99999999-9999-4999-8999-999999999999')),
    0.5,'test_print','Test cut waste','50000000-0000-4000-8000-000000000005')->>'stock_deducted_again')::boolean,
  false,'Waste classifies issued material without a second stock deduction'
);

select is(
  (public.owner_return_job_offcut(
    (select id from public.production_jobs where order_item_id='99999999-9999-4999-8999-999999999999'),
    (select id from public.production_material_issues where job_id=(select id from public.production_jobs where order_item_id='99999999-9999-4999-8999-999999999999')),
    'dddddddd-dddd-4ddd-8ddd-dddddddddddd',0.5,'50000000-0000-4000-8000-000000000006')->>'cost_credit')::bigint,
  25::bigint,'Reusable offcut creates a return movement and credits original issue cost'
);

select throws_ok(
  $$select public.owner_record_job_waste(
    (select id from public.production_jobs where order_item_id='99999999-9999-4999-8999-999999999999'),
    (select id from public.production_material_issues where job_id=(select id from public.production_jobs where order_item_id='99999999-9999-4999-8999-999999999999')),
    3,'scrap','Too much waste','50000000-0000-4000-8000-000000000007')$$,
  '22023',null,'Waste plus offcuts cannot exceed the issued quantity'
);

select is(
  public.owner_record_quality_check(
    (select id from public.production_jobs where order_item_id='99999999-9999-4999-8999-999999999999'),
    'fail','self','11111111-1111-4111-8111-111111111111','First inspection failed',
    '50000000-0000-4000-8000-000000000008')->>'result',
  'fail','Failed QC is recorded and routes the job to rework'
);

select throws_ok(
  $$select public.owner_complete_production_job(
    (select id from public.production_jobs where order_item_id='99999999-9999-4999-8999-999999999999'),
    '50000000-0000-4000-8000-000000000009')$$,
  '22023',null,'Job cannot complete without a latest passing QC'
);

select is(
  public.owner_open_rework_event(
    (select id from public.production_jobs where order_item_id='99999999-9999-4999-8999-999999999999'),
    (select id from public.quality_checks where job_id=(select id from public.production_jobs where order_item_id='99999999-9999-4999-8999-999999999999') and result='fail'),
    'Correct vinyl alignment','50000000-0000-4000-8000-000000000010')->>'status',
  'open','Failed QC creates a linked rework event'
);

select is(
  public.owner_close_rework_event(
    (select id from public.rework_events where job_id=(select id from public.production_jobs where order_item_id='99999999-9999-4999-8999-999999999999')),
    'Alignment corrected','50000000-0000-4000-8000-000000000011')->>'status',
  'closed','Rework is explicitly closed'
);

select is(
  (public.owner_add_production_cost(
    (select id from public.production_jobs where order_item_id='99999999-9999-4999-8999-999999999999'),
    'labour','Finishing labour',1,'hour',20,'50000000-0000-4000-8000-000000000012')->>'amount')::bigint,
  20::bigint,'Actual labour cost is recorded'
);

select is(
  public.owner_record_quality_check(
    (select id from public.production_jobs where order_item_id='99999999-9999-4999-8999-999999999999'),
    'pass','self','11111111-1111-4111-8111-111111111111','Rework passed',
    '50000000-0000-4000-8000-000000000013')->>'result',
  'pass','Subsequent QC pass closes the quality path'
);

select is(
  (public.owner_complete_production_job(
    (select id from public.production_jobs where order_item_id='99999999-9999-4999-8999-999999999999'),
    '50000000-0000-4000-8000-000000000014')->>'actual_cost_total')::bigint,
  145::bigint,'Completed job cost deducts reusable offcut credit once'
);

select throws_ok(
  $$select public.owner_handover_order('cccccccc-cccc-4ccc-8ccc-cccccccccccc','collection','Customer',null,null,
    '60000000-0000-4000-8000-000000000001')$$,
  '22023',null,'Handover is blocked while an order balance remains'
);

select is(
  public.owner_handover_order('cccccccc-cccc-4ccc-8ccc-cccccccccccc','collection','Customer',null,'Owner approved exception',
    '60000000-0000-4000-8000-000000000002')->>'status',
  'completed','Owner exception is audited and handover completes'
);

select is(
  (select coalesce(sum(quantity),0) from public.stock_movements
   where stock_item_id='eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee' and location_id='dddddddd-dddd-4ddd-8ddd-dddddddddddd'),
  5.5::numeric,'Physical on-hand includes transfer out, issue and one offcut return'
);

select is(
  (select coalesce(sum(quantity),0) from public.stock_movements
   where stock_item_id='eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee' and location_id='ffffffff-ffff-4fff-8fff-ffffffffffff'),
  2::numeric,'Destination transfer quantity is recorded once'
);

select set_config('request.jwt.claim.sub','22222222-2222-4222-8222-222222222222',true);
select throws_ok(
  $$select public.owner_get_order_balance('cccccccc-cccc-4ccc-8ccc-cccccccccccc')$$,
  '42501',null,'Authenticated non-owner cannot read order balance or call owner RPCs'
);
reset role;
select * from finish();
rollback;
