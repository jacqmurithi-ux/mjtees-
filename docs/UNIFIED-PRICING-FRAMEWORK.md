# Unified pricing framework

**Status:** Design proposal for review — not an approved database change.  
**Scope:** All MJ Printing & Branding (MJ Tees) products and services.  
**Core rule:** One pricing strategy, multiple product-specific costing methods.

## 1. Purpose

Create one commercial pricing framework that applies consistently across the business without forcing every product or service through the same cost formula. A mug, a banner, a jersey print, artwork preparation and an outsourced job may use different costing methods, but they must all pass through the same pricing, discount, profitability and quotation controls.

This document is a design baseline. It does not change existing catalogue records, costing profiles, pricing rules, quotations or the database.

## 2. Non-negotiable boundaries

- Preserve existing product, service, supplier, stock and quotation data.
- Do not silently replace or broaden an existing category-level costing rule.
- Prefer an exact catalogue-item costing profile; use a category profile only as an intentional fallback.
- A specialised costing method supplies a defensible cost estimate; the shared pricing layer decides how that cost becomes a selling price.
- Customer-supplied items must not incur a blank-item cost or consume blank-item stock.
- Outsourced work must include supplier charges and attributable transport/handling before the selling price is calculated.
- Keep estimated costs, actual costs, selling prices, discounts and profit measures distinguishable.
- Preserve the cost and price snapshots attached to accepted quotations/orders. Later rule changes must not rewrite historical transactions.
- Record manual overrides, who authorised them and why.
- All money remains in KES using the application's existing whole-KSh storage convention. Tax remains outside the current quote calculation until separately designed and approved.
- Never introduce the erroneous KSh 75 value into a costing rule, test fixture or example.

## 3. Shared pricing pipeline

Every quotation line should pass through this sequence:

1. **Identify the sale:** catalogue item or custom description, category, quantity, unit, sale mode, customer-supplied status and production method.
2. **Select the costing method:** exact item profile first, then a deliberately configured category fallback. A missing or ambiguous profile must be visible; it must not silently become a zero-cost estimate.
3. **Calculate estimated production cost:** call the selected method with the line's required specifications and return a cost breakdown, inputs, profile/version and calculation version.
4. **Apply shared commercial adjustments:** quality tier, artwork/preparation, complexity, finishing, handling, outsourcing and any applicable job-level charges. Each charge must have a clear basis and must not duplicate a cost already included in the costing profile.
5. **Calculate the base selling price:** use the active item-specific pricing rule, then category fallback, or require a manual price where no automatic rule exists.
6. **Apply quantity economics:** recognise genuine per-unit savings from batch production, setup sharing or material yield. Do not apply a discount merely because quantity increased.
7. **Apply bundle pricing:** calculate each included line independently, then apply a disclosed bundle adjustment only where the combined job remains profitable.
8. **Apply authorised discounts and overrides:** validate the resulting price against the configured profitability floor; record exceptions with actor and reason.
9. **Present the quotation:** show the customer-facing description, options, quantity, unit price, discounts, line totals, validity and relevant terms. Keep internal cost and margin details owner-only.
10. **Snapshot and audit:** preserve the inputs, costing profile/version, cost breakdown, pricing rule/version, adjustments, override details, final price and calculation version with the quotation.

## 4. Product-specific costing method contract

Each costing method should accept a common line context and return a common result shape.

### Required input context

- Business and catalogue/category identifiers
- Quantity and sale unit
- Sale mode: blank or value-added
- Whether the customer supplies the base item
- Production method
- Product-specific specification data
- Relevant stock-item identifiers and current landed unit costs
- Applicable profile and version

### Required output

- Estimated total and per-unit cost
- Itemised cost components with units, drivers, consumption, waste and unit-cost snapshots
- Inputs used in the calculation
- Costing method identifier and calculation version
- Warnings for missing inputs, unsupported assumptions or manual estimates

### Costing method families

