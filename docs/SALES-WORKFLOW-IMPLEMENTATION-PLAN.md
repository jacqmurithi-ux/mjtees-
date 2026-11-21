# MJ Printing & Branding — Connected Sales Workflow Implementation Plan

**Target branch:** `main`  
**Working branch:** `plan/connected-counter-sales`  
**Scope:** Sales counter, stock consumption, corporate order handoff, payment integrity, reorder alerts and daily closing.  
**Release boundary:** GitHub Pages only. No Vercel. No production database migration or deployment is authorised by this plan.

## 1. Guiding rule

One sale creates one accurate financial record and every stock record that is actually required for the items MJ supplied. The invoice, payment allocation and applicable stock movements must succeed or fail together.

The system must not invent consumption quantities, stock balances, supplier costs or payments. Customer-supplied materials are not MJ stock. Outsourced DTF remains an outsourced direct cost, not an in-house printer cost.

## 2. Current-main audit

Reviewed current `src/Operations.tsx`, `src/VinylStickerCalculator.tsx`, the Quick Sale / vinyl / custom-job / apparel SQL migrations, and the existing Node test contracts.

### Confirmed gaps and existing capabilities

- `owner_create_quick_sale` creates the invoice, invoice line, optional payment and payment allocation, but its own migration explicitly says it does not issue stock. The current `tests/quick-sales.test.mjs` asserts the absence of stock movements in this function.
- The general Quick Sale UI routes an MJ-supplied, no-production-method apparel sale with an exact selected variant through `owner_create_apparel_quick_sale`. That dedicated path must be preserved.
- The dedicated Vinyl Calculator calls `owner_create_vinyl_sticker_quick_sale`; the stock-consumption migration locks the selected vinyl stock row, calculates metres from area and roll dimensions, rejects insufficient stock, and records the stock movement in the same database transaction as the sale.
- The generic custom-job bundle RPC combines its custom-job line and optional catalogue add-on lines into one invoice/payment transaction. It reuses the generic catalogue sale RPC for add-ons. That means stock behaviour cannot be fixed only in the custom-job wrapper; each line's canonical stock path must be correct.
- Corporate quotation acceptance already has a dedicated evidence workflow. Accepted quote conversion and production-job creation are separate owner RPCs. Do not add a second acceptance step or silently merge these workflows without a tested transaction contract.
- Apparel variant inventory and its reservation/issue flow already exist. Preserve exact variant selection, reservations for branded production jobs, and issue-on-production behaviour.
- The current standard Quick Sale is a multi-field operational form, not yet a three-action counter experience. Advanced pricing/cost controls should remain available when required, but not dominate the common walk-in path.

## 3. Target user experience

### Sales home / counter workspace

Make **Quick Sale** the primary action. Keep Quotations, Invoices and Production handoff available as secondary actions.

Common walk-in flow:
1. Tap a favourite or search/select an active catalogue item.
2. Enter quantity and, only where needed, size/dimensions or exact apparel variant.
3. Tap **Cash**, **M-Pesa**, or **Unpaid**. The choice submits the sale; no separate Save button for the normal path.

Defaults:
- Walk-in Customer when no customer is selected.
- Nairobi-local current date and the existing invoice numbering convention.
- Approved catalogue price, active preferred production method and quantity 1.
- Cash as the safe default payment method; last-used method may be remembered only as a convenience and must remain visible/editable.
- M-Pesa is a payment-method selection, not proof that funds arrived. Record a payment only when staff confirms receipt or a trusted payment integration verifies it.
- Favourites are shortcuts to existing active catalogue items; they do not create new prices or costing rules.

Keep exceptional pricing, below-floor authorisation, customer-supplied materials, custom dimensions and detailed costing in an expandable **More details** area. Preserve the minimum 30% gross-margin floor; an exception still requires an authorised approver and a reason of at least the existing required length. The 1.8× full-cost target remains a warning, not a hard floor.

