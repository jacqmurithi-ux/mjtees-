begin;
create extension if not exists pgtap with schema extensions;
select plan(11);

insert into auth.users(id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
values('66666666-6666-4666-8666-666666666666','authenticated','authenticated','mj-payments-owner@example.invalid','',now(),
 '{"provider":"email","providers":["email"]}'::jsonb,'{}'::jsonb,now(),now());
insert into public.businesses(id,name,slug) values('aaaaaaaa-3333-4333-8333-aaaaaaaaaaaa','Payment Reversal Test','payment-reversal-test');
insert into public.business_memberships(business_id,user_id,role,status)
values('aaaaaaaa-3333-4333-8333-aaaaaaaaaaaa','66666666-6666-4666-8666-666666666666','owner','active');
insert into public.user_profiles(user_id) values('66666666-6666-4666-8666-666666666666');
insert into public.customers(id,business_id,display_name,created_by)
values('bbbbbbbb-3333-4333-8333-bbbbbbbbbbbb','aaaaaaaa-3333-4333-8333-aaaaaaaaaaaa',
 'Payment Customer','66666666-6666-4666-8666-666666666666');
insert into public.orders(id,business_id,order_number,customer_id,status,subtotal_amount,discount_amount,total_amount,created_by)
values('cccccccc-3333-4333-8333-cccccccccccc','aaaaaaaa-3333-4333-8333-aaaaaaaaaaaa','PAY-ORDER-1',
 'bbbbbbbb-3333-4333-8333-bbbbbbbbbbbb','confirmed',500,0,500,'66666666-6666-4666-8666-666666666666');

set local role authenticated;
select set_config('request.jwt.claim.sub','66666666-6666-4666-8666-666666666666',true);

select set_config('mj.test.payment_one',
  (public.owner_record_payment('aaaaaaaa-3333-4333-8333-aaaaaaaaaaaa','cccccccc-3333-4333-8333-cccccccccccc',
    'cash',100,now(),'Customer',null,null,'Cash received','92000000-0000-4000-8000-000000000001')->>'payment_id'),true);

select is(
  (select status from public.payments where id=current_setting('mj.test.payment_one')::uuid),
  'posted','Cash payment is posted and allocated'
);

select throws_ok(
  $$select public.owner_reverse_payment(current_setting('mj.test.payment_one')::uuid,'Try to reverse before allocation reversal',
    '92000000-0000-4000-8000-000000000002')$$,
  '22023',null,'Payment cannot be reversed while any order allocation remains'
);

select is(
  (public.owner_reverse_payment_allocation(
    (select id from public.payment_allocations where payment_id=current_setting('mj.test.payment_one')::uuid),
    100,'Reverse allocation before payment reversal','92000000-0000-4000-8000-000000000003')->>'amount')::bigint,
  100::bigint,'Allocation reversal releases the full amount'
);

select is(
  (public.owner_reverse_payment(current_setting('mj.test.payment_one')::uuid,'Duplicate cash entry',
    '92000000-0000-4000-8000-000000000004')->>'status'),
  'reversed','Payment can be reversed after every allocation is fully reversed'
);

select is(
  (select status from public.payments where id=current_setting('mj.test.payment_one')::uuid),
  'reversed','Reversed payment status is persisted'
);

select set_config('mj.test.payment_two',
  (public.owner_record_payment('aaaaaaaa-3333-4333-8333-aaaaaaaaaaaa','cccccccc-3333-4333-8333-cccccccccccc',
    'cash',100,now(),'Customer',null,null,'Second cash entry','92000000-0000-4000-8000-000000000005')->>'payment_id'),true);
select public.owner_reverse_payment_allocation(
  (select id from public.payment_allocations where payment_id=current_setting('mj.test.payment_two')::uuid),
  100,'Reverse allocation for refund test','92000000-0000-4000-8000-000000000006');

select set_config('mj.test.pending_refund',
  (public.owner_record_refund(current_setting('mj.test.payment_two')::uuid,null,'unallocated',100,
    'Cancel duplicate payment','cash',null,'92000000-0000-4000-8000-000000000007')->>'refund_id'),true);

select is(
  (public.owner_cancel_refund(current_setting('mj.test.pending_refund')::uuid,'Refund was not paid out',
    '92000000-0000-4000-8000-000000000008')->>'status'),
  'cancelled','Pending refund can be cancelled before payment reversal'
);

select is(
  (public.owner_reverse_payment(current_setting('mj.test.payment_two')::uuid,'Duplicate cash entry after refund cancellation',
    '92000000-0000-4000-8000-000000000009')->>'status'),
  'reversed','Payment reversal proceeds after pending refund is cancelled'
);

select set_config('mj.test.payment_three',
  (public.owner_record_payment('aaaaaaaa-3333-4333-8333-aaaaaaaaaaaa','cccccccc-3333-4333-8333-cccccccccccc',
    'cash',100,now(),'Customer',null,null,'Third cash entry','92000000-0000-4000-8000-000000000010')->>'payment_id'),true);
select public.owner_reverse_payment_allocation(
  (select id from public.payment_allocations where payment_id=current_setting('mj.test.payment_three')::uuid),
  100,'Reverse allocation before posted refund','92000000-0000-4000-8000-000000000011');
select set_config('mj.test.posted_refund',
  (public.owner_record_refund(current_setting('mj.test.payment_three')::uuid,null,'unallocated',100,
    'Refund actually paid','cash','CASH-REF-001','92000000-0000-4000-8000-000000000012')->>'refund_id'),true);
select public.owner_post_refund(current_setting('mj.test.posted_refund')::uuid,'92000000-0000-4000-8000-000000000013');

select throws_ok(
  $$select public.owner_reverse_payment(current_setting('mj.test.payment_three')::uuid,'Try to reverse after refund',
    '92000000-0000-4000-8000-000000000014')$$,
  '22023',null,'Posted refund blocks payment reversal to prevent double deduction'
);

select is(
  (select status from public.payments where id=current_setting('mj.test.payment_three')::uuid),
  'posted','Payment remains posted when reversal is blocked by a posted refund'
);

select * from finish();
rollback;
