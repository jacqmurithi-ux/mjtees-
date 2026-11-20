import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const calculator=readFileSync(new URL('../src/VinylStickerCalculator.tsx',import.meta.url),'utf8');
const migration=readFileSync(new URL('../supabase/migrations/20261121100000_vinyl_sticker_quick_sales.sql',import.meta.url),'utf8');
test('vinyl sticker pricing has no fixed 5x5 reference price',()=>{
 assert.doesNotMatch(calculator,/5\s*[×x]\s*5-inch|KSh\s*100|baseline/i);
 assert.match(calculator,/area\/stockArea\*stock/);
});
test('sticker pricing applies the 30% margin floor and complexity separately',()=>{
 assert.match(calculator,/unitDirect\/0\.7/);
 assert.match(calculator,/complexityFactors/);
 assert.match(calculator,/Final agreed customer price/);
});
test('calculator records a quick sale through the owner RPC without navigation',()=>{
 assert.match(calculator,/owner_create_vinyl_sticker_quick_sale/);
 assert.match(calculator,/Record Quick Sale/);
 assert.match(calculator,/p_direct_cost_breakdown/);
});
test('server RPC records direct cost snapshot and preserves the canonical sale ledger',()=>{
 assert.match(migration,/owner_create_custom_job_quick_sale/);
 assert.match(migration,/sales_invoice_items/);
 assert.match(migration,/gross_margin_percent/);
 assert.match(migration,/p_payment_amount/); 
});
