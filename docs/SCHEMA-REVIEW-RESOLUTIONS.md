# MJ Tees — Schema Review Resolutions and Owner Provisioning

**Status:** design resolution for review; not executable SQL.  
**Branch:** `first-release-build`  
**Scope:** resolve the open schema/security review points before generating the first Supabase migration.  
**Safety boundary:** this document does not authorize migration execution, database changes, PR merge or deployment.

## 1. Payment, refund and allocation ledger

Use immutable financial events. Never edit or delete posted payments, allocations, reversals, refunds or receipts.

### 1.1 Allocation reversal versus refund

These are different business events and must not be treated as interchangeable:

- **Allocation reversal** removes some or all of an allocation from an order while leaving the original payment received. The amount becomes unallocated on that payment.
- **Refund** records money actually returned to the payer. It reduces the amount retained by the business and the amount credited to the order.
- A pending refund does not change an order balance. Only a posted refund does.

Add the following fields/relations to the design:

- `allocation_reversals.allocation_id` references the original allocation.
- `payment_refunds.allocation_id` is nullable only for a refund explicitly drawn from an unallocated payment balance. `payment_refunds.payment_id` remains the source payment.
- An allocated refund must reference an allocation belonging to the same payment and order.
- An unallocated refund must have no allocation_id and must be explicitly marked `source_bucket = 'unallocated'`.
- Under a lock on the payment and, where relevant, allocation, enforce that the sum of posted allocation reversals plus posted refunds against an allocation never exceeds that allocation's amount.
- For unallocated refunds, enforce that posted unallocated refunds never exceed payment amount less all allocations plus allocation reversals, less prior unallocated refunds.
- Refunds against an allocated amount and reversals against that same amount share one capacity. This prevents the same KSh from being reversed and refunded twice.

Define the derived balances as:

- Remaining allocated credit for an allocation = allocation amount − posted allocation reversals − posted refunds linked to that allocation.
- Net order paid = sum of remaining allocated credit for allocations on posted payments.
- Order balance due = max(order total − net order paid, 0), with overpayment shown separately rather than silently discarded.
- Unallocated payment balance = posted payment amount − total allocations + posted allocation reversals − posted unallocated refunds. Do not count pending/rejected/reversed payments.
- A payment reversal must be a separate, guarded event and cannot silently bypass refund/allocation accounting.

All amount checks happen inside one database transaction after row locks; UI pre-checks are advisory only.

## 2. Order discount allocation snapshot

Add an immutable `order_item_discount_allocations` table:

- `id`, `business_id`, `order_id`, `order_item_id`
- `discount_source` (line_discount/order_discount)
- `pre_discount_line_amount`, `allocated_discount_amount`
- `allocation_version`, `created_at`, `created_by`

At quote acceptance or direct-order confirmation:

1. Validate each line discount does not exceed its line amount.
2. Calculate the remaining order-level discount after line discounts.
3. Allocate that order-level amount pro-rata across eligible pre-order-discount line totals using integer KES.
4. Use deterministic largest-remainder allocation; ties break by stable order_item sequence then UUID. This is more reproducible than relying on unspecified query order.
5. Store the exact allocation rows and algorithm version in the same transaction as the accepted order snapshot.
6. Never recompute historical allocations when catalogue prices, costing profiles or algorithm versions change. Amendments create a new versioned snapshot/event.

Line net revenue = line gross amount − line discount − allocated order discount. Delivery/carrier pass-through is excluded.

## 3. Stock transfer and movement reconciliation

Keep `stock_movements` append-only. Add a `stock_transfer_id` UUID shared by exactly two movements for every transfer:

- source location: negative quantity, movement type `transfer_out`;
- destination location: positive quantity, movement type `transfer_in`;
- same business, stock item, base unit, absolute quantity, unit-cost snapshot and transfer ID;
- source and destination locations must differ;
- the two movements are inserted atomically by one owner RPC;
- unique constraints prevent more than one in/out pair for a transfer;
- transfer does not change business-wide on-hand quantity or weighted-average cost.

For ordinary stock movements, define signs consistently: receipts/opening/count gains/returns are positive; issues/count losses are negative. Use a documented sign convention and check constraints by movement type. Corrections are compensating movements, never row edits.

## 4. Production material, waste and offcut reconciliation

For each material issue, retain the exact issued quantity and unit-cost snapshot.

