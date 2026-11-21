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

test('invalid dimensions and quantities are rejected rather than silently omitted', () => {
  assert.match(layoutDtfStickers([{id:1,widthCm:0,heightCm:10,quantity:1}]).error,/positive finite width and height/i);
  assert.match(layoutDtfStickers([{id:1,widthCm:10,heightCm:10,quantity:1.5}]).error,/whole numbers/i);
  assert.match(layoutDtfStickers([{id:1,widthCm:10,heightCm:10,quantity:0}]).error,/whole numbers/i);
});

test('invalid roll and gap settings are rejected', () => {
  assert.match(layoutDtfStickers([{id:1,widthCm:10,heightCm:10,quantity:1}],{rollWidthCm:0}).error,/roll width/i);
  assert.match(layoutDtfStickers([{id:1,widthCm:10,heightCm:10,quantity:1}],{gapCm:-1}).error,/non-negative/i);
  assert.match(layoutDtfStickers([{id:1,widthCm:10,heightCm:10,quantity:1}],{gapCm:NaN}).error,/non-negative/i);
});

test('every packed piece remains inside the roll and separated by the configured gap', () => {
  const gap = 0.5;
  const result = layoutDtfStickers([
    {id:'A',widthCm:18,heightCm:12,quantity:3,allowRotation:true},
    {id:'B',widthCm:25,heightCm:9,quantity:2,allowRotation:true},
    {id:'C',widthCm:12,heightCm:8,quantity:2,allowRotation:false}
  ],{gapCm:gap});
  assert.equal(result.error,'');
  assert.ok(result.placements.every(p=>p.xCm>=0&&p.yCm>=0&&p.xCm+p.widthCm<=58+1e-9));
  for (let i=0;i<result.placements.length;i++) {
    for (let j=i+1;j<result.placements.length;j++) {
      const a=result.placements[i], b=result.placements[j];
      const separated=a.xCm+a.widthCm+gap<=b.xCm+1e-9 ||
        b.xCm+b.widthCm+gap<=a.xCm+1e-9 ||
        a.yCm+a.heightCm+gap<=b.yCm+1e-9 ||
        b.yCm+b.heightCm+gap<=a.yCm+1e-9;
      assert.ok(separated, 'packed rectangles must not overlap and must respect the gap');
    }
  }
});
