begin;
create extension if not exists pgtap with schema extensions;
select plan(5);

insert into public.businesses(id,name,slug)
values('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','MJ Test Business','mj-test');

set local role service_role;

select ok(
  (public.submit_public_enquiry(
    'mj-test','Test Contact','0712345678',null,'Vinyl printing','Test enquiry',1,null,false,null,
    repeat('a',64),repeat('b',64),'70000000-0000-4000-8000-000000000001')->>'public_reference') like 'ENQ-%',
  'Service-side enquiry RPC returns only a public reference'
);

select is(
  public.submit_public_enquiry(
    'mj-test','Test Contact','0712345678',null,'Vinyl printing','Test enquiry',1,null,false,null,
    repeat('a',64),repeat('b',64),'70000000-0000-4000-8000-000000000001')->>'public_reference',
  (public.submit_public_enquiry(
    'mj-test','Test Contact','0712345678',null,'Vinyl printing','Test enquiry',1,null,false,null,
    repeat('a',64),repeat('b',64),'70000000-0000-4000-8000-000000000001')->>'public_reference'),
  'Same enquiry idempotency key returns the original public reference'
);

select public.submit_public_enquiry('mj-test','Test Contact','0712345678',null,'Vinyl printing','Second',1,null,false,null,
 repeat('a',64),repeat('b',64),'70000000-0000-4000-8000-000000000002');
select public.submit_public_enquiry('mj-test','Test Contact','0712345678',null,'Vinyl printing','Third',1,null,false,null,
 repeat('a',64),repeat('b',64),'70000000-0000-4000-8000-000000000003');
select public.submit_public_enquiry('mj-test','Test Contact','0712345678',null,'Vinyl printing','Fourth',1,null,false,null,
 repeat('a',64),repeat('b',64),'70000000-0000-4000-8000-000000000004');
select public.submit_public_enquiry('mj-test','Test Contact','0712345678',null,'Vinyl printing','Fifth',1,null,false,null,
 repeat('a',64),repeat('b',64),'70000000-0000-4000-8000-000000000005');

select is(
  (public.submit_public_enquiry('mj-test','Test Contact','0712345678',null,'Vinyl printing','Sixth',1,null,false,null,
    repeat('a',64),repeat('b',64),'70000000-0000-4000-8000-000000000006')->>'rate_limited')::boolean,
  true,'Contact rate limit blocks excess submissions'
);

reset role;
set local role anon;
select throws_ok(
  $$select public.submit_public_enquiry('mj-test','Test Contact','0712345678',null,'Vinyl printing','No direct access',1,null,false,null,
    repeat('a',64),repeat('b',64),'70000000-0000-4000-8000-000000000007')$$,
  '42501',null,'Anonymous browser role cannot call the privileged enquiry RPC'
);

select * from finish();
rollback;
