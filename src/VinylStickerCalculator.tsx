import { useMemo, useState } from 'react';

const money=(value:number)=>new Intl.NumberFormat('en-KE',{style:'currency',currency:'KES',maximumFractionDigits:2}).format(Number.isFinite(value)?value:0);
const wholeKsh=(value:number)=>Math.ceil(Math.max(0,value));

export default function VinylStickerCalculator(){
 const [materialCost,setMaterialCost]=useState('51.47');
 const [productionLabour,setProductionLabour]=useState('0');
 const [transferTape,setTransferTape]=useState('0');
 const [applicationCost,setApplicationCost]=useState('0');
 const [design,setDesign]=useState('simple');
 const [quotedPrice,setQuotedPrice]=useState('');
 const multiplier=design==='simple'?1.3:design==='medium'?1.5:1.8;
 const calculation=useMemo(()=>{
  const material=Math.max(0,Number(materialCost)||0);
  const labour=Math.max(0,Number(productionLabour)||0);
  const tape=Math.max(0,Number(transferTape)||0);
  const application=Math.max(0,Number(applicationCost)||0);
  const direct=material+labour+tape+application;
  const minimum=direct>0?wholeKsh(direct/0.7):0;
  const designPrice=direct>0?wholeKsh(direct*multiplier):0;
  const suggested=Math.max(minimum,designPrice);
  const highest=direct>0?wholeKsh(direct*1.8):0;
  const quote=quotedPrice.trim()===''?suggested:Math.max(0,Number(quotedPrice)||0);
  const profit=quote-direct;
  const margin=quote>0?profit/quote*100:0;
  return {material,labour,tape,application,direct,minimum,designPrice,suggested,highest,quote,profit,margin};
 },[materialCost,productionLabour,transferTape,applicationCost,multiplier,quotedPrice]);
 return <div className="sticker-calculator">
  <div className="heading"><div><small className="eyebrow">QUICK PRICING TOOL</small><h1>Vinyl sticker calculator</h1><p>Calculate direct production cost and a design-based selling price.</p></div></div>
  <section className="panel">
   <h3>1. Enter direct production costs</h3>
   <p className="muted">Enter the costs used for this job. Leave optional items at zero when they do not apply.</p>
   <div className="op-grid">
    <label className="op-field">Vinyl material cost (KES)<input type="number" min="0" step="0.01" value={materialCost} onChange={e=>setMaterialCost(e.target.value)}/></label>
    <label className="op-field">Cutting and weeding labour (KES)<input type="number" min="0" step="0.01" value={productionLabour} onChange={e=>setProductionLabour(e.target.value)}/></label>
    <label className="op-field">Transfer tape (KES)<input type="number" min="0" step="0.01" value={transferTape} onChange={e=>setTransferTape(e.target.value)}/></label>
    <label className="op-field">Application labour/cost (KES)<input type="number" min="0" step="0.01" value={applicationCost} onChange={e=>setApplicationCost(e.target.value)}/></label>
   </div>
   <div className="cost-preview">
    <div><small>Vinyl material</small><b>{money(calculation.material)}</b></div>
    <div><small>Cutting and weeding labour</small><b>{money(calculation.labour)}</b></div>
    <div><small>Transfer tape</small><b>{money(calculation.tape)}</b></div>
    <div><small>Application</small><b>{money(calculation.application)}</b></div>
    <div><small>Total direct production cost</small><b>{money(calculation.direct)}</b></div>
   </div>
   <h3>2. Select design difficulty</h3>
   <label className="op-field">Design pricing multiplier<select value={design} onChange={e=>setDesign(e.target.value)}><option value="simple">Simple design · 1.3×</option><option value="medium">Medium design · 1.5×</option><option value="complicated">Complicated design · 1.8×</option></select></label>
   <p className="muted">These are sale-price multipliers based on design difficulty, not labour hours.</p>
   <h3>3. Suggested selling prices</h3>
   <div className="cost-preview">
    <div><small>Minimum acceptable price · 30% gross margin</small><b>{money(calculation.minimum)}</b></div>
    <div><small>Price from selected design multiplier · {multiplier.toFixed(1)}×</small><b>{money(calculation.designPrice)}</b></div>
    <div><small>Suggested sale price (30% floor applied)</small><b>{money(calculation.suggested)}</b></div>
    <div><small>Highest standard multiplier guide · 1.8×</small><b>{money(calculation.highest)}</b></div>
   </div>
   <p className="muted">The selected design multiplier determines the price suggestion. If that result is below the required 30% gross-margin floor, the calculator raises the suggestion to the minimum acceptable price. The 1.8× figure is a guide for complicated designs, not a price ceiling; higher prices may be appropriate.</p>
   <h3>4. Check the customer quotation</h3>
   <label className="op-field">Actual quoted price (KES)<input type="number" min="0" step="1" value={quotedPrice===''?String(calculation.suggested):quotedPrice} onChange={e=>setQuotedPrice(e.target.value)} placeholder="Enter customer price"/></label>
   <div className="cost-preview">
    <div><small>Quoted selling price</small><b>{money(calculation.quote)}</b></div>
    <div><small>Gross profit on direct cost</small><b>{money(calculation.profit)}</b></div>
    <div><small>Gross margin</small><b>{calculation.margin.toFixed(1)}%</b></div>
   </div>
   {calculation.direct>0&&calculation.quote<calculation.minimum?<p className="notice error">Below minimum: this quotation is under the 30% gross-margin floor. Increase the price or handle it as an authorised below-floor exception with a recorded reason.</p>:calculation.direct>0?<p className="muted">This quotation meets the minimum 30% gross-margin requirement.</p>:<p className="muted">Enter production costs to calculate a selling price.</p>}
  </section>
 </div>;
}
