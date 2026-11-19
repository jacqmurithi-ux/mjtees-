import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const sql = readFileSync(new URL("../supabase/migrations/20261119000400_sales_foundation_schema.sql", import.meta.url), "utf8");
const manualPaymentsSql = readFileSync(new URL("../supabase/migrations/20261119000600_sales_manual_payment_ledger.sql", import.meta.url), "utf8");
const salesCreditSql = readFileSync(new URL("../supabase/migrations/20261119000700_sales_customer_credit_application.sql", import.meta.url), "utf8");
const paymentPolicySql = readFileSync(new URL("../supabase/migrations/20261119092752_sales_manual_payment_method_restrictions.sql", import.meta.url), "utf8");
const creditNoteSql = readFileSync(new URL("../supabase/migrations/20261119093825_sales_credit_note_issue_workflow.sql", import.meta.url), "utf8");

test("Sales foundation reuses existing customer, quotation, order, payment, stock and production records", () => {
  assert.match(sql, /alter table public\.customers[\s\S]*sales_price_tier_id/);
  assert.match(sql, /alter table public\.quotations[\s\S]*deposit_required_amount/);
  assert.match(sql, /references public\.orders\(business_id,id\)/);
  assert.match(sql, /references public\.payments\(business_id,id\)/);
  assert.match(sql, /references public\.production_jobs\(business_id,id\)/);
  assert.match(sql, /references public\.stock_items\(business_id,id\)/);
});

test("Invoice and credit records retain tenant-scoped relationships and KES-only totals", () => {
  assert.match(sql, /sales_invoices_order_fk/);
  assert.match(sql, /sales_invoices_business_number_key/);
  assert.match(sql, /sales_invoice_items_business_invoice_fk/);
  assert.match(sql, /sales_credit_notes_invoice_fk/);
  assert.match(sql, /currency_code char\(3\) not null default 'KES' check \(currency_code='KES'\)/);
  assert.doesNotMatch(sql, /\bvat_(rate|amount|inclusive)\b|tax_(rate|amount)/i);
});

