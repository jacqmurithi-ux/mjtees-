begin;
create extension if not exists pgtap with schema extensions;
select extensions.plan(94);

insert into auth.users(
 id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,
 created_at,updated_at,raw_app_meta_data,raw_user_meta_data
) values(
 '11111111-1111-4111-8111-111111111111',
 '00000000-0000-0000-0000-000000000000',
 'authenticated','authenticated','mj-e2e@example.test','',now(),
 now(),now(),'{"provider":"email","providers":["email"]}'::jsonb,'{}'::jsonb
) on conflict(id) do nothing;

select set_config('request.jwt.claim.sub','11111111-1111-4111-8111-111111111111',true);
set local role authenticated;

select extensions.is(public.owner_bootstrap_workspace()->>'business_name','MJ Printing & Branding','existing owner can bootstrap the new workspace');
select set_config('test.business_id',(public.owner_bootstrap_workspace()->>'business_id'),true);
select extensions.is((select count(*)::integer from public.business_memberships where business_id=current_setting('test.business_id')::uuid and user_id=auth.uid() and role='owner'),1,'bootstrap creates exactly one owner membership for the existing Auth user');
select extensions.is((select count(*)::integer from public.inventory_locations where business_id=current_setting('test.business_id')::uuid),2,'bootstrap creates both Shop 1 and Shop 2 inventory locations');
select extensions.ok(exists(select 1 from public.business_settings where business_id=current_setting('test.business_id')::uuid),'bootstrap creates business settings');
select extensions.ok(
 exists(select 1 from information_schema.columns where table_schema='public' and table_name='quotations' and column_name='below_floor_exception_reason' and data_type='text' and is_nullable='YES') and
 exists(select 1 from information_schema.columns where table_schema='public' and table_name='quotations' and column_name='below_floor_approved_by' and data_type='uuid' and is_nullable='YES') and
 exists(select 1 from pg_constraint c join pg_attribute a on a.attrelid=c.conrelid and a.attnum=any(c.conkey) where c.conrelid='public.quotations'::regclass and c.contype='f' and a.attname='below_floor_approved_by' and c.confrelid='auth.users'::regclass),
'quotation margin exception fields are nullable and approver is linked to Auth users');

select extensions.ok(
 exists(select 1 from information_schema.columns
   where table_schema='public' and table_name='sales_invoice_items'
     and column_name='direct_cost' and data_type='numeric'
     and is_nullable='NO' and column_default is not null)
 and exists(select 1 from pg_constraint
   where conrelid='public.sales_invoice_items'::regclass
     and contype='c'
     and pg_get_constraintdef(oid) ilike '%direct_cost%'
     and pg_get_constraintdef(oid) ilike '%>=%'
     and pg_get_constraintdef(oid) ilike '%0%'),
 'invoice items carry a nonnegative direct production cost for quotation conversion');


select extensions.ok(
 not has_table_privilege('authenticated','public.costing_profiles','INSERT') and
 not has_table_privilege('authenticated','public.quotations','INSERT') and
 not has_table_privilege('authenticated','public.quotation_lines','INSERT') and
 not has_table_privilege('authenticated','public.sales_invoices','INSERT') and
 not has_table_privilege('authenticated','public.sales_invoice_items','INSERT') and
 not has_table_privilege('authenticated','public.production_jobs','INSERT') and
 not has_table_privilege('authenticated','public.purchase_orders','INSERT') and
 not has_table_privilege('authenticated','public.payments','INSERT') and
 not has_table_privilege('authenticated','public.payment_allocations','INSERT') and
 not has_table_privilege('authenticated','public.expenses','INSERT') and
 not has_table_privilege('authenticated','public.audit_events','INSERT'),
 'direct inserts into financial and audit tables are blocked');

insert into public.customers(business_id,customer_name,customer_type,created_by)
select (public.owner_bootstrap_workspace()->>'business_id')::uuid,'Example Customer','individual',auth.uid();

