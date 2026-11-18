import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const sql = readFileSync(new URL("../supabase/migrations/20261119000300_bulk_contract_printing_output.sql", import.meta.url), "utf8");

test("production output is owner-authorised, idempotent and append-only", () => {
  assert.match(sql, /private\.assert_active_owner\(v_job\.business_id\)/);
  assert.match(sql, /begin_idempotent_request\(v_job\.business_id,'record_production_output'/);
  assert.match(sql, /unique \(business_id,request_id\)/);
  assert.match(sql, /before update or delete on public\.production_output_entries/);
  assert.match(sql, /revoke all on function public\.owner_record_production_output/);
});

test("accepted production cannot exceed the contracted quantity", () => {
  assert.match(sql, /v_accepted_after>v_job\.planned_quantity/);
  assert.match(sql, /quantity_accepted numeric\(12,3\) generated always as \(quantity_printed - quantity_rejected\)/);
});

test("customer supplied garments are not written to inventory by the output ledger", () => {
  assert.doesNotMatch(sql, /insert into public\.(stock_movements|inventory_movements)/i);
  assert.match(sql, /production_output_entries/);
  assert.match(sql, /insert into public\.production_cost_entries/);
  assert.match(sql, /owner_list_production_output/);
  assert.match(sql, /private\.assert_active_owner\(p_business_id\)/);
});
