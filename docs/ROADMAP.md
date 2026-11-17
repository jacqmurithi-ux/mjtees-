# Development roadmap

## Milestone 01 — foundation and owner workspace

- [x] Inspect repository and linked Supabase project read-only.
- [x] Establish React + TypeScript + Vite and GitHub Pages direction.
- [x] Create responsive public-site and owner-workspace preview shell.
- [x] Apply MJ orange, blue and green identity.
- [x] Draft database, RPC, RLS and security design.
- [x] Implement seven timestamped database migrations on `first-release-build`.
- [x] Implement owner transactional RPCs and database integrity guards.
- [x] Implement constrained public enquiry Edge Function and database rate limiting.
- [x] Add pgTAP coverage for schema security, financial flows, costing, purchasing, production and reversals.
- [x] Validate migrations against a disposable local Supabase stack (83 assertions passed at last completed validation).
- [ ] Complete final implementation review and resolve findings.
- [ ] Complete concurrency, recovery and full workflow regression tests.
- [ ] Present complete implementation for review before any hosted database execution.

## Milestone 02 — owner access and business setup

- [x] Design trusted first-owner bootstrap script; not run.
- [ ] Make bootstrap safe under concurrent execution and validate its safeguards.
- [ ] Configure and verify owner Auth sign-in and session handling.
- [ ] Provision first owner only after separate approval for hosted execution.

## Milestone 03 — public website and enquiries

- [x] Create initial public services and process presentation.
- [x] Implement Edge Function source for public enquiry intake.
- [ ] Build public enquiry form and artwork Drive-reference fields.
- [ ] Configure and deploy Edge Function secrets, allowed origins and Turnstile.
- [ ] Connect public catalogue projection and enquiry receipt flow.

## Milestone 04 — owner operations application

- [ ] Implement authenticated owner application and real Supabase data access.
- [ ] Customers, enquiries, quotations, revisions and quote acceptance.
- [ ] Orders, turnaround tracking, payment recording, receipts and handover lock.
- [ ] Stock variants, logical shop locations, reservations, purchasing and receiving.
- [ ] Production jobs, materials, waste/offcuts, QC and rework.
- [ ] Owner-only expenses, delivery pass-through charges and audit trail.
- [ ] Daily overview, reports and financial reconciliation.

## Milestone 05 — verification and pilot

- [ ] Complete browser-based end-to-end workflows against an isolated development project.
- [ ] Verify RLS and RPC permissions with owner, other authenticated user and anon sessions.
- [ ] Verify backup/restore and operational recovery.
- [ ] Owner acceptance review and controlled pilot.

## Deferred

Daraja automatic M-Pesa confirmation, staff accounts/permissions, WhatsApp/SMS integrations and tax functionality remain outside the first-release scope. M-Pesa is manually recorded and owner-verified. Tax is excluded.
