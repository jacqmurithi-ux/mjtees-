begin;
create extension if not exists pgtap with schema extensions;
select plan(11);

insert into auth.users(id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
values('55555555-5555-4555-8555-555555555555','authenticated','authenticated','mj-discount-owner@example.invalid','',now(),
 '{"provider":"email","providers":["email"]}'::jsonb,'{}'::jsonb,now(),now());
insert into public.businesses(id,name,slug) values('aaaaaaaa-2222-4222-8222-aaaaaaaaaaaa','Discount Test Business','discount-test');
insert into public.business_memberships(business_id,user_id,role,status)
values('aaaaaaaa-2222-4222-8222-aaaaaaaaaaaa','55555555-5555-4555-8555-555555555555','owner','active');
insert into public.user_profiles(user_id) values('55555555-5555-4555-8555-555555555555');
insert into public.service_categories(id,business_id,name,slug)
values('bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb','aaaaaaaa-2222-4222-8222-aaaaaaaaaaaa','Apparel','apparel');
insert into public.catalogue_items(id,business_id,category_id,name,slug,item_type,is_published)
values('cccccccc-2222-4222-8222-cccccccccccc','aaaaaaaa-2222-4222-8222-aaaaaaaaaaaa',
 'bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb','Custom Printed T-shirt','custom-printed-tshirt','product',true);
insert into public.stock_items(id,business_id,sku,name,stock_kind,base_unit,purchase_unit,purchase_to_base_factor,current_average_unit_cost)
values('dddddddd-2222-4222-8222-dddddddddddd','aaaaaaaa-2222-4222-8222-aaaaaaaaaaaa',
 'TEE-M','Blank T-shirt Medium','blank_product','piece','piece',1,100);
insert into public.customers(id,business_id,display_name,created_by)
values('ffffffff-2222-4222-8222-ffffffffffff','aaaaaaaa-2222-4222-8222-aaaaaaaaaaaa',
 'Discount Customer','55555555-5555-4555-8555-555555555555');

set local role authenticated;
select set_config('request.jwt.claim.sub','55555555-5555-4555-8555-555555555555',true);

select is(
  (public.owner_create_costing_profile('aaaaaaaa-2222-4222-8222-aaaaaaaaaaaa',
    'cccccccc-2222-4222-8222-cccccccccccc','bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb','value_added',
    (select id from public.production_methods where code='vinyl_cut'),
    jsonb_build_array(jsonb_build_object('component_type','blank_item','stock_item_id','dddddddd-2222-4222-8222-dddddddddddd',
      'unit','piece','driver_type','per_piece','factor',1,'expected_waste_percent',0,'fixed_cost',0)),
    '91000000-0000-4000-8000-000000000001')->>'version')::integer,
  1,'Create the versioned blank-garment costing profile'
);

select ok(
  (public.owner_upsert_pricing_rule('aaaaaaaa-2222-4222-8222-aaaaaaaaaaaa',null,
    'bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb',null,'Apparel 100 percent markup',
    'percentage_on_cost',100,current_date,null,true,'91000000-0000-4000-8000-000000000002')->>'pricing_rule_id') is not null,
  'Create category pricing rule'
);

select is(
  (public.owner_create_quotation_with_discount('aaaaaaaa-2222-4222-8222-aaaaaaaaaaaa',
    'ffffffff-2222-4222-8222-ffffffffffff',null,
    jsonb_build_array(
      jsonb_build_object('catalogue_item_id','cccccccc-2222-4222-8222-cccccccccccc','stock_item_id','dddddddd-2222-4222-8222-dddddddddddd',
        'description','T-shirt 1','quantity',1,'unit','piece','line_discount',0,'sale_mode','value_added',
        'customer_supplies_item',false,'production_method_id',(select id from public.production_methods where code='vinyl_cut'),
        'production_specification','{}'::jsonb),
      jsonb_build_object('catalogue_item_id','cccccccc-2222-4222-8222-cccccccccccc','stock_item_id','dddddddd-2222-4222-8222-dddddddddddd',
        'description','T-shirt 2','quantity',1,'unit','piece','line_discount',0,'sale_mode','value_added',
        'customer_supplies_item',false,'production_method_id',(select id from public.production_methods where code='vinyl_cut'),
        'production_specification','{}'::jsonb),
      jsonb_build_object('catalogue_item_id','cccccccc-2222-4222-8222-cccccccccccc','stock_item_id','dddddddd-2222-4222-8222-dddddddddddd',
        'description','T-shirt 3','quantity',1,'unit','piece','line_discount',0,'sale_mode','value_added',
        'customer_supplies_item',false,'production_method_id',(select id from public.production_methods where code='vinyl_cut'),
        'production_specification','{}'::jsonb)
    ),10,now()+interval '14 days','Customer quote','Internal notes',
    '91000000-0000-4000-8000-000000000003')->>'total_amount')::bigint,
  590::bigint,'Quote applies a KES 10 order discount after line pricing'
);

select set_config('mj.test.discount_quote_id',
  (select id::text from public.quotations where business_id='aaaaaaaa-2222-4222-8222-aaaaaaaaaaaa'),true);

select set_config('mj.test.discount_quote_token',
  public.owner_send_quotation(current_setting('mj.test.discount_quote_id')::uuid,now()+interval '14 days',
    '91000000-0000-4000-8000-000000000004')->>'acceptance_token',true);

reset role;
set local role anon;

select is(
  public.accept_quotation(current_setting('mj.test.discount_quote_token'),'91000000-0000-4000-8000-000000000005')->>'total_amount',
  '590','Public acceptance creates order with order-level discount applied'
);

select set_config('mj.test.discount_order_number',
  public.accept_quotation(current_setting('mj.test.discount_quote_token'),'91000000-0000-4000-8000-000000000005')->>'order_number',true);

reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub','55555555-5555-4555-8555-555555555555',true);

select is(
  (select discount_amount from public.quotations where id=current_setting('mj.test.discount_quote_id')::uuid),
  10::bigint,'Quotation header records order-level discount separately from line discounts'
);

select is(
  (select array_agg(order_discount_allocated order by line_sequence) from public.order_items
   where order_id=(select id from public.orders where order_number=current_setting('mj.test.discount_order_number'))),
  array[4,3,3]::bigint[],'Largest-remainder allocation breaks equal remainders by stable line sequence'
);

select is(
  (select array_agg(line_total order by line_sequence) from public.order_items
   where order_id=(select id from public.orders where order_number=current_setting('mj.test.discount_order_number'))),
  array[196,197,197]::bigint[],'Order line totals include their allocated order discount'
);

select is(
  (select sum(allocated_discount_amount)::bigint from public.order_item_discount_allocations
   where order_id=(select id from public.orders where order_number=current_setting('mj.test.discount_order_number'))),
  10::bigint,'Immutable discount allocation rows reconcile exactly to the order discount'
);

select is(
  (public.owner_get_order_balance((select id from public.orders where order_number=current_setting('mj.test.discount_order_number')))->>'balance_due')::bigint,
  590::bigint,'Order balance matches the discounted total'
);

select is(
  public.owner_create_direct_order('aaaaaaaa-2222-4222-8222-aaaaaaaaaaaa','ffffffff-2222-4222-8222-ffffffffffff',null,
    jsonb_build_array(jsonb_build_object('catalogue_item_id','cccccccc-2222-4222-8222-cccccccccccc',
      'stock_item_id','dddddddd-2222-4222-8222-dddddddddddd','description','Walk-in T-shirt','quantity',1,'unit','piece',
      'line_discount',0,'sale_mode','value_added','customer_supplies_item',false,
      'production_method_id',(select id from public.production_methods where code='vinyl_cut'),'production_specification','{}'::jsonb)),
    0,'Walk-in order','Created directly by owner','91000000-0000-4000-8000-000000000006')->>'status',
  'confirmed','Owner can create a direct order without sending a customer acceptance link'
);

select is(
  (select count(*) from public.orders where business_id='aaaaaaaa-2222-4222-8222-aaaaaaaaaaaa'),
  2::bigint,'Direct order and accepted quotation each create exactly one order'
);

select * from finish();
rollback;