select set_config('test.stock_id',public.owner_create_stock_item('shop_1','Generic test stock item','General','piece',10,2,10,'E2E-STOCK')::text,true);
select extensions.throws_ok(
 $$select public.owner_create_quotation((select id from public.customers where customer_name='Example Customer'),null,'Q-NO-PROFILE',current_date+7,'[{"description":"No profile","quantity":1,"unit_price":100,"direct_cost":10,"details":{}}]'::jsonb,false,null)$$,
 'P0001','An active versioned costing profile is required before pricing this quotation',
 'refuses to price without an active versioned costing profile');

select set_config('test.profile_id',public.owner_create_costing_profile(
 'Generic production service',
 '[{"name":"Outsourced printing labour","category":"production","cost":600,"basis":"per_job"}]'::jsonb,
 600,true
)::text,true);
select extensions.ok((select is_active and version=1 and direct_cost=600 from public.costing_profiles where id=current_setting('test.profile_id')::uuid),'version one costing profile is active and stores its direct cost');

select public.owner_update_max_unit_selling_price(450);
select extensions.is(public.owner_get_max_unit_selling_price(),450::numeric,'owner can read the configured maximum price through the protected RPC');
select extensions.is((select max_unit_selling_price from public.business_settings where business_id=current_setting('test.business_id')::uuid),450::numeric,'owner can set a maximum selling price per finished item');
select extensions.throws_ok(
 $$select public.owner_create_quotation((select id from public.customers where customer_name='Example Customer'),current_setting('test.profile_id')::uuid,'Q-TEST-CEILING',current_date+7,'[{"description":"Ceiling test","quantity":1,"unit_price":500,"details":{}}]'::jsonb,false,null)$$,
 'P0001','Unit selling price exceeds the owner-set maximum price of KSh 450.00',
 'server rejects a unit selling price above the owner-set ceiling');
select public.owner_update_max_unit_selling_price(null);
select extensions.is((select max_unit_selling_price from public.business_settings where business_id=current_setting('test.business_id')::uuid),null::numeric,'owner can clear the optional selling price ceiling');

select set_config('test.cost_override_quote',public.owner_create_quotation(
 (select id from public.customers where customer_name='Example Customer'),current_setting('test.profile_id')::uuid,
 'Q-COST-BREAKDOWN',current_date+7,
 '[{"description":"Generic garment printing","quantity":16,"unit_price":800,"details":{"blank_cost_per_piece":450,"other_costs_total":800}}]'::jsonb,false,null
)::text,true);
select extensions.is((select direct_cost from public.quotation_lines where quotation_id=current_setting('test.cost_override_quote')::uuid),8600::numeric,'quotation cost combines per-job labour, quantity-aware blank cost and other job costs');
select extensions.is((select round(((q.total-l.direct_cost)/q.total)*100,2) from public.quotations q join public.quotation_lines l on l.quotation_id=q.id where q.id=current_setting('test.cost_override_quote')::uuid),32.81::numeric,'quotation uses gross profit divided by revenue for true gross margin');
select extensions.ok((select details->'cost_snapshot'->>'profile_version'='1' and jsonb_array_length(details->'cost_snapshot'->'components')=3 from public.quotation_lines where quotation_id=current_setting('test.cost_override_quote')::uuid),'quotation stores a versioned component cost snapshot');

select extensions.throws_ok(
 $$select public.owner_create_quotation((select id from public.customers where customer_name='Example Customer'),current_setting('test.profile_id')::uuid,'Q-TEST-LOW',current_date+7,'[{"description":"Low price test","quantity":2,"unit_price":100,"direct_cost":0,"details":{}}]'::jsonb,false,null)$$,
 'P0001','Quotation is below the 30% gross-margin floor. An authorised exception and reason are required.',
 'blocks quotations below the 30 percent floor without an exception');

select set_config('test.exception_quote_id',public.owner_create_quotation(
 (select id from public.customers where customer_name='Example Customer'),current_setting('test.profile_id')::uuid,
 'Q-TEST-EXCEPTION',current_date+7,
 '[{"description":"Approved below-floor test","quantity":50,"unit_price":5,"direct_cost":0,"details":{}}]'::jsonb,
 true,'Approved contract exception'
)::text,true);
select extensions.ok((select below_floor_approved_by=auth.uid() and below_floor_exception_reason='Approved contract exception' from public.quotations where id=current_setting('test.exception_quote_id')::uuid),'below-floor exception records owner approver and reason');

