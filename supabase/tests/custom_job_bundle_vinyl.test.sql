begin;
create extension if not exists pgtap with schema extensions;
select extensions.plan(12);

insert into auth.users(
 id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,
 created_at,updated_at,raw_app_meta_data,raw_user_meta_data
) values(
 '22222222-2222-4222-8222-222222222222',
 '00000000-0000-0000-0000-000000000000',
 'authenticated','authenticated','mj-vinyl-bundle-e2e@example.test','',now(),
 now(),now(),'{"provider":"email","providers":["email"]}'::jsonb,'{}'::jsonb
) on conflict(id) do nothing;

select set_config('request.jwt.claim.sub','22222222-2222-4222-8222-222222222222',true);
set local role authenticated;
select set_config('test.business_id',(public.owner_bootstrap_workspace()->>'business_id'),true);

insert into public.customers(business_id,customer_name,customer_type,created_by)
values(current_setting('test.business_id')::uuid,'Vinyl Bundle Test Customer','individual',auth.uid());

select set_config('test.profile_id',public.owner_create_costing_profile(
 'Vinyl bundle E2E main job',
 '[{"name":"Outsourced production labour","category":"production","cost":100,"basis":"per_job"}]'::jsonb,
 100,true
)::text,true);

select set_config('test.vinyl_catalogue_id',public.owner_save_catalogue_item_v2(
 null,'E2E-VINYL-BUNDLE','Vinyl lettering add-on','Vinyl add-on transaction test',
 'service','Vinyl sticker material','shop_1','job_costed',300,'piece',null,'{}'::jsonb,true,
 jsonb_build_array(jsonb_build_object(
  'production_method','vinyl_cutting','costing_profile_id',current_setting('test.profile_id'),
  'is_preferred',true,'is_active',true
 ))
)::text,true);

select set_config('test.stock_good',public.owner_create_stock_item(
 'shop_1','E2E Vinyl Black','Vinyl sticker material','metre',2,100,0.2,'E2E-VINYL-GOOD'
)::text,true);
select set_config('test.stock_short',public.owner_create_stock_item(
 'shop_1','E2E Vinyl Red','Vinyl sticker material','metre',0.01,120,0.2,'E2E-VINYL-SHORT'
)::text,true);

select set_config('test.success_result',public.owner_create_custom_job_bundle_quick_sale(
 null,'INV-E2E-VINYL-BUNDLE',current_date+7,'Main custom job','A4','dtf',
 current_setting('test.profile_id')::uuid,1,500,'customer_supplies',0,false,null,
 jsonb_build_array(
  jsonb_build_object(
   'catalogue_item_id',current_setting('test.vinyl_catalogue_id'),'production_method','vinyl_cutting',
   'quantity',2,'unit_price',300,'supply_arrangement','mj_supplies','other_direct_costs',0,
   'price_reason',null,'allow_below_floor',false,'exception_reason',null,
   'vinyl_length_inches',10,'vinyl_width_inches',5,'vinyl_roll_width_inches',24,
   'vinyl_stock_item_id',current_setting('test.stock_good'),
   'vinyl_direct_labour',10,'vinyl_transfer_tape_cost',2,'vinyl_application_cost',0
  ),
  jsonb_build_object(
   'catalogue_item_id',current_setting('test.vinyl_catalogue_id'),'production_method','vinyl_cutting',
   'quantity',1,'unit_price',300,'supply_arrangement','customer_supplies','other_direct_costs',0,
   'price_reason',null,'allow_below_floor',false,'exception_reason',null,
   'vinyl_length_inches',8,'vinyl_width_inches',4,'vinyl_roll_width_inches',24,
   'vinyl_stock_item_id',null,
   'vinyl_direct_labour',8,'vinyl_transfer_tape_cost',0,'vinyl_application_cost',0
  )
 ),
 'PAY-E2E-VINYL-BUNDLE','cash',50,null
)::text,true);

select extensions.is(
 (current_setting('test.success_result')::jsonb->>'total')::numeric,1400::numeric,
 'successful mixed-supply custom job and vinyl add-ons share one combined invoice total');
select extensions.is(
 (select count(*)::integer from public.sales_invoices where invoice_number='INV-E2E-VINYL-BUNDLE'),1,
 'successful bundle creates exactly one customer invoice');
select extensions.is(
 (select count(*)::integer from public.sales_invoice_items where invoice_id=(current_setting('test.success_result')::jsonb->>'invoice_id')::uuid),3,
 'custom job and both vinyl add-ons remain separate lines on the one invoice');
select extensions.is(
 (select count(*)::integer from public.payments where payment_number='PAY-E2E-VINYL-BUNDLE'),1,
 'combined payment is recorded exactly once after all add-ons succeed');
