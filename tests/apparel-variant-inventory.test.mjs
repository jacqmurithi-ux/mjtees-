import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const migration = readFileSync(new URL('../supabase/migrations/20261121201000_apparel_variant_inventory.sql', import.meta.url), 'utf8');
const operations = readFileSync(new URL('../src/Operations.tsx', import.meta.url), 'utf8');
const apparelUi = readFileSync(new URL('../src/ApparelInventory.tsx', import.meta.url), 'utf8');
const purchasing = readFileSync(new URL('../supabase/migrations/20261120100000_restore_supplier_purchase_workflows.sql', import.meta.url), 'utf8');

test('apparel sale movement type is allowed by the stock ledger constraint', () => {
  assert.match(migration, /stock_movements_movement_type_check[\s\S]*?'apparel_sale'/i);
  assert.match(migration, /'vinyl_sticker_sale','apparel_sale'/i);
});

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
  assert.match(migration, /coalesce\(actual_direct_cost,0\)-v_blank_estimate_to_replace/i);
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
  assert.match(operations, /Select the exact apparel variant before confirming this blank-item sale/i);
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

test('direct apparel sales cannot consume stock committed to active production reservations', () => {
  assert.match(migration, /perform 1 from public\.businesses where id=v_business for update/i);
  assert.match(migration, /sum\(quantity-issued_quantity\)[\s\S]*?status in\('reserved','partially_issued'\)/i);
  assert.match(migration, /v_stock\.quantity_on_hand-v_reserved<v_qty/i);
  assert.match(migration, /Insufficient available apparel stock after reservations/i);
});

test('production issue replaces estimated blank-item cost instead of double-counting it', () => {
  assert.match(migration, /cost_snapshot->>'catalogue_item_id'=v_variant\.catalogue_item_id::text/i);
  assert.match(migration, /where c\.value->>'category'='blank_item'/i);
  assert.match(migration, /v_blank_estimate_total\/v_invoice_quantity/i);
  assert.match(migration, /greatest\(coalesce\(sum\(r\.issued_quantity\),0\)-p_quantity,0\)/i);
  assert.match(migration, /coalesce\(actual_direct_cost,0\)-v_blank_estimate_to_replace/i);
  assert.match(migration, /round\(p_quantity\*v_stock\.average_unit_cost,2\)/i);
});

test('variant creation enforces the required attributes for each known merchandise category', () => {
  assert.match(migration, /This apparel variant requires both size and colour/i);
  assert.match(migration, /A cap variant requires colour and style/i);
  assert.match(migration, /A drinkware variant requires colour and capacity\/type/i);
  assert.match(migration, /A reflective garment variant requires size, colour and reflective style/i);
  assert.match(apparelUi, /requiredAttributes=isReflective/);
  assert.match(apparelUi, /const missing=requiredAttributes\.filter/i);
});

test('MJ-supplied merchandise requires managed variant stock; blank sales select the exact variant', () => {
  assert.match(operations, /select\('id,name,item_type,category,selling_method/);
  assert.match(operations, /requiresManagedVariant=\['apparel','headwear','drinkware','merchandise'\]/);
  assert.match(operations, /quickSupply==='mj_supplies'&&!quickMethod&&itemVariants\.length&&!quickApparelVariant/);
  assert.match(operations, /quickSupply==='mj_supplies'&&!quickMethod&&apparelVariants\.some\(v=>v\.catalogue_item_id===quickItemId\)/);
  assert.doesNotMatch(operations, /quickSupply==='mj_supplies'&&quickApparelVariant/);
});

test('apparel issue locks production job before reservation to avoid cancellation deadlocks', () => {
  const start=migration.indexOf('create or replace function public.owner_issue_apparel_variant_reservation');
  const end=migration.indexOf('create or replace function public.owner_release_apparel_variant_reservation',start);
  const issue=migration.slice(start,end);
  assert.ok(issue.indexOf('from public.production_jobs')<issue.indexOf('from public.apparel_variant_reservations where id=p_reservation_id for update'));
  assert.match(issue,/production job first, reservation second, stock item third/i);
});

test('apparel stock quantities are restricted to whole pieces at the database boundary', () => {
  assert.match(migration, /p_opening_quantity<>trunc\(p_opening_quantity\)/i);
  assert.match(migration, /p_reorder_level<>trunc\(p_reorder_level\)/i);
  assert.match(migration, /p_quantity<>trunc\(p_quantity\).*whole-piece reservation quantity/i);
  assert.match(migration, /p_quantity<>trunc\(p_quantity\).*whole-piece issue quantity/i);
});


test('branded apparel remains reserved until production issue while blank-item sales consume stock', () => {
  assert.match(operations, /quickSupply==='mj_supplies'&&!quickMethod&&quickApparelVariant/);
  assert.match(operations, /Blank item — no decoration/);
  assert.match(operations, /quickSupply==='mj_supplies'&&!quickMethod&&apparelVariants\.some/);
});
