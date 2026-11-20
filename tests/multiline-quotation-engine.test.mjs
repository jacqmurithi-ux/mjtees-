import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const migration = await readFile(new URL('../supabase/migrations/20261120140000_add_multiline_quotation_engine.sql', import.meta.url), 'utf8');
const authoritativeMigration = await readFile(new URL('../supabase/migrations/20261120150000_enforce_catalogue_quote_authority.sql', import.meta.url), 'utf8');

test('accepted quotation RPC supports multiple independent lines and catalogue-linked methods', () => {
  assert.match(migration, /jsonb_array_length\(p_lines\)<1/);
  assert.match(migration, /for v_line in select value from jsonb_array_elements\(p_lines\)/);
  assert.match(migration, /catalogue_item_id/);
  assert.match(migration, /production_method/);
  assert.match(migration, /costing_profile_id/);
  assert.match(migration, /Selected production method is not active for this catalogue item/);
});

test('fixed-price services may omit a costing profile while costed lines may not', () => {
  assert.match(migration, /selling_method','\)<>\x27fixed_price\x27/);
  assert.match(migration, /A costing profile is required for job-costed or quantity-tier lines/);
});

test('customer-supplied items exclude blank-item costing and retain supply arrangement', () => {
  assert.match(migration, /v_customer_supplied/);
  assert.match(migration, /v_category='blank_item' and \(v_customer_supplied/);
  assert.match(migration, /supply_arrangement/);
});

test('line discounts are fixed or percentage, reasoned, bounded and independently margin-checked', () => {
  assert.match(migration, /fixed_amount','percentage/);
  assert.match(migration, /discount cannot exceed its standard unit price/);
  assert.match(migration, /reason is required for every discretionary line discount/);
  assert.match(migration, /v_margin<30/);
  assert.match(migration, /authorised exception and reason are required/);
});

test('quotation cost snapshots and accepted revision history are stored at creation', () => {
  assert.match(migration, /cost_snapshot jsonb/);
  assert.match(migration, /create table if not exists public\.quotation_revision_history/);
  assert.match(migration, /'Initial accepted quotation'/);
  assert.match(migration, /quotation\.accepted_created/);
});

test('new quotation RPC is owner-authorized and does not grant direct table writes', () => {
  assert.match(migration, /business_memberships/);
  assert.match(migration, /role='owner'/);
  assert.match(migration, /security definer/);
  assert.match(migration, /grant execute on function public\.owner_create_accepted_quotation/);
});
