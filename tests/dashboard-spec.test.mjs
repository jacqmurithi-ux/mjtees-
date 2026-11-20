import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const app = await readFile(new URL('../src/App.tsx', import.meta.url), 'utf8');

test('dashboard uses quote revenue, invoice balances, defined production stages and supplier net payable', () => {
  assert.match(app, /from\('quotations'\)/);
  assert.match(app, /!\['declined','expired'\]\.includes\(x\.status\)/);
  assert.match(app, /from\('sales_invoices'\)/);
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
