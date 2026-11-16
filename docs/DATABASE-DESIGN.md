# Database design — proposal only

**Status: NOT APPROVED FOR IMPLEMENTATION**

The Supabase project currently has no MJ Tees application tables in the public schema and no recorded application migrations. This document describes candidate domains only; it is not a migration or final schema.

## Proposed domains

| Domain | Candidate entities | Main responsibility |
|---|---|---|
| Business and access | business_settings, staff_profiles, staff_roles, permissions, role_permissions | Business identity and trusted staff authorisation |
| Customers | customers, customer_contacts, customer_addresses, customer_interactions | Customer records and history |
| Catalogue | product_categories, products, product_variants, services | Products, sizes, colours and service definitions |
| Suppliers | suppliers, supplier_products, supplier_price_history | Supplier relationships and changing purchase prices |
| Inventory | stock_locations, stock_movements, stock_reservations, stock_counts | Auditable quantities, reservations and adjustments |
| Purchasing | purchase_orders, purchase_order_items, goods_receipts | Ordering and receiving materials/merchandise |
| Quotations | quotations, quotation_versions, quotation_items, quotation_approvals | Versioned job-specific quotes and exceptions |
| Orders and sales | orders, order_items, sales, order_status_events | Confirmed customer work and walk-in sales |
| Payments | payments, payment_allocations, refunds, receipts, account_transfers | Collections, allocation and reconciliation |
| Production | production_jobs, production_tasks, task_assignments, production_materials, quality_checks | Work planning, execution and QC |
| Artwork | artwork_assets, artwork_versions, artwork_approvals | Customer artwork, outputs and approvals |
| Outsourcing | outsourced_jobs, outsourced_job_items | External suppliers, costs and turnaround |
| Expenses | expense_categories, expenses, expense_approvals | Operating expenses and job-attributed costs |
| Delivery | deliveries, delivery_events, handover_confirmations | Collection, dispatch and proof of handover |
| Reporting and audit | audit_events, daily_closings | Traceability and operational summaries |

Final names and normalisation will be decided after workflow review.

## Design requirements

- Use stable UUID primary keys and explicit foreign keys.
- Define NOT NULL, CHECK, UNIQUE and deletion rules intentionally.
- Use integer minor units for money (Kenyan shillings in cents) or a documented NUMERIC strategy; never floating-point money.
- Store currency explicitly where relevant.
- Store timestamps consistently and define the business timezone for reporting.
- Preserve historical unit prices, supplier costs, quote versions and approvals.
- Use immutable or append-only event records where an audit trail is required.
- Separate customer revenue, payment receipts, expense payments, refunds and account transfers.
- Make payment allocation and stock reservation/consumption transactional.
- Prevent duplicate payment imports with provider reference/idempotency keys where available.
- Record who performed sensitive actions and when.
- Add indexes based on actual query patterns and foreign keys.
- Keep sensitive documents in private Storage buckets with scoped policies.

## Critical workflow decisions to settle before migration

1. Staff roles and exact permission matrix, including who can approve discounts, expenses, refunds and stock adjustments.
2. Order, quote, sale and production status transitions.
3. How stock is reserved, released, consumed, wasted and returned.
4. Payment allocation rules for deposits and instalments.
5. Owner approval process for exceptions to full payment before handover.
6. Cash drawer and Paybill reconciliation workflow.
7. Whether POS sales and custom orders share one order model or have separate sale records.
8. Opening stock and historical data migration rules.
9. Customer data retention and consent requirements.
10. File retention, upload size/type limits and artwork access rules.

## Approval gate

No business tables, RLS policies, triggers, RPCs, Storage buckets or migrations should be created until the complete schema and workflows have been presented and explicitly approved. The user has not approved a database migration.
