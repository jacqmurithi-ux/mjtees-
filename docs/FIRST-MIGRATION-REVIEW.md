# First-release implementation review — MJ Printing & Branding

**Branch:** `first-release-build`  
**Review status:** backend review in progress; no live database execution authorised.  
**Current boundary:** migrations and tests have been exercised against a disposable local Supabase stack only.

## Scope and current evidence

The branch contains seven timestamped migrations covering the schema, owner RPCs, ledger and stock integrity, public enquiry intake, purchasing and reservations, costing and quotations, and payment reversal/discount allocation. The latest local validation completed successfully with 83 pgTAP assertions across six test files, plus the Edge Function type-check and application quality workflow.

That evidence establishes that the migrations apply and the tested database paths pass. It does not establish that the complete application is operational or production-ready.

## Review finding corrected in this pass

- **Value-added blank-stock consumption:** reservations included tracked stock items on value-added order lines, but the handover trigger consumed stock only for lines whose sale mode was `blank`. This left branded garments reserved but not deducted from stock. The trigger now consumes any tracked, non-customer-supplied stock item at handover, matching the reservation logic. A regression test covers a value-added garment order.
- **Inactive pricing-rule replacement:** the overlap check considered inactive historical pricing rules, preventing a new active rule from replacing them over the same effective period. The check now considers only active rules, with regression coverage.
- **First-owner bootstrap race:** the trusted bootstrap script previously checked for an existing owner without serializing concurrent operators. It now takes a transaction-scoped advisory lock before checking and creating the first business/owner.
- **Public landing route:** the app previously opened the owner preview by default. It now opens the public website first; the owner preview remains visibly marked as not live data.

## Remaining release-readiness work

1. Complete a further SQL/RPC review and expand concurrency tests for payment allocation/refund capacity, stock reservations, and first-owner provisioning.
2. Make first-owner bootstrap concurrency-safe before any hosted execution.
3. Deploy/configure the public enquiry Edge Function separately, including the allowed-origin, Turnstile, service-role, and rate-limit secrets. The migration alone does not deploy the function.
4. Build the real owner application: authentication, customer/enquiry workflow, quotes, orders, payments, stock/purchasing, production/QC, expenses, delivery, and reports. The current React dashboard is explicitly a preview with placeholder modules and no Supabase client.
5. Add environment configuration and deployment instructions, verify GitHub Pages routing/base path, and complete end-to-end browser tests.
6. Reconcile the roadmap and legacy design notes with the actual implementation.

## Explicitly not done

- No SQL has been applied to the linked hosted Supabase project.
- No owner account or business has been provisioned.
- No Supabase project settings or secrets have been changed.
- PR #1 remains open and unmerged.
- No GitHub Pages deployment has occurred.

A separate, explicit approval is required before hosted database execution. Approval to review or correct the branch is not approval to run migrations against the live project.
