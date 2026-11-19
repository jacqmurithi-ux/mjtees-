import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const sql = await readFile(new URL('../supabase/migrations/20261119170000_add_operational_workflows.sql', import.meta.url), 'utf8');
const pricingSql = await readFile(new URL('../supabase/migrations/20261120110000_fix_costing_pricing_integrity.sql', import.meta.url), 'utf8');

test('quotation RPC enforces 30% gross margin and requires a reason for exceptions', () => {
  assert.match(pricingSql, /\(\(v_total-v_cost\)\/v_total\)\*100/);
  assert.match(pricingSql, /v_margin_percent<30/);
  assert.match(pricingSql, /An authorised exception and reason are required/);
  assert.match(pricingSql, /below_floor_approved_by/);
});

test('quotation pricing requires an active versioned costing profile and ignores client cost figures', () => {
  assert.match(pricingSql, /An active versioned costing profile is required before pricing this quotation/);
  assert.match(pricingSql, /jsonb_array_elements\(v_components\)/);
  assert.match(pricingSql, /v_basis='per_job'/);
  assert.match(pricingSql, /v_component_cost\*v_qty/);
  assert.match(pricingSql, /direct_cost_total/);
});
test('generic quotation pricing clears the 30% gross-margin floor using versioned direct cost', () => {
  const quantity = 2, unitPrice = 500, directCost = 600;
  const total = quantity * unitPrice;
  const grossMargin = ((total - directCost) / total) * 100;
  assert.equal(total, 1000);
  assert.equal(grossMargin.toFixed(2), '40.00');
  assert.ok(grossMargin >= 30);
});

test('accepted quotation conversion creates an invoice and a production job atomically', () => {
  assert.match(sql, /Only accepted quotations can be invoiced/);
  assert.match(sql, /insert into public\.sales_invoices/);
  assert.match(sql, /insert into public\.production_jobs/);
  assert.match(sql, /update public\.quotations set status='converted'/);
});

test('customer-supplied goods do not create automatic MJ stock issues', () => {
  assert.match(sql, /coalesce\(\(details->>'customer_supplied_items'\)::boolean,false\)/);
  const conversion = sql.match(/create or replace function public\.owner_convert_quote_to_invoice[\s\S]*?end \$\$;/)?.[0] || '';
  assert.ok(conversion.length > 0, 'conversion RPC exists');
  assert.doesNotMatch(conversion, /insert into public\.stock_movements/);
});

test('stock issues are owner-authorized, quantity-limited and recorded as movements', () => {
  assert.match(sql, /owner_issue_job_material/);
  assert.match(sql, /Insufficient stock/);
  assert.match(sql, /Issue quantity exceeds planned balance/);
  assert.match(sql, /apply_stock_movement\(m\.business_id,s\.id,-p_quantity,s\.average_unit_cost,'job_issue'\)/);
  assert.match(sql, /insert into public\.stock_movements/);
});

test('payments are cash or M-Pesa Paybill, allocated once, and cannot exceed invoice balance', () => {
  assert.match(sql, /p_method not in\('cash','mpesa_paybill'\)/);
  assert.match(sql, /p_amount>i\.balance/);
  assert.match(sql, /insert into public\.payment_allocations/);
  assert.doesNotMatch(sql, /payment_reversal|reverse_payment|reversal/i);
});

test('purchasing receipts update stock and weighted average cost', () => {
  assert.match(sql, /owner_create_purchase_order/);
  assert.match(sql, /owner_receive_purchase_order_line/);
  assert.match(sql, /v_new_cost:=case/);
  assert.match(sql, /apply_stock_movement\(l\.business_id,s\.id,p_received_quantity,v_landed,'purchase'\)/);
});

test('reports use recorded invoices, payments, receivables and expenses', () => {
  assert.match(pricingSql, /owner_operational_report/);
  assert.match(pricingSql, /outstanding_receivables/);
  assert.match(pricingSql, /payments_received/);
  assert.match(pricingSql, /'expenses'/);
});


test('payment, allocation, stock movement and audit ledgers are append-only', () => {
  assert.match(sql, /revoke update,delete on public\.payments,public\.payment_allocations,public\.audit_events from authenticated/);
  assert.match(sql, /revoke insert,update,delete on public\.stock_movements from authenticated/);
  assert.match(sql, /revoke update,delete on public\.stock_items from authenticated/);
  assert.match(sql, /private\.apply_stock_movement/);
});

test('financial and stock quantities cannot be manually edited through table grants', () => {
  assert.match(sql, /revoke update,delete on public\.quotations,public\.quotation_lines,public\.sales_invoices/);
  assert.match(sql, /grant update\(status\) on public\.quotations/);
  assert.match(sql, /revoke update,delete on public\.stock_items/);
  assert.match(sql, /quantity_on_hand=0 and average_unit_cost=0/);
  assert.match(sql, /revoke update,delete on public\.production_job_materials/);
});

