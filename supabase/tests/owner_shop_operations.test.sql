begin;
create extension if not exists pgtap with schema extensions;
select plan(20);

insert into auth.users(id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
values('33333333-3333-4333-8333-333333333333','authenticated','authenticated','mj-ops-owner@example.invalid','',now(),
 '{"provider":"email","providers":["email"]}'::jsonb,'{}'::jsonb,now(),now());
insert into public.businesses(id,name,slug) values('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','MJ Operations Test','mj-ops-test');
insert into public.business_memberships(business_id,user_id,role,status)
values('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','33333333-3333-4333-8333-333333333333','owner','active');
insert into public.user_profiles(user_id) values('33333333-3333-4333-8333-333333333333');
insert into public.inventory_locations(id,business_id,name,code)
values('dddddddd-dddd-4ddd-8ddd-dddddddddddd','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','Main stock','MAIN');
insert into public.customers(id,business_id,display_name,created_by)
values('cccccccc-cccc-4ccc-8ccc-cccccccccccc','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','Ops Customer','33333333-3333-4333-8333-333333333333');
insert into public.orders(id,business_id,order_number,customer_id,status,subtotal_amount,discount_amount,total_amount,created_by)
values('eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','OPS-ORDER-1',
 'cccccccc-cccc-4ccc-8ccc-cccccccccccc','confirmed',300,0,300,'33333333-3333-4333-8333-333333333333');
set local role authenticated;
select set_config('request.jwt.claim.sub','33333333-3333-4333-8333-333333333333',true);

select is(
  (public.owner_upsert_supplier('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',null,'Test Supplier',null,'0711111111',null,null,
    '80000000-0000-4000-8000-000000000001')->>'created')::boolean,
  true,'Owner can create a supplier'
);

select is(
  (public.owner_upsert_stock_item('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',null,null,'BLANK-TEE-M','Blank T-shirt Medium',
    'blank_product','piece','box',10,null,null,'{"size":"M","colour":"black"}'::jsonb,2,
    null,'80000000-0000-4000-8000-000000000002')->>'created')::boolean,
  true,'Owner can create a variant-specific stock SKU'
);

reset role;
insert into public.order_items(id,business_id,order_id,description,quantity,unit,unit_price,line_discount,line_total,
  sale_mode,customer_supplies_item,stock_item_id)
values('ffffffff-ffff-4fff-8fff-ffffffffffff','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee','Blank T-shirt Medium',3,'piece',100,0,300,'blank',false,
 (select id from public.stock_items where business_id='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb' and sku='BLANK-TEE-M'));

set local role authenticated;

select is(
  public.owner_create_purchase_order('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
    (select id from public.suppliers where business_id='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb' and display_name='Test Supplier'),
    jsonb_build_array(jsonb_build_object('stock_item_id',(select id from public.stock_items where business_id='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb' and sku='BLANK-TEE-M'),
      'ordered_quantity',5,'unit_price',100)),
    'Initial blank T-shirt purchase','80000000-0000-4000-8000-000000000003')->>'status',
  'draft','Purchase order is created as a draft'
);

select is(
  public.owner_update_purchase_order_status(
    (select id from public.purchase_orders where business_id='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'),
    'ordered','Purchase order sent to supplier','80000000-0000-4000-8000-000000000004')->>'status',
  'ordered','Purchase order can be formally ordered'
);

select is(
  public.owner_receive_purchase('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
    (select id from public.suppliers where business_id='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb' and display_name='Test Supplier'),
    (select id from public.purchase_orders where business_id='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'),
    now(),jsonb_build_array(jsonb_build_object(
      'purchase_order_item_id',(select id from public.purchase_order_items where business_id='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'),
      'location_id','dddddddd-dddd-4ddd-8ddd-dddddddddddd','accepted_quantity',5,'rejected_quantity',0,'actual_unit_cost',100)),
    '80000000-0000-4000-8000-000000000005')->>'status',
  'received','Goods receipt completes the purchase order'
);

select is(
  (select current_average_unit_cost from public.stock_items where business_id='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb' and sku='BLANK-TEE-M'),
  10::bigint,'Weighted-average cost converts box cost into base-unit cost'
);

select is(
  (select coalesce(sum(quantity),0) from public.stock_movements
    where business_id='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
      and stock_item_id=(select id from public.stock_items where business_id='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb' and sku='BLANK-TEE-M')),
  50::numeric,'Accepted purchase quantity enters stock in base units'
);


select is(
  (public.owner_reserve_order_stock('eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',
    '80000000-0000-4000-8000-000000000006')->>'reserved_quantity')::numeric,
  3::numeric,'Order stock reservation holds the required variant quantity'
);

select is(
  public.owner_mark_order_ready('eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee','No production work required','80000000-0000-4000-8000-000000000014')->>'status',
  'ready','Owner can mark an order with no production work ready for handover'
);

select is(
  (public.owner_record_delivery('eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee','collection',null,null,80,'Customer',
    '80000000-0000-4000-8000-000000000007')->>'customer_paid_charge')::bigint,
  80::bigint,'Delivery charge is recorded separately as a customer-paid pass-through'
);

select is(
  public.owner_handover_order('eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee','collection','Customer',null,'Owner approved unpaid balance',
    '80000000-0000-4000-8000-000000000008')->>'status',
  'completed','Handover consumes reserved blank stock and records owner payment exception'
);

select is(
  (select count(*) from public.deliveries where business_id='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
    and order_id='eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee'),
  1::bigint,'Handover reuses the prepared delivery rather than creating a duplicate'
);

select is(
  (select coalesce(sum(quantity),0) from public.stock_movements
    where business_id='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
      and stock_item_id=(select id from public.stock_items where business_id='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb' and sku='BLANK-TEE-M')),
  47::numeric,'Blank stock is deducted exactly once at handover'
);

select is(
  (public.owner_upsert_expense_category('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',null,'Utilities',true,
    '80000000-0000-4000-8000-000000000009')->>'created')::boolean,
  true,'Owner can create an expense category'
);

select is(
  (public.owner_record_expense('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
    (select id from public.expense_categories where business_id='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb' and name='Utilities'),
    125,current_date,'Electricity','mpesa',null,'Shop power','80000000-0000-4000-8000-000000000010')->>'amount')::bigint,
  125::bigint,'Owner can record an operating expense'
);

reset role;
insert into public.enquiries(business_id,public_reference,contact_name,phone,requested_service,description)
values('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','ENQ-OPS-001','Prospect','0712222222','Vinyl branding','Need ten shirts');
set local role authenticated;

select is(
  public.owner_update_enquiry_status((select id from public.enquiries where public_reference='ENQ-OPS-001'),
    'reviewing','Owner is reviewing the request','80000000-0000-4000-8000-000000000011')->>'status',
  'reviewing','Owner can triage a public enquiry'
);

-- Value-added orders also consume an MJ Tees blank garment SKU.
reset role;
insert into public.orders(id,business_id,order_number,customer_id,status,subtotal_amount,discount_amount,total_amount,created_by)
values('11111111-1111-4111-8111-111111111111','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','OPS-ORDER-2',
 'cccccccc-cccc-4ccc-8ccc-cccccccccccc','confirmed',200,0,200,'33333333-3333-4333-8333-333333333333');
insert into public.order_items(id,business_id,order_id,description,quantity,unit,unit_price,line_discount,line_total,
  sale_mode,customer_supplies_item,stock_item_id)
values('22222222-2222-4222-8222-222222222222','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
 '11111111-1111-4111-8111-111111111111','Branded T-shirt Medium',2,'piece',100,0,200,'value_added',false,
 (select id from public.stock_items where business_id='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb' and sku='BLANK-TEE-M'));
set local role authenticated;
select is(
  (public.owner_reserve_order_stock('11111111-1111-4111-8111-111111111111',
    '80000000-0000-4000-8000-000000000012')->>'reserved_quantity')::numeric,
  2::numeric,'Value-added order reserves the required blank garment stock'
);
select is(
  public.owner_mark_order_ready('11111111-1111-4111-8111-111111111111','No production method assigned to this value-added item','80000000-0000-4000-8000-000000000015')->>'status',
  'ready','Owner can mark an order ready when no production method is configured'
);
select is(
  public.owner_handover_order('11111111-1111-4111-8111-111111111111','collection','Customer',null,'Owner approved unpaid balance',
    '80000000-0000-4000-8000-000000000013')->>'status',
  'completed','Value-added order can hand over after consuming its reserved blank garment'
);
select is(
  (select coalesce(sum(quantity),0) from public.stock_movements
    where business_id='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
      and stock_item_id=(select id from public.stock_items where business_id='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb' and sku='BLANK-TEE-M')),
  45::numeric,'Value-added handover deducts blank garment stock exactly once'
);

select * from finish();
rollback;