select set_config('test.catalogue_item_id',public.owner_save_catalogue_item(
 null,'E2E-REV-ITEM','Customer supplied print service','', 'service',null,'fixed_price',500,'item','{}'::jsonb,true,'[]'::jsonb
)::text,true);
select set_config('test.original_quote_id',public.owner_create_accepted_quotation(
 (select id from public.customers where customer_name='Example Customer'),'Q-TEST-E2E',current_date+7,
 '[{"catalogue_item_id":"'||current_setting('test.catalogue_item_id')||'","description":"Customer supplied print service","quantity":2,"unit_price":500,"supply_arrangement":"customer_supplies","discount_type":"none","discount_value":0}]'::jsonb,
 false,null
)::text,true);
select extensions.is((select status from public.quotations where id=current_setting('test.original_quote_id')::uuid),'draft','new quotations are drafts and are not accepted automatically');
select extensions.is((select total from public.quotations where id=current_setting('test.original_quote_id')::uuid),1000::numeric,'test quotation total is KES 1,000');
select extensions.is((select round(((total-(select sum(direct_cost) from public.quotation_lines where quotation_id=q.id))/total)*100,2) from public.quotations q where id=current_setting('test.original_quote_id')::uuid),100.00::numeric,'customer-supplied fixed-price quote excludes blank-item cost and calculates gross margin over revenue');

select public.owner_set_quotation_status(current_setting('test.original_quote_id')::uuid,'sent');
select public.owner_record_quotation_acceptance(current_setting('test.original_quote_id')::uuid,'phone','CALL-TEST-001','Customer confirmed every line and the full quotation total.');
select extensions.ok((select status='accepted' and accepted_at is not null and accepted_recorded_by=auth.uid() and acceptance_method='phone' and acceptance_reference='CALL-TEST-001' and acceptance_notes='Customer confirmed every line and the full quotation total.' and accepted_revision_number=1 from public.quotations where id=current_setting('test.original_quote_id')::uuid),'manual acceptance stores the accepted version, timestamp, staff account and customer confirmation evidence');

select set_config('test.revision_quote_id',public.owner_create_quotation_revision(
 current_setting('test.original_quote_id')::uuid,'Q-TEST-E2E-R2',current_date+14,
 '[{"catalogue_item_id":"'||current_setting('test.catalogue_item_id')||'","description":"Customer supplied print service","quantity":2,"unit_price":500,"supply_arrangement":"customer_supplies","discount_type":"none","discount_value":0}]'::jsonb,
 false,null,'Customer requested a revised quotation'
)::text,true);
select extensions.ok((select status='accepted' and revision_number=1 and accepted_revision_number=1 from public.quotations where id=current_setting('test.original_quote_id')::uuid),'creating a revision preserves the original accepted agreement');
select extensions.ok((select status='draft' and revision_number=2 and supersedes_quotation_id=current_setting('test.original_quote_id')::uuid from public.quotations where id=current_setting('test.revision_quote_id')::uuid),'revision creates a new draft version linked to the prior quotation');
select extensions.ok(exists(select 1 from public.quotation_revision_history where quotation_id=current_setting('test.original_quote_id')::uuid and revision_number=1 and snapshot->'quotation'->>'acceptance_method'='phone' and snapshot->'quotation'->>'acceptance_notes'='Customer confirmed every line and the full quotation total.'),'revision history preserves the prior version and its acceptance evidence');
select extensions.throws_ok(
 $select public.owner_convert_accepted_quote_to_invoice(current_setting('test.original_quote_id')::uuid,'INV-STALE-REVISION',current_date+14)$,
 'P0001','Only the current quotation revision can be converted to an invoice',
 'a superseded accepted version cannot be invoiced after a newer revision exists');
