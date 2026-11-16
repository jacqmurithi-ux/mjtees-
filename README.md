# MJ Tees

**Business:** MJ Tees — print, apparel branding and customisation  
**Tagline:** To be confirmed  
**Hosting:** GitHub Pages  
**Backend:** Supabase (`rbbluwsniiwzixlvdnwz`)

MJ Tees is being developed as one web application with a public business website and a private shop operations system. The initial release is intended to cover the core business workflow: customers, quotations, orders, inventory, purchasing, production, payments, expenses, collection/delivery and owner reporting.

## Project status

Milestone 01 — repository foundation and architecture. No business database schema has been deployed yet.

## Technology direction

- React + TypeScript + Vite for the frontend.
- GitHub Pages for static frontend hosting.
- Supabase PostgreSQL, Auth, Storage and Edge Functions for backend services.
- Supabase Row Level Security (RLS) and server-side validation for business data protection.

GitHub Pages serves static files; it does not secure private business data. Every private operation must be authorised by Supabase policies and trusted backend logic. Never place Supabase service-role keys or other secrets in frontend code.

## Local development

The setup instructions will be added with the application scaffold. Copy `.env.example` to `.env.local` when Supabase client configuration is introduced. Never commit real credentials.

## Project documentation

- `docs/PROJECT-OVERVIEW.md` — business scope and operating assumptions.
- `docs/ARCHITECTURE.md` — application and security architecture.
- `docs/DATABASE-DESIGN.md` — proposed database domains and approval gate.
- `docs/ROADMAP.md` — milestones and release boundaries.
- `docs/DECISIONS.md` — confirmed technical and business decisions.

## Change control

Database migrations, production deployments, integrations and changes to financial/inventory rules require explicit review and approval. The initial repository foundation does not create or modify Supabase business tables.