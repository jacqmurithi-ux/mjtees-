# MJ Tees — database and security design (review draft)

**Status: design only. Not a migration. Not deployed.**  
Project: `rbbluwsniiwzixlvdnwz` · Repository branch: `first-release-build`

This document defines the first connected business workflow: customer → quotation → accepted order → cash/M-Pesa payments → allocations → receipt → outstanding balance. It is deliberately a reviewable design, not executable SQL. No database objects, accounts, payment records or customer data have been created.

## 1. Design principles

1. One MJ Tees business and one physical shop in the first release. Inventory storage areas can be distinguished (e.g. apparel/vinyl and inks/screens/emulsion) without pretending they are separate branches.
2. The application is one system: public service catalogue and enquiry intake feed the same customer, quote and order records used by the owner workspace.
3. PostgreSQL is the source of truth. The browser never calculates or writes authoritative balances, stock totals, payment allocations or order totals.
4. Store money as integer Kenyan shillings (KES) for this first release; do not use floating point. Persist currency explicitly on financial records even though the first shop currency is KES.
5. Keep an immutable financial and stock movement history. Corrections are reversals/adjustments with a reason, never silent edits or deletes.
6. The customer may supply the item to be printed. Such items are marked customer-supplied and must not be counted as MJ Tees stock or purchases.
7. Artwork binaries remain in Google Drive. The system stores Drive references, version details, approval state and audit history only.
8. Category-specific pricing/costing supports screen printing, sublimation, vinyl, stickers, outsourced DTF and future categories. No single global margin is imposed.
9. Payment recording and payment-provider integration are separate. First release records cash and manually verified M-Pesa transactions. Daraja automation is later.
10. Owner-only financial administration in the first release. Staff roles can be added later without weakening the data model.

## 2. Core relationships

```text
auth.users
  └── user_profiles ── business_memberships ── business
                                              ├── customers
                                              ├── quotations ── quotation_items
                                              │       └── accepted → orders ── order_items
                                              │                             ├── order_events
                                              │                             ├── artwork_references
                                              │                             └── payments
                                              │                                    └── payment_allocations
                                              │                                           └── receipts
                                              └── audit_events
```

A payment can be allocated to one or more orders in the future; for the initial workflow it will normally be allocated to one order. The allocation table remains separate so partial payments, split payments and later customer-account workflows do not require a redesign.

## 3. Proposed tables and responsibilities

All business tables carry `business_id` even though there is one business initially. Use UUID primary keys, `created_at`, and where appropriate `created_by`. Use foreign keys with deliberate delete behaviour; financial and operational history should generally be restricted from deletion.

### Identity and business boundary

- **businesses** — business name, trading name, currency (KES), timezone (Africa/Nairobi), contact details and active status.
- **user_profiles** — authenticated user identity and display name; keyed to `auth.users.id`. No client-editable role field.
- **business_memberships** — user, business, status and role. Initial role: owner. Later roles can be introduced through a permission matrix. The owner membership is provisioned by a trusted administrative process, not public signup metadata.
- **audit_events** — actor, business, action, entity type/id, timestamp, request/correlation id, and structured before/after metadata where safe. Never store passwords, access tokens or full payment credentials.

### Customers and quotations

- **customers** — display name, phone, optional email, optional business name, notes, created/updated timestamps and archive status. Phone is stored in normalized form for searching but should not be assumed globally unique (families and organisations can share a contact).
- **customer_addresses** — optional delivery address, locality, recipient and contact phone. Keep address data only when needed for delivery.
- **service_categories** — configurable service grouping and costing basis (e.g. screen printing, sublimation, vinyl branding, stickers, outsourced DTF).
- **catalogue_items** — public-facing products/services, type, description, category, active flag, optional public starting price and display order. A public starting price is indicative and never silently becomes a confirmed quote.
- **pricing_rules** — category/item-level costing and markup configuration, effective dates and owner audit. Store cost basis and markup method explicitly. The quote line snapshots the final agreed price so later rule changes do not rewrite historical quotes.
- **quotations** — business, sequential human-readable quote number, customer, status (draft/sent/accepted/declined/expired/converted), issue/expiry dates, currency, subtotal, discount, tax (only if configured), total, notes and creator. Totals are server-calculated.
- **quotation_items** — quote, description snapshot, category/item reference (nullable for custom work), quantity, unit, unit price, line discount, line total, production notes, customer-supplied-item flag and pricing/cost snapshot. Quantity and money values must be validated server-side.
- **quotation_events** — append-only sent/viewed/accepted/declined/expired/revised/conversion events, actor/source, timestamp and reason. Customer acceptance from a public link must use an unguessable, expiring token stored hashed, with narrowly scoped access; do not expose owner data through that link.
- Quote revisions should create a new revision/snapshot or a new quote linked to its predecessor. Never mutate an already accepted quote in a way that changes the accepted commercial terms.

