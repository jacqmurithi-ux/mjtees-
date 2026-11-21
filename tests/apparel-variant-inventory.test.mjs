import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const migration = readFileSync(new URL('../supabase/migrations/20261121200000_apparel_variant_inventory.sql', import.meta.url), 'utf8');
const operations = readFileSync(new URL('../src/Operations.tsx', import.meta.url), 'utf8');
const apparelUi = readFileSync(new URL('../src/ApparelInventory.tsx', import.meta.url), 'utf8');
const purchasing = readFileSync(new URL('../supabase/migrations/20261120100000_restore_supplier_purchase_workflows.sql', import.meta.url), 'utf8');

test('variant SKUs are unique per business and link catalogue products to stock ledger items', () => {
  assert.match(migration, /unique \(business_id, sku\)/i);
  assert.match(migration, /foreign key \(business_id,stock_item_id\) references public\.stock_items\(business_id,id\)/i);
  assert.match(migration, /catalogue_item_id uuid not null/i);
});

test('variant creation records verified opening stock through the canonical stock movement helper', () => {
  assert.match(migration, /owner_create_apparel_variant/i);
  assert.match(migration, /if p_opening_quantity>0 then\s+perform private\.apply_stock_movement/i);
  assert.match(migration, /'opening'/i);
});

test('reservations check on-hand less active reservations before reserving', () => {
  assert.match(migration, /sum\(quantity-issued_quantity\)/i);
  assert.match(migration, /v_stock\.quantity_on_hand-v_reserved<p_quantity/i);
  assert.match(migration, /customer-supplied items cannot reserve mj stock/i);
});

test('issuing reserved merchandise posts a negative stock movement and records actual cost', () => {
  assert.match(migration, /owner_issue_apparel_variant_reservation/i);
  assert.match(migration, /'job_issue'/i);
  assert.match(migration, /actual_direct_cost=coalesce\(actual_direct_cost,0\)/i);
});

test('release and job cancellation close only unissued reservation balances', () => {
  assert.match(migration, /owner_release_apparel_variant_reservation/i);
  assert.match(migration, /release_apparel_reservations_on_job_cancel/i);
  assert.match(migration, /issued_quantity_kept_consumed/i);
});

test('direct apparel sales call the canonical quick-sale RPC and consume the selected variant atomically', () => {
  assert.match(migration, /public\.owner_create_quick_sale\(/i);
  assert.match(migration, /'apparel_sale'/i);
  assert.match(operations, /owner_create_apparel_quick_sale/i);
  assert.match(operations, /Select the exact apparel variant before confirming this sale/i);
});

test('variant management UI supports exact product attributes, reservations, issue and release', () => {
  for (const token of ['p_size','p_colour','p_style','p_capacity','owner_reserve_apparel_variant','owner_issue_apparel_variant_reservation','owner_release_apparel_variant_reservation']) {
    assert.ok(migration.includes(token), `missing migration token: ${token}`);
  }
  assert.match(apparelUi, /Apparel & merchandise variants/);
  assert.match(apparelUi, /Reserve and issue branded-order stock/);
});

test('purchase order receipt remains linked to exact stock item and uses the existing purchase ledger path', () => {
  assert.match(purchasing, /stock_item_id uuid/i);
  assert.match(purchasing, /private\.apply_stock_movement\([\s\S]*?'purchase'/i);
  assert.match(apparelUi, /stock_item_id/);
});
