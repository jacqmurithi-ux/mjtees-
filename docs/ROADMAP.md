# Go-live readiness roadmap

## Implemented on `first-release-build`

- [x] MJ orange, blue and green identity and responsive public website.
- [x] Authenticated owner workspace with email/password sign-in and active-owner membership check.
- [x] Owner customer and enquiry management.
- [x] Quotation costing, pricing rules, revisions and customer acceptance-to-order conversion.
- [x] Payment recording, manual M-Pesa verification, receipts, refund posting/cancellation and payment/allocation reversals.
- [x] Order turnaround scheduling, production jobs, material issue, production cost entries, quality checks, rework and handover.
- [x] Inventory items, variant attributes, logical storage locations, opening cost/quantity, movements, reservation and reorder monitoring.
- [x] Suppliers, purchase orders, goods receipt, expense categories, owner-recorded expenses and operational reports.
- [x] Restricted public enquiry Edge Function with Turnstile verification, origin allow-list, payload validation and database rate limits.
- [x] Public enquiry form with Google Drive artwork-reference field and customer-supplied-item option.
- [x] CI type-check/build and disposable local Supabase migration + pgTAP validation.
- [x] Manual-only GitHub Pages deployment workflow (no automatic deployment on merge).

## Final technical review still required

- [ ] Re-run frontend build and full local Supabase migration/pgTAP validation after the latest changes.
- [ ] Review and correct any findings from production, refund/reversal, purchasing/receiving and cross-module workflow tests.
- [ ] Verify the complete browser flow on an isolated hosted development project, including public enquiry/Turnstile, quote acceptance, owner operations, receipts, refund/reversal, inventory, QC and handover.
- [ ] Verify anon, non-owner authenticated and owner access against every exposed table, view and RPC; review SECURITY DEFINER grants and Supabase advisors.
- [ ] Validate pagination/report totals and backup/restore/recovery procedures.
- [ ] Perform final owner acceptance review.

## Live setup — separate approvals required

- [ ] Confirm hosted Supabase project settings, Auth redirect URLs, Data API exposure, RLS and backups.
- [ ] Apply reviewed migrations to the hosted business database.
- [ ] Configure Edge Function secrets, deploy the enquiry function and configure Turnstile allowed origins.
- [ ] Configure GitHub Pages Actions secrets and Pages source.
- [ ] Provision the first owner account through the trusted bootstrap process.
- [ ] Merge PR #1 into `main` only after final review.
- [ ] Manually run the GitHub Pages deployment workflow after deployment approval.
- [ ] Verify public site, owner login and live business workflows after release.

## Release boundaries

No hosted migration, first-owner provisioning, PR merge, live-secret configuration or deployment is performed by local CI. The current green database validation is against a disposable local database, not the hosted business database.

## Deferred beyond first release

Staff accounts and permissions, automatic M-Pesa/Daraja confirmation, tax functionality, WhatsApp/SMS integrations and other additions remain deferred until operational use demonstrates the need.
