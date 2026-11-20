import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const app = await readFile(new URL('../src/App.tsx', import.meta.url), 'utf8');

test('dashboard separates invoiced sales, payment receipts and invoice balances without double-counting', () => {
  assert.match(app, /from\('quotations'\)/); // customer quote counts only; not sales revenue
  assert.match(app, /from\('sales_invoices'\)\.select\('id,total,balance,status'\)/);
  assert.match(app, /const sold=\(i\.data\|\|\[\]\)\.reduce\(\(n,x\)=>n\+Number\(x\.total\|\|0\),0\)/);
  assert.match(app, /from\('payments'\)\.select\('id,amount,received_at'\)/);
  assert.match(app, /const received=\(pm\.data\|\|\[\]\)\.reduce\(\(n,x\)=>n\+Number\(x\.amount\|\|0\),0\)/);
  assert.match(app, /const due=\(i\.data\|\|\[\]\)\.reduce\(\(n,x\)=>n\+Number\(x\.balance\|\|0\),0\)/);
  assert.match(app, /title="Invoiced sales"/);
  assert.match(app, /title="Cash received"/);
  assert.match(app, /title="Outstanding receivables"/);
  assert.match(app, /\['in_production','quality_check'\]/);
  assert.match(app, /purchases-supplierPaid/);
});

test('dashboard due jobs use expected completion dates and include customer, quantity/product and current status', () => {
  assert.match(app, /from\('production_jobs'\)/);
  assert.match(app, /quotation_lines\(description,quantity\)/);
  assert.match(app, /expected_completion_at/);
  assert.match(app, /production_status/);
  assert.match(app, /customer\?\.customer_name/);
  assert.match(app, /Nothing late/);
});

test('dashboard stock and supplier price alert empty states match the approved wording', () => {
  assert.match(app, /Stock is above reorder levels/);
  assert.match(app, /No price changes waiting/);
  assert.match(app, /owner_supplier_price_alerts/);
  assert.match(app, /Mark reviewed/);
});


test('customer directory shows categories, phone fallback, quote counts and customer profile history', () => {
  assert.match(app, /quote_count\?:number/);
  assert.match(app, /quoteCounts\.set\(quote\.customer_id/);
  assert.match(app, /No phone recorded/);
  assert.match(app, /category-pill/);
  assert.match(app, /Trade · another uniform shop/);
  assert.match(app, /customerDetail\.quotes/);
  assert.match(app, /customerDetail\.payments/);
  assert.match(app, /Outstanding balance/);
  assert.match(app, /from\('payments'\).*customer_id/s);
});
