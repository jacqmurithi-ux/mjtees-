import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const migration = await readFile(new URL('../supabase/migrations/20261119192000_restore_production_material_workflow.sql', import.meta.url), 'utf8');
const quotationMigration = await readFile(new URL('../supabase/migrations/20261119191500_restore_public_quotation_rpc.sql', import.meta.url), 'utf8');
const quotationColumnsMigration = await readFile(new URL('../supabase/migrations/20261119200000_add_quotation_margin_exception_columns.sql', import.meta.url), 'utf8');

test('production materials are business-scoped and reference jobs and stock within the same business', () => {
  assert.match(migration, /business_id uuid not null references public\.businesses\(id\)/);
  assert.match(migration, /foreign key \(business_id,job_id\)[\s\S]*?references public\.production_jobs\(business_id,id\)/);
  assert.match(migration, /foreign key \(business_id,stock_item_id\)[\s\S]*?references public\.stock_items\(business_id,id\)/);
  assert.match(migration, /planned_quantity numeric\(14,3\) not null check \(planned_quantity > 0\)/);
  assert.match(migration, /issued_quantity numeric\(14,3\) not null default 0[\s\S]*?issued_quantity <= planned_quantity/);
});

test('production materials expose owner-only reads and prohibit direct browser writes', () => {
  assert.match(migration, /alter table public\.production_job_materials enable row level security/);
  assert.match(migration, /bm\.role='owner'/);
  assert.match(migration, /revoke all on public\.production_job_materials from anon,authenticated/);
  assert.match(migration, /grant select on public\.production_job_materials to authenticated/);
});

test('material planning and issuing RPCs are owner-authorized privileged transactions', () => {
  for (const fn of ['owner_add_job_material','owner_issue_job_material']) {
    const body = migration.match(new RegExp('create or replace function public\\.' + fn + '[\\s\\S]*?\\$function\\$;'))?.[0] || '';
    assert.ok(body, fn + ' exists');
    assert.match(body, /security definer/);
    assert.match(body, /business_memberships/);
    assert.match(body, /role='owner'/);
    assert.match(body, /audit_events/);
  }
});

test('material issue checks the plan and available stock, then uses the stock ledger', () => {
  assert.match(migration, /Issue quantity exceeds planned balance/);
  assert.match(migration, /Cannot issue material for a closed production job/);
  assert.match(migration, /Insufficient stock/);
  assert.match(migration, /private\.apply_stock_movement\([\s\S]*?'job_issue'\s*\)/);
  assert.match(migration, /actual_direct_cost=actual_direct_cost\+v_cost/);
  assert.match(migration, /production\.material_issued/);
});

test('production stage transitions are sequential, locked and audited', () => {
  const body = migration.match(/create or replace function public\.owner_set_production_stage[\s\S]*?\$function\$;/)?.[0] || '';
  assert.ok(body);
  assert.match(body, /security definer/);
  assert.match(body, /for update/);
  assert.match(body, /Invalid production stage transition/);
  assert.match(body, /production\.stage_changed/);
});

test('the private stock helper is not directly executable by browser roles', () => {
  assert.match(migration, /revoke all on function private\.apply_stock_movement\(uuid,uuid,numeric,numeric,text\) from public,anon,authenticated/);
  assert.match(migration, /revoke all on function private\.update_job_material_issue/);
  assert.match(migration, /revoke all on function private\.update_job_stage/);
  assert.match(migration, /revoke all on function private\.update_purchase_receipt/);
});

test('existing stock creation and purchasing receipt workflows remain callable through owner RPCs', () => {
  for (const fn of ['owner_create_stock_item','owner_receive_purchase_order_line']) {
    const body = migration.match(new RegExp('create or replace function public\\.' + fn + '[\\s\\S]*?\\$function\\$;'))?.[0] || '';
    assert.ok(body, fn + ' exists');
    assert.match(body, /security definer/);
    assert.match(body, /business_memberships/);
    assert.match(body, /private\.apply_stock_movement/);
  }
});