select extensions.is(
 (select count(*)::integer from public.payment_allocations where invoice_id=(current_setting('test.success_result')::jsonb->>'invoice_id')::uuid and amount=50),1,
 'the single combined payment is allocated once to the primary invoice');
select extensions.is(
 (select count(*)::integer from public.stock_movements where stock_item_id=current_setting('test.stock_good')::uuid and movement_type='vinyl_sticker_sale'),1,
 'MJ-supplied vinyl posts one canonical stock movement');
select extensions.ok(
 (select quantity_on_hand<2 from public.stock_items where id=current_setting('test.stock_good')::uuid),
 'MJ-supplied vinyl reduces the selected colour stock');
select extensions.is(
 (select count(*)::integer from public.stock_movements where stock_item_id=current_setting('test.stock_short')::uuid),0,
 'customer-supplied vinyl does not create an MJ stock movement');
select extensions.ok(
 exists(select 1 from public.audit_events where event_type='inventory.vinyl_sticker_stock_consumed'
  and entity_type='sales_invoice' and entity_id=(current_setting('test.success_result')::jsonb->>'invoice_id')::uuid
  and details->>'bundle_addon_catalogue_item_name'='Vinyl lettering add-on'),
 'vinyl stock and pricing audit evidence is attached to the final invoice');

-- First vinyl add-on consumes available stock; the second add-on then fails.
-- The raised exception must roll back the first movement and the main invoice.
select set_config('test.stock_before_rollback',(
 select quantity_on_hand::text from public.stock_items where id=current_setting('test.stock_good')::uuid
),true);
select set_config('test.movements_before_rollback',(
 select count(*)::text from public.stock_movements where movement_type='vinyl_sticker_sale'
),true);
do $test$
declare v_message text;
begin
 begin
  perform public.owner_create_custom_job_bundle_quick_sale(
   null,'INV-E2E-VINYL-ROLLBACK',current_date+7,'Rollback main job','A4','dtf',
   current_setting('test.profile_id')::uuid,1,500,'customer_supplies',0,false,null,
   jsonb_build_array(
    jsonb_build_object(
     'catalogue_item_id',current_setting('test.vinyl_catalogue_id'),'production_method','vinyl_cutting',
     'quantity',2,'unit_price',300,'supply_arrangement','mj_supplies','other_direct_costs',0,
     'allow_below_floor',false,'vinyl_length_inches',10,'vinyl_width_inches',5,
     'vinyl_roll_width_inches',24,'vinyl_stock_item_id',current_setting('test.stock_good'),
     'vinyl_direct_labour',10,'vinyl_transfer_tape_cost',2,'vinyl_application_cost',0
    ),
    jsonb_build_object(
     'catalogue_item_id',current_setting('test.vinyl_catalogue_id'),'production_method','vinyl_cutting',
     'quantity',2,'unit_price',300,'supply_arrangement','mj_supplies','other_direct_costs',0,
     'allow_below_floor',false,'vinyl_length_inches',10,'vinyl_width_inches',5,
     'vinyl_roll_width_inches',24,'vinyl_stock_item_id',current_setting('test.stock_short'),
     'vinyl_direct_labour',10,'vinyl_transfer_tape_cost',2,'vinyl_application_cost',0
    )
   ),
   'PAY-E2E-VINYL-ROLLBACK','cash',50,null
  );
  raise exception 'Expected insufficient vinyl stock rejection did not occur';
 exception when others then
  get stacked diagnostics v_message=message_text;
  if v_message not like 'Insufficient vinyl stock.%' then raise; end if;
  perform set_config('test.rollback_error',v_message,true);
 end;
end
$test$;

select extensions.ok(
 current_setting('test.rollback_error') like 'Insufficient vinyl stock.%',
 'insufficient stock on a later add-on rejects the complete bundle');
select extensions.is(
 (select quantity_on_hand::text from public.stock_items where id=current_setting('test.stock_good')::uuid),
 current_setting('test.stock_before_rollback'),
 'earlier successful vinyl deduction is fully rolled back when a later add-on fails');
select extensions.is(
 (select count(*)::text from public.stock_movements where movement_type='vinyl_sticker_sale'),
 current_setting('test.movements_before_rollback'),
 'failed bundle leaves no partial vinyl stock movements');
select extensions.is(
 (select count(*)::integer from public.sales_invoices where invoice_number='INV-E2E-VINYL-ROLLBACK'),0,
 'failed bundle leaves no primary or temporary invoice');
select extensions.is(
 (select count(*)::integer from public.payments where payment_number='PAY-E2E-VINYL-ROLLBACK'),0,
 'failed bundle leaves no payment record');

select * from extensions.finish();
rollback;