select public.owner_set_quotation_status(current_setting('test.revision_quote_id')::uuid,'sent');
select public.owner_record_quotation_acceptance(current_setting('test.revision_quote_id')::uuid,'whatsapp','MSG-TEST-002','Customer approved all revised lines and the revised total.');
select extensions.ok((select status='accepted' and accepted_revision_number=2 and acceptance_method='whatsapp' from public.quotations where id=current_setting('test.revision_quote_id')::uuid),'only the current issued revision can be accepted and its version is recorded');
select set_config('test.quote_id',current_setting('test.revision_quote_id'),true);
select extensions.is((select count(*)::integer from public.audit_events where entity_type='quotation' and entity_id=current_setting('test.quote_id')::uuid and event_type='quotation.status_changed'),1,'quotation issue transition is audited separately from acceptance evidence');
select set_config('test.deposit_id',public.owner_record_quote_deposit(current_setting('test.quote_id')::uuid,'DEP-TEST-001','mpesa_paybill',200,'DEP-REF-001')::text,true);
select extensions.is((select amount from public.quotation_deposits where id=current_setting('test.deposit_id')::uuid),200::numeric,'quotation deposit is recorded before invoicing');
select set_config('test.converted',public.owner_convert_accepted_quote_to_invoice(current_setting('test.quote_id')::uuid,'INV-TEST-E2E',current_date+14)::text,true);
select set_config('test.invoice_id',(current_setting('test.converted')::jsonb->>'invoice_id'),true);
select extensions.ok(not coalesce((current_setting('test.converted')::jsonb->>'production_job_created')::boolean,true),'invoice conversion does not create a production job');
select set_config('test.job_created',public.owner_create_production_job_from_quote(current_setting('test.quote_id')::uuid,'JOB-TEST-E2E',current_date+14)::text,true);
select set_config('test.job_id',(current_setting('test.job_created')::jsonb->>'job_id'),true);

select extensions.is((select amount_paid from public.sales_invoices where id=current_setting('test.invoice_id')::uuid),200::numeric,'quote deposit is carried into invoice paid amount');
select extensions.is((select balance from public.sales_invoices where id=current_setting('test.invoice_id')::uuid),800::numeric,'invoice balance is reduced by the quote deposit');
select extensions.is((select sum(pa.amount) from public.payment_allocations pa join public.payments p on p.id=pa.payment_id where pa.invoice_id=current_setting('test.invoice_id')::uuid and p.payment_number='QD-DEP-TEST-001'),200::numeric,'quote deposit creates an allocated append-only payment record');
select extensions.ok((select customer_supplied_items from public.production_jobs where id=current_setting('test.job_id')::uuid),'production job records customer-supplied garments');
select extensions.is((select direct_cost from public.sales_invoice_items where invoice_id=current_setting('test.invoice_id')::uuid),600::numeric,'invoice retains the original quotation cost snapshot');
select extensions.ok(exists(select 1 from public.sales_invoice_items ii join public.quotation_lines ql on ql.quotation_id=current_setting('test.quote_id')::uuid and ql.business_id=ii.business_id where ii.invoice_id=current_setting('test.invoice_id')::uuid and ii.cost_snapshot=ql.details->'cost_snapshot'),'invoice line carries the exact component breakdown snapshot from its quotation line');

