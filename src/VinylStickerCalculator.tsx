import { useMemo, useState } from 'react';

const money=(value:number)=>new Intl.NumberFormat('en-KE',{style:'currency',currency:'KES',maximumFractionDigits:2}).format(Number.isFinite(value)?value:0);

export default function VinylStickerCalculator(){
 const [materialCost,setMaterialCost]=useState('154.43');
 const [design,setDesign]=useState('simple');
 const [hourlyRate,setHourlyRate]=useState('220');
 const hours=design==='simple'?1.3:design==='medium'?1.5:1.8;
 const calculation=useMemo(()=>{
  const material=Math.max(0,Number(materialCost)||0);
  const rate=Math.max(0,Number(hourlyRate)||0);
  const labour=hours*rate;
  const direct=material+labour;
  return {material,labour,direct,minimum:direct>0?Math.ceil(direct/0.7):0,target:direct*1.8};
 },[materialCost,hourlyRate,hours]);
 return <div className="sticker-calculator">
  <div className="heading"><div><small className="eyebrow">QUICK PRICING TOOL</small><h1>Vinyl sticker calculator</h1><p>Standalone calculator for plotter-cut vinyl lettering and designs.</p></div></div>
  <section className="panel">
   <h3>1. Material cost</h3>
   <p className="muted">Enter the vinyl material cost after calculating the required length from the sticker dimensions and roll price.</p>
   <label className="op-field">Vinyl material cost (KES)<input type="number" min="0" step="0.01" value={materialCost} onChange={e=>setMaterialCost(e.target.value)} placeholder="Enter material cost"/></label>
   <h3>2. Cutting and weeding</h3>
   <div className="op-grid">
    <label className="op-field">Design complexity<select value={design} onChange={e=>setDesign(e.target.value)}><option value="simple">Simple lettering · 1.3 hours</option><option value="medium">Medium design · 1.5 hours</option><option value="complicated">Complicated design · 1.8 hours</option></select></label>
    <label className="op-field">Labour rate (KES per hour)<input type="number" min="0" step="1" value={hourlyRate} onChange={e=>setHourlyRate(e.target.value)} /></label>
   </div>
   <div className="cost-preview">
    <div><small>Cutting and weeding time</small><b>{hours.toFixed(1)} hours</b></div>
    <div><small>Cutting and weeding labour</small><b>{money(calculation.labour)}</b></div>
    <div><small>Vinyl material</small><b>{money(calculation.material)}</b></div>
    <div><small>Total direct production cost</small><b>{money(calculation.direct)}</b></div>
    <div><small>Minimum selling price · 30% gross margin</small><b>{money(calculation.minimum)}</b></div>
    <div><small>1.8× target · warning only</small><b>{money(calculation.target)}</b></div>
   </div>
   <p className="muted">Minimum selling price = (material cost + cutting and weeding labour) ÷ 0.70, rounded up to the next KSh. Transfer tape and application are excluded. The 1.8× target is a warning, not a mandatory price.</p>
  </section>
 </div>;
}
