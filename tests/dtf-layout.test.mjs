import test from 'node:test';
import assert from 'node:assert/strict';
import { layoutDtfStickers, DTF_RATE_PER_CM2_KES } from '../src/lib/dtf-layout.js';

test('a 30 × 20 cm sticker uses only its printed dimensions, not the full 58 cm width', () => {
  const result = layoutDtfStickers([{id:1,widthCm:30,heightCm:20,quantity:1,allowRotation:true}]);
  assert.equal(result.usedWidthCm,30);
  assert.equal(result.usedLengthCm,20);
  assert.equal(result.materialAreaCm2,600);
  assert.ok(Math.abs(result.materialAreaCm2*DTF_RATE_PER_CM2_KES-72.413793)<0.001);
});

test('different sizes share one roll run and can be rotated automatically', () => {
  const result = layoutDtfStickers([
    {id:1,widthCm:30,heightCm:20,quantity:1,allowRotation:true},
    {id:2,widthCm:20,heightCm:30,quantity:1,allowRotation:true}
  ]);
  assert.equal(result.error,'');
  assert.ok(result.usedWidthCm<=58);
  assert.equal(result.placements.length,2);
  assert.ok(result.materialAreaCm2<58*50);
});

test('rotation allows a design wider than the roll in its original orientation', () => {
  const result = layoutDtfStickers([{id:1,widthCm:60,heightCm:10,quantity:1,allowRotation:true}]);
  assert.equal(result.error,'');
  assert.equal(result.placements[0].rotated,true);
  assert.equal(result.usedWidthCm,10);
  assert.equal(result.usedLengthCm,60);
});

test('a design that cannot fit in either orientation is rejected', () => {
  const result = layoutDtfStickers([{id:1,widthCm:60,heightCm:59,quantity:1,allowRotation:true}]);
  assert.match(result.error,/cannot fit/i);
});

test('rotation can be disabled for a design', () => {
  const result = layoutDtfStickers([{id:1,widthCm:60,heightCm:10,quantity:1,allowRotation:false}]);
  assert.match(result.error,/cannot fit/i);
});

test('a configurable gap is included between stickers', () => {
  const result = layoutDtfStickers([{id:1,widthCm:20,heightCm:10,quantity:2,allowRotation:false}],{gapCm:1});
  assert.equal(result.error,'');
  assert.equal(result.usedWidthCm,41);
  assert.equal(result.usedLengthCm,10);
});
