import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const migration = await readFile(new URL('../supabase/migrations/20261120170000_quotation_acceptance_and_revisions.sql', import.meta.url), 'utf8');
const operations = await readFile(new URL('../src/Operations.tsx', import.meta.url), 'utf8');
const revisionBase = await readFile(new URL('../supabase/migrations/20261120140000_add_multiline_quotation_engine.sql', import.meta.url), 'utf8');
const e2e = await readFile(new URL('../supabase/tests/operational_e2e.test.sql', import.meta.url), 'utf8');

test('new quotations are saved as accepted only with complete customer evidence', () => {
  assert.match(migration, /values\(v_business,p_customer_id,btrim\(p_quote_number\),p_valid_until,0,v_user,'draft'\)/);
  assert.match(migration, /update public\.quotations set total=round\(v_lines_total,2\)\s+where id=v_quote/);
  assert.doesNotMatch(migration, /accepted_at=now\(\),accepted_recorded_by=v_user/);
  assert.match(migration, /'quotation\.created'/);
  assert.match(migration, /create or replace function public\.owner_create_accepted_quotation[\s\S]*?p_acceptance_method text[\s\S]*?p_acceptance_notes text[\s\S]*?status='accepted'[\s\S]*?accepted_at=now\(\)/);
  assert.match(migration, /quotation\.accepted/);
});

test('legacy quotations can be accepted only with complete evidence and current-version checks', () => {
  assert.match(migration, /create or replace function public\.owner_record_quotation_acceptance/);
  assert.match(migration, /p_acceptance_method not in\('in_person','phone','email','whatsapp','other'\)/);
  assert.match(migration, /length\(btrim\(coalesce\(p_acceptance_notes,''\)\)\)<3/);
  assert.match(migration, /accepted_recorded_by=auth\.uid\(\)/);
  assert.match(migration, /accepted_revision_number=revision_number/);
  assert.match(migration, /Only the current issued quotation revision can be accepted/);
});

test('revisions create a separately accepted version and preserve the previous accepted snapshot', () => {
  assert.match(migration, /create or replace function public\.owner_create_quotation_revision/);
  assert.match(migration, /revision_number=v_revision,revision_reason=btrim\(p_revision_reason\),supersedes_quotation_id=q\.id,[\s\S]*?status='accepted',[\s\S]*?accepted_at=now\(\)/);
  assert.match(migration, /'quotation',to_jsonb\(q\),'lines'/);
  assert.match(revisionBase, /quotation_revision_history_immutable/);
  assert.match(migration, /Only the current quotation revision can be converted to an invoice/);
});

test('sales UI requires fresh acceptance evidence for each quotation and revision', () => {
  assert.match(operations, /owner_record_quotation_acceptance/);
  assert.doesNotMatch(operations, /p_status:'accepted'/);
  assert.match(operations, /owner_create_quotation_revision/);
  assert.match(operations, /Save accepted quotation/);
  assert.match(operations, /Customer acceptance method/);
  assert.match(operations, /Customer acceptance notes \(required\)/);
  assert.match(operations, /Record full acceptance/);
  assert.match(operations, /details:\{blank_cost_per_piece:/);
});

test('database end-to-end tests cover acceptance evidence and stale revision protection', () => {
  assert.match(e2e, /only fully accepted quotations are saved, with timestamp, staff account and customer confirmation evidence/);
  assert.match(e2e, /revision history preserves the prior version and its acceptance evidence/);
  assert.match(e2e, /a superseded accepted version cannot be invoiced after a newer revision exists/);
  assert.match(e2e, /current revision retains its fresh customer acceptance evidence/);
});
