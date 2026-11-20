import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const migration = await readFile(new URL('../supabase/migrations/20261120130000_add_catalogue_foundation.sql', import.meta.url), 'utf8');

test('catalogue supports products, services, independent selling methods and unapproved prices', () => {
  assert.match(migration, /item_type in \('product','service'\)/);
  assert.match(migration, /selling_method in \('fixed_price','job_costed','quantity_tier'\)/);
  assert.match(migration, /standard_unit_price numeric\(14,2\)/);
  assert.match(migration, /standard_unit_price is null/);
  assert.match(migration, /quantity_rules jsonb/);
  assert.match(migration, /is_active boolean/);
});

test('catalogue methods support different printing processes and optional costing profiles', () => {
  for (const method of ['sublimation','dtf','screen_printing','embroidery','vinyl_cutting']) {
    assert.ok(migration.includes(method), method + ' is supported');
  }
  assert.match(migration, /costing_profile_id uuid/);
  assert.match(migration, /is_preferred boolean/);
  assert.match(migration, /suitability_notes text/);
});

test('catalogue access is owner-scoped and browser writes go through the owner RPC', () => {
  assert.match(migration, /alter table public\.catalogue_items enable row level security/);
  assert.match(migration, /bm\.role='owner'/);
  assert.match(migration, /revoke all on public\.catalogue_items,public\.catalogue_item_methods from anon,authenticated/);
  assert.match(migration, /create or replace function public\.owner_save_catalogue_item/);
  assert.match(migration, /security definer/);
  assert.match(migration, /catalogue\.item_saved/);
});

test('catalogue save validates workspace ownership of every linked costing profile', () => {
  assert.match(migration, /where id=v_profile and business_id=v_business/);
  assert.match(migration, /Unsupported production method/);
  assert.match(migration, /quantity rules must be an object/i);
});
