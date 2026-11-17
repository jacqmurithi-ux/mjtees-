# First migration review — MJ Printing & Branding

**Branch:** `first-release-build`  
**Migration:** `supabase/migrations/20261117044844_first_release_schema.sql`  
**CLI:** Supabase CLI 3.2.0  
**Status:** schema foundation authored and locally validated; not approved for live application.

## What is in this migration

- KES-only business identity and owner membership tables, with no self-service owner assignment.
- Customer, enquiry, catalogue, pricing, quotation, order and immutable event/discount snapshot tables.
- Cash and manually entered M-Pesa payment records, allocations, allocation reversals, refunds, receipts and document counters.
- Inventory locations, variant-aware stock SKUs, weighted-average cost fields, stock movements/reservations/transfers, suppliers, purchase orders and goods receipts.
- Costing profiles/components, production jobs/issues/waste/offcut returns/cost entries, QC, rework, Drive artwork references, expenses, deliveries and owner approvals.
- RLS enabled on business tables. Owner reads are membership-scoped. Direct client writes are revoked.
- A restricted public catalogue projection. No public access to customer, enquiry, quote, order, payment, inventory or expense records.
- No tax fields or calculations.

## Validation completed

GitHub Actions used a disposable local Supabase stack, not the linked hosted project.

- Supabase CLI project configuration loaded.
- `supabase start` completed.
- `supabase db reset --local` applied the migration successfully.
- The disposable local stack was stopped.
- Frontend quality check passed separately.

Validation run: https://github.com/jacqmurithi-ux/mjtees-/actions/runs/44020869464

## Important implementation boundary

This migration is a **schema foundation**, not yet the complete operational backend. It deliberately does not pretend that the proposed RPC contracts are implemented. Before this can be considered a usable first release, the following remain to be built and tested:

1. Transactional owner RPCs for customer, quotation, quote acceptance/order conversion, order amendment, payment posting, M-Pesa verification, allocation reversal/refund, receipt reprint and payment-gated handover.
2. Inventory and purchasing RPCs for receipt, weighted-average cost update, reservation/release, atomic stock issue, stock transfer and adjustment.
3. Production RPCs and database-enforced reconciliation for issue/waste/offcut quantities, rework, QC and job finalisation.
4. Database-enforced shared refund/reversal capacity, payment reversal semantics, discount-allocation totals and paired stock-transfer movements.
5. One-time trusted owner provisioning operation after the intended Auth user is verified. The migration does not create a business or assign an owner.
6. Public enquiry ingress through an Edge Function with server-side validation, rate limiting and bot protection. No unrestricted anonymous table insert is granted.
7. Automated authorization, RLS, concurrency, idempotency, accounting and inventory tests.

Until these items are implemented and validated, the dashboard must not be connected to these tables as if the workflows were live.

## Safety boundary

- No SQL has been applied to the linked Supabase project.
- No owner account or business has been provisioned.
- No Supabase settings or live data have been changed.
- PR #1 remains open and unmerged.
- No website deployment has occurred.

The migration is ready for technical review as a first schema foundation only. A separate approval is required before any hosted database execution, PR merge or deployment.
