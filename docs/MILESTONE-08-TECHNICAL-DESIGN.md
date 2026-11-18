# Milestone 08 — Technical Design

**Status:** Approved for implementation by the owner on 18 November 2026.  
**Target:** Live MJ Tees Supabase project `rbbluwsniiwzixlvdnwz`; GitHub Pages only.  
**Workstream:** Separate from production workflow PR #10. This branch must not merge or modify PR #10.

## 1. Existing structures and reuse

| Existing object | Milestone 08 use | Rule |
|---|---|---|
| `orders` | Order value, status, received/required timestamps | Not revenue or cash |
| `order_events` | Ready and handover event timestamps | Use event time, not page-load time |
| `production_jobs` | Production start/completion | Production duration |
| `deliveries` | One row per delivery/collection attempt | Preserve completed and failed attempts |
| `payments` | Customer payment evidence and posted receipts | Only `posted` is a receipt |
| `payment_allocations` | Allocation of posted payment to order | Do not duplicate payment |
| `payment_refunds` | Refund evidence and status | Posted refunds reduce net receipts |
| `allocation_reversals` | Reverse allocations | Reconcile separately; never rewrite source |
| `receipts` | Customer receipt documents | Keep linked to original payment |
| `expenses` | Business expenses | Cash expenses affect till; non-cash do not |
| `audit_events` and idempotency RPC helpers | Audit and safe retry | Reuse owner assertion, idempotency and audit |

Existing RPCs to preserve and extend: `owner_record_delivery`, `owner_handover_order`, `owner_record_payment`, `owner_verify_mpesa_payment`, `owner_record_refund`, `owner_record_expense`, `owner_get_order_balance`, `owner_update_order_schedule`. Existing blank-stock handover trigger and QC/payment exception rules remain unchanged.

## 2. Daily closing and cash movements

### New tables

**`cash_movements`** is an append-only till movement ledger, separate from `expenses` and customer `payments`.
- Fields: id, business_id, business_date, movement_type, amount, direction, source_account, destination_account, reference, notes, created_by, request_id, created_at.
- Types: `till_top_up`, `bank_deposit`, `owner_withdrawal`, `other_cash_in`, `other_cash_out`.
- Positive integer KES amounts. Direction is constrained by movement type. A bank deposit/withdrawal is not an expense. A till top-up is not a sale.
- Unique (business_id, request_id) for idempotency. Corrections are compensating movements with a reason; no editing/deleting original movements.

**`daily_closings`** is one immutable confirmed snapshot per business date.
- Fields: id, business_id, business_date, status (`draft`/`closed`), opening_float, posted_cash_receipts, posted_cash_refunds, cash_expenses, cash_top_ups, cash_bank_deposits, cash_owner_withdrawals, other_cash_in, other_cash_out, expected_cash, actual_cash, difference, notes, prepared_by/at, closed_by/at, created_at.
- Unique (business_id, business_date). A draft can be resumed and recalculated; after close it cannot be edited or deleted.
- First business day requires owner-entered opening float. Later days default opening float to previous closed day's actual cash count. Owner can record a separately audited float correction/top-up; never silently alter a prior close.
- A no-transaction day can be closed.

### Cash formula

`expected_cash = opening_float + posted_cash_receipts - posted_cash_refunds - cash_expenses + cash_top_ups - cash_bank_deposits - cash_owner_withdrawals + other_cash_in - other_cash_out`

`difference = actual_cash - expected_cash`

Only cash-method posted receipts count. M-Pesa pending evidence is excluded. Cash refunds count only when posted. Only expenses whose method is cash reduce the till. M-Pesa/bank/card expenses do not. Banking and owner withdrawals are cash movements, not expenses. A non-zero difference requires an explanation before close.

## 3. Payment-method reconciliation

**`daily_payment_reconciliations`** stores one per business date and supported non-cash method (initially `mpesa`; schema permits `bank` and `card` when those receipt methods are enabled).
- Fields: id, business_id, business_date, method, system_receipts, system_refunds, statement_receipts, statement_refunds, net_system, net_statement, difference, statement_reference, notes, prepared_by/at, confirmed_by/at, status, created_at.
- Snapshot totals are calculated in the database from posted `payments` and posted `payment_refunds`; statement values and reference are owner-entered.
- `mpesa_manual` payments map to reconciliation method `mpesa`. Pending verification is excluded.
- Transfers between M-Pesa and bank are transfers, never second receipts.
- Bank/card remain reconciliation-only until payment methods are explicitly added to the payment ledger; do not pretend current `payments.method` supports them.
- Cash is reconciled by physical till closing, not duplicated in this table.
- Variance must be explained before confirmation. Confirmed snapshots are immutable; corrections are a new adjustment record/period, never overwrite.

## 4. Delivery visibility and retry handling

