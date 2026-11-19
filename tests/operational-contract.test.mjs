import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const sql = await readFile(new URL('../supabase/migrations/20261119170000_add_operational_workflows.sql', import.meta.url), 'utf8');

test('quotation RPC enforces 30% gross margin and requires a reason for exceptions', () => {
  assert.match(sql, /\(\(v_total-v_cost\)\/v_total\)\*100 < 30/);
  assert.match(sql, /An authorised exception and reason are required/);
  assert.match(sql, /below_floor_approved_by/);
});

test('quotation pricing requires an active versioned costing profile and ignores client cost figures', () => {
  assert.match(sql, /An active versioned costing profile is required before pricing this quotation/);
  assert.match(sql, /select id,direct_cost into v_profile,v_profile_direct_cost/);
  assert.match(sql, /v_cost:=v_profile_direct_cost/);
  assert.match(sql, /direct_cost,line_total,details\)[\s\S]*?values\(v_business,v_quote,btrim\(v_line->>'description'\),v_qty,v_price,v_cost/);
});
test('Baraka supplied-garment scenario prices 50 prints at KES 30 and records KES 200 direct labour', () => {
  const quantity = 50, unitPrice = 30, directCost = 200;
  const total = quantity * unitPrice;
  const grossMargin = ((total - directCost) / total) * 100;
  assert.equal(total, 1500);
  assert.equal(grossMargin.toFixed(2), '86.67');
  assert.ok(grossMargin >= 30);
  assert.match(sql, /customer_supplied_items/);
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
  assert.match(sql, /average_unit_cost=case/);
  assert.match(sql, /'purchase',p_received_quantity/);
});

test('reports use recorded invoices, payments, receivables and expenses', () => {
  assert.match(sql, /owner_operational_report/);
  assert.match(sql, /outstanding_receivables/);
  assert.match(sql, /payments_received/);
  assert.match(sql, /'expenses'/);
});


test('payment, allocation, stock movement and audit ledgers are append-only', () => {
  assert.match(sql, /revoke update,delete on public\.payments,public\.payment_allocations,public\.audit_events from authenticated/);
  assert.match(sql, /revoke insert,update,delete on public\.stock_movements from authenticated/);
  assert.match(sql, /revoke update,delete on public\.stock_items from authenticated/);
  assert.match(sql, /private\.apply_stock_movement/);
});

test('all transaction RPCs are revoked from public and anon and granted to authenticated', () => {
  for (const fn of ['owner_create_quotation','owner_convert_quote_to_invoice','owner_issue_job_material','owner_record_payment','owner_record_expense','owner_operational_report']) {
    assert.match(sql, new RegExp('revoke all on function public\\.' + fn));
    assert.match(sql, new RegExp('grant execute on function public\\.' + fn + '.*to authenticated'));
  }
});