## 4. Prioritised implementation stages

### Stage 0 — Baseline and safety (no production writes)

- Reconfirm the latest `main` SHA and all current Quick Sale RPC signatures before coding.
- Map each supported sale line to its canonical invoice, payment and stock RPC.
- Inspect live schema/migration history, constraints, RLS, grants, triggers and RPC return shapes before proposing SQL.
- Capture the current test baseline and preserve existing apparel, DTF, refund and pricing contracts.
- Do not backfill or adjust historic invoices or stock balances.

**Exit:** written RPC/stock mapping and passing baseline tests.

### Stage 1 — Close the Quick Sale / stock gap (highest priority)

- Preserve the existing apparel-variant quick-sale RPC for MJ-supplied direct apparel sales.
- Route vinyl sticker sales through the existing stock-consuming vinyl RPC, including sales started from the Sales counter. Avoid a second vinyl calculation or a second stock movement.
- For other catalogue items, inspect whether an approved, versioned material-usage recipe already exists. If it does, use that canonical data. If it does not, do not infer consumption from costing-profile money components or invent quantities. Prepare a separate proposed recipe schema and obtain approval for the exact migration and initial recipe values.
- Customer-supplied goods/materials must not decrement MJ stock.
- Keep branded apparel and larger/corporate work on production reservations and material issue; do not consume reserved stock a second time at invoice creation.
- For every path, ensure invoice + payment/allocation + applicable stock movement + audit event are one database transaction. Stock shortage or validation failure must leave no orphan invoice/payment.
- Add idempotency protection for repeat submissions so a double tap or network retry cannot create duplicate invoices, payments or stock movements.

**Exit:** tested walk-in cases for vinyl, apparel, customer-supplied items, non-stock services and insufficient stock; ledger quantities reconcile exactly.

### Stage 2 — Three-action counter UI

- Rework the Sales Quick Sale panel around item favourites/search, quantity/size, and Cash/M-Pesa/Unpaid submit actions.
- Show only fields needed for the selected product. Reveal custom pricing/costing and exception controls only when needed.
- Default to Walk-in Customer and approved prices; keep price edits reason-gated as today.
- Retain a clear success receipt with invoice number, total, amount received and balance.
- Disable the submit action while saving and use an idempotency key for retries.
- Keep an accessible full form for complex one-off custom jobs; do not force corporate work into the counter flow.

**Exit:** ordinary catalogue sale can be completed in under 15 seconds in a seeded test scenario without bypassing price or stock controls.

### Stage 3 — Corporate quotation to production handoff

- Retain quotation preparation, customer acceptance evidence, positive deposit recording, invoice conversion, and production-job creation as distinct domain steps.
- Remove duplicate data entry through a clear **Confirm Order** handoff that reuses existing accepted-quote and invoice/job RPCs, or a new transactional orchestration RPC only if the schema audit proves it is needed.
- Do not record the deposit twice. Allocate the existing deposit once to the converted invoice.
- Preserve line-level pricing/cost snapshots, acceptance evidence, revision history and 30% margin policy.
- Create a production job only for orders that need production; no job is required for a normal walk-in sale.

**Exit:** accepted corporate quote with positive deposit converts once; invoice balance equals total less allocated payments; one linked production job is created when required; retry is idempotent.

### Stage 4 — Payment integrity and receivables

- Verify positive-only deposit and payment constraints in the authoritative database RPCs, not only HTML input validation. Reject zero and negative deposits/payments; a zero deposit is no payment record.
- Reconcile any reported invoice by reading invoice total, amount_paid, payment rows and payment allocations. Never fix a discrepancy by manually editing totals.
- Derive overdue as **balance > 0 and due_date earlier than the current Africa/Nairobi date**. Due today is not overdue.
- Display Paid, Partially paid, Unpaid, Due today and Overdue using the canonical balance.
- Keep refunds separate. Do not add payment reversal functionality.