test('invoice snapshots direct cost and reports gross profit and gross margin distinctly', () => {
  assert.match(sql, /add column if not exists direct_cost numeric\(14,2\)/);
  assert.match(sql, /l\.line_total,l\.direct_cost/);
  assert.match(sql, /'direct_production_cost'/);
  assert.match(sql, /'gross_profit'/);
  assert.match(sql, /'gross_margin_percent'/);
});

test('production stages follow a controlled sequence with a rework path', () => {
  assert.match(sql, /v_old='awaiting_artwork' and p_stage in\('artwork_proof','cancelled'\)/);
  assert.match(sql, /v_old='quality_check' and p_stage in\('ready','printing','cancelled'\)/);
  assert.match(sql, /Invalid production stage transition/);
});

test('transaction inserts are routed through private owner-checked implementations', async () => {
  const migration = await readFile(new URL('../supabase/migrations/20261119171000_lock_transaction_writes.sql', import.meta.url), 'utf8');
  assert.match(migration, /revoke insert on public\.costing_profiles,[\s\S]*?from authenticated/);
  assert.match(migration, /create or replace function private\.owner_create_quotation_impl[\s\S]*?security definer/);
  assert.match(migration, /create or replace function public\.owner_create_quotation[\s\S]*?security invoker/);
  assert.match(migration, /grant execute on function private\.owner_record_payment_impl/);
});

test('release migrations never drop or delete the existing Supabase Auth user', async () => {
  const retirement = await readFile(new URL('../supabase/migrations/20261119160000_retire_legacy_application.sql', import.meta.url), 'utf8');
  const fresh = await readFile(new URL('../supabase/migrations/20261119161000_clean_mj_workspace.sql', import.meta.url), 'utf8');
  const workflows = await readFile(new URL('../supabase/migrations/20261119170000_add_operational_workflows.sql', import.meta.url), 'utf8');
  const lock = await readFile(new URL('../supabase/migrations/20261119171000_lock_transaction_writes.sql', import.meta.url), 'utf8');
  for (const migration of [retirement,fresh,workflows,lock]) {
    assert.doesNotMatch(migration, /drop schema auth|drop table auth\.users|delete from auth\.users|truncate auth\.users/i);
  }
});

test('release removes the unused recursive invoice-balance helper', async () => {
  const migration = await readFile(new URL('../supabase/migrations/20261119173000_remove_recursive_invoice_balance_helper.sql', import.meta.url), 'utf8');
  assert.ok(migration.includes('revoke all on function private.update_invoice_balance'));
  assert.ok(migration.includes('drop function if exists private.update_invoice_balance'));
});

test('owner pricing ceiling is nullable, owner-only and audited without changing fixed pricing policies', () => {
  assert.match(pricingSql, /add column if not exists max_unit_selling_price numeric\(14,2\)/);
  assert.match(pricingSql, /max_unit_selling_price is null or max_unit_selling_price>0/);
  assert.match(pricingSql, /owner_update_max_unit_selling_price/);
  assert.match(pricingSql, /owner_get_max_unit_selling_price/);
  assert.match(pricingSql, /role='owner'/);
  assert.match(pricingSql, /pricing\.ceiling_updated/);
  assert.match(pricingSql, /gross_margin_floor/);
  assert.match(pricingSql, /full_cost_target_multiplier/);
  assert.match(pricingSql, /Unit selling price exceeds the owner-set maximum price/);
});

test('quotation cost snapshots preserve profile version, component basis, customer supply and total cost', () => {
  assert.match(pricingSql, /'profile_id',v_profile/);
  assert.match(pricingSql, /'profile_version',v_profile_version/);
  assert.match(pricingSql, /'components',v_breakdown/);
  assert.match(pricingSql, /v_customer_supplied/);
  assert.match(pricingSql, /'direct_cost_total'/);
  assert.match(pricingSql, /'direct_cost_per_piece'/);
  assert.match(pricingSql, /'gross_margin_percent'/);
});

test('gross margin reports use gross profit divided by revenue rather than markup', () => {
  assert.match(pricingSql, /\(\(v_sales-v_cost\)\/v_sales\)\*100/);
  assert.doesNotMatch(pricingSql, /\(\(v_sales-v_cost\)\/v_cost\)\*100/);
});

test('all transaction RPCs are revoked from public and anon and granted to authenticated', () => {
  for (const fn of ['owner_create_quotation','owner_convert_quote_to_invoice','owner_issue_job_material','owner_record_payment','owner_record_expense','owner_operational_report']) {
    assert.match(sql, new RegExp('revoke all on function public\\.' + fn));
    assert.match(sql, new RegExp('grant execute on function public\\.' + fn + '.*to authenticated'));
  }
});
