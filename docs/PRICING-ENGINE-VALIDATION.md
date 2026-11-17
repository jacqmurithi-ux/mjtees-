# Pricing engine validation and calculation rules

**Status:** Shared calculation tests and database enforcement implemented; the 30% direct-cost gross-margin policy is approved.  
**Repository:** `jacqmurithi-ux/mjtees-`  
**Scope:** Shared pricing layer only. No product-specific calculator is introduced here.

## 1. Validation against the current quotation engine

Reviewed the current quotation and costing implementation in `src/QuoteWorkflow.tsx` and `supabase/migrations/20261117060131_quote_costing_and_order_conversion.sql`, plus the order-discount and order-conversion logic in `supabase/migrations/20261117061034_payment_reversal_and_order_discount_allocation.sql`.

### Existing capabilities confirmed

- Costing profiles are versioned and can target a catalogue item or a service category.
- The cost estimator prefers an exact catalogue-item profile over a category profile. Within those targets, a production-method-specific profile is preferred over a generic method profile, followed by the latest profile version.
- A missing active profile is rejected for value-added work. A blank stock item may fall back to its current weighted-average stock cost when a valid stock SKU is supplied.
- Customer-supplied items skip the `blank_item` component; the quotation RPC also rejects a stock item linked to a customer-supplied item.
- Cost component drivers currently include per piece, per order, per metre, per square metre, machine minutes, labour hours, fixed setup and manual input.
- Pricing rules support percentage on cost, margin on selling price, fixed amount and manual pricing. Exact catalogue-item pricing rules take precedence over category rules.
- Quotation lines preserve the estimated cost breakdown and pricing-rule details as snapshots. Accepted orders carry forward those cost snapshots.
- The quotation RPC is owner-checked and validates that line discounts do not exceed the gross line amount.

### Gaps and constraints confirmed

1. **Manual override reasons are not separately captured at line level.** The pricing snapshot retains the manual-override flag. A below-floor quotation exception is separately reasoned and audited at issue time.
2. **Component cost semantics need clearer UI guidance.** For stock-linked components, the current function multiplies consumption by weighted-average stock cost and adds fixed cost. For components without a stock link, fixed cost is multiplied by consumption. Labour hours and machine minutes use separate specification fields; a generic machine-hour driver is not currently provided.
3. **No quantity-discount engine or bundle-pricing policy is implemented in the reviewed quote RPC.** Existing order-level discount allocation is an allocation mechanism, not a profitability policy.

These are the boundaries the unified layer must address. They are not reasons to rewrite existing product profiles.

## 2. Shared calculation contract implemented in code

The pure calculation module is `src/lib/pricing.js`, with TypeScript declarations in `src/lib/pricing.d.ts`.

It provides:

- `calculateRuleUnitPrice`: the same three automatic pricing formulas as the database (percentage on cost, margin on selling price and fixed amount), with manual pricing requiring an explicitly entered price.
- `calculateLineProfitability`: calculates gross line amount, line discount, net selling amount, gross profit, gross margin and markup from the estimated total cost.
- `calculateMinimumNetSellingAmount`: calculates the minimum net line amount for a supplied minimum gross-margin policy and rounds upward to the next whole KSh.
- `evaluateMinimumMargin`: reports whether a line passes a configured floor, falls below it, or has no configured floor. An absent policy is explicitly reported as `not_configured`; no percentage is silently assumed.

### Formula definitions

Let:

- (C) = estimated total production cost for the line
- (Q) = quantity
- (P) = unit selling price
- (D) = line discount
- (N) = net selling amount after discount

Then:

- Gross line amount: (G = round(Q \times P))
- Net selling amount: (N = G - D)
- Gross profit: (GP = N - C)
- Gross margin: (GM = GP / N \times 100), where (N > 0)
- Markup: (MU = GP / C \times 100), where (C > 0)
- Minimum net selling amount: (N_{min} = ceil(C / (1 - GM_{min}/100)))

Markup and gross margin are different measures and must never share the same label.

### Calculation boundaries

- Monetary inputs and outputs follow the existing whole-KSh convention.
- Quantity may be fractional where the unit permits it.
- Profitability is measured after line discounts.
- The approved minimum gross margin is 30% on direct production cost.
- The current policy basis is estimated production cost. General overhead is not silently assumed to be included.
- Tax is excluded, matching the current quotation workflow.
- The pure module remains a calculation foundation and test target. The database is the authoritative enforcement boundary for the 30% floor.

## 3. Validation tests

The test suite in `tests/pricing.test.mjs` covers:

- All automatic pricing formulas against known arithmetic examples.
- Manual pricing requiring an explicit owner-entered price.
- Gross profit, margin and markup after discounts.
- Upward rounding of the minimum net selling amount.
- Passing exactly at the configured margin floor and failing one KSh below it.
- Explicit handling of an unconfigured margin policy.
- Rejection of discounts greater than the gross line amount.
- Rejection of a 100% target margin.

Run with:

```sh
npm run test:pricing
npm run build
```

## 4. Owner decisions required before database enforcement

No default values should be activated until the owner confirms:

1. Minimum gross margin percentage(s), including whether different product/service classes need different floors.
2. Whether the protected cost basis is direct production cost only or direct cost plus an allocated overhead amount.
3. Which roles may approve a below-floor exception.
4. Whether manual price overrides require a reason and what audit detail should be retained.
5. Whether quantity discounts and bundle adjustments share one floor or need additional approval rules.

## 5. Database work that remains separate

Migration `20261118000100_enforce_30_percent_gross_margin.sql` is now applied to the MJ Tees Supabase project. It adds a database helper that evaluates the saved direct-cost snapshots against the final quotation total after all discounts, records owner exceptions in `owner_approvals`, and writes an audit event. The check is performed by the quotation-send RPC, so standard quotations, revisions and quotations with allocated order discounts share the same enforcement point. The direct-order RPC accepts and forwards the same exception reason before sending and accepting its internal quotation.

The existing 3-argument send RPC and 8-argument direct-order RPC remain available for compatibility; they cannot bypass the floor because they pass no exception reason. The UI now sends the optional reason through the 4-argument send RPC. No product costing profile or historical quotation/order snapshot is rewritten. No deployment is included.


## 6. Deployment control finding

The repository contained a workflow named `Deploy MJ Tees owner preview` that ran on every push to `main` and deployed to the `github-pages` environment. This contradicted the README's manual-deployment rule and the owner's separate-approval requirement.

The workflow has now been changed to `workflow_dispatch` only. The separate `Deploy GitHub Pages` workflow was already manual-only. Future commits to `main` therefore do not trigger the owner-preview deployment workflow.

**Incident note:** The code commit in this development phase triggered the pre-existing push workflow before the trigger was corrected. GitHub Actions reports that deployment job as completed successfully. No rollback or further deployment has been initiated. The owner should decide separately whether the resulting Pages deployment should remain or be replaced by a previously approved version.
