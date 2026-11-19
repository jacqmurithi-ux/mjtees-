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

## Deployment
The workflow is manual and checks out `main`. It requires a public Supabase URL and publishable key. Never place a service-role or secret key in a browser build.

## Database replacement
The first migration is intentionally destructive to the former application schema and records, but explicitly preserves Supabase Auth users, identities, sessions and Auth configuration. The replacement migration establishes the new business schema and RLS foundation. Do not apply the production migrations until the migration replay and security tests pass.

Supabase Storage metadata and objects must only be managed through the Storage API, not direct SQL writes.
