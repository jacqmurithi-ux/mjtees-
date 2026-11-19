# MJ Printing & Branding — clean replacement workspace

This is a clean replacement for the former MJ Printing & Branding application. The application uses React, TypeScript, Vite and Supabase. GitHub Pages is the only release target; production deployment is manual from the approved `main` branch.

## Approved business rules
- Owner-first: the owner can run every core workflow; delegation is optional and task-scoped.
- Currency KES; timezone Africa/Nairobi.
- Manual payments: Cash and M-Pesa Paybill only.
- VAT is disabled.
- 30% gross-margin floor on direct production cost.
- 1.8× full-cost target is a warning only; do not add unapproved overhead allocations.
- No payment reversals. Refunds are a separate audited workflow.
- Customer-owned garments are not MJ inventory.
- Shop 1: apparel, vinyl and stickers.
- Shop 2: inks, screens, emulsion and printing consumables.

## Quote pricing
- Revenue = unit price × quantity.
- Direct cost = blank cost per piece × quantity + other direct costs.
- Contribution = revenue − direct cost.
- Margin = contribution ÷ direct cost.
- The 30% floor is checked against direct cost; a written owner exception is required below the floor.
- The 1.8× full-cost target is a warning only.

## Owner workflows
- Supplier balances are calculated from non-cancelled purchase orders and append-only supplier payments; supplier payments cannot exceed the outstanding balance.
- Supplier price alerts compare the two latest purchase prices for the same supplier and stock item; reviewed alerts retain an audit record.
- Deposits are recorded against sent or accepted quotations and allocated to the invoice when the accepted quote is converted.
- Refund requests are recorded separately and can be posted without changing or reversing the original payment.
- Inventory adjustments require a reason and create a stock movement plus an adjustment audit record.
- Per-job reports show revenue, direct cost, gross profit, contribution margin, amount paid, balance and turnaround time.
- Production, purchase, supplier-payment, refund and inventory ledgers are written through owner-checked RPCs; the browser has read-only access to ledger tables.
- The production workspace is not seeded with demo transactions. Disposable fixtures are used only in rolled-back automated tests.

## Deployment
The workflow is manual and checks out `main`. It requires a public Supabase URL and publishable key. Never place a service-role or secret key in a browser build.

## Database replacement
The first migration is intentionally destructive to the former application schema and records, but explicitly preserves Supabase Auth users, identities, sessions and Auth configuration. The replacement migration establishes the new business schema and RLS foundation. Do not apply the production migrations until the migration replay and security tests pass.

Supabase Storage metadata and objects must only be managed through the Storage API, not direct SQL writes.