select set_config('test.mixed_profile_id',public.owner_create_costing_profile(
 'Mixed basis production',
 '[{"name":"Blank garment","category":"blank_item","cost":100,"basis":"per_piece"},{"name":"Decoration labour","category":"production","cost":50,"basis":"per_piece"},{"name":"Screen setup","category":"production","cost":300,"basis":"per_job"}]'::jsonb,
 450,true
)::text,true);
select set_config('test.mixed_quote_id',public.owner_create_quotation(
 (select id from public.customers where customer_name='Example Customer'),current_setting('test.mixed_profile_id')::uuid,
 'Q-MIXED-BASIS',current_date+7,
 '[{"description":"Mixed basis production","quantity":3,"unit_price":500,"details":{}}]'::jsonb,false,null
)::text,true);
select extensions.is((select direct_cost from public.quotation_lines where quotation_id=current_setting('test.mixed_quote_id')::uuid),750::numeric,'three-piece quote multiplies per-piece components and counts per-job setup once');
select set_config('test.customer_supplied_quote_id',public.owner_create_quotation(
 (select id from public.customers where customer_name='Example Customer'),current_setting('test.mixed_profile_id')::uuid,
 'Q-CUSTOMER-SUPPLIED',current_date+7,
 '[{"description":"Customer-supplied garments","quantity":3,"unit_price":500,"details":{"customer_supplied_items":true}}]'::jsonb,false,null
)::text,true);
select extensions.is((select direct_cost from public.quotation_lines where quotation_id=current_setting('test.customer_supplied_quote_id')::uuid),450::numeric,'customer-supplied garments omit only blank-item component and retain per-piece decoration plus per-job setup');
select extensions.ok((select details->'cost_snapshot'->>'profile_id'=current_setting('test.mixed_profile_id') from public.quotation_lines where quotation_id=current_setting('test.mixed_quote_id')::uuid),'quotation snapshot identifies the exact costing profile version');
select extensions.ok((select costing_profile_id=current_setting('test.profile_id')::uuid from public.quotations where id=current_setting('test.quote_id')::uuid),'historical quotation retains the costing profile version used when it was created');

select extensions.is((select quantity_on_hand from public.stock_items where id=current_setting('test.stock_id')::uuid),10::numeric,'customer-owned items do not reduce MJ stock');

select extensions.ok(not has_table_privilege('authenticated','public.production_job_materials','INSERT'),'production materials cannot be inserted directly outside the owner RPC');
select extensions.ok(not has_function_privilege('authenticated','private.apply_stock_movement(uuid,uuid,numeric,numeric,text)','EXECUTE') and not has_function_privilege('authenticated','private.update_job_material_issue(uuid,uuid,numeric,numeric)','EXECUTE') and not has_function_privilege('authenticated','private.update_job_stage(uuid,uuid,text)','EXECUTE') and not has_function_privilege('authenticated','private.update_purchase_receipt(uuid,uuid,numeric)','EXECUTE'),'private stock movement helper cannot be called directly by clients');
select set_config('test.material_id',public.owner_add_job_material(current_setting('test.job_id')::uuid,current_setting('test.stock_id')::uuid,2)::text,true);
select extensions.is((select planned_quantity from public.production_job_materials where id=current_setting('test.material_id')::uuid),2::numeric,'owner can plan a positive quantity of same-business stock for a production job');
select extensions.throws_ok(
 $assert$select public.owner_add_job_material(current_setting('test.job_id')::uuid,current_setting('test.stock_id')::uuid,0)$assert$,
 'P0001','Planned quantity must be greater than zero',
 'rejects a zero production material plan');
select extensions.throws_ok(
 $assert$select public.owner_set_production_stage(current_setting('test.job_id')::uuid,'printing')$assert$,
 'P0001','Invalid production stage transition',
 'rejects skipping required production stages');
select public.owner_issue_job_material(current_setting('test.material_id')::uuid,1);
select extensions.is((select issued_quantity from public.production_job_materials where id=current_setting('test.material_id')::uuid),1::numeric,'partial material issue is recorded against the plan');
select extensions.is((select quantity_on_hand from public.stock_items where id=current_setting('test.stock_id')::uuid),9::numeric,'partial material issue reduces available stock through the ledger');
select extensions.throws_ok(
 $assert$select public.owner_issue_job_material(current_setting('test.material_id')::uuid,1.01)$assert$,
 'P0001','Issue quantity exceeds planned balance',
 'rejects issuing more than the remaining planned quantity');
