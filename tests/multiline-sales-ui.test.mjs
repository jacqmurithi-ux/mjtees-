import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const source = await readFile(new URL('../src/Operations.tsx', import.meta.url), 'utf8');

test('Sales loads active catalogue items with their configured production methods', () => {
  assert.match(source, /from\('catalogue_items'\)\.select\([^)]*catalogue_item_methods/);
  assert.match(source, /setCatalogue\(ci\.data\|\|\[\]\)/);
});

test('Sales editor supports multiple independently configured quotation lines', () => {
  assert.match(source, /quoteLines\.map\(/);
  assert.match(source, /\+ Add quotation line/);
  assert.match(source, /Remove line/);
  for (const field of ['catalogue_item_id','production_method','costing_profile_id','supply_arrangement','discount_type','discount_value','discount_reason']) {
    assert.ok(source.includes(field), field + ' is submitted per line');
  }
});

test('Sales creates draft quotations through the multi-line RPC and records acceptance separately', () => {
  assert.match(source, /owner_create_accepted_quotation/);
  assert.match(source, /Save draft quotation/);
  assert.match(source, /owner_record_quotation_acceptance/);
  assert.doesNotMatch(source, /p_status:'accepted'/);
  assert.doesNotMatch(source, /rpc\('owner_create_quotation'/);
});

test('existing customer, deposit, invoice and costing sections remain present', () => {
  for (const text of ['Record quotation deposit','Panel title="Invoices"','owner_convert_accepted_quote_to_invoice','owner_create_production_job_from_quote','Create and activate new version','quotation_deposits']) {
    assert.ok(source.includes(text), text + ' remains in the Sales or costing workflow');
  }
});

test('failed quotation saves retain the editor contents', () => {
  assert.match(source, /const saved=await rpc\(revisionSourceId\?'owner_create_quotation_revision':'owner_create_accepted_quotation'[\s\S]*?if\(!saved\)return/);
  assert.match(source, /async function rpc\([\s\S]*?Promise<boolean>/);
});