### Orders and payments

- **orders** — business, order number, source quotation (nullable for direct orders), customer, status, currency, subtotal/discount/tax/total snapshots, required-by date, promised turnaround, received date, notes, creator. Order total is frozen from the accepted quote unless an owner-authorized change is recorded as an order amendment.
- **order_items** — line snapshots copied from accepted quote; quantity, description, agreed price, category, customer-supplied item flag, and production specification. Changes after acceptance create a dated amendment event.
- **order_events** — append-only lifecycle events: created, confirmed, in production, quality checked, ready, collected/delivered, cancelled, payment exception approved. Record actor, time, status transition and reason.
- **payments** — business, payment reference, payment date/time, method (cash or mpesa_manual initially), amount, currency, payer details where useful, M-Pesa transaction code where applicable, receiving user, verification/reconciliation status and notes. A manually entered M-Pesa record is not labelled provider-confirmed. A unique normalized M-Pesa transaction reference prevents duplicate entry where a reference exists.
- **payment_allocations** — payment, order, amount allocated, created timestamp and actor. Enforce positive allocation and prevent total allocations from exceeding the payment amount or order's payable amount; enforce this transactionally in trusted database code.
- **receipts** — receipt number, payment, issued timestamp, amount/currency snapshot, customer snapshot and issuer. Receipt is generated only after a payment is successfully recorded. Reprints preserve the original receipt identity and are logged.
- **payment_events** — append-only verification, reconciliation, reversal and refund events. Do not overwrite original payment facts to hide a correction.
- **order_balance view/function** — derives paid amount from valid allocations and outstanding balance from frozen order total less net allocated payments/refunds. It is read-only and must not become a writable balance column maintained by the browser.

### Operational tables retained in the model

- **inventory_locations** — logical storage areas within the one shop, not branches.
- **stock_items** and **stock_variants** — materials/products, SKU, unit, size/colour, category and reorder settings.
- **stock_movements** — append-only receipts, issues, reservations, releases, adjustments, waste and returns; every adjustment has a reason and actor. On-hand quantity is derived from movements.
- **suppliers**, **purchase_orders**, **purchase_order_items**, **goods_receipts** — supplier purchasing and receiving. Receiving goods is a separate event from creating an order for a customer.
- **artwork_references** — order/item, Google Drive URL or file ID, filename, version, uploaded-by/source, approval status, approved-by and timestamps. Validate permitted Drive URL patterns; do not treat the link as authorization.
- **production_jobs**, **production_tasks**, **quality_checks**, **rework_events** — stages, assignments, due/started/completed times, inspection outcome, defect notes and rework. Record whether QC was performed by a second person or self-inspected.
- **expenses** — owner-created expense, category, amount/currency, date, payee, receipt reference and notes. RLS and server checks enforce owner-only create/edit in release one.
- **deliveries** — collection/delivery method, carrier, parcel tracking reference, customer-paid delivery charge and handover time. Parcel-carrier charge is paid by customer and must be separately represented, not silently included in production revenue.
- **owner_approvals** — explicit approvals for financial exceptions, discounts beyond configured limits, payment overrides and release of goods before full payment. Include reason, actor and timestamp.

## 4. Payment and balance rules

1. A quote is not a payment request and an enquiry is not an order.
2. An order is created only from an accepted quote or an explicitly recorded owner-created direct order.
3. Record each receipt of money as its own payment. Deposits and instalments are multiple payment rows, not overwritten paid-to-date figures.
4. Allocate payments to orders through payment_allocations. The database transaction validates allocation amounts and prevents over-allocation.
5. Outstanding balance is derived: `order_total - net_allocated_payments`. A refund/reversal is represented by a separate event/record and correctly reduces net paid.
6. A receipt is issued for the payment amount received, not for the whole order value unless the whole amount was received.
7. Cash and manual M-Pesa are distinct methods. For M-Pesa, store transaction code and mark it pending verification until checked. Do not claim automatic confirmation before Daraja is implemented.
8. Full payment is required before collection or dispatch. Any exception requires a recorded owner approval with reason; the handover action checks this rule on the server.
9. Never accept amount, order total, allocation status, receipt number, owner role or payment verification status as trusted values from the browser.
10. Use idempotency/request IDs for payment submission so a retry cannot create duplicate money records. M-Pesa transaction references should be unique per business after normalization where present.

## 5. Security model

### Authentication and authorization

