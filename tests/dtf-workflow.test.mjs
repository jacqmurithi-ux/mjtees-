import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const migration = await readFile(new URL('../supabase/migrations/20261121200000_dtf_mixed_customer_batches.sql', import.meta.url), 'utf8');
const ui = await readFile(new URL('../src/DtfCalculator.tsx', import.meta.url), 'utf8');
const databaseE2e = await readFile(new URL('../supabase/tests/operational_e2e.test.sql', import.meta.url), 'utf8');

test('mixed DTF batch costs are calculated and rounded by the database, not trusted from the browser', () => {
  assert.match(migration, /alloc_print:=round\\(print_total\\*a\\/area_total,2\\)/);
  assert.match(migration, /direct:=alloc_print\\+alloc_press\\+alloc_labour/);
  assert.doesNotMatch(migration, /direct:=coalesce\\(\\(j->>'direct_cost'\\)/);
  assert.match(migration, /allocated_print:=allocated_print\\+alloc_print/);
  assert.match(migration, /allocated_press:=allocated_press\\+alloc_press/);
  assert.match(migration, /allocated_labour:=allocated_labour\\+alloc_labour/);
});

test('mixed DTF batch validates heat-press totals and enforces the 30% margin floor server-side', () => {
  assert.match(migration, /Per-piece heat-press total does not match the job quantities and rate/);
  assert.match(migration, /Batch heat-press total does not match the entered batch rate/);
  assert.match(migration, /DTF job agreed price is below the 30%% gross-margin floor/);
  // The percent is doubled in the SQL source so PostgreSQL RAISE prints one literal percent.
  assert.match(migration, /DTF job price is below the 30%% gross-margin floor/);
});

test('mixed-customer batch UI excludes unallocated garment inventory costs and displays per-job cost splits', () => {
  assert.match(ui, /Mixed-customer supplier batches contain DTF sticker jobs only/);
  assert.match(ui, /allocated_print_transport_cost/);
  assert.match(ui, /allocated_heat_press_cost/);
  assert.match(ui, /Print \\+ transport/);
  assert.match(ui, /Heat press/);
  assert.match(ui, /Actual supplier printing charge/);
  assert.match(ui, /Labour cost/);
  assert.match(ui, /allocated_labour_cost/);
});

test('database E2E exercises mixed batch allocation, separate quotes, Quick Sales and duplicate protection', () => {
  assert.match(databaseE2e, /mixed DTF supplier batch saves two independent customer jobs/);
  assert.match(databaseE2e, /individual mixed-batch customer quotation is created/);
  assert.match(databaseE2e, /individual DTF Quick Sale creates its own customer invoice/);
  assert.match(databaseE2e, /duplicate Quick Sale attempt is blocked/);
  assert.match(databaseE2e, /duplicate supplier payment does not duplicate the Supplies expense/);
  assert.match(databaseE2e, /database blocks mixed-batch agreed prices below the 30 percent margin floor/);
});
