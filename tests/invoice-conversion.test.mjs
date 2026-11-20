import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const conversion = await readFile(new URL('../supabase/migrations/20261120160000_split_invoice_and_production_job_creation.sql', import.meta.url), 'utf8');
const catalogueAuthority = await readFile(new URL('../supabase/migrations/20261120150000_enforce_catalogue_quote_authority.sql', import.meta.url), 'utf8');
const operations = await readFile(new URL('../src/Operations.tsx', import.meta.url), 'utf8');

const invoiceFunction = conversion.match(/create or replace function public\.owner_convert_accepted_quote_to_invoice[\s\S]*?\$fn\$;/)?.[0] || '';
const jobFunction = conversion.match(/create or replace function public\.owner_create_production_job_from_quote[\s\S]*?\$fn\$;/)?.[0] || '';

test('quotation lines receive a stable position and the accepted quote writer records that position', () => {
  assert.match(catalogueAuthority, /add column if not exists line_number integer/);
  assert.match(catalogueAuthority, /quotation_lines_order_unique/);
  assert.match(catalogueAuthority, /quotation_id,line_number,catalogue_item_id/);
  assert.match(catalogueAuthority, /values\(v_business,v_quote,v_line_count,v_item/);
});

test('one accepted quotation can be invoiced only once and repeated requests return the existing invoice', () => {
  assert.ok(invoiceFunction);
  assert.match(conversion, /create unique index if not exists sales_invoices_one_per_quotation/);
  assert.match(invoiceFunction, /where quotation_id=q\.id and business_id=q\.business_id for update/);
  assert.match(invoiceFunction, /'already_converted',true/);
  assert.match(invoiceFunction, /q\.status<>'accepted'/);
  assert.match(invoiceFunction, /Only fully accepted quotations/);
});

test('invoice conversion copies every quotation line and its exact financial and costing snapshot', () => {
  assert.match(invoiceFunction, /insert into public\.sales_invoice_items/);
  assert.match(invoiceFunction, /l\.description,l\.quantity,l\.unit_price,l\.line_total,l\.direct_cost/);
  assert.match(invoiceFunction, /coalesce\(l\.details->'cost_snapshot','\{\}'::jsonb\)/);
  assert.match(invoiceFunction, /order by l\.line_number nulls last,l\.id/);
  assert.match(invoiceFunction, /count\(\*\),coalesce\(sum\(line_total\),0\)/);
  assert.match(invoiceFunction, /Quotation line totals do not match/);
});

test('invoice conversion preserves deposit payment records, allocations and invoice balances', () => {
  assert.match(invoiceFunction, /from public\.quotation_deposits/);
  assert.match(invoiceFunction, /insert into public\.payments/);
  assert.match(invoiceFunction, /'QD-'\|\|v_deposit\.deposit_number/);
  assert.match(invoiceFunction, /insert into public\.payment_allocations/);
  assert.match(invoiceFunction, /amount_paid,balance/);
  assert.match(invoiceFunction, /deposits_applied/);
});

test('invoice conversion does not create a production job or alter the costing and customer workflows', () => {
  assert.doesNotMatch(invoiceFunction, /insert into public\.production_jobs/);
  assert.match(invoiceFunction, /customer_id/);
  assert.match(invoiceFunction, /quotation\.invoiced/);
  assert.match(conversion, /revoke all on function public\.owner_convert_quote_to_invoice\(uuid,text,text,date\) from public,anon,authenticated/);
});

test('production job creation is a separate owner-authorized and idempotent action linked to the invoice', () => {
  assert.ok(jobFunction);
  assert.match(jobFunction, /role='owner'/);
  assert.match(jobFunction, /q\.status<>'converted'/);
  assert.match(jobFunction, /Create the invoice before creating its production job/);
  assert.match(jobFunction, /where quotation_id=q\.id and business_id=q\.business_id for update/);
  assert.match(jobFunction, /insert into public\.production_jobs/);
  assert.match(jobFunction, /business_id,invoice_id,quotation_id,customer_id,job_number/);
  assert.match(jobFunction, /production_job\.created/);
});

test('the legacy combined invoice-and-job RPC is revoked and only the two split owner RPCs are granted', () => {
  assert.match(conversion, /revoke all on function public\.owner_convert_quote_to_invoice\(uuid,text,text,date\) from public,anon,authenticated/);
  assert.match(conversion, /grant execute on function public\.owner_convert_accepted_quote_to_invoice\(uuid,text,date\) to authenticated/);
  assert.match(conversion, /grant execute on function public\.owner_create_production_job_from_quote\(uuid,text,date\) to authenticated/);
});

test('Sales UI resolves invoices directly from quotations and presents a separate production-job action', () => {
  assert.match(operations, /quotation_id,status,total,amount_paid,balance,customer_id,due_date/);
  assert.match(operations, /invoices\.find\(i=>i\.quotation_id===q\.id\)/);
  assert.match(operations, /owner_convert_accepted_quote_to_invoice/);
  assert.match(operations, /owner_create_production_job_from_quote/);
  assert.match(operations, /Create invoice/);
  assert.match(operations, /Create production job/);
  assert.doesNotMatch(operations, /Create invoice \+ job/);
});
