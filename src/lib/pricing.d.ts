export type PricingMethod = "percentage_on_cost" | "margin_on_price" | "fixed_amount" | "manual";

export interface LineProfitabilityInput {
  quantity: number;
  unitPrice: number;
  lineDiscount?: number;
  estimatedTotalCost: number;
}

export interface LineProfitability {
  grossAmount: number;
  lineDiscount: number;
  netSellingAmount: number;
  estimatedTotalCost: number;
  grossProfit: number;
  grossMarginPercent: number | null;
  markupPercent: number | null;
}

export function calculateRuleUnitPrice(input: {
  unitCost: number;
  method: PricingMethod;
  value?: number;
}): number;

export function calculateLineProfitability(input: LineProfitabilityInput): LineProfitability;

export function calculateMinimumNetSellingAmount(input: {
  estimatedTotalCost: number;
  minimumGrossMarginPercent: number;
}): number;

export function evaluateMinimumMargin(input: LineProfitabilityInput & {
  minimumGrossMarginPercent?: number | null;
}): LineProfitability & {
  status: "not_configured" | "passes" | "below_floor";
  passes: boolean | null;
  minimumNetSellingAmount: number | null;
  shortfall: number | null;
};

export interface QuotationLineProfitabilityInput extends LineProfitabilityInput {
  orderDiscountAllocated?: number;
}

export function calculateQuotationProfitability(input: {
  lines: QuotationLineProfitabilityInput[];
  minimumGrossMarginPercent?: number;
}): {
  lines: Array<LineProfitability & { orderDiscountAllocated: number }>;
  netSellingAmount: number;
  estimatedTotalCost: number;
  grossProfit: number;
  grossMarginPercent: number | null;
  minimumNetSellingAmount: number;
  shortfall: number;
  status: "passes" | "below_floor";
  passes: boolean;
};
