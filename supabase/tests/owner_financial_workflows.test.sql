begin;
create extension if not exists pgtap with schema extensions;
select plan(12);

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
  $$select public.owner_upsert_customer('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',null,'Different Payload',null,null,null,null,
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

reset role;
select * from finish();
rollback;
