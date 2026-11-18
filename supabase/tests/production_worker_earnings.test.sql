begin;
create extension if not exists pgtap with schema extensions;
select plan(15);

insert into auth.users(id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
values('11111111-1111-4111-8111-111111111111','authenticated','authenticated',
  'mj-worker-test@example.invalid','',now(),
  '{"provider":"email","providers":["email"]}'::jsonb,'{}'::jsonb,now(),now());

insert into public.businesses(id,name)
values('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','MJ Worker Test Business');

insert into public.business_memberships(business_id,user_id,role,status)
values('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','11111111-1111-4111-8111-111111111111','owner','active');

insert into public.customers(id,business_id,display_name,created_by)
values('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  'Worker Test Customer','11111111-1111-4111-8111-111111111111');

set local role authenticated;
select set_config('request.jwt.claim.sub','11111111-1111-4111-8111-111111111111',true);

-- Create a quote with an explicit KSh 600 garment component and KSh 400 printing component.
select is(
  public.owner_create_quotation_with_price_components(
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
    null,
    jsonb_build_array(jsonb_build_object(
      'description','Printed uniform test line',
      'quantity',10,
      'unit','piece',
      'unit_price',1000,
      'line_discount',100,
      'sale_mode','value_added',
      'customer_supplies_item',false,
      'production_method_id',(select id from public.production_methods where code='vinyl_cut'),
      'production_specification','{}'::jsonb,
      'garment_supply_unit_price',600
    )),
    null,null,null,
    '10000000-0000-4000-8000-000000000001'
  )->>'price_components_version',
  '1','Quotation records versioned garment and printing components'
);

insert into public.orders(
  id,business_id,order_number,customer_id,quotation_id,status,
  subtotal_amount,discount_amount,total_amount,created_by
)
select
  'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  'WORKER-TEST-ORDER',
  'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
  q.id,'in_production',10000,200,9800,
  '11111111-1111-4111-8111-111111111111'
from public.quotations q
where q.business_id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
  and q.quote_number=(select max(quote_number) from public.quotations where business_id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');

insert into public.order_items(
  id,business_id,order_id,line_sequence,description,quantity,unit,unit_price,
  line_discount,order_discount_allocated,line_total,customer_supplies_item,
  sale_mode,production_method_id,production_specification
)
values(
  'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
  1,'Printed uniform test line',10,'piece',1000,
  100,100,9800,false,'value_added',
  (select id from public.production_methods where code='vinyl_cut'),'{}'::jsonb
);

select is(
  (select (price_components_snapshot->>'eligible_printing_revenue')::bigint
   from public.order_items where id='dddddddd-dddd-4ddd-8ddd-dddddddddddd'),
  3920::bigint,
  'Accepted order snapshot allocates both discounts proportionally and preserves net printing revenue'
);

select is(
  (select (price_components_snapshot->>'garment_supply_net_amount')::bigint
   from public.order_items where id='dddddddd-dddd-4ddd-8ddd-dddddddddddd'),
  5880::bigint,
  'Garment supply net amount reconciles independently'
);

select is(
  public.owner_start_production_job(
    'dddddddd-dddd-4ddd-8ddd-dddddddddddd','vinyl_cut','{}'::jsonb,
    '20000000-0000-4000-8000-000000000001'
  )->>'status',
  'in_progress',
  'Owner starts production job for the accepted order line'
);

select is(
  public.owner_upsert_production_worker(
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',null,'Temporary Worker','0712345678','temporary',
    '30000000-0000-4000-8000-000000000001'
  )->>'worker_type',
  'temporary',
  'Owner creates a temporary worker without a login account'
);

select is(
  public.owner_assign_production_worker(
    (select id from public.production_jobs where order_item_id='dddddddd-dddd-4ddd-8ddd-dddddddddddd'),
    (select id from public.production_workers where full_name='Temporary Worker'),
    'daily_rate',800,'day','Two days of printing assistance',
    '30000000-0000-4000-8000-000000000002'
  )->>'status',
  'assigned',
  'Owner assigns a worker with an agreed daily rate'
);

select ok(
  (public.owner_confirm_worker_commencement(
    (select id from public.production_worker_assignments where job_id=(
      select id from public.production_jobs where order_item_id='dddddddd-dddd-4ddd-8ddd-dddddddddddd')),
    '30000000-0000-4000-8000-000000000003'
  )->>'temporary_labour_allocation_id') is not null,
  'Confirmed temporary commencement creates the initial allocation'
);

select is(
  (select allocation_amount from public.temporary_labour_allocations
   where job_id=(select id from public.production_jobs where order_item_id='dddddddd-dddd-4ddd-8ddd-dddddddddddd')),
  784.00::numeric,
  'Initial allocation is exactly 20 percent of eligible net printing revenue'
);

select is(
  (public.owner_confirm_worker_earnings(
    (select id from public.production_worker_assignments where job_id=(
      select id from public.production_jobs where order_item_id='dddddddd-dddd-4ddd-8ddd-dddddddddddd')),
    2,'Two approved work days','40000000-0000-4000-8000-000000000001'
  )->>'amount')::bigint,
  1600::bigint,
  'Confirmed earnings calculate daily rate times actual days'
);

select is(
  (select count(*) from public.production_worker_earnings e
   join public.production_cost_entries c on c.business_id=e.business_id and c.id=e.cost_entry_id
   where e.job_id=(select id from public.production_jobs where order_item_id='dddddddd-dddd-4ddd-8ddd-dddddddddddd')
     and c.amount=1600),
  1::bigint,
  'Each confirmed earning has exactly one linked production cost entry'
);

select is(
  (public.owner_record_worker_payment(
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    (select id from public.production_workers where full_name='Temporary Worker'),
    1000,'mpesa','QWERTY123456','Part payment',now(),
    jsonb_build_array(jsonb_build_object(
      'earning_id',(select id from public.production_worker_earnings where job_id=(
        select id from public.production_jobs where order_item_id='dddddddd-dddd-4ddd-8ddd-dddddddddddd')),
      'amount',1000
    )),
    '50000000-0000-4000-8000-000000000001'
  )->>'status'),
  'posted',
  'Worker payment records a partial settlement against confirmed earnings'
);

select is(
  (select e.amount-coalesce(sum(a.amount),0)
   from public.production_worker_earnings e
   left join public.production_worker_payment_allocations a
     on a.business_id=e.business_id and a.earning_id=e.id
   where e.job_id=(select id from public.production_jobs where order_item_id='dddddddd-dddd-4ddd-8ddd-dddddddddddd')
   group by e.id,e.amount),
  600::bigint,
  'Outstanding worker balance remains after partial payment'
);

select is(
  (select sum(amount) from public.production_cost_entries
   where job_id=(select id from public.production_jobs where order_item_id='dddddddd-dddd-4ddd-8ddd-dddddddddddd')),
  1600::bigint,
  'Worker settlement does not create a second production cost'
);

select is(
  (public.owner_adjust_temporary_labour_allocation(
    (select id from public.temporary_labour_allocations where job_id=(
      select id from public.production_jobs where order_item_id='dddddddd-dddd-4ddd-8ddd-dddddddddddd')),
    4200,'Approved correction to eligible printing revenue',
    '60000000-0000-4000-8000-000000000001'
  )->>'adjustment_amount')::numeric,
  56.00::numeric,
  'Allocation adjustment records only the 20 percent delta'
);

select is(
  (select count(*) from public.temporary_labour_adjustments
   where allocation_id=(select id from public.temporary_labour_allocations where job_id=(
     select id from public.production_jobs where order_item_id='dddddddd-dddd-4ddd-8ddd-dddddddddddd'))),
  1::bigint,
  'Allocation history is append-only and retains the adjustment'
);

reset role;
select * from finish();
rollback;
