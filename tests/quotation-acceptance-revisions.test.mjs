import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const migration = await readFile(new URL('../supabase/migrations/20261120170000_quotation_acceptance_and_revisions.sql', import.meta.url), 'utf8');
const operations = await readFile(new URL('../src/Operations.tsx', import.meta.url), 'utf8');
const revisionBase = await readFile(new URL('../supabase/migrations/20261120140000_add_multiline_quotation_engine.sql', import.meta.url), 'utf8');
const e2e = await readFile(new URL('../supabase/tests/operational_e2e.test.sql', import.meta.url), 'utf8');

test('new quotations are drafts and do not receive acceptance evidence at creation', () => {
  assert.match(migration, /values\(v_business,p_customer_id,btrim\(p_quote_number\),p_valid_until,0,v_user,'draft'\)/);
  assert.match(migration, /update public\.quotations set total=round\(v_lines_total,2\)\s+where id=v_quote/);
  assert.doesNotMatch(migration, /accepted_at=now\(\),accepted_recorded_by=v_user/);
  assert.match(migration, /'quotation\.created'/);
});

test('acceptance is a separate owner-only evidence action for the current issued revision', () => {
  assert.match(migration, /create or replace function public\.owner_record_quotation_acceptance/);
  assert.match(migration, /p_acceptance_method not in\('in_person','phone','email','whatsapp','other'\)/);
  assert.match(migration, /length\(btrim\(coalesce\(p_acceptance_notes,''\)\)\)<3/);
  assert.match(migration, /accepted_recorded_by=auth\.uid\(\)/);
  assert.match(migration, /accepted_revision_number=revision_number/);
  assert.match(migration, /Only the current issued quotation revision can be accepted/);
});

test('revisions create a new draft and preserve the previous accepted snapshot', () => {
  assert.match(migration, /create or replace function public\.owner_create_quotation_revision/);
  assert.match(migration, /revision_number=v_revision,revision_reason=btrim\(p_revision_reason\),supersedes_quotation_id=q\.id/);
  assert.match(migration, /'quotation',to_jsonb\(q\),'lines'/);
  assert.match(revisionBase, /quotation_revision_history_immutable/);
  assert.match(migration, /Only the current quotation revision can be converted to an invoice/);
});

test('sales UI requires evidence to accept and offers a separate revision action', () => {
  assert.match(operations, /owner_record_quotation_acceptance/);
  assert.doesNotMatch(operations, /p_status:'accepted'/);
  assert.match(operations, /owner_create_quotation_revision/);
  assert.match(operations, /Save draft quotation/);
  assert.match(operations, /Record full acceptance/);
  assert.match(operations, /details:\{blank_cost_per_piece:/);
});

test('database end-to-end tests cover acceptance evidence and stale revision protection', () => {
  assert.match(e2e, /manual acceptance stores the accepted version, timestamp, staff account and customer confirmation evidence/);
  assert.match(e2e, /revision history preserves the prior version and its acceptance evidence/);
  assert.match(e2e, /a superseded accepted version cannot be invoiced after a newer revision exists/);
  assert.match(e2e, /only the current issued revision can be accepted/);
});