test('the repair is additive and does not alter payments or existing customer records', () => {
  assert.match(migration, /add column if not exists actual_direct_cost/);
  assert.match(migration, /create table if not exists public\.production_job_materials/);
  assert.doesNotMatch(migration, /drop table|truncate|delete from public\.(customers|payments|sales_invoices)/i);
  assert.doesNotMatch(migration, /payment_reversal|reverse_payment/i);
});

test('Production screen queries the restored schema, calls the matching RPCs, and exposes Supabase diagnostics', async () => {
  const operations = await readFile(new URL('../src/Operations.tsx', import.meta.url), 'utf8');
  for (const table of ['production_jobs','stock_items','production_job_materials']) {
    assert.match(operations, new RegExp("from\\('" + table + "'\\)"));
  }
  for (const rpc of ['owner_add_job_material','owner_issue_job_material','owner_set_production_stage']) {
    assert.ok(operations.includes(rpc), rpc + ' is wired to the Production screen');
  }
  assert.match(operations, /Reflect\.get\(e,'message'\)/);
  assert.match(operations, /Reflect\.get\(e,'details'\)/);
  assert.match(operations, /Reflect\.get\(e,'hint'\)/);
});

test('quotation creation is exposed through the PostgREST public RPC with the exact frontend argument names', () => {
  assert.match(quotationMigration, /create or replace function public\.owner_create_quotation\([\s\S]*?p_customer_id uuid[\s\S]*?p_costing_profile_id uuid[\s\S]*?p_quote_number text[\s\S]*?p_valid_until date[\s\S]*?p_lines jsonb[\s\S]*?p_allow_below_floor boolean default false[\s\S]*?p_exception_reason text default null[\s\S]*?\) returns uuid/);
  assert.match(quotationMigration, /select private\.owner_create_quotation_impl\([\s\S]*?p_allow_below_floor,p_exception_reason/);
  assert.match(quotationMigration, /grant execute on function public\.owner_create_quotation\(uuid,uuid,text,date,jsonb,boolean,text\) to authenticated/);
  assert.match(quotationMigration, /notify pgrst, 'reload schema'/);
});


test('quotation margin exception audit columns are restored additively and owner attribution references Auth', () => {
  assert.match(quotationColumnsMigration, /alter table public\.quotations[\s\S]*?add column if not exists below_floor_exception_reason text/);
  assert.match(quotationColumnsMigration, /add column if not exists below_floor_approved_by uuid references auth\.users\(id\)/);
  assert.match(quotationColumnsMigration, /comment on column public\.quotations\.below_floor_exception_reason/);
  assert.match(quotationColumnsMigration, /comment on column public\.quotations\.below_floor_approved_by/);
  assert.doesNotMatch(quotationColumnsMigration, /drop column|update public\.quotations|delete from public\.quotations/i);
});

const quotationStatusMigration = await readFile(new URL('../supabase/migrations/20261119210000_restore_quotation_status_rpc.sql', import.meta.url), 'utf8');

test('quotation status RPC is owner-scoped, transition-checked, audited and callable by authenticated owners', () => {
  assert.match(quotationStatusMigration, /create or replace function public\.owner_set_quotation_status\(\s*p_quote_id uuid,\s*p_status text/);
  assert.match(quotationStatusMigration, /security definer/);
  assert.match(quotationStatusMigration, /role='owner'/);
  assert.match(quotationStatusMigration, /v_old_status='draft' and p_status='sent'/);
  assert.match(quotationStatusMigration, /v_old_status='sent' and p_status='accepted'/);
  assert.match(quotationStatusMigration, /Invalid quotation status transition/);
  assert.match(quotationStatusMigration, /quotation\.status_changed/);
  assert.match(quotationStatusMigration, /grant execute on function public\.owner_set_quotation_status\(uuid,text\) to authenticated/);
});

const invoiceItemCostMigration = await readFile(new URL('../supabase/migrations/20261119220000_restore_sales_invoice_item_direct_cost.sql', import.meta.url), 'utf8');

test('invoice item direct production cost is restored additively for quotation conversion', () => {
  assert.match(invoiceItemCostMigration, /alter table public\.sales_invoice_items[\s\S]*?add column if not exists direct_cost numeric\(14,2\) not null default 0/);
  assert.match(invoiceItemCostMigration, /check \(direct_cost >= 0\)/);
  assert.match(invoiceItemCostMigration, /comment on column public\.sales_invoice_items\.direct_cost/);
  assert.match(invoiceItemCostMigration, /notify pgrst, 'reload schema'/);
  assert.doesNotMatch(invoiceItemCostMigration, /drop column|truncate|delete from|update public\.sales_invoice_items/i);
});

test('Production page explains missing stock items and missing material requirements with a path to Inventory', async () => {
  const operations = await readFile(new URL('../src/Operations.tsx', import.meta.url), 'utf8');
  assert.match(operations, /No active stock items available/);
  assert.match(operations, /Add the real materials and their opening quantities in Inventory first/);
  assert.match(operations, /onNavigate\?\.\('inventory'\)/);
  assert.match(operations, /No material requirements planned yet/);
  assert.match(operations, /Issue remaining planned material/);
});


test('Production stage selector only offers legal next stages and includes quality check', async () => {
  const operations = await readFile(new URL('../src/Operations.tsx', import.meta.url), 'utf8');
  assert.match(operations, /quality_check/);
  assert.match(operations, /const nextStages:Record<string,string\[]>/);
  assert.match(operations, /\[j\.stage,\.\.\.\(nextStages\[j\.stage\]\|\|\[\]\)\]/);
});

test('Production planning supports multiple material requirements on one job and scopes issuing to that job', async () => {
  const operations = await readFile(new URL('../src/Operations.tsx', import.meta.url), 'utf8');
  assert.match(operations, /const jobMaterials=invoices\.filter\(m=>m\.job_id===selectedJob\)/);
  assert.match(operations, /jobMaterials\.map\(m=>/);
  assert.match(operations, /previous requirements remain listed below/);
  assert.match(operations, /material\.job_id!==selectedJob/);
  assert.match(operations, /owner_add_job_material/);
});


test('quotation form uses whole quantities and integer KSh selling prices', async () => {
  const operations = await readFile(new URL('../src/Operations.tsx', import.meta.url), 'utf8');
  assert.match(operations, /Quantity',qty,setQty,\{type:'number',min:'1',step:'1'\}/);
  assert.match(operations, /Unit selling price \(KES\)',price,setPrice,\{type:'number',min:'1',step:'1'\}/);
  assert.match(operations, /Quantity must be a whole number of at least 1/);
  assert.match(operations, /Unit selling price must be at least KSh 1/);
});

test('quotation pricing shows rounded minimum, 1.8x warning and margin exception reason', async () => {
  const operations = await readFile(new URL('../src/Operations.tsx', import.meta.url), 'utf8');
  assert.match(operations, /Math\.ceil\(directCostPerPiece\*1\.3\)/);
  assert.match(operations, /directCostPerPiece\*1\.8/);
  assert.match(operations, /Below 1\.8× full-cost target/);
  assert.match(operations, /Approved exception:/);
  assert.match(operations, /Below 30% margin/);
  assert.match(operations, /blank_cost_per_piece:effectiveBlankCost/);
});


test('quotation deposits show received and remaining balances and cannot exceed the remaining quote value', async () => {
  const operations = await readFile(new URL('../src/Operations.tsx', import.meta.url), 'utf8');
  assert.match(operations, /const depositTotals=useMemo/);
  assert.ok(operations.includes('Deposits {cash(Number(depositTotals[q.id]||0))}'));
  assert.match(operations, /Deposit cannot exceed the remaining quotation balance/);
  assert.match(operations, /selectedDepositRemaining/);
  assert.ok(operations.includes("Number(depositTotals[q.id]||0)<Number(q.total)"));
});

test('invoice cards expose customer, paid amount and outstanding balance; customer payments are bounded by balance', async () => {
  const operations = await readFile(new URL('../src/Operations.tsx', import.meta.url), 'utf8');
  assert.match(operations, /amount_paid,balance,customer_id,due_date/);
  assert.match(operations, /invoice-paid/);
  assert.match(operations, /invoice-balance-open/);
  assert.match(operations, /Payment cannot exceed the outstanding invoice balance/);
  assert.ok(operations.includes('max:String(selectedInvoice?.balance??0)'));
  assert.match(operations, /owner_record_payment/);
});

test('quotation conversion continues to allocate deposits through the existing owner RPC without editing payment history', async () => {
  const operations = await readFile(new URL('../src/Operations.tsx', import.meta.url), 'utf8');
  assert.match(operations, /owner_convert_quote_to_invoice/);
  assert.match(operations, /owner_record_quote_deposit/);
  assert.match(operations, /payment ledger remains append-only/);
  assert.doesNotMatch(operations, /reverse_payment|payment_reversal/i);
});


test('costing profiles use multiple per-piece components with separate blank-item and production categories', async () => {
  const operations = await readFile(new URL('../src/Operations.tsx', import.meta.url), 'utf8');
  assert.match(operations, /costComponents/);
  assert.match(operations, /category:'blank_item'/);
  assert.match(operations, /category:'production'/);
  assert.match(operations, /basis:'per_piece'/);
  assert.match(operations, /profileCostTotal/);
  assert.match(operations, /Minimum price · 30% margin/);
  assert.match(operations, /Full-cost target · 1.8×/);
});

test('customer-supplied items exclude blank-item cost but retain production costs from the active profile', async () => {
  const operations = await readFile(new URL('../src/Operations.tsx', import.meta.url), 'utf8');
  assert.match(operations, /activeBlankProfileCost/);
  assert.match(operations, /activeProductionCost/);
  assert.match(operations, /customerSupplied\?0:.*activeBlankProfileCost/);
  assert.match(operations, /effectiveBlankCost\+activeProductionCost/);
  assert.match(operations, /direct_cost,is_active,components'\)\.eq\('is_active',true\)/);
});

test('cost profile history displays component breakdown and retains immutable version activation', async () => {
  const operations = await readFile(new URL('../src/Operations.tsx', import.meta.url), 'utf8');
  assert.match(operations, /p\.components\.map/);
  assert.match(operations, /owner_create_costing_profile/);
  assert.match(operations, /owner_activate_costing_profile/);
  assert.match(operations, /older versions remain in the audit history|Earlier versions and quotations keep their recorded costs/);
});


test('Production material issue supports partial quantities with client-side planned and available stock validation', async () => {
  const operations = await readFile(new URL('../src/Operations.tsx', import.meta.url), 'utf8');
  assert.match(operations, /Issue quantity cannot exceed the remaining planned quantity/);
  assert.match(operations, /Issue quantity cannot exceed available stock/);
  assert.match(operations, /p_quantity:quantity/);
  assert.match(operations, /Issue selected quantity/);
  assert.match(operations, /max={selectedMaterialRemaining}/);
  assert.match(operations, /Available in stock:/);
});

test('Production material selector is constrained to the selected job and resets to its first outstanding requirement', async () => {
  const operations = await readFile(new URL('../src/Operations.tsx', import.meta.url), 'utf8');
  assert.match(operations, /const activeJobMaterials=\(m\.data\|\|\[\]\)\.filter\(x=>x\.job_id===activeJobId\)/);
  assert.match(operations, /activeJobMaterials\.some\(x=>x\.id===selectedMaterial\)/);
  assert.match(operations, /setIssueQty\(first\?String/);
  assert.match(operations, /jobMaterials\.find\(x=>x\.id===selectedMaterial\)/);
});

test('Production UI labels all persisted stages including quality check and cancellation', async () => {
  const operations = await readFile(new URL('../src/Operations.tsx', import.meta.url), 'utf8');
  assert.match(operations, /quality_check:'Quality check'/);
  assert.match(operations, /cancelled:'Cancelled'/);
  assert.match(operations, /const nextStages:Record<string,string\[]>/);
});
