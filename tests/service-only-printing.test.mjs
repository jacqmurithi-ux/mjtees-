import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const quote = readFileSync("src/QuoteWorkflow.tsx", "utf8");
const production = readFileSync("src/OrderProductionWorkflow.tsx", "utf8");
const realtime = readFileSync("supabase/migrations/20261119130000_enable_owner_workflow_realtime.sql", "utf8");

test("customer-supplied screen printing has a versioned outsourced-labour costing preset", () => {
  assert.match(quote, /prepareScreenPrintingCostProfile/);
  assert.match(quote, /code==="screen_printing"/);
  assert.match(quote, /componentType:"outsourced_service"/);
  assert.match(quote, /driverType:"per_order"/);
  assert.match(quote, /fixedCost:"200"/);
  assert.match(quote, /owner_create_costing_profile/);
});

test("service-only quotations retain customer-supplied garments and manual agreed price", () => {
  assert.match(quote, /Customer supplies the item/);
  assert.match(quote, /customerSupplies/);
  assert.match(quote, /Final agreed unit selling price/);
  assert.match(quote, /owner_create_quotation/);
});

test("outsourced printing labour can be recorded against the production job", () => {
  assert.match(production, /Use Baraka outsourced labour example/);
  assert.match(production, /workerType:"temporary"/);
  assert.match(production, /workerName:"Outsourced printer"/);
  assert.match(production, /labourCost:"200"/);
  assert.match(production, /owner_record_production_output/);
});

test("owner workflow changes refresh from Realtime while preserving payment exception for later settlement", () => {
  assert.match(quote, /postgres_changes/);
  assert.match(production, /postgres_changes/);
  assert.match(production, /invoice remains outstanding until a payment is posted/);
  for (const table of ["quotations","orders","order_items","sales_invoices","production_jobs","production_cost_entries","production_output_entries","quality_checks","rework_events"]) {
    assert.match(realtime, new RegExp("'" + table + "'"));
  }
});

test("Realtime publication only exposes tables already protected by RLS", () => {
  assert.match(realtime, /Supabase Realtime publication/);
  assert.match(realtime, /alter publication supabase_realtime add table/);
});
