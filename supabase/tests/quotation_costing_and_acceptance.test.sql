begin;
create extension if not exists pgtap with schema extensions;
select plan(11);

insert into auth.users(id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
values('44444444-4444-4444-8444-444444444444','authenticated','authenticated','mj-quote-owner@example.invalid','',now(),
 '{"provider":"email","providers":["email"]}'::jsonb,'{}'::jsonb,now(),now());
insert into public.businesses(id,name,slug) values('aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa','Quote Test Business','quote-test');
insert into public.business_memberships(business_id,user_id,role,status)
values('aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa','44444444-4444-4444-8444-444444444444','owner','active');
insert into public.user_profiles(user_id) values('44444444-4444-4444-8444-444444444444');
insert into public.service_categories(id,business_id,name,slug)
values('bbbbbbbb-1111-4111-8111-bbbbbbbbbbbb','aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa','Apparel','apparel');
insert into public.catalogue_items(id,business_id,category_id,name,slug,item_type,is_published)
values('cccccccc-1111-4111-8111-cccccccccccc','aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa',
 'bbbbbbbb-1111-4111-8111-bbbbbbbbbbbb','Custom Printed T-shirt','custom-printed-tshirt','product',true);
insert into public.stock_items(id,business_id,sku,name,stock_kind,base_unit,purchase_unit,purchase_to_base_factor,current_average_unit_cost)
values
 ('dddddddd-1111-4111-8111-dddddddddddd','aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa','TEE-M','Blank T-shirt Medium','blank_product','piece','piece',1,10),
 ('eeeeeeee-1111-4111-8111-eeeeeeeeeeee','aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa','VINYL-M','Vinyl per metre','material','m','m',1,5);
insert into public.customers(id,business_id,display_name,created_by)
values('ffffffff-1111-4111-8111-ffffffffffff','aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa','Quote Customer','44444444-4444-4444-8444-444444444444');

set local role authenticated;
select set_config('request.jwt.claim.sub','44444444-4444-4444-8444-444444444444',true);

select is(
  (public.owner_create_costing_profile('aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa',
    'cccccccc-1111-4111-8111-cccccccccccc','bbbbbbbb-1111-4111-8111-bbbbbbbbbbbb','value_added',
    (select id from public.production_methods where code='vinyl_cut'),
    jsonb_build_array(
      jsonb_build_object('component_type','blank_item','stock_item_id','dddddddd-1111-4111-8111-dddddddddddd',
        'unit','piece','driver_type','per_piece','factor',1,'expected_waste_percent',0,'fixed_cost',0),
      jsonb_build_object('component_type','meter_material','stock_item_id','eeeeeeee-1111-4111-8111-eeeeeeeeeeee',
        'unit','m','driver_type','per_metre','factor',1,'expected_waste_percent',10,'fixed_cost',0),
      jsonb_build_object('component_type','labour_time','unit','hour','driver_type','per_hour',
        'factor',1,'expected_waste_percent',0,'fixed_cost',100)
    ),'90000000-0000-4000-8000-000000000001')->>'version')::integer,
  1,'Costing profile is versioned and created with material, blank item and labour components'
);

select ok(
  (public.owner_upsert_pricing_rule('aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa',null,
    'bbbbbbbb-1111-4111-8111-bbbbbbbbbbbb',null,'Apparel 100 percent markup',
    'percentage_on_cost',100,current_date,null,true,'90000000-0000-4000-8000-000000000002')->>'pricing_rule_id') is not null,
  'Owner can configure a category pricing rule'
);

select is(
  (public.owner_create_quotation('aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa',
    'ffffffff-1111-4111-8111-ffffffffffff',null,
    jsonb_build_array(jsonb_build_object(
      'catalogue_item_id','cccccccc-1111-4111-8111-cccccccccccc',
      'stock_item_id','dddddddd-1111-4111-8111-dddddddddddd',
      'description','Custom T-shirt Medium','quantity',2,'unit','piece','line_discount',10,
      'sale_mode','value_added','customer_supplies_item',false,
      'production_method_id',(select id from public.production_methods where code='vinyl_cut'),
      'production_specification',jsonb_build_object('linear_metres',2,'labour_hours',0.5)
    )),now()+interval '14 days','Customer quote','Internal costing notes',
    '90000000-0000-4000-8000-000000000003')->>'total_amount')::bigint,
  152::bigint,'Quote price is calculated from component cost, category markup and line discount'
);

select set_config('mj.test.quote_token',
  public.owner_send_quotation(
    (select id from public.quotations where business_id='aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa'),
    now()+interval '14 days','90000000-0000-4000-8000-000000000004')->>'acceptance_token',true);

select ok(length(current_setting('mj.test.quote_token'))>=64,'Quote send returns a high-entropy one-time acceptance token');

reset role;
set local role anon;

select is(
  public.accept_quotation(current_setting('mj.test.quote_token'),'90000000-0000-4000-8000-000000000005')->>'total_amount',
  '152','Public token acceptance creates the order without exposing customer records'
);

select set_config('mj.test.accepted_order_number',
  public.accept_quotation(current_setting('mj.test.quote_token'),'90000000-0000-4000-8000-000000000005')->>'order_number',true);

select is(
  public.accept_quotation(current_setting('mj.test.quote_token'),'90000000-0000-4000-8000-000000000005')->>'order_number',
  current_setting('mj.test.accepted_order_number'),
  'Retry with the same request id returns the original order without direct table access'
);

select throws_ok(
  $$select public.accept_quotation(current_setting('mj.test.quote_token'),'90000000-0000-4000-8000-000000000006')$$,
  '22023',null,'A quote acceptance token cannot be reused with a new request id'
);

reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub','44444444-4444-4444-8444-444444444444',true);

select is(
  (select estimated_total_cost from public.order_items where order_id=(select id from public.orders where quotation_id=(select id from public.quotations where business_id='aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa'))),
  81::bigint,'Order conversion preserves the server-calculated cost snapshot'
);

select is(
  (select status from public.quotations where business_id='aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa'),
  'accepted','Quote is marked accepted after order conversion'
);

select is(
  (select allocated_discount_amount from public.order_item_discount_allocations where order_id=(select id from public.orders where quotation_id=(select id from public.quotations where business_id='aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa'))),
  10::bigint,'Accepted line discount is stored as an immutable allocation snapshot'
);

select is(
  (public.owner_get_order_balance((select id from public.orders where quotation_id=(select id from public.quotations where business_id='aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa')))->>'balance_due')::bigint,
  152::bigint,'New order balance matches the accepted quote total'
);

select * from finish();
rollback;
