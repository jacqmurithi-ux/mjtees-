import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const migration = await readFile(new URL('../supabase/migrations/20261120130012_add_quick_sales.sql', import.meta.url), 'utf8');
const operations = await readFile(new URL('../src/Operations.tsx', import.meta.url), 'utf8');
const vinyl = await readFile(new URL('../src/VinylStickerCalculator.tsx', import.meta.url), 'utf8');

test('Quick Sales creates a direct invoice without creating a quotation', () => {
  assert.match(migration, /create or replace function public\.owner_create_quick_sale\(/);
  assert.match(migration, /insert into public\.sales_invoices\(/);
  assert.match(migration, /insert into public\.sales_invoice_items\(/);
  assert.doesNotMatch(migration, /insert into public\.quotations\(/);
  assert.match(migration, /quick_sale\.created/);
});

test('Quick Sales records optional payments through the shared append-only ledger', () => {
  assert.match(migration, /insert into public\.payments\(/);
  assert.match(migration, /insert into public\.payment_allocations\(/);
  assert.match(migration, /p_payment_amount/);
  assert.match(migration, /p_payment_method not in\('cash','mpesa_paybill'\)/);
});

test('Quick Sales enforces owner access, catalogue pricing and the gross-margin floor', () => {
  assert.match(migration, /business_memberships[\s\S]*role='owner'/);
  assert.match(migration, /catalogue_items[\s\S]*is_active/);
  assert.match(migration, /30%% gross-margin floor/);
  assert.match(migration, /below the catalogue-approved price/);
  assert.match(migration, /grant execute on function public\.owner_create_quick_sale/);
});

test('Quick Sales does not issue inventory and can create a production job separately', () => {
  const quickSaleFunction = migration.split('create or replace function public.owner_create_quick_sale')[1].split('create or replace function public.owner_create_production_job_from_invoice')[0];
  assert.doesNotMatch(quickSaleFunction, /apply_stock_movement|stock_movements|owner_issue_job_material/);
  assert.match(migration, /create or replace function public\.owner_create_production_job_from_invoice/);
  assert.match(operations, /Create production job/);
});

test('Sales UI exposes Quick Sale, a printable receipt and combined daily invoice totals', () => {
  assert.match(operations, /Panel title="Quick Sale"/);
  assert.match(operations, /owner_create_quick_sale/);
  assert.match(operations, /Print \{Number\(quickReceipt\.amount_paid\)>0\?'receipt':'invoice'\}/);
  assert.match(operations, /Today's invoiced sales/);
  assert.match(operations, /Quick Sales/);
  assert.match(operations, /Quotation invoices/);
  assert.match(operations, /Panel title="Invoices"/);
});


test('generic Quick Sale blocks MJ-supplied vinyl paths that would bypass stock consumption', () => {
  assert.match(operations, /quickSupply==='mj_supplies'&&customMethod==='vinyl_cutting'[\s\S]*Vinyl Sticker Calculator/);
  assert.match(operations, /quickSupply==='mj_supplies'&&quickMethod==='vinyl_cutting'[\s\S]*Vinyl Sticker Calculator/);
  assert.match(vinyl, /owner_create_vinyl_sticker_quick_sale/);
});

test('Sales counter exposes the canonical stock-consuming vinyl sale workflow', () => {
  assert.match(operations, /import VinylStickerCalculator from '\.\/VinylStickerCalculator'/);
  assert.match(operations, /<VinylStickerCalculator onSaleSaved=/);
  assert.match(operations, /<VinylAddonCalculator line=\{line\} onChange=\{update\}/);
  assert.match(vinyl, /owner_create_vinyl_sticker_quick_sale/);
});
