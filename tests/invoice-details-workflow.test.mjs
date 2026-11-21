import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const operations = await readFile(new URL('../src/Operations.tsx', import.meta.url), 'utf8');

test('Quick Sale requires an explicitly selected customer and offers inline customer creation', () => {
  assert.match(operations, /Customer \*/);
  assert.match(operations, /Select a named customer or explicitly choose Walk-in customer/);
  assert.match(operations, /Use walk-in customer/);
  assert.match(operations, /async function createQuickCustomer/);
  assert.match(operations, /Contact person \(optional\)/);
  assert.match(operations, /Address \(optional\)/);
  assert.match(operations, /notes,created_by:user.id/);
  assert.match(operations, /p_customer_id:quickCustomerId/);
});

test('Sales history can search invoice number, customer name and phone and filter payment status', () => {
  assert.match(operations, /Search invoice, customer or phone/);
  assert.match(operations, /salesSearchMatches/);
  assert.match(operations, /Partially paid/);
  assert.match(operations, /filteredSalesInvoices=invoices\.filter\(i=>salesDateMatches\(i\)&&salesSearchMatches\(i\)&&salesStatusMatches\(i\)\)/);
});

test('Invoice details use existing invoice, allocation, payment and production records', () => {
  assert.match(operations, /async function openInvoiceDetails/);
  assert.match(operations, /payment_allocations/);
  assert.match(operations, /payment:payments\(id,payment_number,method,amount,reference_code,received_at\)/);
  assert.match(operations, /Production & stock/);
  assert.match(operations, /production_job_materials/);
  assert.match(operations, /Original quotation/);
  assert.match(operations, /Activity history/);
});

test('Quotation documents are printable and accepted quotes pass through a final conversion review', () => {
  assert.match(operations, /Quotation document/);
  assert.match(operations, /Print \/ save PDF/);
  assert.match(operations, /Final review/);
  assert.match(operations, /owner_convert_accepted_quote_to_invoice/);
  assert.match(operations, /Open existing invoice/);
  assert.match(operations, /Confirm and create invoice/);
});

test('Invoice payment receipts are reprints of saved payments and do not create payment records', () => {
  assert.match(operations, /PAYMENT RECEIPT/);
  assert.match(operations, /View receipt/);
  assert.match(operations, /Print receipt/);
  assert.doesNotMatch(operations, /payment_reversal|reverse_payment|reversal/i);
});

test('M-Pesa Paybill references are required before payment and deposit recording', () => {
  assert.match(operations, /paymentMethod==='mpesa_paybill'&&!paymentRef\.trim\(\)/);
  assert.match(operations, /depositMethod==='mpesa_paybill'&&!depositRef\.trim\(\)/);
  assert.match(operations, /quickPaymentMethod==='mpesa_paybill'&&!quickPaymentReference\.trim\(\)/);
});
