import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const migration = await readFile(new URL('../supabase/migrations/20261120210000_catalogue_categories_and_seed_items.sql', import.meta.url), 'utf8');
const catalogue = await readFile(new URL('../src/Catalogue.tsx', import.meta.url), 'utf8');
const app = await readFile(new URL('../src/App.tsx', import.meta.url), 'utf8');

test('catalogue adds category and optional minimum quantity without inventing prices', () => {
  assert.match(migration, /add column if not exists category text/);
  assert.match(migration, /add column if not exists minimum_quantity numeric/);
  assert.ok(migration.includes('null,s.price_unit'));
  assert.match(migration, /customer_supplied_bulk_pricing_minimum',10/);
  assert.match(migration, /bulk_discount_automatic',false/);
  assert.match(migration, /v_quantity<v_item.minimum_quantity/);
});

test('catalogue seeds the requested products and services for owner workspaces', () => {
  for (const name of ['T-shirts','Hoodies','Caps','Stickers','Self-adhesive vinyl','Screen printing','Sublimation','Vinyl cutting','Branding','Other printing services']) {
    assert.ok(migration.includes(name), name);
  }
  assert.match(migration, /business_memberships where role='owner'/);
});

test('catalogue saves through an owner RPC and supports methods with active costing profiles', () => {
  assert.match(migration, /owner_save_catalogue_item_v2/);
  assert.match(migration, /role='owner'/);
  assert.match(catalogue, /owner_save_catalogue_item_v2/);
  assert.match(catalogue, /costing_profile_id/);
  assert.equal(catalogue.includes(".from('catalogue_items').insert"), false);
  assert.equal(catalogue.includes(".from('catalogue_items').update"), false);
});

test('catalogue management is available in the owner workspace navigation', () => {
  assert.match(app, /Catalogue/);
  assert.match(app, /page==='catalogue'/);
});
