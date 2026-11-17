const roundKes = (amount) => {
  if (!Number.isFinite(amount)) throw new TypeError("Amount must be a finite number.");
  return Math.sign(amount) * Math.round(Math.abs(amount));
};

const requireNonNegative = (value, label) => {
  if (!Number.isFinite(value) || value < 0) {
    throw new RangeError(label + " must be a finite, non-negative number.");
  }
};

export function calculateRuleUnitPrice({ unitCost, method, value = 0 }) {
  requireNonNegative(unitCost, "Unit cost");
  requireNonNegative(value, "Pricing value");

  let rawPrice;
  switch (method) {
    case "percentage_on_cost":
      rawPrice = unitCost * (1 + value / 100);
      break;
    case "margin_on_price":
      if (value >= 100) throw new RangeError("Target margin must be below 100%.");
      rawPrice = unitCost / (1 - value / 100);
      break;
    case "fixed_amount":
      rawPrice = unitCost + value;
      break;
    case "manual":
      throw new Error("Manual pricing requires an explicit owner-entered unit price.");
    default:
      throw new Error("Unsupported pricing method.");
  }

  return roundKes(rawPrice);
}

export function calculateLineProfitability({
  quantity,
  unitPrice,
  lineDiscount = 0,
  estimatedTotalCost,
}) {
  if (!Number.isFinite(quantity) || quantity <= 0) {
    throw new RangeError("Quantity must be greater than zero.");
  }
  requireNonNegative(unitPrice, "Unit price");
  requireNonNegative(lineDiscount, "Line discount");
  requireNonNegative(estimatedTotalCost, "Estimated total cost");
  if (!Number.isSafeInteger(unitPrice) || !Number.isSafeInteger(lineDiscount)
    || !Number.isSafeInteger(estimatedTotalCost)) {
    throw new RangeError("KES unit prices, discounts and costs must be whole amounts.");
  }

  const grossAmount = roundKes(quantity * unitPrice);
  if (lineDiscount > grossAmount) {
    throw new RangeError("Line discount cannot exceed the gross line amount.");
  }
  const netSellingAmount = grossAmount - lineDiscount;
  const grossProfit = netSellingAmount - estimatedTotalCost;

  return {
    grossAmount,
    lineDiscount,
    netSellingAmount,
    estimatedTotalCost,
    grossProfit,
    grossMarginPercent: netSellingAmount > 0
      ? (grossProfit / netSellingAmount) * 100
      : null,
    markupPercent: estimatedTotalCost > 0
      ? (grossProfit / estimatedTotalCost) * 100
      : null,
  };
}

export function calculateMinimumNetSellingAmount({
  estimatedTotalCost,
  minimumGrossMarginPercent,
}) {
  requireNonNegative(estimatedTotalCost, "Estimated total cost");
  if (!Number.isFinite(minimumGrossMarginPercent)
    || minimumGrossMarginPercent < 0
    || minimumGrossMarginPercent >= 100) {
    throw new RangeError("Minimum gross margin must be from 0% up to, but below, 100%.");
  }
  return Math.ceil(estimatedTotalCost / (1 - minimumGrossMarginPercent / 100));
}

export function evaluateMinimumMargin({
  quantity,
  unitPrice,
  lineDiscount = 0,
  estimatedTotalCost,
  minimumGrossMarginPercent = null,
}) {
  const economics = calculateLineProfitability({
    quantity, unitPrice, lineDiscount, estimatedTotalCost,
  });

  if (minimumGrossMarginPercent === null || minimumGrossMarginPercent === undefined) {
    return {
      status: "not_configured",
      passes: null,
      minimumNetSellingAmount: null,
      shortfall: null,
      ...economics,
    };
  }

  const minimumNetSellingAmount = calculateMinimumNetSellingAmount({
    estimatedTotalCost,
    minimumGrossMarginPercent,
  });
  const shortfall = Math.max(0, minimumNetSellingAmount - economics.netSellingAmount);

  return {
    status: shortfall === 0 ? "passes" : "below_floor",
    passes: shortfall === 0,
    minimumNetSellingAmount,
    shortfall,
    ...economics,
  };
}
