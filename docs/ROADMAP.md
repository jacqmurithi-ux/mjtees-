# Development roadmap

## Milestone 01 — foundation and owner workspace

- [x] Inspect GitHub repository and Supabase project read-only.
- [x] Establish React + TypeScript + Vite direction for GitHub Pages.
- [x] Add initial repository structure and project documentation.
- [x] Build responsive owner workspace shell, navigation and dashboard layout.
- [x] Apply MJ orange, blue and green identity to the public site and owner workspace.
- [ ] Review and approve database domains, detailed schema and security model.
- [ ] Implement authentication and connect real owner data after schema approval.
- [ ] Install dependencies locally and generate/commit the package lockfile.
- [ ] Verify type-check and production build.

## Milestone 02 — business setup and access

- Owner identity and individual staff accounts.
- Role/permission matrix and server-enforced access.
- Shared-device session and inactivity controls.
- Audit events for sensitive actions.

## Milestone 03 — public website and customers

- Public pages, product/service catalogue and portfolio.
- Contact details and enquiry channels.
- Customer profiles and interaction history.
- Quotation enquiry intake.

## Milestone 04 — catalogue, inventory and suppliers

- Products, variants, units and categories.
- Opening stock and stock counts.
- Stock movements and reservations.
- Suppliers, purchase orders and receiving.

## Milestone 05 — POS, quotations, orders and payments

- Walk-in sales and custom quotations.
- Quote revisions, approvals and conversion to orders.
- Deposits, instalments, balances and receipts.
- Payment allocation and customer account history.

## Milestone 06 — purchasing and financial controls

- Supplier costs and payables.
- Expenses and approvals.
- Cash/Paybill reconciliation and account transfers.
- Job costing and daily close.

## Milestone 07 — artwork, production and outsourcing

- Artwork repository and version approval.
- Production jobs, tasks and staff assignments.
- Materials, waste and quality checks.
- Outsourced DTF tracking.

## Milestone 08 — delivery and reporting

- Collection/delivery and payment lock.
- Owner dashboard live metrics and reports.
- Reconciliation and exception reporting.

## Milestone 09 — testing and pilot

- RLS and permission tests.
- Concurrent stock/payment workflow tests.
- Backup and restore checks.
- Staff training, pilot data and controlled launch.

## Later integrations

Daraja automatic payment confirmation, WhatsApp Business API, SMS and social publishing are deferred until core workflows are stable and provider requirements are confirmed.
