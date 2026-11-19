begin;
create extension if not exists pgtap with schema extensions;
select plan(46);

insert into auth.users(id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
values
('11111111-1111-4111-8111-111111111111','authenticated','authenticated','sales-owner@example.invalid','',now(),
 '{"provider":"email","providers":["email"]}'::jsonb,'{}'::jsonb,now(),now()),
('22222222-2222-4222-8222-222222222222','authenticated','authenticated','sales-outsider@example.invalid','',now(),
 '{"provider":"email","providers":["email"]}'::jsonb,'{}'::jsonb,now(),now());

insert into public.businesses(id,name)
values('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','MJ Sales Test');
insert into public.business_memberships(business_id,user_id,role,status)
values('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','11111111-1111-4111-8111-111111111111','owner','active');
insert into public.customers(id,business_id,display_name,created_by)
values('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  'Sales Test Customer','11111111-1111-4111-8111-111111111111');
insert into public.inventory_locations(id,business_id,name,code)
values('dddddddd-dddd-4ddd-8ddd-dddddddddddd','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','Shop One','SHOP1');
insert into public.stock_items(
  id,business_id,sku,name,stock_kind,base_unit,purchase_unit,purchase_to_base_factor,
  current_average_unit_cost,reorder_level
) values (
  'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  'TSHIRT-BLK-M','Black T-shirt M','blank_product','piece','piece',1,80,1
);
insert into public.stock_movements(
  business_id,stock_item_id,location_id,movement_type,quantity,unit_cost_snapshot,
  source_type,source_id,reason,actor_user_id,request_id
) values (
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',
  'dddddddd-dddd-4ddd-8ddd-dddddddddddd','opening',5,80,'owner_adjustment',null,
  'Test opening balance','11111111-1111-4111-8111-111111111111',
  '90000000-0000-4000-8000-000000000001'
);

insert into public.quotations(
  id,business_id,quote_number,customer_id,status,issued_at,accepted_at,
  subtotal_amount,discount_amount,total_amount,deposit_required_amount,created_by
) values (
  'a1000000-0000-4000-8000-000000000001','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  'QT-SALES-001','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','accepted',now(),now(),
  600,0,600,200,'11111111-1111-4111-8111-111111111111'
);
insert into public.orders(
  id,business_id,order_number,customer_id,quotation_id,status,subtotal_amount,discount_amount,total_amount,created_by
) values (
  'c1000000-0000-4000-8000-000000000001','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  'ORD-SALES-001','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
  'a1000000-0000-4000-8000-000000000001','confirmed',600,0,600,
  '11111111-1111-4111-8111-111111111111'
);
insert into public.order_items(
  id,business_id,order_id,description,quantity,unit,unit_price,line_discount,line_total,
  stock_item_id,customer_supplies_item,sale_mode,production_specification
) values (
  '91000000-0000-4000-8000-000000000001','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  'c1000000-0000-4000-8000-000000000001','Black T-shirt M',3,'piece',200,0,600,
  'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',false,'blank','{"variant_snapshot":{"size":"M","colour":"Black"}}'::jsonb
);

insert into public.quotations(
  id,business_id,quote_number,customer_id,status,issued_at,accepted_at,
  subtotal_amount,discount_amount,total_amount,created_by
) values (
  'a2000000-0000-4000-8000-000000000002','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  'QT-SALES-002','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','accepted',now(),now(),
  400,0,400,'11111111-1111-4111-8111-111111111111'
);
insert into public.orders(
  id,business_id,order_number,customer_id,quotation_id,status,subtotal_amount,discount_amount,total_amount,created_by
) values (
  'c2000000-0000-4000-8000-000000000002','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  'ORD-SALES-002','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
  'a2000000-0000-4000-8000-000000000002','confirmed',400,0,400,
  '11111111-1111-4111-8111-111111111111'
);
insert into public.order_items(
  id,business_id,order_id,description,quantity,unit,unit_price,line_discount,line_total,
  stock_item_id,customer_supplies_item,sale_mode
) values (
  '92000000-0000-4000-8000-000000000002','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  'c2000000-0000-4000-8000-000000000002','Black T-shirt M',4,'piece',100,0,400,
  'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',false,'blank'
);

insert into public.quotations(
  id,business_id,quote_number,customer_id,status,issued_at,accepted_at,
  subtotal_amount,discount_amount,total_amount,created_by
) values (
  'a3000000-0000-4000-8000-000000000003','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  'QT-SALES-003','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','accepted',now(),now(),
  100,0,100,'11111111-1111-4111-8111-111111111111'
);
insert into public.orders(
  id,business_id,order_number,customer_id,quotation_id,status,subtotal_amount,discount_amount,total_amount,created_by
) values (
  'c3000000-0000-4000-8000-000000000003','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  'ORD-SALES-003','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
  'a3000000-0000-4000-8000-000000000003','confirmed',100,0,100,
  '11111111-1111-4111-8111-111111111111'
);
insert into public.order_items(
  id,business_id,order_id,description,quantity,unit,unit_price,line_discount,line_total,
  customer_supplies_item,sale_mode
) values (
  '93000000-0000-4000-8000-000000000003','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  'c3000000-0000-4000-8000-000000000003','Customer supplied polo',1,'piece',100,0,100,
  true,'blank'
);

-- Simulate legacy receiving accounts that predate the Cash/M-Pesa-only policy.
-- The test temporarily disables only the new-account guard while seeding fixtures.
alter table public.sales_payment_accounts disable trigger sales_payment_accounts_new_method_guard;
insert into public.sales_payment_accounts(
  id,business_id,account_name,account_type,account_reference,bank_name,created_by
) values
('d1000000-0000-4000-8000-000000000001','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
 'Legacy Main Bank','bank','Account ending 4567','Test Bank','11111111-1111-4111-8111-111111111111'),
('d1000000-0000-4000-8000-000000000002','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
 'Legacy Cheque Clearing','cheque_clearing',null,null,'11111111-1111-4111-8111-111111111111');
alter table public.sales_payment_accounts enable trigger sales_payment_accounts_new_method_guard;

set local role authenticated;
select set_config('request.jwt.claim.sub','11111111-1111-4111-8111-111111111111',true);
select is(
  (select count(*) from public.sales_payment_accounts
   where business_id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
     and account_type in ('bank','cheque_clearing')),
  2::bigint,'Legacy bank and cheque receiving accounts remain preserved for history');

select is(
  (select count(*) from public.sales_price_tiers where business_id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'),
  3::bigint,'New businesses receive retail, wholesale and reseller price tiers'
);

select is(
  public.owner_convert_accepted_quote_to_invoice(
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','a1000000-0000-4000-8000-000000000001',
    'net_7',null,'dddddddd-dddd-4ddd-8ddd-dddddddddddd',false,null,
    '70000000-0000-4000-8000-000000000001'
  )->>'status',
  'sent','Owner converts an accepted quotation into an issued invoice'
);

select is(
  (select invoice_number from public.sales_invoices where quotation_id='a1000000-0000-4000-8000-000000000001'),
  'INV-0001','Invoice number is generated atomically using the INV sequence'
);

select is(
  (select due_date from public.sales_invoices where quotation_id='a1000000-0000-4000-8000-000000000001'),
  current_date+7,'Net 7 payment terms calculate the due date'
);

select is(
  (select status from public.quotations where id='a1000000-0000-4000-8000-000000000001'),
  'converted','Accepted quotation is marked converted after invoice issue'
);

select is(
  (select deposit_required_amount from public.sales_invoices where quotation_id='a1000000-0000-4000-8000-000000000001'),
  200::bigint,'Required deposit is carried from the accepted quotation'
);

select is(
  (select spt.code from public.sales_price_tiers spt where spt.id=(
    select sales_price_tier_id from public.sales_invoices where quotation_id='a1000000-0000-4000-8000-000000000001'
  )),
  'retail','Invoice snapshots the default retail price tier'
);

select is(
  (select count(*) from public.sales_invoice_items where invoice_id=(
    select id from public.sales_invoices where quotation_id='a1000000-0000-4000-8000-000000000001'
  )),
  1::bigint,'Invoice lines snapshot the accepted order lines'
);

select is(
  (select quantity from public.sales_invoice_stock_issues where invoice_id=(
    select id from public.sales_invoices where quotation_id='a1000000-0000-4000-8000-000000000001'
  )),
  3::numeric,'Shop stock issue records the sold variant quantity'
);

select is(
  (select sum(quantity) from public.stock_movements
   where business_id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
     and stock_item_id='eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee'
     and location_id='dddddddd-dddd-4ddd-8ddd-dddddddddddd'),
  2::numeric,'Invoice issue deducts sold stock from on-hand quantity'
);

select is(
  public.owner_convert_accepted_quote_to_invoice(
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','a1000000-0000-4000-8000-000000000001',
    'net_7',null,'dddddddd-dddd-4ddd-8ddd-dddddddddddd',false,null,
    '70000000-0000-4000-8000-000000000001'
  )->>'invoice_number',
  'INV-0001','Retry with the same request id returns the original invoice'
);

select is(
  (select count(*) from public.sales_invoice_stock_issues),
  1::bigint,'Idempotent retry does not duplicate stock issues'
);

select throws_ok(
  $pt$select public.owner_convert_accepted_quote_to_invoice(
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','a2000000-0000-4000-8000-000000000002',
    'due_on_receipt',null,'dddddddd-dddd-4ddd-8ddd-dddddddddddd',false,null,
    '70000000-0000-4000-8000-000000000002'
  )$pt$,
  '22023',null,'Insufficient stock blocks invoice issue without explicit owner override'
);

select is(
  public.owner_convert_accepted_quote_to_invoice(
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','a2000000-0000-4000-8000-000000000002',
    'due_on_receipt',null,'dddddddd-dddd-4ddd-8ddd-dddddddddddd',true,
    'Owner confirmed supplier replenishment before collection',
    '70000000-0000-4000-8000-000000000003'
  )->>'status',
  'sent','Owner may explicitly confirm an oversell with a recorded reason'
);

select is(
  jsonb_array_length(public.owner_convert_accepted_quote_to_invoice(
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','a2000000-0000-4000-8000-000000000002',
    'due_on_receipt',null,'dddddddd-dddd-4ddd-8ddd-dddddddddddd',true,
    'Owner confirmed supplier replenishment before collection',
    '70000000-0000-4000-8000-000000000003'
  )->'low_stock_items'),
  1,'Oversell response flags stock at or below its reorder level'
);

select is(
  (select count(*) from public.sales_invoice_stock_issues),
  2::bigint,'Confirmed oversell is still recorded as an auditable stock issue'
);

select is(
  public.owner_convert_accepted_quote_to_invoice(
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','a3000000-0000-4000-8000-000000000003',
    'due_on_receipt',null,null,false,null,
    '70000000-0000-4000-8000-000000000004'
  )->>'status',
  'sent','Customer-supplied garments can be invoiced without a shop stock location'
);

select is(
  (select count(*) from public.sales_invoice_stock_issues),
  2::bigint,'Customer-supplied garments do not reduce shop inventory'
);


-- Configure receiving accounts. All payment channels are entered manually.
select is((public.owner_upsert_sales_payment_account(
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',null,'Shop Cash Drawer','cash',null,null,true,
  '71000000-0000-4000-8000-000000000001')->>'created')::boolean,
  true,'Owner can create a cash receiving account');
select is((public.owner_upsert_sales_payment_account(
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',null,'M-Pesa Paybill','mpesa_paybill','Paybill 123456',null,true,
  '71000000-0000-4000-8000-000000000002')->>'created')::boolean,
  true,'Owner can create a manual M-Pesa Paybill receiving account');
select throws_ok(
  $pt$select public.owner_upsert_sales_payment_account(
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',null,'New Bank','bank','Account ending 4567','Test Bank',true,
    '71000000-0000-4000-8000-000000000003')$pt$,
  '22023',null,'New bank receiving accounts are blocked');
select throws_ok(
  $pt$select public.owner_upsert_sales_payment_account(
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',null,'New Cheque','cheque_clearing',null,null,true,
    '71000000-0000-4000-8000-000000000004')$pt$,
  '22023',null,'New cheque-clearing accounts are blocked');

-- One manually entered cash payment can be split across invoices; excess is
-- retained as customer credit and the invoices remain partially paid.
select is((public.owner_record_sales_payment(
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
  (select id from public.sales_payment_accounts where business_id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' and account_name='Shop Cash Drawer'),
  'cash',500,now()-interval '30 minutes',null,
  jsonb_build_array(
    jsonb_build_object('invoice_id',(select id from public.sales_invoices where quotation_id='a1000000-0000-4000-8000-000000000001'),'amount',200),
    jsonb_build_object('invoice_id',(select id from public.sales_invoices where quotation_id='a2000000-0000-4000-8000-000000000002'),'amount',100)
  ),'Manual cash receipt','72000000-0000-4000-8000-000000000001')->>'status'),
  'posted','Cash payment is posted immediately without an online verification step');

select is((select status from public.payments where idempotency_key='72000000-0000-4000-8000-000000000001'),
  'posted','Manually recorded cash is stored as a posted payment');
select is((select count(*) from public.sales_invoice_payment_allocations
  where request_id='72000000-0000-4000-8000-000000000001'),2::bigint,
  'A single payment request can allocate to two invoices');
select is((select status from public.sales_invoices where quotation_id='a1000000-0000-4000-8000-000000000001'),
  'partially_paid','First invoice balance changes after partial allocation');
select is((select status from public.sales_invoices where quotation_id='a2000000-0000-4000-8000-000000000002'),
  'partially_paid','Second invoice balance changes after partial allocation');
select is((select sum(amount) from public.sales_customer_credit_entries
  where payment_id=(select id from public.payments where idempotency_key='72000000-0000-4000-8000-000000000001')),
  200::numeric,'Payment excess is posted to the customer credit ledger');

select is((public.owner_record_sales_payment(
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
  (select id from public.sales_payment_accounts where business_id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' and account_name='Shop Cash Drawer'),
  'cash',500,now()-interval '30 minutes',null,
  jsonb_build_array(
    jsonb_build_object('invoice_id',(select id from public.sales_invoices where quotation_id='a1000000-0000-4000-8000-000000000001'),'amount',200),
    jsonb_build_object('invoice_id',(select id from public.sales_invoices where quotation_id='a2000000-0000-4000-8000-000000000002'),'amount',100)
  ),'Manual cash receipt','72000000-0000-4000-8000-000000000001')->>'payment_id'),
  (select id::text from public.payments where idempotency_key='72000000-0000-4000-8000-000000000001'),
  'Retrying the same payment request returns the original payment');

-- M-Pesa Paybill is also a manual owner entry and is posted immediately.
select is((public.owner_record_sales_payment(
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
  (select id from public.sales_payment_accounts where business_id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' and account_name='M-Pesa Paybill'),
  'mpesa_manual',100,now()-interval '20 minutes','ABC123456',
  jsonb_build_array(jsonb_build_object('invoice_id',(select id from public.sales_invoices where quotation_id='a3000000-0000-4000-8000-000000000003'),'amount',100)),
  'Manually checked Paybill receipt','72000000-0000-4000-8000-000000000002')->>'status'),
  'posted','Manual Paybill entry posts immediately without pending verification');
select is((select status from public.payments where idempotency_key='72000000-0000-4000-8000-000000000002'),
  'posted','M-Pesa Paybill payment is not left pending verification');

select is((public.owner_record_sales_payment(
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
  (select id from public.sales_payment_accounts where business_id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' and account_name='M-Pesa Paybill'),
  'mpesa_manual',50,now()-interval '10 minutes','ABC123456','[]'::jsonb,
  'Duplicate reference test','72000000-0000-4000-8000-000000000003')->>'duplicate_reference_warning')::boolean,
  true,'Duplicate Paybill references are flagged for owner review');

select is((select duplicate_reference_warning from public.payments
  where idempotency_key='72000000-0000-4000-8000-000000000003'),
  true,'Duplicate reference warning is stored on the payment record');

select is((public.owner_reconcile_sales_payment(
  (select id from public.payments where idempotency_key='72000000-0000-4000-8000-000000000001'),
  current_date,null,'Matched to the physical cash record','72000000-0000-4000-8000-000000000004')->>'reconciliation_status'),
  'reconciled','Owner can manually reconcile a recorded payment');
select is((select count(*) from public.sales_payment_reconciliations
  where payment_id=(select id from public.payments where idempotency_key='72000000-0000-4000-8000-000000000001')),
  1::bigint,'Manual reconciliation is retained as an auditable record');

select throws_ok(
  $pt$select public.owner_record_sales_payment(
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
    'd1000000-0000-4000-8000-000000000001',
    'bank_transfer',50,now()-interval '5 minutes','BANK-REF-001','[]'::jsonb,
    'Legacy bank payment attempt','72000000-0000-4000-8000-000000000005'
  )$pt$,
  '22023',null,'Legacy bank accounts remain readable but cannot receive new payments');
select is((select count(*) from public.payments where idempotency_key='72000000-0000-4000-8000-000000000005'),
  0::bigint,'Rejected bank payment does not create a payment record');

select throws_ok(
  $pt$select public.owner_record_sales_payment(
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
    'd1000000-0000-4000-8000-000000000002',
    'cheque',25,now()-interval '5 minutes','CHEQUE-001','[]'::jsonb,
    'Legacy cheque payment attempt','72000000-0000-4000-8000-000000000006'
  )$pt$,
  '22023',null,'Legacy cheque accounts remain readable but cannot receive new payments');
select is((select count(*) from public.payments where idempotency_key='72000000-0000-4000-8000-000000000006'),
  0::bigint,'Rejected cheque payment does not create a payment record');

select throws_ok(
  $pt$select public.owner_record_sales_payment(
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
    (select id from public.sales_payment_accounts where business_id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' and account_name='M-Pesa Paybill'),
    'cash',10,now(),null,'[]'::jsonb,null,'72000000-0000-4000-8000-000000000007'
  )$pt$,
  '22023',null,'Payment method must match the receiving account type'
);


-- Customer credit can be applied to an issued invoice.
select is((public.owner_apply_sales_customer_credit(
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
  (select id from public.sales_invoices where quotation_id='a1000000-0000-4000-8000-000000000001'),100,
  '73000000-0000-4000-8000-000000000001')->>'amount_applied')::bigint,
  100::bigint,'Owner can apply customer credit to an issued invoice');
select is((select sum(amount) from public.sales_customer_credit_entries
  where customer_id='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'),
  150::numeric,'Customer credit balance reflects only accepted Cash and M-Pesa entries after applying credit');
select is((select status from public.sales_invoices
  where quotation_id='a1000000-0000-4000-8000-000000000001'),
  'partially_paid','Applied customer credit updates the invoice status');


select set_config('request.jwt.claim.sub','22222222-2222-4222-8222-222222222222',true);
select throws_ok(
  $pt$select public.owner_record_sales_payment(
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
    (select id from public.sales_payment_accounts where business_id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' and account_name='Shop Cash Drawer'),
    'cash',10,now(),null,'[]'::jsonb,null,'72000000-0000-4000-8000-000000000008'
  )$pt$,
  '42501',null,'Non-owner cannot record a Sales payment'
);
select throws_ok(
  $$select public.owner_convert_accepted_quote_to_invoice(
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','a3000000-0000-4000-8000-000000000003',
    'due_on_receipt',null,null,false,null,
    '70000000-0000-4000-8000-000000000005'
  )$$,
  '42501',null,'Non-owner cannot issue a Sales invoice'
);

select * from finish();
rollback;