- Extend `deliveries` additively with attempt status, failure timestamp/reason, and update timestamp.
- Each row represents one attempt. States: `prepared`, `dispatched`, `handed_over`, `failed`, `cancelled`.
- Collection is prepared then handed over. Courier is dispatched and remains outstanding until confirmed received.
- Failed attempt is retained; retry creates a new row. Existing rows are backfilled from timestamps without losing history.
- Owner view shows active outstanding collections, dispatched parcels awaiting confirmation, failed attempts and completed handovers.
- Existing `owner_record_delivery` must be idempotent and must not rewrite a failed/completed attempt. A retry creates a fresh attempt.
- Existing `owner_handover_order` only completes the current eligible attempt. Full payment remains default; explicit owner exception and reason remain required. A dispatched courier is not completed until receipt confirmation.
- Preserve latest passing QC, completed production and blank-stock consumption trigger.

## 5. Reporting queries and dashboard

Use database-side aggregate RPCs, business-scoped and owner-authorised; do not compute financial totals from truncated client arrays.

Dashboard cards:
- Orders in progress; ready awaiting collection; courier parcels outstanding; failed delivery attempts; overdue orders.
- Pending M-Pesa verification.
- Today's order value (labelled order value, not sales receipts).
- Today's posted receipts, net posted refunds, customer balances.
- Expenses by payment method; production costs.
- Expected and counted till cash; cash variance; daily close status.
- M-Pesa reconciliation status/variance.

Report definitions:
- Production duration = production job started_at → completed_at.
- Ready turnaround = order received_at → first ready event.
- Customer turnaround = order received_at → confirmed handover timestamp.
- Overdue = required_by before business-local today and order not handed over.
- On-time handover = handed_over_at's Africa/Nairobi date on or before required_by.
- Ready awaiting collection = ready order with no handed-over delivery attempt.
- Outstanding courier = dispatched attempt without handover/failure/cancellation.
- Customer balance = existing owner order balance logic; posted allocations less posted refunds and reversals.
- Financial totals must not be labelled profit unless all direct costs and expenses are reconciled.

Use `Africa/Nairobi` for business-day boundaries. Query by timestamp half-open intervals [local midnight, next local midnight) converted to timestamptz.

## 6. Frontend structure

- Add an owner-first **Daily Closing** workflow: choose business date, begin/resume draft, enter opening float (first day only), record till movements, review system-calculated totals, enter actual cash count and explain variance, confirm close.
- Add **Reconciliation** within Reports/Payments: M-Pesa statement amount/reference/notes, system-vs-statement variance, confirmation. Bank/card appear only when receipt support is enabled.
- Extend delivery screen with attempt history, current outstanding state, mark failed with reason, and create retry.
- Replace limited-array financial summaries with database aggregate RPC results and pagination for detail lists.
- No staff role or supervisor approval is introduced; owner can complete every action.

## 7. Tests and acceptance criteria

### Daily closing
1. First close requires opening float.
2. Subsequent opening float defaults to prior closed actual count.
3. Cash receipt increases expected till; pending M-Pesa does not.
4. Posted cash refund decreases expected till; pending refund does not.
5. Cash expense reduces till; M-Pesa/bank/card expense does not.
6. Top-up increases till but not sales; bank deposit/owner withdrawal reduces till but is not expense.
7. Duplicate request ID creates one movement.
8. One close per business date; draft resumes; no-transaction day closes.
9. Non-zero variance requires explanation.
10. Closed snapshot cannot be updated/deleted; adjustment is append-only and audited.

### Reconciliation
1. Posted M-Pesa receipts included; pending/rejected excluded.
2. Posted refunds reduce net receipts; pending/cancelled refunds excluded.
3. M-Pesa-to-bank transfer is not double-counted.
4. Statement variance is correct and requires explanation.
5. Cross-business access denied; confirmed reconciliation immutable.

### Delivery
1. Prepared collection is outstanding, not complete.
2. Dispatched courier remains outstanding until receipt confirmation.
3. Failed attempt stays visible and does not complete order.
4. Retry creates a new attempt without changing history.
5. Repeated RPC request is idempotent.
6. Payment/QC/production checks and blank-stock trigger remain enforced.
7. Full payment exception requires reason and is audited.

### Reporting and security
1. Aggregate totals match source-ledger SQL for large datasets beyond former frontend limits.
2. Ready/handed-over/overdue metrics use event timestamps and Africa/Nairobi date.
3. Order value, posted receipts, balances, expenses, production cost and cash position remain separate.
4. Every new table has RLS enabled, owner-scoped access and no direct client write path.
5. Every mutating RPC asserts active owner, validates business scope, uses idempotency and writes audit events.
6. No secret/service-role key enters frontend code.
7. Existing production PR #10 remains open and unchanged; GitHub Pages only, no Vercel.

## 8. Implementation sequence

1. Additive migration: cash movements, daily closings, reconciliation snapshots, delivery-attempt lifecycle, constraints/indexes/RLS.
2. Owner-only transactional RPCs and database aggregate/report RPCs.
3. Frontend Daily Closing, reconciliation, delivery attempt history and dashboard integration.
4. Database tests and frontend build; verify live schema, RLS, RPC grants, advisors and sample read-only calculations.
5. Deploy only through the existing GitHub Pages workflow after checks; no Vercel.

**Safety:** no destructive changes, no rewrite of payment history, no duplicated payment/expense ledgers, no direct client writes to financial tables.
