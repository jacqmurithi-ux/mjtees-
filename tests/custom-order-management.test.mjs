import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const migration = readFileSync("supabase/migrations/20261119000800_custom_order_management_workflows.sql", "utf8");
const component = readFileSync("src/CustomOrderDetails.tsx", "utf8");
const production = readFileSync("src/OrderProductionWorkflow.tsx", "utf8");

test("custom order detail writes use owner-authorised transactional RPCs", () => {
  for (const name of [
    "owner_add_job_size_breakdown",
    "owner_add_job_artwork",
    "owner_set_job_artwork_status",
    "owner_add_job_colour_separation",
  ]) {
    assert.match(migration, new RegExp("create or replace function private\\." + name));
    assert.match(migration, new RegExp("create or replace function public\\." + name));
    assert.match(migration, new RegExp("private\\.assert_active_owner"));
    assert.match(migration, new RegExp("private\\.begin_idempotent_request"));
    assert.match(migration, new RegExp("private\\.write_audit"));
  }
});

test("artwork proof history only accepts Google Drive references and preserves versions", () => {
  assert.match(migration, /drive\|docs\)\[\.\]google\[\.\]com/);
  assert.match(migration, /coalesce\(max\(version\),0\)\+1/);
  assert.match(migration, /proof_status='superseded'/);
  assert.match(migration, /approved_at=case when p_proof_status='approved'/);
});

test("custom order UI reads owner-visible records and calls RPCs, never direct-writes protected tables", () => {
  for (const table of ["sales_job_size_breakdown", "sales_job_artworks", "sales_job_colour_separations"]) {
    assert.match(component, new RegExp('from\\("' + table + '"\\)'));
    assert.doesNotMatch(component, new RegExp('from\\("' + table + '"\\)\\.(insert|update|upsert|delete)'));
  }
  for (const name of [
    "owner_add_job_size_breakdown",
    "owner_add_job_artwork",
    "owner_set_job_artwork_status",
    "owner_add_job_colour_separation",
  ]) assert.match(component, new RegExp('run\\("' + name + '"'));
});

test("custom order details are available within each production job", () => {
  assert.match(production, /import CustomOrderDetails from "\.\/CustomOrderDetails"/);
  assert.match(production, /<CustomOrderDetails businessId=\{businessId\} jobId=\{job\.id\}\/>/);
  assert.match(component, /Artwork stays in Google Drive/);
  assert.match(component, /Individual garment \/ player sizes/);
  assert.match(component, /Colour separations \/ screen setup/);
});
