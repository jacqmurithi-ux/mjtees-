begin;
create extension if not exists pgtap with schema extensions;
select plan(19);

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

select set_config('mj.test.pricing_rule_id',
  public.owner_upsert_pricing_rule('aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa',null,
    'bbbbbbbb-1111-4111-8111-bbbbbbbbbbbb',null,'Apparel 100 percent markup',
    'percentage_on_cost',100,current_date,null,true,'90000000-0000-4000-8000-000000000002')->>'pricing_rule_id',true);

select ok(current_setting('mj.test.pricing_rule_id')<>'','Owner can configure a category pricing rule');

select is(
  (public.owner_upsert_pricing_rule('aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa',
    current_setting('mj.test.pricing_rule_id')::uuid,'bbbbbbbb-1111-4111-8111-bbbbbbbbbbbb',null,
    'Retired apparel pricing','percentage_on_cost',100,current_date,null,false,
    '90000000-0000-4000-8000-000000000006')->>'created')::boolean,
  false,'Owner can deactivate an existing pricing rule');

select is(
  (public.owner_upsert_pricing_rule('aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa',null,
    'bbbbbbbb-1111-4111-8111-bbbbbbbbbbbb',null,'Replacement apparel pricing',
    'percentage_on_cost',120,current_date,null,true,'90000000-0000-4000-8000-000000000007')->>'created')::boolean,
  true,'Inactive historical pricing rules do not block a replacement rule');

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
  168::bigint,'Quote price reflects the replacement 120 percent markup and line discount'
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
  '168','Public token acceptance creates the order without exposing customer records'
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
  168::bigint,'New order balance matches the accepted quote total'
);

select is(
  (public.owner_update_order_schedule(
    (select id from public.orders where quotation_id=(select id from public.quotations where business_id='aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa')),
    current_date+5,48,'90000000-0000-4000-8000-000000000008')->>'promised_turnaround_hours')::integer,
  48,'Owner can record a promised turnaround period on the converted order'
);

select is(
  (select count(*) from public.order_events where event_type='schedule_updated'
    and order_id=(select id from public.orders where quotation_id=(select id from public.quotations where business_id='aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa'))),
  1::bigint,'Order schedule changes are recorded in the order event history'
);


select set_config('mj.test.revision_source',
  public.owner_create_quotation('aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa',
    'ffffffff-1111-4111-8111-ffffffffffff',null,
    jsonb_build_array(jsonb_build_object(
      'catalogue_item_id','cccccccc-1111-4111-8111-cccccccccccc',
      'stock_item_id','dddddddd-1111-4111-8111-dddddddddddd',
      'description','Revised sample T-shirt','quantity',1,'unit','piece','unit_price',100,
      'sale_mode','value_added','customer_supplies_item',false,
      'production_method_id',(select id from public.production_methods where code='vinyl_cut'),
      'production_specification',jsonb_build_object('linear_metres',1,'labour_hours',0.5)
    )),now()+interval '14 days',null,'Original draft','90000000-0000-4000-8000-000000000009')->>'quotation_id',true);

select set_config('mj.test.revision_result',
  public.owner_create_quotation_revision(current_setting('mj.test.revision_source')::uuid,
    jsonb_build_array(jsonb_build_object(
      'catalogue_item_id','cccccccc-1111-4111-8111-cccccccccccc',
      'stock_item_id','dddddddd-1111-4111-8111-dddddddddddd',
      'description','Revised sample T-shirt - updated artwork','quantity',1,'unit','piece','unit_price',120,
      'sale_mode','value_added','customer_supplies_item',false,
      'production_method_id',(select id from public.production_methods where code='vinyl_cut'),
      'production_specification',jsonb_build_object('linear_metres',1,'labour_hours',0.5)
    )),now()+interval '14 days','Updated specification','Revision notes',
    '90000000-0000-4000-8000-000000000010')->>'quotation_id',true);

select is(
  (select revision_of from public.quotations where id=current_setting('mj.test.revision_result')::uuid),
  current_setting('mj.test.revision_source')::uuid,
  'Quotation revisions link to the original quotation');

select is(
  (select status from public.quotations where id=current_setting('mj.test.revision_source')::uuid),
  'draft','Creating a revision preserves the original quotation and its status');


-- Exercise the database-enforced vinyl ceiling against the server-generated cost.
insert into public.service_categories(id,business_id,name,slug)
values('bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb','aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa','Vinyl Stickers','vinyl-stickers');

select public.owner_create_costing_profile(
  'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa',null,
  'bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb','value_added',null,
  jsonb_build_array(jsonb_build_object(
    'component_type','meter_material',
    'stock_item_id','eeeeeeee-1111-4111-8111-eeeeeeeeeeee',
    'unit','m','driver_type','per_metre','factor',1,
    'expected_waste_percent',0,'fixed_cost',0
  )),
  '90000000-0000-4000-8000-000000000011'
);

select public.owner_upsert_pricing_rule(
  'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa',null,
  'bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb',null,
  'Vinyl sticker price ceiling · Vinyl Stickers',
  'percentage_on_cost',400,current_date,null,true,
  '90000000-0000-4000-8000-000000000012'
);

select throws_ok(
  $select public.owner_create_quotation(
    'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa',
    'ffffffff-1111-4111-8111-ffffffffffff',null,
    jsonb_build_array(jsonb_build_object(
      'category_id','bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb',
      'description','Vinyl sticker above ceiling','quantity',1,'unit','piece',
      'unit_price',26,'sale_mode','value_added',
      'production_specification',jsonb_build_object('linear_metres',1)
    )),now()+interval '14 days',null,'Ceiling test',
    '90000000-0000-4000-8000-000000000013'
  )$,
  '23514',null,
  'Database rejects a vinyl sticker unit price above 400% markup on server cost'
);

select set_config('mj.test.vinyl_quote_id',
  public.owner_create_quotation(
    'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa',
    'ffffffff-1111-4111-8111-ffffffffffff',null,
    jsonb_build_array(jsonb_build_object(
      'category_id','bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb',
      'description','Vinyl sticker within ceiling','quantity',1,'unit','piece',
      'unit_price',25,'sale_mode','value_added',
      'production_specification',jsonb_build_object('linear_metres',1)
    )),now()+interval '14 days',null,'Ceiling test',
    '90000000-0000-4000-8000-000000000014'
  )->>'quotation_id',true);

select is(
  (select (cost_estimate_snapshot->>'estimated_total_cost')::bigint
   from public.quotation_items
   where quotation_id=current_setting('mj.test.vinyl_quote_id')::uuid),
  5::bigint,
  'Vinyl ceiling is based on the server-calculated material cost snapshot'
);

select * from finish();
rollback;