| Method family | Typical use | Main cost drivers |
|---|---|---|
| Per-piece / blank item | Blank garments, mugs, caps and other stocked blanks | Blank-item landed cost, quantity, decoration and finishing |
| Linear material | Roll vinyl, ribbon and other length-based materials | Length consumed, usable width/layout, waste and reusable offcuts policy |
| Area / sheet yield | Stickers, labels, banners and sheet materials | Dimensions, usable area, nesting/yield, waste and finishing |
| Time-based production | Plotter, heat press, sewing, screen preparation or other machine/labour processes | Machine minutes, labour minutes, setup and process difficulty |
| Consumables | Ink, emulsion, cleaning materials and small production inputs | Measured or standard consumption per job/unit |
| Outsourced service | External DTF, specialist finishing or other supplier work | Supplier quote, quantity, transport, handling, quality/rework risk and lead time |
| Service / artwork | Design, editing, logo recreation and artwork preparation | Skill/time band, complexity, revisions and deliverables |
| Composite / bundle | Multi-process jobs | Sum of independently costed component lines and shared setup savings |

These are method families, not a requirement to create a separate hard-coded calculator for every catalogue item. A method may be reused where its physical cost drivers genuinely match.

## 5. Shared commercial pricing rules

### 5.1 Good, Better, Best

Where a product supports meaningful choices, define tiers by real differences such as material grade, garment quality, print/finish durability, colour coverage or service level. Each tier must have its own cost basis and customer-visible description. Do not create artificial tiers for services where the distinction is not meaningful.

### 5.2 Complexity and specification charges

Complexity may reflect size, number of colours, design difficulty, material, placement, production time, finishing, handling or special requirements. The charge must be based on an explainable driver (measured quantity, time, selected band or fixed setup), and must not duplicate labour, machine or material costs already counted.

### 5.3 Artwork and creative services

Distinguish print-ready customer artwork from file correction, text/layout editing, logo recreation, new design and artwork preparation. Define what is included, revision limits and approval status. Artwork may be a separate line or a clearly itemised component.

### 5.4 Quantity discounts

Calculate discounts from the cost difference between individual and batch production. Setup sharing, repeat runs, nesting/yield and purchasing efficiencies may create savings. Configure minimum profit requirements before exposing any discount. Avoid universal quantity percentages until actual operating data supports them.

### 5.5 Profitable sales and customer value

Evaluate both gross profit in KSh and gross margin percentage. Turnover alone is not a success measure. Reports should distinguish estimated from actual job cost and identify profitable categories, customers, channels and bundles.

### 5.6 Bundles

Cost each bundle component independently. Show the normal combined price and bundle adjustment internally; allocate any order-level discount to lines using a deterministic, auditable method. A bundle must pass the same post-discount profitability checks as a standalone order.

### 5.7 Outsourcing

Use the complete landed outsourced cost: supplier amount, attributable transport, handling and other job-specific costs. Include an appropriate allowance for coordination, quality risk and rework only when defined and not already included elsewhere. Keep supplier cost and customer selling price separate.

### 5.8 Transparent price changes

Pricing rules should have effective dates and clear version history. A quotation uses the rule active when it is created; later changes affect new quotations only. Display quotation validity and communicate material changes before customer approval.

### 5.9 Online merchandise stores

Support school, club, church and organisation merchandise stores as a sales channel. Store products still use the same item costing and profitability controls. Channel-specific fees, fulfilment, collection and delivery costs must be included where applicable.

### 5.10 Positioning

Price the complete creative-branding service, not just machine output. Quotation descriptions should make the value visible: design/preparation, material, production, finishing, quality checks and fulfilment where relevant.

## 6. Profit calculations and guardrails

Use precise definitions throughout the application:

- **Gross profit (KSh):** net selling amount after discounts minus the defined production cost basis.
- **Gross margin (%):** gross profit divided by net selling amount, multiplied by 100.
- **Markup (%):** gross profit divided by cost, multiplied by 100.

Do not label markup as margin. For example, a KSh 1,000 cost and KSh 1,500 selling price gives KSh 500 gross profit, 33.3% gross margin and 50% markup.

The shared pricing layer should calculate a minimum allowable selling price from the configured minimum margin:

`minimum price = cost basis / (1 - minimum margin)`

The minimum margin is a configurable business policy, not a value to invent in code. The system must define whether the protected cost basis is direct production cost alone or direct cost plus an allocated overhead amount. Until that policy is configured, show both direct-cost profitability and any separately allocated overhead rather than pretending they are the same measure.

A discount, tier selection, bundle adjustment or manual price must be rechecked after all adjustments. If it breaches the floor, block it or require a specifically authorised, reasoned exception. Do not silently accept it.

## 7. Cost classification and double-counting controls

For every cost component, define whether it is:

- Direct material or blank-item cost
- Direct labour
- Machine use / maintenance
- Outsourced supplier cost
- Artwork / design service
- Finishing / packaging / handling
- Job-attributed overhead
- Delivery or pass-through expense

