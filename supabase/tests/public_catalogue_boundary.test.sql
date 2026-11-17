begin;
create extension if not exists pgtap with schema extensions;
select plan(5);

insert into public.businesses(id,name,slug) values('aaaaaaaa-4444-4444-8444-aaaaaaaaaaaa','Catalogue Boundary Test','catalogue-boundary');
insert into public.service_categories(id,business_id,name,slug)
values('bbbbbbbb-4444-4444-8444-bbbbbbbbbbbb','aaaaaaaa-4444-4444-8444-aaaaaaaaaaaa','Apparel','apparel');
insert into public.catalogue_items(id,business_id,category_id,name,slug,item_type,description,public_starting_price,is_published)
values
 ('cccccccc-4444-4444-8444-cccccccccccc','aaaaaaaa-4444-4444-8444-aaaaaaaaaaaa','bbbbbbbb-4444-4444-8444-bbbbbbbbbbbb',
  'Public Shirt','public-shirt','product','Published item',500,true),
 ('dddddddd-4444-4444-8444-dddddddddddd','aaaaaaaa-4444-4444-8444-aaaaaaaaaaaa','bbbbbbbb-4444-4444-8444-bbbbbbbbbbbb',
  'Internal Draft','internal-draft','product','Unpublished item',700,false);

set local role anon;

select is((select count(*) from public.get_public_catalogue('catalogue-boundary')),1::bigint,
  'Anonymous catalogue projection returns published products only');

select is((select name from public.public_catalogue limit 1),'Public Shirt',
  'Anonymous catalogue projection returns the approved public name');

select is(
  (select count(*) from information_schema.columns
   where table_schema='public' and table_name='public_catalogue' and column_name in ('id','business_id')),
  0::bigint,'Public catalogue projection exposes no internal row or business identifiers'
);

select throws_ok(
  $$select count(*) from public.catalogue_items$$,
  '42501',null,'Anonymous role cannot query catalogue base table directly'
);

select throws_ok(
  $$select count(*) from public.service_categories$$,
  '42501',null,'Anonymous role cannot query service category base table directly'
);

select * from finish();
rollback;
