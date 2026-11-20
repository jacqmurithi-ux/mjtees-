import { useMemo, useState } from 'react';

const money=(value:number)=>new Intl.NumberFormat('en-KE',{style:'currency',currency:'KES',maximumFractionDigits:2}).format(Number.isFinite(value)?value:0);
const wholeKsh=(value:number)=>Math.ceil(Math.max(0,value));

export default function VinylStickerCalculator(){
 const [materialCost,setMaterialCost]=useState('51.47');
 const [design,setDesign]=useState('simple');
 const [hourlyRate,setHourlyRate]=useState('220');
 const [quotedPrice,setQuotedPrice]=useState('');
 const hours=design==='simple'?1.3:design==='medium'?1.5:1.8;
 const calculation=useMemo(()=>{
  const material=Math.max(0,Number(materialCost)||0);
  const rate=Math.max(0,Number(hourlyRate)||0);
  const labour=hours*rate;
  const direct=material+labour;
  const minimum=direct>0?wholeKsh(direct/0.7):0;
  const recommended=direct>0?wholeKsh(direct*1.8):0;
  const quote=quotedPrice.trim()===''?recommended:Math.max(0,Number(quotedPrice)||0);
  const profit=quote-direct;
  const margin=quote>0?profit/quote*100:0;
  return {material,labour,direct,minimum,recommended,quote,profit,margin};
 },[materialCost,hourlyRate,hours,quotedPrice]);
 return <div className="sticker-calculator">
  <div className="heading"><div><small className="eyebrow">QUICK PRICING TOOL</small><h1>Vinyl sticker calculator</h1><p>Calculate direct production cost, the minimum acceptable price and a recommended customer price.</p></div></div>
  <section className="panel">
   <h3>1. Material and labour costs</h3>
   <p className="muted">Enter the vinyl material cost for the required sticker area. Include only costs that apply to this job.</p>
   <label className="op-field">Vinyl material cost (KES)<input type="number" min="0" step="0.01" value={materialCost} onChange={e=>setMaterialCost(e.target.value)} placeholder="Enter material cost"/></label>
   <div className="op-grid">
    <label className="op-field">Design complexity<select value={design} onChange={e=>setDesign(e.target.value)}><option value="simple">Simple lettering · 1.3 hours</option><option value="medium">Medium design · 1.5 hours</option><option value="complicated">Complicated design · 1.8 hours</option></select></label>
    <label className="op-field">Labour rate (KES per hour)<input type="number" min="0" step="1" value={hourlyRate} onChange={e=>setHourlyRate(e.target.value)} /></label>
   </div>
   <div className="cost-preview">
    <div><small>Cutting and weeding time</small><b>{hours.toFixed(1)} hours</b></div>
    <div><small>Cutting and weeding labour</small><b>{money(calculation.labour)}</b></div>
    <div><small>Vinyl material</small><b>{money(calculation.material)}</b></div>
    <div><small>Total direct production cost</small><b>{money(calculation.direct)}</b></div>
   </div>
   <h3>2. Suggested selling prices</h3>
   <div className="cost-preview">
    <div><small>Minimum acceptable price · 30% gross margin</small><b>{money(calculation.minimum)}</b></div>
    <div><small>Recommended selling price · 1.8× direct cost</small><b>{money(calculation.recommended)}</b></div>
   </div>
   <p className="muted">The minimum protects a 30% gross margin on direct production cost. The 1.8× figure is a recommended target, not a maximum or compulsory price. You may quote above it when the work and market justify it.</p>
   <h3>3. Check the customer quotation</h3>
   <label className="op-field">Actual quoted price (KES)<input type="number" min="0" step="1" value={quotedPrice===''?String(calculation.recommended):quotedPrice} onChange={e=>setQuotedPrice(e.target.value)} placeholder="Enter customer price"/></label>
   <div className="cost-preview">
    <div><small>Quoted selling price</small><b>{money(calculation.quote)}</b></div>
    <div><small>Gross profit on direct cost</small><b>{money(calculation.profit)}</b></div>
    <div><small>Gross margin</small><b>{calculation.margin.toFixed(1)}%</b></div>
   </div>
   {calculation.direct>0&&calculation.quote<calculation.minimum?<p className="notice error">Below minimum: this quotation is under the 30% gross-margin floor. Increase the price or handle it as an authorised below-floor exception with a recorded reason.</p>:calculation.direct>0&&calculation.quote<calculation.recommended?<p className="muted">This quotation is above the minimum but below the recommended 1.8× target. Review the margin and customer context before confirming.</p>:calculation.direct>0?<p className="muted">This quotation meets the minimum margin and reaches or exceeds the recommended target.</p>:<p className="muted">Enter a production cost to calculate a selling price.</p>}
   <p className="muted">Current calculation includes vinyl material and cutting/weeding labour. Transfer tape and application are not included yet; add them to direct cost when they apply before relying on the suggested prices.</p>
  </section>
 </div>;
}
