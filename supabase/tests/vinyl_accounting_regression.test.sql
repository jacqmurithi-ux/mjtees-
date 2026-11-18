-- MJ Tees — isolated vinyl accounting regression tests
-- Test-only fixture. Run with Supabase CLI / pgTAP in an isolated local test database.
-- Never run against the linked production project.
-- Every fixture is enclosed in a transaction and rolled back at the end.
-- Exercises existing accounting RPCs only; does not test physical-piece inventory yet.

BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT plan(22);

-- Deterministic identities make failures reproducible. These rows are test fixtures only.
INSERT INTO auth.users(id,aud,role,email,encrypted_password,email_confirmed_at,
  raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
VALUES(
  '33333333-3333-4333-8333-333333333333','authenticated','authenticated',
  'mj-vinyl-accounting@example.invalid','',now(),
  '{"provider":"email","providers":["email"]}'::jsonb,'{}'::jsonb,now(),now()
);

INSERT INTO public.businesses(id,name,slug)
VALUES('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','MJ Vinyl Accounting Test','mj-vinyl-accounting-test');

INSERT INTO public.business_memberships(business_id,user_id,role,status)
VALUES('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
  '33333333-3333-4333-8333-333333333333','owner','active');

INSERT INTO public.user_profiles(user_id)
VALUES('33333333-3333-4333-8333-333333333333');

INSERT INTO public.inventory_locations(id,business_id,name,code)
VALUES('dddddddd-dddd-4ddd-8ddd-dddddddddddd',
  'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','Vinyl test stock','VINYL-TEST');

INSERT INTO public.customers(id,business_id,display_name,created_by)
VALUES('cccccccc-cccc-4ccc-8ccc-cccccccccccc',
  'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','Vinyl Test Customer',
  '33333333-3333-4333-8333-333333333333');

INSERT INTO public.orders(id,business_id,order_number,customer_id,status,
  subtotal_amount,discount_amount,total_amount,created_by)
VALUES('eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',
  'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','VINYL-TEST-ORDER',
  'cccccccc-cccc-4ccc-8ccc-cccccccccccc','in_production',100,0,100,
  '33333333-3333-4333-8333-333333333333');

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','33333333-3333-4333-8333-333333333333',true);

SELECT public.owner_upsert_supplier(
  'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',null,'Vinyl Test Supplier',
  null,null,null,null,'80000000-0000-4000-8000-000000000001'
);

SELECT public.owner_upsert_stock_item(
  'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',null,null,
  'VINYL-TEST-01','Test Sticker Vinyl','material','metre','metre',1,
  null,null,'{}'::jsonb,0,null,'80000000-0000-4000-8000-000000000002'
);

SELECT public.owner_set_stock_opening_cost(
  (SELECT id FROM public.stock_items
   WHERE business_id='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb' AND sku='VINYL-TEST-01'),
  170,'80000000-0000-4000-8000-000000000003'
);

SELECT set_config('mj.test.purchase_order_id',
  public.owner_create_purchase_order(
    'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
    (SELECT id FROM public.suppliers
     WHERE business_id='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
       AND display_name='Vinyl Test Supplier'),
    jsonb_build_array(jsonb_build_object(
      'stock_item_id',(SELECT id FROM public.stock_items
        WHERE business_id='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
          AND sku='VINYL-TEST-01'),
      'ordered_quantity',1,'unit_price',170
    )),
    'Controlled test stock receipt','80000000-0000-4000-8000-000000000004'
  )->>'purchase_order_id',true
);

SELECT public.owner_update_purchase_order_status(
  current_setting('mj.test.purchase_order_id')::uuid,
  'ordered','Controlled test order','80000000-0000-4000-8000-000000000005'
);

SELECT public.owner_receive_purchase(
  'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
  (SELECT id FROM public.suppliers
   WHERE business_id='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
     AND display_name='Vinyl Test Supplier'),
  current_setting('mj.test.purchase_order_id')::uuid,
  now(),
  jsonb_build_array(jsonb_build_object(
    'purchase_order_item_id',(SELECT id FROM public.purchase_order_items
      WHERE purchase_order_id=current_setting('mj.test.purchase_order_id')::uuid),
    'location_id','dddddddd-dddd-4ddd-8ddd-dddddddddddd',
    'accepted_quantity',1,'rejected_quantity',0,'actual_unit_cost',170
  )),
  '80000000-0000-4000-8000-000000000006'
);

RESET ROLE;

INSERT INTO public.order_items(
  id,business_id,order_id,description,quantity,unit,unit_price,line_discount,line_total,
  sale_mode,customer_supplies_item,production_method_id,production_specification
)
VALUES(
  'ffffffff-ffff-4fff-8fff-ffffffffffff',
  'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
  'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',
  'Vinyl cut test item',1,'piece',100,0,100,'value_added',false,
  (SELECT id FROM public.production_methods WHERE code='vinyl_cut' AND is_active),
  '{"test_fixture":true}'::jsonb
);

INSERT INTO public.production_jobs(
  id,business_id,order_item_id,production_method_id,status,planned_quantity
)
VALUES(
  '99999999-9999-4999-8999-999999999999',
  'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
  'ffffffff-ffff-4fff-8fff-ffffffffffff',
  (SELECT id FROM public.production_methods WHERE code='vinyl_cut' AND is_active),
  'planned',1
);

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','33333333-3333-4333-8333-333333333333',true);

SELECT set_config('mj.test.issue_result',
  public.owner_issue_job_material(
    '99999999-9999-4999-8999-999999999999',
    (SELECT id FROM public.stock_items
     WHERE business_id='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb' AND sku='VINYL-TEST-01'),
    'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
    0.020000000,'Controlled vinyl accounting test',
    '80000000-0000-4000-8000-000000000010'
  )::text,true);

SELECT set_config('mj.test.issue_id',
  (current_setting('mj.test.issue_result')::jsonb->>'issue_id'),true);

SELECT is(
  (current_setting('mj.test.issue_result')::jsonb->>'quantity_issued')::numeric,
  0.020000000::numeric,
  'Material issue records the exact nine-decimal quantity'
);

SELECT is(
  (SELECT quantity FROM public.stock_movements
   WHERE business_id='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
     AND request_id='80000000-0000-4000-8000-000000000010'),
  -0.020000000::numeric,
  'Material issue creates one matching negative stock movement'
);

SELECT is(
  public.owner_issue_job_material(
    '99999999-9999-4999-8999-999999999999',
    (SELECT id FROM public.stock_items
     WHERE business_id='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb' AND sku='VINYL-TEST-01'),
    'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
    0.020000000,'Controlled vinyl accounting test',
    '80000000-0000-4000-8000-000000000010'
  )->>'issue_id',
  current_setting('mj.test.issue_id'),
  'Repeated issue request returns the original idempotent result'
);

SELECT is(
  (SELECT count(*)::integer FROM public.production_material_issues
   WHERE business_id='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
     AND job_id='99999999-9999-4999-8999-999999999999'),
  1,'Idempotent issue request does not create a duplicate material issue'
);

SELECT is(
  (public.owner_return_job_offcut(
    '99999999-9999-4999-8999-999999999999',current_setting('mj.test.issue_id')::uuid,
    'dddddddd-dddd-4ddd-8ddd-dddddddddddd',0.003000000,
    '80000000-0000-4000-8000-000000000011')->>'cost_credit')::bigint,
  1::bigint,'First fractional offcut return receives the initial rounded cost credit'
);

SELECT set_config('mj.test.return_two',
  public.owner_return_job_offcut(
    '99999999-9999-4999-8999-999999999999',current_setting('mj.test.issue_id')::uuid,
    'dddddddd-dddd-4ddd-8ddd-dddddddddddd',0.003000000,
    '80000000-0000-4000-8000-000000000012'
  )::text,true);

SELECT is(
  (current_setting('mj.test.return_two')::jsonb->>'cost_credit')::bigint,
  0::bigint,'Second fractional return receives only the incremental aggregate credit'
);

SELECT is(
  public.owner_return_job_offcut(
    '99999999-9999-4999-8999-999999999999',current_setting('mj.test.issue_id')::uuid,
    'dddddddd-dddd-4ddd-8ddd-dddddddddddd',0.003000000,
    '80000000-0000-4000-8000-000000000012'
  )->>'offcut_return_id',
  current_setting('mj.test.return_two')::jsonb->>'offcut_return_id',
  'Repeated offcut request returns the original idempotent result'
);

SELECT is(
  (public.owner_return_job_offcut(
    '99999999-9999-4999-8999-999999999999',current_setting('mj.test.issue_id')::uuid,
    'dddddddd-dddd-4ddd-8ddd-dddddddddddd',0.003000000,
    '80000000-0000-4000-8000-000000000013')->>'cost_credit')::bigint,
  1::bigint,'Third fractional return receives the next aggregate rounding increment'
);

SELECT is(
  (SELECT count(*)::integer FROM public.production_offcut_returns
   WHERE business_id='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
     AND issue_id=current_setting('mj.test.issue_id')::uuid),
  3,'Three unique return requests create exactly three offcut records'
);

SELECT is(
  (SELECT sum(quantity) FROM public.production_offcut_returns
   WHERE business_id='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
     AND issue_id=current_setting('mj.test.issue_id')::uuid),
  0.009000000::numeric,'Fractional offcut quantities aggregate without precision loss'
);

SELECT throws_ok(
  $test$SELECT public.owner_return_job_offcut(
    '99999999-9999-4999-8999-999999999999',
    current_setting('mj.test.issue_id')::uuid,
    'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
    0.012000000,'80000000-0000-4000-8000-000000000014')$test$,
  '22023','Offcut return exceeds remaining issued quantity',
  'Offcut return exceeding the unallocated issued quantity is rejected'
);

SELECT throws_ok(
  $test$INSERT INTO public.production_waste(
    business_id,job_id,issue_id,quantity,waste_type,reason
  ) VALUES(
    'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
    '99999999-9999-4999-8999-999999999999',
    current_setting('mj.test.issue_id')::uuid,
    0.012000000,'test','Would make offcuts plus waste exceed issued quantity'
  )$test$,
  '23514',null,
  'Waste plus previously returned offcuts cannot exceed issued quantity'
);

SELECT throws_ok(
  $test$SELECT public.owner_return_job_offcut(
    '99999999-9999-4999-8999-999999999999',
    current_setting('mj.test.issue_id')::uuid,
    'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
    0.004000000,'80000000-0000-4000-8000-000000000012')$test$,
  '22023','request_id reused with different payload',
  'Reusing a request ID with a different return payload is rejected'
);

SELECT is(
  (SELECT coalesce(sum(quantity),0) FROM public.stock_movements
   WHERE business_id='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
     AND stock_item_id=(SELECT id FROM public.stock_items
       WHERE business_id='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb' AND sku='VINYL-TEST-01')
     AND location_id='dddddddd-dddd-4ddd-8ddd-dddddddddddd'),
  0.989000000::numeric,
  'Stock ledger reconciles opening receipt, material issue and offcut returns'
);

SELECT throws_ok(
  $test$SELECT public.owner_complete_production_job(
    '99999999-9999-4999-8999-999999999999',
    '80000000-0000-4000-8000-000000000020')$test$,
  '22023','A latest passing quality check is required',
  'Production cannot complete without a latest passing quality check'
);

RESET ROLE;
INSERT INTO public.quality_checks(
  business_id,job_id,result,inspection_mode,inspector_user_id,notes
)
VALUES(
  'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
  '99999999-9999-4999-8999-999999999999',
  'pass','second_person','33333333-3333-4333-8333-333333333333',
  'Controlled passing quality check'
);

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','33333333-3333-4333-8333-333333333333',true);

SELECT is(
  (public.owner_complete_production_job(
    '99999999-9999-4999-8999-999999999999',
    '80000000-0000-4000-8000-000000000021')->>'status'),
  'completed','Production completes after a passing quality check'
);

SELECT is(
  (SELECT actual_cost_total FROM public.production_jobs
   WHERE id='99999999-9999-4999-8999-999999999999'),
  1::bigint,'Completed job cost equals issue cost less aggregate offcut credit'
);

SELECT is(
  (SELECT actual_total_cost FROM public.order_items
   WHERE id='ffffffff-ffff-4fff-8fff-ffffffffffff'),
  1::bigint,'Completed production cost is copied to the order item'
);

SELECT is(
  (SELECT status FROM public.orders
   WHERE id='eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee'),
  'ready','Order becomes ready after its production job completes'
);

SELECT is(
  (SELECT count(*)::integer FROM public.audit_events
   WHERE business_id='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
     AND action='production.material_issued'),
  1,'Successful material issue creates one audit event'
);

SELECT is(
  (SELECT count(*)::integer FROM public.audit_events
   WHERE business_id='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
     AND action='production.offcut_returned'),
  3,'Each unique offcut return creates one audit event'
);

SELECT is(
  (SELECT count(*)::integer FROM public.audit_events
   WHERE business_id='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
     AND action='production.job_completed'),
  1,'Production completion creates one audit event'
);

SELECT * FROM finish();
ROLLBACK;