test("Payment UI offers only cash and M-Pesa Paybill for new manual entries", () => {
  const ui = readFileSync(new URL("../src/PaymentWorkflow.tsx", import.meta.url), "utf8");
  assert.match(ui, /<option value=\"cash\">Cash<\/option><option value=\"mpesa_manual\">M-Pesa Paybill<\/option>/);
  assert.doesNotMatch(ui, /<option value=\"bank_transfer\"|<option value=\"cheque\"/);
});

test("Payments retain legacy methods in the database until safely migrated", () => {
  assert.match(sql, /method in \('cash','mpesa_manual','bank_transfer','cheque'\)/); // Legacy rows remain readable; new-entry restriction is covered by the follow-up migration.
  assert.match(sql, /external_reference/);
});

test("Financial allocations and customer credit are idempotent append-only ledgers", () => {
  assert.match(manualPaymentsSql, /sales_invoice_payment_allocations_request_invoice_unique/);
  assert.match(sql, /sales_customer_credit_request_unique/);
  assert.match(sql, /before update or delete on public\.sales_invoice_payment_allocations/);
  assert.match(sql, /before update or delete on public\.sales_customer_credit_entries/);
});

test("New Sales tables are RLS-enabled, owner-readable and not directly writable by clients", () => {
  assert.match(sql, /alter table public\.%I enable row level security/);
  assert.match(sql, /revoke all on table public\.%I from anon,\s*authenticated,\s*public/);
  assert.match(sql, /private\.is_active_owner\(business_id\)/);
  assert.doesNotMatch(sql, /grant (insert|update|delete|all) on table public\.sales_/i);
});

test("Production job artwork and team size breakdowns are linked to existing jobs", () => {
  assert.match(sql, /sales_job_size_breakdown/);
  assert.match(sql, /sales_job_artworks/);
  assert.match(sql, /sales_job_colour_separations/);
  assert.match(sql, /sales_job_artworks_contact_fk/);
});

test("Issued invoice and credit note records cannot be deleted or have their lines rewritten", () => {
  assert.match(sql, /sales_invoices_retain_finalised/);
  assert.match(sql, /sales_credit_notes_retain_finalised/);
  assert.match(sql, /Issued invoice lines are immutable/);
  assert.match(sql, /Issued credit note lines are immutable/);
});

test("Issued invoice and credit note lines reject inserts as well as edits and deletion", () => {
  assert.match(sql, /before insert or update or delete on public.sales_invoice_items/);
  assert.match(sql, /before insert or update or delete on public.sales_credit_note_items/);
});

test("Decoration pricing supports design setup, colours, print locations and quantity breaks", () => {
  assert.match(sql, /sales_decoration_price_rules/);
  assert.match(sql, /setup_per_design/);
  assert.match(sql, /per_colour/);
  assert.match(sql, /per_location/);
  assert.match(sql, /quantity_break/);
});

test("Quotes and invoices preserve the selected customer contact and pricing tier", () => {
  assert.match(sql, /quotations_sales_price_tier_fk/);
  assert.match(sql, /quotations_customer_contact_fk/);
  assert.match(sql, /sales_invoices_sales_price_tier_fk/);
  assert.match(sql, /sales_invoices_customer_contact_fk/);
  assert.match(sql, /sales_invoices_business_order_key/);
});

test("Sales tables grant authenticated owner reads while keeping client writes revoked", () => {
  assert.match(sql, /grant select on table public\.%I to authenticated/);
  assert.match(sql, /revoke all on table public\.%I from anon,authenticated,public/);
  assert.match(sql, /private\.is_active_owner\(business_id\)/);
});


test("Sales payment entries are manual, posted immediately and linked to a receiving account", () => {
  assert.match(manualPaymentsSql, /create table public\.sales_payment_accounts/);
  assert.match(manualPaymentsSql, /add column receiving_account_id uuid/);
  assert.match(manualPaymentsSql, /create or replace function public\.owner_record_sales_payment/);
  assert.match(manualPaymentsSql, /'posted',p_amount,p_received_at/);
  assert.doesNotMatch(manualPaymentsSql, /pending_verification|owner_verify_mpesa_payment/);
  assert.match(manualPaymentsSql, /duplicate_reference_warning/);
  assert.match(manualPaymentsSql, /add column duplicate_reference_warning boolean not null default false/);
  assert.match(manualPaymentsSql, /sales_customer_credit_entries/);
});

test("Payment reconciliation is a manual append-only owner action", () => {
  assert.match(manualPaymentsSql, /create table public\.sales_payment_reconciliations/);
  assert.match(manualPaymentsSql, /create or replace function public\.owner_reconcile_sales_payment/);
  assert.match(manualPaymentsSql, /Payment reconciliation records are append-only/);
  assert.match(manualPaymentsSql, /sales\.payment_reconciled/);
  assert.match(manualPaymentsSql, /No gateway, callbacks, webhooks, automatic imports or automatic matching/);
});

test("Receiving accounts and reconciliation records use owner RLS and explicit RPC grants", () => {
  assert.match(manualPaymentsSql, /sales_payment_accounts_owner_read/);
  assert.match(manualPaymentsSql, /sales_payment_reconciliations_owner_read/);
  assert.match(manualPaymentsSql, /revoke all on table public\.sales_payment_accounts from public,anon,authenticated/);
  assert.match(manualPaymentsSql, /grant execute on function public\.owner_upsert_sales_payment_account[\s\S]*public\.owner_record_sales_payment/);
});


test("Customer credit can be applied without payment reversal functionality", () => {
  assert.match(salesCreditSql, /create or replace function public\.owner_apply_sales_customer_credit/);
  assert.doesNotMatch(salesCreditSql, /owner_reverse|payment_reversed|reversal|reversed/i);
  assert.doesNotMatch(readFileSync(new URL("../src/PaymentWorkflow.tsx", import.meta.url), "utf8"), /reverse payment|reverse legacy|owner_reverse_payment/i);
  assert.match(manualPaymentsSql, /entry_type='apply_to_invoice'/);
});

test("Invoice conversion sends the exact RPC stock-location argument", () => {
  const ui = readFileSync(new URL("../src/QuoteWorkflow.tsx", import.meta.url), "utf8");
  assert.match(ui, /p_stock_location_id:stockLocationId\|\|null/);
  assert.doesNotMatch(ui, /p_customer_contact_id/);
});


test("Database rejects new non-Cash and non-M-Pesa payments while preserving legacy rows", () => {
  assert.match(paymentPolicySql, /create trigger payments_sales_new_method_guard\s+before insert on public\.payments/);
  assert.match(paymentPolicySql, /new\.method not in \('cash','mpesa_manual'\)/);
  assert.match(paymentPolicySql, /create trigger sales_payment_accounts_new_method_guard\s+before insert or update of account_type on public\.sales_payment_accounts/);
  assert.match(paymentPolicySql, /new\.account_type not in \('cash','mpesa_paybill'\)/);
  assert.match(sql, /method in \('cash','mpesa_manual','bank_transfer','cheque'\)/);
  assert.match(manualPaymentsSql, /account_type in \('cash','mpesa_paybill','bank','cheque_clearing'\)/);
});


test("Credit note issuance preserves paid invoices and applies value to outstanding balances", () => {
  assert.match(creditNoteSql, /create or replace function public\.owner_issue_sales_credit_note/);
  assert.match(creditNoteSql, /v_customer_id,'credit_note',v_total/);
  assert.match(creditNoteSql, /v_customer_id,'apply_to_invoice',-v_apply_amount/);
  assert.match(creditNoteSql, /sales\.credit_note_issued/);
  assert.match(creditNoteSql, /private\.assert_active_owner/);
  assert.match(creditNoteSql, /private\.begin_idempotent_request/);
  assert.match(creditNoteSql, /v_requested_item_credit/);
  assert.match(creditNoteSql, /Combined credit note lines exceed the remaining value/);
  assert.doesNotMatch(creditNoteSql, /owner_reverse_payment|payment_reversed|reversal/i);
});