**Exit:** zero deposit rejected at the database boundary; partial payments and deposit allocations reconcile; overdue status changes by date without mutating financial records.

### Stage 5 — Reorder alerts and one-tap daily closing

- Show low-stock/reorder alerts by stock item and location, using existing `reorder_level` values.
- Review vinyl reorder levels against actual usage and supplier lead time. Do not apply guessed thresholds as production stock settings.
- For inks and other consumables, configure reorder points only after usage data or owner-approved quantities exist.
- Daily close summary must distinguish:
  - invoices issued today;
  - cash payments actually received today;
  - M-Pesa payments actually received today;
  - unpaid/outstanding balances on today's invoices;
  - deposits and later payments received today (separate from invoice totals);
  - materials consumed today;
  - low-stock items and location;
  - reconciliation/failed-payment warnings.
- Use payment received timestamps and methods for cash/M-Pesa totals, not invoice totals or invoice `amount_paid` alone. Show older overdue receivables separately from today's unpaid sales.
- Daily close is a report/confirmation, not a journal adjustment or an artificial cash-balance mutation.

**Exit:** sample-day close reconciles exactly to invoice and payment/allocation ledgers and lists low-stock items without double-counting.

## 5. Non-negotiable business rules

- Minimum 30% gross margin on direct production cost. Below-floor exceptions require authorised approval and a recorded reason.
- 1.8× full-cost target is a warning only. No unapproved overhead allocation.
- Customer-supplied blanks/materials do not consume MJ stock.
- DTF printing is outsourced: use actual supplier printing charges, transport and other direct costs; allocate shared batch costs fairly. Never add in-house printer/ink/machine-running costs.
- No fabricated opening stock. Any opening quantity must be physically counted and entered through the approved opening-stock workflow.
- Reusable screens/plates are not consumed per job unless a real loss/damage event is recorded.
- Owner-first workflow. Staff delegation remains optional and permission-limited.
- No payment reversal feature. Refunds remain separate.
- GitHub Pages only; no Vercel.

## 6. Required test matrix

| Scenario | Expected result |
|---|---|
| KSh 100 cash catalogue sale | One invoice, one cash payment/allocation, correct applicable stock movement |
| KSh 200 M-Pesa sale | One invoice; payment only after receipt is confirmed; M-Pesa method/reference retained |
| Unpaid walk-in sale | One invoice, zero payment rows, full balance outstanding |
| Vinyl sticker sale (MJ supplies) | Correct metre usage and one vinyl stock movement in the same transaction |
| Vinyl sticker sale (customer supplies) | No MJ vinyl stock movement |
| Apparel direct sale | Exact selected size/colour variant decremented once |
| Branded apparel order | Variant reserved, then issued through production; no double deduction |
| Screen print / other consumable sale | Deduct only from an owner-approved usage recipe; otherwise block automatic deduction and request configuration |
| Insufficient stock | Sale rejected atomically; no invoice/payment/stock partial writes |
| Double tap / retry | Same result returned or duplicate prevented; no duplicate ledger rows |
| Accepted corporate quote + deposit | Deposit allocated once; invoice balance correct; production job linked when required |
| Zero/negative deposit | Rejected by database RPC |
| Overdue invoice | Overdue only when positive balance and due date is before Nairobi today |
| End-of-day close | Invoice, payment-method and stock totals reconcile to source ledgers |

## 7. Approval and release gates

This plan does not authorise a production migration or production deployment.

Before any database migration is run, present:
1. the exact migration filename and full SQL;
2. affected tables, constraints, indexes, RLS policies, grants, triggers and RPC signatures;
3. compatibility/rollback considerations;
4. tests and evidence from a disposable/local database;
5. explicit approval to run that named migration.

Code changes should be developed on a feature branch, tested with `npm test` and `npm run build`, and reviewed in a pull request. Merge/deploy only after the user explicitly authorises that release step. GitHub Pages remains the only deployment target.
