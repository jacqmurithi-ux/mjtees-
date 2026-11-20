import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const migration = await readFile(new URL('../supabase/migrations/20261120150000_enforce_catalogue_quote_authority.sql', import.meta.url), 'utf8');
const operations = await readFile(new URL('../src/Operations.tsx', import.meta.url), 'utf8');

test('quotation RPC requires an active catalogue item and an approved catalogue price', () => {
  assert.match(migration, /Every quotation line must use an active catalogue item/);
  assert.match(migration, /ci\.standard_unit_price/);
  assert.match(migration, /Catalogue item % has no owner-approved standard price/);
  assert.match(migration, /v_standard:=v_catalogue_price/);
  assert.doesNotMatch(migration, /v_standard:=nullif\(v_line->>'unit_price'/);
});

test('quotation RPC derives selling method from the catalogue, not the browser payload', () => {
  assert.match(migration, /select ci\.selling_method,ci\.standard_unit_price,ci\.name/);
  assert.match(migration, /v_selling_method in\('job_costed','quantity_tier'\)/);
  assert.doesNotMatch(migration, /v_line->>'selling_method'/);
});

test('production method and costing profile are resolved from the active catalogue method link', () => {
  assert.match(migration, /from public\.catalogue_item_methods cm/);
  assert.match(migration, /cm\.production_method=v_method and cm\.is_active/);
  assert.match(migration, /select cm\.costing_profile_id into v_profile/);
  assert.match(migration, /Costing profile is controlled by the selected catalogue production method/);
  assert.match(migration, /This catalogue item requires an active production method with its linked costing profile/);
});

test('Sales editor displays approved catalogue price and does not submit editable price or selling method', () => {
  assert.match(operations, /Catalogue-approved unit price \(KES\)/);
  assert.match(operations, /Catalogue-linked costing profile/);
  assert.doesNotMatch(operations, /unit_price:unitPrice/);
  assert.doesNotMatch(operations, /selling_method:item\.selling_method/);
});

test('quantity-tier items fail closed until approved tier rules are implemented server-side', () => {
  assert.match(migration, /v_selling_method='quantity_tier' then raise exception/);
  assert.match(operations, /quantity-tier pricing is not yet configured for server-side calculation/);
});
