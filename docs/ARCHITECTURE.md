# Application architecture

## System shape

- Public frontend and private shop application live in one React + TypeScript + Vite codebase.
- GitHub Pages serves the built static frontend.
- Supabase provides PostgreSQL, Auth, Storage and Edge Functions.
- The frontend uses only the Supabase publishable key.
- Business access is enforced by PostgreSQL Row Level Security (RLS) and trusted server-side functions, not by hiding pages or controls.

## Frontend boundaries

Suggested feature boundaries:

- Public: home, about, services/products, portfolio, contact and quotation enquiry.
- Private: dashboard, customers, quotations, sales, orders, inventory, purchasing, suppliers, production, artwork, payments, expenses, deliveries, reports, staff and settings.

A page being private in the user interface does not make its data private. All reads and writes must be authorised at the backend.

## Authentication and shared shop device

- Every staff member has an individual account; no shared staff credentials.
- Owner account should use multi-factor authentication.
- The shared shop computer/tablet should lock after inactivity and require staff to sign in individually.
- A quick-switch PIN, if introduced, is only a convenience layer and never a replacement for authenticated identity.
- Sensitive actions should require appropriate permission and, where justified, re-authentication.
- Role assignment must be performed through trusted backend logic; never trust user-editable profile metadata.

## Data security

- Enable and test RLS on every exposed business table.
- Define policies around authenticated identity, staff status, role and permission.
- Do not assume authenticated database role alone is sufficient authorisation.
- UPDATE policies need both row visibility and valid new-row checks.
- Restrict Storage buckets and object paths with Storage policies.
- Treat uploaded artwork and customer files as private business data.
- Do not expose service-role keys, database passwords or provider secrets in frontend code or repository history.
- Avoid privileged SECURITY DEFINER functions unless the use case, ownership, search path, grants and identity checks have been explicitly reviewed.
- Use database transactions or trusted functions for operations that must remain consistent, especially inventory, payment allocation and order closure.

## Financial and inventory integrity

- Customer payments are recorded once and allocated to invoices/orders.
- Bank deposits and Paybill settlement transfers must not be counted as new sales.
- Stock movements are the auditable source of inventory change.
- Available stock is physical stock less reservations and other committed quantities.
- Do not allow direct client-side edits to derived financial totals or stock balances.
- Collection/delivery must be blocked while a balance remains unless a recorded owner-approved exception exists.

## Deployment

- GitHub Pages deployment is intentionally not enabled by this foundation commit.
- The current project base path is configurable through VITE_BASE_PATH; GitHub Pages can use /mjtees-/ until a custom domain is connected.
- A custom domain can later use / as the base path without changing the database architecture.
- GitHub Actions currently performs a build check only. It does not publish the site.

## Secrets and configuration

Use .env.local for local development. .env.example contains variable names only. The browser may receive the Supabase project URL and publishable key; it must never receive the service-role key or other privileged credentials.