select public.owner_issue_job_material(current_setting('test.material_id')::uuid,1);
select extensions.is((select issued_quantity from public.production_job_materials where id=current_setting('test.material_id')::uuid),2::numeric,'remaining planned material can be issued exactly once');
select extensions.is((select quantity_on_hand from public.stock_items where id=current_setting('test.stock_id')::uuid),8::numeric,'full material issue leaves the correct stock balance');
select extensions.is((select actual_direct_cost from public.production_jobs where id=current_setting('test.job_id')::uuid),20::numeric,'issued material cost is added to actual production direct cost');
select extensions.is((select count(*)::integer from public.stock_movements where stock_item_id=current_setting('test.stock_id')::uuid and movement_type='job_issue' and quantity=-1),2,'each partial issue creates its own append-only stock movement');
select extensions.is((select count(*)::integer from public.audit_events where entity_type='production_job_material' and entity_id=current_setting('test.material_id')::uuid and event_type in('production.material_planned','production.material_issued')),3,'material planning and both partial issues create audit events');
select set_config('test.insufficient_material_id',public.owner_add_job_material(current_setting('test.job_id')::uuid,current_setting('test.stock_id')::uuid,20)::text,true);
select extensions.throws_ok(
 $assert$select public.owner_issue_job_material(current_setting('test.insufficient_material_id')::uuid,9)$assert$,
 'P0001','Insufficient stock',
 'rejects issuing material beyond available stock');

select public.owner_set_production_stage(current_setting('test.job_id')::uuid,'artwork_proof');
select public.owner_set_production_stage(current_setting('test.job_id')::uuid,'screens_prepared');
select public.owner_set_production_stage(current_setting('test.job_id')::uuid,'printing');
select public.owner_set_production_stage(current_setting('test.job_id')::uuid,'finishing');
select public.owner_set_production_stage(current_setting('test.job_id')::uuid,'quality_check');
select public.owner_set_production_stage(current_setting('test.job_id')::uuid,'ready');
select public.owner_set_production_stage(current_setting('test.job_id')::uuid,'delivered');
select extensions.ok((select delivered_at is not null from public.production_jobs where id=current_setting('test.job_id')::uuid),'production delivery is timestamped');
select extensions.throws_ok(
 $assert$select public.owner_issue_job_material(current_setting('test.insufficient_material_id')::uuid,1)$assert$,
 'P0001','Cannot issue material for a closed production job',
 'prevents issuing material after a production job is closed');
select extensions.ok((select due_at is not null from public.production_jobs where id=current_setting('test.job_id')::uuid),'production due date is carried from the invoice terms');

select extensions.throws_ok(
 $test$select public.owner_record_payment(current_setting('test.invoice_id')::uuid,'PAY-TEST-OVER','cash',801,null)$test$,
 'P0001','Invalid payment method or amount exceeds invoice balance',
 'rejects a customer payment greater than the outstanding invoice balance');
