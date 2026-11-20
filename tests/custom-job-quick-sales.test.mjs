import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const migration = await readFile(new URL('../supabase/migrations/20261120195854_custom_job_quick_sales.sql', import.meta.url), 'utf8');
const operations = await readFile(new URL('../src/Operations.tsx', import.meta.url), 'utf8');

test('custom job Quick Sale accepts a one-off price without creating a catalogue standard price', () => {
  assert.match(migration, /owner_create_custom_job_quick_sale/);
  assert.match(migration, /'Custom jobs','shop_1','job_costed'/);
  assert.match(migration, /one_off_custom_job/);
  assert.match(migration, /'transaction_type','custom_job'/);
  assert.match(migration, /'one_off_price',true/);
  assert.match(migration, /'agreed_unit_price',round\(p_agreed_price,2\)/);
  assert.match(migration, /- 'catalogue_standard_price'/);
  assert.doesNotMatch(migration, /'catalogue_standard_price'\s*,\s*round\(p_agreed_price,2\)/);
});

test('custom job invoice retains description, dimensions, method and costing profile without a temporary catalogue reference', () => {
  assert.match(migration, /set description=v_label[\s\S]*item_type='custom_production'/);
  assert.match(migration, /'description',btrim\(p_description\)/);
  assert.match(migration, /'dimensions',btrim\(p_dimensions\)/);
  assert.match(migration, /'production_method',p_production_method/);
  assert.match(migration, /'profile_id',p_costing_profile_id/);
  assert.match(migration, /- 'catalogue_item_id'[\s\S]*- 'catalogue_item_name'/);
  assert.match(migration, /details=\(coalesce\(details,'\{\}'::jsonb\)-'catalogue_item_id'\)/);
  assert.match(migration, /delete from public\.catalogue_item_methods[\s\S]*delete from public\.catalogue_items/);
});

test('custom job Quick Sale enforces whole-number quantities in the database', () => {
  assert.match(migration, /p_quantity<>trunc\(p_quantity\)/);
  assert.match(migration, /Quantity must be a whole number greater than zero/);
});

test('custom job Quick Sale retains costing, payment and margin controls in the UI', () => {
  assert.match(operations, /customDimensions/);
  assert.match(operations, /customProfileId/);
  assert.match(operations, /owner_create_custom_job_quick_sale/);
  assert.match(operations, /p_dimensions:customDimensions\.trim\(\)/);
  assert.match(operations, /p_costing_profile_id:customProfileId/);
  assert.match(operations, /p_allow_below_floor:quickBelowFloor/);
  assert.match(operations, /p_payment_amount:paid/);
  assert.match(operations, /Custom job — one-off price/);
});