- Supabase Auth authenticates users. The first owner is created/invited through a trusted setup flow.
- Authorization comes from `business_memberships` and server-checked permissions, never from editable `user_metadata`, local storage, route visibility or a role value supplied by the client.
- Public visitors can read only active public catalogue content and submit a constrained enquiry. They cannot query customers, quotes, orders, payments, receipts, inventory or expenses.
- Owner can access all business operations in release one. Expense create/update and all financial exception approvals are owner-only.
- Later staff roles will be least-privilege: for example production staff can see assigned production details without seeing customer financial records. Do not grant this in release one by assumption.

### Row-level security and grants

- Enable RLS on every table in exposed schemas.
- Grant only the minimum table privileges required. RLS is not a substitute for grants and grants are not a substitute for RLS.
- Policies scope every private row to the authenticated user's active business membership. Do not use a generic `TO authenticated` policy without an ownership/business predicate.
- Public catalogue reads are limited to active, published rows. Public enquiry submission should go through a narrow RPC/Edge Function with validation and abuse controls, not unrestricted INSERT on customer/order tables.
- Financial and ledger tables: authenticated owner read access as required; no direct browser INSERT/UPDATE/DELETE. Mutations use narrowly scoped transactional database functions or trusted Edge Functions after checking the caller's active membership and permission.
- Avoid `SECURITY DEFINER` unless a specific privilege boundary requires it. Any such function must live outside exposed schemas, pin a safe `search_path`, explicitly validate `auth.uid()` and permissions, and have EXECUTE revoked from PUBLIC/anon unless explicitly required.
- Any views exposed through the API must use `security_invoker = true` where supported, or be placed in a non-exposed schema/revoked from client roles.
- No service-role key, database password or secret key in GitHub Pages/browser code. Only the publishable/anon key may be present in public client code, protected by RLS.
- Keep audit records for changes to customer contact details, quotes, order amendments, payments, allocations, receipts, expenses, stock and approvals.

### Required transactional operations

Implement as atomic server-side operations, not sequences of client writes:

- `create_quote` / `revise_quote`: validate customer and lines; calculate totals; snapshot pricing.
- `accept_quote_and_create_order`: validate acceptance token or owner action; prevent duplicate conversion; create order and copied item snapshots in one transaction.
- `record_payment_and_allocate`: validate owner permission, amount, method, idempotency key and M-Pesa reference; create payment, allocation, receipt and audit event atomically.
- `reverse_payment` / `record_refund`: append correction and recompute derived balance; never delete the original payment.
- `approve_payment_exception`: record owner reason and approval; handover function must check this record.
- `handover_order`: reject if net paid is below amount due and no valid owner exception exists; append order event atomically.

Function names are design labels, not deployed RPCs. Exact parameter and return contracts must be specified and tested before implementation.

## 6. Data integrity and validation

- Foreign keys must include business boundaries where practical, so a quote/customer/order/payment cannot be joined across businesses.
- Monetary columns use integer minor units or integer KES consistently; choose one representation before SQL. For KES-only release one, integer KES is simplest; if fractional currency is needed later, migrate deliberately.
- Positive quantities and payment amounts; nonnegative discounts/tax; valid status CHECK constraints; unique business-scoped quote/order/receipt numbers.
- Enforce unique payment idempotency keys and unique normalized M-Pesa references (nullable for cash).
- Use database transactions and row locks when allocating money or converting a quote to an order to prevent concurrent over-allocation or duplicate conversion.
- Soft-archive customers/catalogue items; do not cascade-delete financial history.
- Store timestamps as `timestamptz`; render in Africa/Nairobi.
- Do not store card data, M-Pesa PINs, passwords, or unnecessary identity documents.

## 7. Build sequence after design review

1. Finalise table columns, enums/status transitions, constraints, RPC contracts and RLS policy matrix.
2. Implement Auth, owner membership provisioning and session controls.
3. Implement customer CRUD and public enquiry intake.
4. Implement category/service catalogue and quote builder with price snapshots and quote revision/acceptance.
5. Implement order conversion and order lifecycle.
6. Implement cash/manual M-Pesa payment capture, allocations, receipts, balance view and owner exception workflow.
7. Connect the owner dashboard to real records; remove preview-only values/states.
8. Add automated tests for permissions, duplicate requests, concurrent allocations, quote conversion, receipt correctness and payment-gated handover.

## 8. Approval boundary

This draft does not authorize a migration, production SQL execution, deployment, PR merge or real customer/payment data entry. Those remain separate steps. Before the first migration, the final SQL, RLS policies, RPC definitions and test plan must be reviewed together and explicitly approved.
