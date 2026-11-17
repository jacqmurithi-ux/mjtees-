import test from "node:test";
import assert from "node:assert/strict";
import {
  calculateRuleUnitPrice,
  calculateLineProfitability,
  calculateMinimumNetSellingAmount,
  evaluateMinimumMargin,
} from "../src/lib/pricing.js";

test("percentage-on-cost pricing matches the database rule", () => {
  assert.equal(calculateRuleUnitPrice({ unitCost: 1000, method: "percentage_on_cost", value: 50 }), 1500);
});

test("margin-on-price pricing calculates a target gross margin", () => {
  assert.equal(calculateRuleUnitPrice({ unitCost: 1000, method: "margin_on_price", value: 33.333 }), 1500);
});

test("fixed amount pricing adds the configured amount to cost", () => {
  assert.equal(calculateRuleUnitPrice({ unitCost: 1000, method: "fixed_amount", value: 250 }), 1250);
});

test("manual pricing requires an explicit entered price", () => {
  assert.throws(() => calculateRuleUnitPrice({ unitCost: 1000, method: "manual" }), /owner-entered/);
});

test("line profitability is calculated after discounts", () => {
  const result = calculateLineProfitability({
    quantity: 3, unitPrice: 500, lineDiscount: 100, estimatedTotalCost: 900,
  });
  assert.equal(result.grossAmount, 1500);
  assert.equal(result.netSellingAmount, 1400);
  assert.equal(result.grossProfit, 500);
  assert.equal(result.grossMarginPercent, (500 / 1400) * 100);
  assert.equal(result.markupPercent, (500 / 900) * 100);
});

test("minimum selling amount rounds upward to protect the margin floor", () => {
  assert.equal(calculateMinimumNetSellingAmount({
    estimatedTotalCost: 1000, minimumGrossMarginPercent: 30,
  }), 1429);
});

test("floor evaluation passes at the boundary and fails one shilling below", () => {
  const common = { quantity: 1, lineDiscount: 0, estimatedTotalCost: 1000, minimumGrossMarginPercent: 30 };
  assert.equal(evaluateMinimumMargin({ ...common, unitPrice: 1429 }).status, "passes");
  const below = evaluateMinimumMargin({ ...common, unitPrice: 1428 });
  assert.equal(below.status, "below_floor");
  assert.equal(below.shortfall, 1);
});

test("unconfigured margin policy is reported, not silently invented", () => {
  const result = evaluateMinimumMargin({
    quantity: 1, unitPrice: 1500, estimatedTotalCost: 1000,
  });
  assert.equal(result.status, "not_configured");
  assert.equal(result.passes, null);
  assert.equal(result.minimumNetSellingAmount, null);
});

test("discount cannot exceed the gross line amount", () => {
  assert.throws(() => calculateLineProfitability({
    quantity: 1, unitPrice: 100, lineDiscount: 101, estimatedTotalCost: 50,
  }), /cannot exceed/);
});

test("invalid target margin is rejected", () => {
  assert.throws(() => calculateRuleUnitPrice({
    unitCost: 1000, method: "margin_on_price", value: 100,
  }), /below 100/);
});