select set_config('test.payment_id',public.owner_record_payment(current_setting('test.invoice_id')::uuid,'PAY-TEST-E2E','mpesa_paybill',800,'E2E-TEST-REF')::text,true);
select extensions.is((select balance from public.sales_invoices where id=current_setting('test.invoice_id')::uuid),0::numeric,'payment clears invoice balance');
select extensions.is((select status from public.sales_invoices where id=current_setting('test.invoice_id')::uuid),'paid','invoice status changes to paid');
select set_config('test.refund_id',public.owner_record_refund(current_setting('test.payment_id')::uuid,100,'Customer returned part of the completed order')::text,true);
select extensions.is((select status from public.refunds where id=current_setting('test.refund_id')::uuid),'pending','refund request is separate and starts pending');
select public.owner_post_refund(current_setting('test.refund_id')::uuid);
select extensions.is((select status from public.refunds where id=current_setting('test.refund_id')::uuid),'posted','refund is posted as a separate record');
select extensions.is((select amount from public.payments where id=current_setting('test.payment_id')::uuid),800::numeric,'posting a refund never reverses or changes the original payment');
select public.owner_adjust_inventory(current_setting('test.stock_id')::uuid,2,'Counted two extra units');
select extensions.is((select quantity_on_hand from public.stock_items where id=current_setting('test.stock_id')::uuid),10::numeric,'inventory adjustment updates stock on hand');
select extensions.ok(exists(select 1 from public.stock_movements where stock_item_id=current_setting('test.stock_id')::uuid and movement_type='adjustment' and quantity=2),'inventory adjustment creates an auditable stock movement');
select extensions.is(jsonb_array_length(public.owner_job_report()),1,'per-job report returns the completed production job');
select extensions.is((public.owner_job_report()->0->>'gross_margin_percent')::numeric,98.00::numeric,'per-job report calculates gross margin using actual direct cost over revenue');
select set_config('test.supplier_id',public.owner_create_supplier('Test Supplier',null,null)::text,true);
select set_config('test.po_one',public.owner_create_purchase_order(current_setting('test.supplier_id')::uuid,'PO-TEST-001',10,jsonb_build_array(jsonb_build_object('stock_item_id',current_setting('test.stock_id')::uuid,'quantity',10,'unit_cost',10)))::text,true);
select set_config('test.po_two',public.owner_create_purchase_order(current_setting('test.supplier_id')::uuid,'PO-TEST-002',0,jsonb_build_array(jsonb_build_object('stock_item_id',current_setting('test.stock_id')::uuid,'quantity',10,'unit_cost',12)))::text,true);
select set_config('test.supplier_payment',public.owner_record_supplier_payment(current_setting('test.supplier_id')::uuid,current_setting('test.po_one')::uuid,'SPAY-TEST-001','cash',50,null)::text,true);
select public.owner_receive_purchase_order_line((select id from public.purchase_order_lines where purchase_order_id=current_setting('test.po_one')::uuid limit 1),2);
select extensions.is((select quantity_on_hand from public.stock_items where id=current_setting('test.stock_id')::uuid),12::numeric,'purchase receipt updates stock through the protected movement helper');
select extensions.ok(exists(select 1 from public.stock_movements where stock_item_id=current_setting('test.stock_id')::uuid and movement_type='purchase' and quantity=2),'purchase receipt creates an append-only stock movement');
select extensions.ok(exists(select 1 from public.audit_events where event_type='purchasing.goods_received' and entity_type='purchase_order_line'),'purchase receipt creates an audit event');
select extensions.is((select amount from public.supplier_payments where id=current_setting('test.supplier_payment')::uuid),50::numeric,'supplier payment is recorded in its own ledger');
select extensions.is((select sum(po.total+po.transport_cost) from public.purchase_orders po where po.supplier_id=current_setting('test.supplier_id')::uuid)-(select sum(sp.amount) from public.supplier_payments sp where sp.supplier_id=current_setting('test.supplier_id')::uuid),180::numeric,'supplier balance reflects purchase orders less payments');
select extensions.is(jsonb_array_length(public.owner_supplier_price_alerts()),1,'supplier price change alert detects a new purchase price');
select public.owner_review_supplier_price_change(current_setting('test.supplier_id')::uuid,current_setting('test.stock_id')::uuid,(select id from public.purchase_order_lines where purchase_order_id=current_setting('test.po_one')::uuid),(select id from public.purchase_order_lines where purchase_order_id=current_setting('test.po_two')::uuid));
select extensions.ok((public.owner_supplier_price_alerts()->0->>'reviewed')::boolean,'supplier price alert can be marked reviewed');

select extensions.is((public.owner_operational_report()->>'invoiced_sales')::numeric,1000::numeric,'report includes invoiced sales');
select extensions.is((public.owner_operational_report()->>'payments_received')::numeric,1000::numeric,'report includes received payment');
select extensions.is((public.owner_operational_report()->>'direct_production_cost')::numeric,600::numeric,'report carries costing profile direct cost into invoice');
select extensions.is((public.owner_operational_report()->>'gross_profit')::numeric,400::numeric,'gross profit before other direct costs is KES 400');
select extensions.is((public.owner_operational_report()->>'gross_margin_percent')::numeric,40.00::numeric,'report calculates gross profit divided by invoiced sales');
select extensions.is((public.owner_operational_report()->>'outstanding_receivables')::numeric,0::numeric,'report clears paid receivable');
select extensions.is((public.owner_operational_report()->>'delivered_jobs')::integer,1,'report includes delivered production job');

