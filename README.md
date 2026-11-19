# MJ Printing & Branding

**Business:** MJ Printing & Branding (MJ Tees)  
**Website description:** Printing, apparel and branding.  
**Hosting target:** GitHub Pages (manual deployment only)  
**Backend:** Supabase project `rbbluwsniiwzixlvdnwz`

This repository contains the public website and the private, owner-first shop operations application. The first release covers a published public product/service catalogue managed by the owner, customer enquiries, customers, quotations and revisions, order conversion, payments and receipts, refunds, stock, purchasing, production, expenses, delivery and reporting.

## Current release status

The first-release implementation is merged into `main`. The hosted Supabase project has the first-release schema and the approved 30% gross-margin enforcement migration recorded. Local migration/pgTAP validation remains separate from production verification.

- The business record exists with slug `mj-tees`.
- The first owner account and active owner membership still need to be provisioned through the trusted bootstrap process.
- The public enquiry Edge Function is not yet deployed.
- Public online enquiries remain disabled until a Cloudflare Turnstile site key, matching secret, rate-limit salt and allowed origin are configured.
- GitHub Pages deployment is manual via `Deploy GitHub Pages`; it does not run on every push.
- The published site is not a substitute for hosted database, Auth, RLS and RPC verification.

## Technology

- React, TypeScript and Vite.
- GitHub Pages for static frontend hosting.
- Supabase PostgreSQL, Auth and Edge Functions.
- Supabase Row Level Security and owner-checked transactional RPCs.
- Artwork remains in Google Drive; the application stores only the supplied Drive reference.

GitHub Pages serves static files and does not protect private business data. Every business operation must be authorised by Supabase. Never expose a Supabase service-role key, secret key, database password or access token in frontend code.

## Local development

1. Install Node.js 22 or newer.
2. Copy `.env.example` to `.env.local`.
3. Set only the public browser values for local development:
   - `VITE_SUPABASE_URL`
   - `VITE_SUPABASE_PUBLISHABLE_KEY`
   - `VITE_BUSINESS_SLUG`
   - `VITE_TURNSTILE_SITE_KEY`
4. Install dependencies with `npm install`.
5. Run `npm run dev`; run `npm run build` for the production bundle.

The service-role key is used only by the deployed Edge Function and must be configured as a Supabase Function secret, never as a `VITE_` variable.

## GitHub Pages configuration

The `Deploy GitHub Pages` workflow is intentionally `workflow_dispatch` only. It has safe public defaults for this project:

- Supabase URL: `https://rbbluwsniiwzixlvdnwz.supabase.co`
- Supabase publishable key: supplied as a browser-visible publishable key (never use a secret/service-role key)
- Business slug: `mj-tees`
- Turnstile site key: optional; without it, the public enquiry form stays disabled and the rest of the website can still build.

Optional GitHub Actions Variables with the same `VITE_` names override the public defaults. The GitHub Pages site must use **GitHub Actions** as its build/deployment source. The workflow does not run on push or pull request.

## Public enquiry service configuration

Deploy `supabase/functions/submit-public-enquiry` only after hosted database setup and approval. Configure these Edge Function secrets:

- `ALLOWED_ORIGINS` — exact HTTPS public website origin(s), comma-separated.
- `TURNSTILE_SECRET_KEY` — Cloudflare Turnstile secret.
- `RATE_LIMIT_SALT` — long random secret used for keyed hashes.
- Supabase-provided `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY`.

The Cloudflare Turnstile hostname must match one of the allowed website origins. The function validates payloads, rejects non-Google-Drive artwork URLs, applies Turnstile and rate limits, and submits enquiries through a restricted database RPC.

## Database and owner setup

Migrations are in `supabase/migrations`; pgTAP tests are in `supabase/tests`. The CI workflow applies them only to an ephemeral local Supabase stack. Review the complete migration set, security policies, RPC grants and tests before any hosted execution.

Owner access is by email/password with public registration disabled. The signed-in user must have an active `owner` membership for the business. No default password or public owner signup exists. First-owner provisioning must use the reviewed trusted bootstrap process and a separate explicit approval.

## Operational scope

- One shop with logical stock locations (Shop One: apparel, vinyl and stickers; Shop Two: inks, screens, emulsion and consumables).
- Customers may bring their own items; no blank garment stock is deducted for customer-supplied goods.
- Manual M-Pesa evidence stays pending until owner verification.
- Refunds are recorded pending and affect balances only after posting. Payment reversal is not supported.
- Full payment is required before handover unless the owner records an explicit, audited exception.
- Courier delivery is recorded at actual carrier cost as a pass-through.
- Artwork files stay in Google Drive; only references and version/approval details belong in the system.
- Staff accounts, automatic Daraja confirmation, tax and messaging integrations are deferred.

## Change control

Do not apply hosted migrations, provision the owner, merge the pull request, configure live secrets or deploy the website without the user's separate explicit approval for each live action.
