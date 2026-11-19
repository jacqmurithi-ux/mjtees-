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
  assert.match(quotationStatusMigration, /create or replace function public\\.owner_set_quotation_status\\(\\s*p_quote_id uuid,\\s*p_status text/);
  assert.match(quotationStatusMigration, /security definer/);
  assert.match(quotationStatusMigration, /role='owner'/);
  assert.match(quotationStatusMigration, /v_old_status='draft' and p_status='sent'/);
  assert.match(quotationStatusMigration, /v_old_status='sent' and p_status='accepted'/);
  assert.match(quotationStatusMigration, /Invalid quotation status transition/);
  assert.match(quotationStatusMigration, /quotation\\.status_changed/);
  assert.match(quotationStatusMigration, /grant execute on function public\\.owner_set_quotation_status\\(uuid,text\\) to authenticated/);
});