- Waste is a classification of issued material; it does not create another stock movement.
- An offcut return creates one positive stock movement at the destination and one linked offcut-return row. The return cost credit uses the original issue's unit-cost snapshot, capped by remaining unreturned quantity.
- A given issued quantity cannot be both returned as reusable offcut and classified as waste.
- Waste and offcut records must reference the source issue row, not merely a job/stock item pair.
- Sum of returned quantity + classified waste quantity must not exceed issued quantity. Remaining quantity is treated as consumed/used in the job cost; the UI must make this visible.
- A rework event creates additional linked material issues and cost entries; it never reopens or rewrites the original issue.
- Job completion locks further ordinary issue/cost entry and snapshots total actual cost. Corrections after completion use explicit adjustment entries with reason, actor and timestamp.
- Completion requires the required QC pass. A failed check requires a recorded rework path and a subsequent passing check before the job can be marked complete.
- Self-inspection remains permitted but must be recorded as `inspection_mode = 'self'`; do not represent it as independent inspection.

## 5. One-time first-owner provisioning

There must be no public signup path, browser RPC or user-editable profile field that grants the owner role.

Use a controlled, documented bootstrap operation:

1. The intended owner creates/authenticates their Supabase Auth account through the configured authentication provider.
2. Verify the authenticated user's identity out-of-band before granting business ownership.
3. An authorised project operator uses a trusted administrative environment with the Supabase service-role credential held only server-side. Never put that credential in GitHub Pages, browser bundles, client configuration, source control or logs.
4. The operator runs a one-time bootstrap script/administrative SQL operation that:
   - locks the business bootstrap record;
   - confirms no active owner membership exists;
   - confirms the target Auth user exists;
   - creates/links the business and exactly one active owner membership;
   - writes an immutable audit event with operator, target user, business, timestamp and reason;
   - marks bootstrap completed so it cannot be repeated.
5. Verify owner login and owner-only access with a normal authenticated session.
6. Remove/disable the temporary bootstrap credential/path and retain no reusable public bootstrap token.

The migration may create the business bootstrap state and private helper structures, but it must not guess an Auth user ID or grant ownership to the first person who signs up. The actual first-owner assignment is a separate controlled provisioning action after migration review and approval.

## 6. Public API boundary and abuse controls

- Anonymous visitors may read only a narrow published catalogue projection containing public descriptions, images/references and starting prices. No cost profiles, stock levels, internal notes, customer data or unpublished catalogue rows.
- Anonymous visitors may submit an enquiry only through a constrained Edge Function or public RPC. They cannot select/read enquiries or create customers, quotes, orders, payments or receipts.
- Validate field lengths, content types, contact channel, optional quantity/date, and permitted artwork link host. Treat all submitted text and links as untrusted.
- Apply per-IP and per-contact rate limits, request idempotency, bot protection (captcha or equivalent), payload size limits and abuse logging at the Edge Function boundary. Do not rely on a client-side captcha alone.
- Return only a public reference and generic confirmation. Do not expose internal UUIDs or echo sensitive submitted details.
- Prefer an Edge Function as the public ingress so rate limits and bot checks happen before database insertion. Grant the function only the minimum database capability needed to insert a pending enquiry.
- Owner reads/updates remain behind authenticated owner membership checks and private-schema functions/RPCs.

## 7. Additional schema constraints to freeze before migration

- Every business-owned row has a non-null `business_id` and business-scoped foreign keys/unique constraints where cross-business references could otherwise be supplied.
- Use explicit `ON DELETE RESTRICT` for financial, order, stock and audit history. Archive catalogue/supplier/category records instead of deleting referenced records.
- Use `numeric` quantities in base units and integer KES amounts. Validate unit conversions as positive and finite; do not store floating-point money.
- Store timestamps as `timestamptz`; store business dates separately as `date`.
- Add `created_at`/actor fields consistently. Audit/ledger records are append-only.
- Idempotency keys are unique within business and operation scope, and store the resulting entity/reference so retries return the original result.
- Define all status enums/check constraints and allowed transitions explicitly in the migration, not only in frontend code.
- Every SECURITY DEFINER function must pin `search_path`, schema-qualify references, validate `auth.uid()` and owner membership, and have PUBLIC/anon execute revoked unless deliberately public.
- Revoke broad table writes from anon/authenticated; grant only the required reads and function execution.
- The release-one schema contains no tax fields, tax rates, tax calculations or tax lines.

## 8. Migration and release gate

The next migration authoring pass must:

1. Translate the approved schema and these resolutions into a timestamped migration created by the Supabase CLI.
2. Run SQL formatting/lint and a clean local Supabase reset/apply test where the CLI and Docker are available.
3. Run database tests for RLS, grants, RPC authorization, idempotency, concurrent allocation/stock issue, refunds/reversals, transfers and production reconciliation.
4. Review the exact generated SQL and test results in the pull request.
5. Stop for explicit approval before applying to the linked Supabase project.

A successful frontend build is not evidence that database policies or migrations are correct. No migration, PR merge or deployment is authorised by this design document.
