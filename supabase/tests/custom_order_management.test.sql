begin;
create extension if not exists pgtap with schema extensions;
select plan(13);

select has_table('public','sales_job_size_breakdown','Sales foundation provides individual garment sizing records');
select has_table('public','sales_job_artworks','Sales foundation provides versioned artwork proof records');
select has_table('public','sales_job_colour_separations','Sales foundation provides colour separation records');

insert into auth.users(id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
values('33333333-3333-4333-8333-333333333333','authenticated','authenticated','mj-custom-order@example.invalid','',now(),
 '{"provider":"email","providers":["email"]}'::jsonb,'{}'::jsonb,now(),now());
insert into public.businesses(id,name,slug)
values('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','MJ Custom Order Test','mj-custom-order-test');
insert into public.business_memberships(business_id,user_id,role,status)
values('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','33333333-3333-4333-8333-333333333333','owner','active');
insert into public.user_profiles(user_id) values('33333333-3333-4333-8333-333333333333');
insert into public.customers(id,business_id,display_name,created_by)
values('cccccccc-cccc-4ccc-8ccc-cccccccccccc','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','Custom Order Customer','33333333-3333-4333-8333-333333333333');
insert into public.orders(id,business_id,order_number,customer_id,status,subtotal_amount,discount_amount,total_amount,created_by)
values('eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','CO-ORDER-1',
 'cccccccc-cccc-4ccc-8ccc-cccccccccccc','confirmed',1000,0,1000,'33333333-3333-4333-8333-333333333333');
insert into public.order_items(id,business_id,order_id,description,quantity,unit,unit_price,line_discount,line_total,
 sale_mode,customer_supplies_item)
values('ffffffff-ffff-4fff-8fff-ffffffffffff','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee','Custom printed team jerseys',10,'piece',100,0,1000,'value_added',true);
insert into public.production_methods(id,code,name,configuration,is_active)
values('22222222-2222-4222-8222-222222222222','custom_order_test','Custom order test','{}'::jsonb,true);
insert into public.production_jobs(id,business_id,order_item_id,production_method_id,status,planned_quantity)
values('11111111-1111-4111-8111-111111111111','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
 'ffffffff-ffff-4fff-8fff-ffffffffffff','22222222-2222-4222-8222-222222222222','planned',10);

set local role authenticated;
select set_config('request.jwt.claim.sub','33333333-3333-4333-8333-333333333333',true);

select set_config('mj.test.size_result',
 public.owner_add_job_size_breakdown(
  '11111111-1111-4111-8111-111111111111','Alex Mwangi','10','M','Black',1,'Captain jersey',
  '80000000-0000-4000-8000-000000000001')->>'size_breakdown_id',true);
select is((select count(*)::integer from public.sales_job_size_breakdown where job_id='11111111-1111-4111-8111-111111111111'),
  1,'Owner can record an individual garment size and player detail');

select is(
 public.owner_add_job_size_breakdown(
  '11111111-1111-4111-8111-111111111111','Alex Mwangi','10','M','Black',1,'Captain jersey',
  '80000000-0000-4000-8000-000000000001')->>'size_breakdown_id',
 current_setting('mj.test.size_result'),
 'Repeating a size request returns the original record');

select set_config('mj.test.artwork_result',
 public.owner_add_job_artwork(
  '11111111-1111-4111-8111-111111111111','https://drive.google.com/file/d/abc123/view',
  'team-jersey-proof-v1.png','First customer proof','80000000-0000-4000-8000-000000000002')->>'artwork_id',true);
select is((select version from public.sales_job_artworks where id=current_setting('mj.test.artwork_result')::uuid),
  1,'First artwork proof is stored as version one');

select is(
 public.owner_set_job_artwork_status(current_setting('mj.test.artwork_result')::uuid,'sent',null,'Sent to customer',
  '80000000-0000-4000-8000-000000000003')->>'proof_status',
 'sent','Owner can record that a proof was sent');

select is(
 public.owner_set_job_artwork_status(current_setting('mj.test.artwork_result')::uuid,'approved',null,'Customer approved',
  '80000000-0000-4000-8000-000000000004')->>'proof_status',
 'approved','Owner can record customer proof approval');

select is(
 public.owner_set_job_artwork_status(current_setting('mj.test.artwork_result')::uuid,'approved',null,'Customer approved',
  '80000000-0000-4000-8000-000000000004')->>'proof_status',
 'approved','Retrying the same approval request is idempotent');

select set_config('mj.test.artwork_v2',
 public.owner_add_job_artwork(
  '11111111-1111-4111-8111-111111111111','https://drive.google.com/file/d/def456/view',
  'team-jersey-proof-v2.png','Updated sponsor placement','80000000-0000-4000-8000-000000000005')->>'artwork_id',true);
select is((select version from public.sales_job_artworks where id=current_setting('mj.test.artwork_v2')::uuid),
  2,'New artwork is stored as a separate version without overwriting the approved proof');

select is(
 public.owner_add_job_colour_separation(
  '11111111-1111-4111-8111-111111111111',current_setting('mj.test.artwork_v2')::uuid,
  'White','White plastisol','SCREEN-01','front',1,'Front chest print',
  '80000000-0000-4000-8000-000000000006')->>'job_id',
 '11111111-1111-4111-8111-111111111111','Owner can record a colour separation linked to the selected proof');

select throws_ok(
 $$select public.owner_add_job_artwork('11111111-1111-4111-8111-111111111111','https://example.com/artwork.png',
   'bad.png',null,'80000000-0000-4000-8000-000000000007')$$,
 '22023',null,'Artwork references outside Google Drive are rejected');

select throws_ok(
 $$insert into public.sales_job_size_breakdown(business_id,job_id,person_name,size,quantity)
   values('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','11111111-1111-4111-8111-111111111111','Direct write','L',1)$$,
 '42501',null,'Direct client writes to custom order details remain blocked');

select * from finish();
rollback;