select set_config('test.supplier_notes_id',public.owner_create_supplier('Supplier With Notes',null,'notes@example.test','inks and vinyl')::text,true);
select extensions.is((select notes from public.suppliers where id=current_setting('test.supplier_notes_id')::uuid),'inks and vinyl','owner can save supplier items supplied and notes');
select extensions.ok(has_function_privilege('authenticated','public.owner_create_supplier(text,text,text,text)','EXECUTE'),'authenticated owner workflow exposes the supplier details RPC');
select extensions.ok(has_function_privilege('authenticated','public.owner_create_purchase_order(uuid,text,numeric,jsonb)','EXECUTE'),'authenticated owner workflow exposes purchase order creation');
select extensions.ok(not has_function_privilege('anon','public.owner_create_supplier(text,text,text,text)','EXECUTE') and not has_function_privilege('anon','public.owner_create_purchase_order(uuid,text,numeric,jsonb)','EXECUTE'),'anonymous users cannot create suppliers or purchase orders');
select set_config('test.stock_two',public.owner_create_stock_item('shop_2','E2E purchase test ink','Printing consumable','kg',0,0,3)::text,true);
select set_config('test.po_multi',public.owner_create_purchase_order(
 current_setting('test.supplier_id')::uuid,'PO-TEST-MULTI',6,
 jsonb_build_array(
  jsonb_build_object('stock_item_id',current_setting('test.stock_id')::uuid,'quantity',4,'unit_cost',10),
  jsonb_build_object('stock_item_id',current_setting('test.stock_two')::uuid,'quantity',3,'unit_cost',20)
 )
)::text,true);
select extensions.is((select count(*)::integer from public.purchase_order_lines where purchase_order_id=current_setting('test.po_multi')::uuid),2,'purchase order accepts multiple distinct stock lines');
select extensions.is((select count(*)::integer from public.purchase_order_lines where purchase_order_id=current_setting('test.po_multi')::uuid and stock_item_id is not null),2,'every new purchase line retains an exact stock-item reference');
select extensions.is((select total+transport_cost from public.purchase_orders where id=current_setting('test.po_multi')::uuid),106::numeric,'purchase order total includes item values and transport once');
select public.owner_receive_purchase_order_line((select id from public.purchase_order_lines where purchase_order_id=current_setting('test.po_multi')::uuid and stock_item_id=current_setting('test.stock_id')::uuid),2);
select extensions.is((select status from public.purchase_orders where id=current_setting('test.po_multi')::uuid),'part_received','partial receipt leaves a multi-line order open');
select public.owner_receive_purchase_order_line((select id from public.purchase_order_lines where purchase_order_id=current_setting('test.po_multi')::uuid and stock_item_id=current_setting('test.stock_id')::uuid),2);
select public.owner_receive_purchase_order_line((select id from public.purchase_order_lines where purchase_order_id=current_setting('test.po_multi')::uuid and stock_item_id=current_setting('test.stock_two')::uuid),3);
select extensions.is((select status from public.purchase_orders where id=current_setting('test.po_multi')::uuid),'received','order closes only after every ordered unit is received');
select extensions.throws_ok(
 $assert$select public.owner_record_supplier_payment(current_setting('test.supplier_id')::uuid,current_setting('test.po_multi')::uuid,'SPAY-TEST-OVER','cash',107,null)$assert$,
 'P0001','Supplier payment exceeds outstanding balance',
 'rejects supplier payment above the selected purchase order balance');
select set_config('test.supplier_payment_multi',public.owner_record_supplier_payment(current_setting('test.supplier_id')::uuid,current_setting('test.po_multi')::uuid,'SPAY-TEST-MULTI','mpesa_paybill',20,'SUPPLIER-REF-02')::text,true);
select extensions.is((select amount from public.supplier_payments where id=current_setting('test.supplier_payment_multi')::uuid),20::numeric,'partial supplier payment is recorded without changing purchase or stock movements');
select extensions.is((select count(*)::integer from public.stock_movements where movement_type='purchase' and stock_item_id=current_setting('test.stock_two')::uuid and quantity=3),1,'goods receipt creates a separate append-only stock movement for each received stock line');

select * from extensions.finish();
rollback;
