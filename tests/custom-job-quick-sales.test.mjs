import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const migration = await readFile(new URL('../supabase/migrations/20261120220000_custom_job_quick_sales.sql', import.meta.url), 'utf8');
const operations = await readFile(new URL('../src/Operations.tsx', import.meta.url), 'utf8');

test('custom job Quick Sale accepts a one-off price without requiring a catalogue standard price', () => {
  assert.match(migration, /owner_create_custom_job_quick_sale/);
  assert.match(migration, /'Custom jobs','shop_1','job_costed'/);
  assert.match(migration, /standard_unit_price[\s\S]*round\(p_agreed_price,2\)/);
  assert.match(migration, /one_off_custom_job/);
  assert.match(migration, /delete from public\.catalogue_item_methods[\s\S]*delete from public\.catalogue_items/);
  assert.match(migration, /custom_job_quick_sale\.created/);
});

test('custom job Quick Sale retains dimensions, costing profile, payment and margin controls', () => {
  assert.match(operations, /customDimensions/);
  assert.match(operations, /customProfileId/);
  assert.match(operations, /owner_create_custom_job_quick_sale/);
  assert.match(operations, /p_dimensions:customDimensions\.trim\(\)/);
  assert.match(operations, /p_costing_profile_id:customProfileId/);
  assert.match(operations, /p_allow_below_floor:quickBelowFloor/);
  assert.match(operations, /p_payment_amount:paid/);
  assert.match(operations, /Custom job — one-off price/);
});