A component must appear once in the calculation. For example, if a machine hourly rate already includes electricity, electricity must not be added again. Labour time and machine time are separate unless a documented process rate explicitly combines them. Customer-supplied blanks are excluded from blank-item cost, but printing, labour, machine use, artwork and finishing remain chargeable.

## 8. Fit with the current application

The existing application already has versioned product costing profiles, costing components, pricing rules, an `estimate_line_cost` function, quotation pricing snapshots and cost-estimate snapshots. The current quote flow supports percentage-on-cost, margin-on-price, fixed-amount and manual pricing, and it stores the estimated cost and pricing rule details with each quotation line.

The design should extend these capabilities rather than replace them wholesale:

- Keep the current costing engine as the method execution layer where it fits.
- Add a common pricing-policy layer around method results.
- Preserve item-specific-over-category profile precedence.
- Keep manual prices as explicit overrides, with improved authorisation/reason capture.
- Add discount-floor validation after line and order discounts, not only before them.
- Keep historical quote/order snapshots immutable.
- Avoid a database migration until the full policy, schema impact, RLS, RPC signatures, audit behaviour and test plan are reviewed and separately approved.

The quote UI now supports both exact catalogue-item costing profiles and category-level fallback profiles on `main`. This incorporates the reviewed changes from draft PR #4, which was closed as superseded after its changes were committed directly to `main` at the owner's request.

## 9. Validation plan before specialised calculators

Use a representative test matrix. Test values should come from verified stock costs, supplier quotes and measured production times; do not invent final rates or discounts.

| Scenario | Expected validation |
|---|---|
| Stocked blank garment + decoration | Blank cost, material, labour and machine components appear once |
| Customer-supplied garment | Blank cost and blank stock issue are absent; decoration costs remain |
| Mug / sublimation item | Uses its own blank, transfer, consumable, labour and press assumptions |
| Sticker / vinyl job | Uses an appropriate area/yield or linear-layout method; no full-roll charge by default |
| Banner / signage | Uses dimensions, material, finishing and any outsourced process |
| Artwork-only service | No irrelevant physical-material cost; artwork effort and revisions are priced |
| Outsourced DTF | Supplier and attributable landed costs are included before margin |
| Quantity order | Per-unit cost changes only where measurable batch efficiencies exist |
| Good / Better / Best | Each tier has a distinct specification and cost |
| Bundle | Each line remains traceable and combined discount respects the floor |
| Manual override | Actor, reason, original calculated price and final price are retained |
| Pricing-rule change | New quotes use the new effective rule; existing quotes remain unchanged |
| Missing costing profile | Quote cannot silently produce a zero-cost automatic price |
| Margin boundary | Price at the floor passes; price below it is blocked or explicitly escalated |

Also validate that all monetary arithmetic uses the current integer-KSh convention and that rounding is deterministic at line and order level.

## 10. Decisions still required before rates are configured

The framework can be designed now, but these commercial values must come from the owner and actual business evidence before they are activated:

1. Minimum gross margin policy, potentially varying by product/service class.
2. Whether and how job-attributed overhead is included in the protected price floor.
3. Which products genuinely need Good / Better / Best tiers.
4. Quantity breakpoints and the actual savings at each breakpoint.
5. Artwork service levels, revision allowances and charges.
6. Which complexity drivers are measurable and which require a documented manual band.
7. Which roles may approve below-floor exceptions and manual overrides.
8. Bundle discount authority and allocation policy.
9. Outsourcing risk/handling policy based on real supplier experience.
10. Quotation validity periods and price-change communication rules.

No default percentage, price, commission, labour rate or margin threshold should be hard-coded before these decisions are confirmed.

## 11. Delivery sequence

1. Review this framework against the current UI, SQL functions, schema constraints, RLS and tests.
2. Resolve policy decisions and confirm the profitability cost basis.
3. Define a pure, testable pricing calculation contract and representative fixtures.
4. Validate existing pricing-rule behaviour and quotation snapshots against that contract.
5. Implement shared pricing controls on an isolated branch, without changing unrelated product costing.
6. Add measurement-and-complexity as one specialised method after the shared framework passes validation.
7. Present database impact and migration/test plan separately for explicit approval.
8. Merge and deploy only after their separate approvals.

**No database migration, hosted database write, merge or deployment is authorised by this design document.**
