import { useMemo, useState } from 'react';

const money=(value:number)=>new Intl.NumberFormat('en-KE',{style:'currency',currency:'KES',maximumFractionDigits:2}).format(Number.isFinite(value)?value:0);
const wholeKsh=(value:number)=>Math.ceil(Math.max(0,value));

export default function VinylStickerCalculator(){
 const [length,setLength]=useState('12');
 const [width,setWidth]=useState('4');
 const [stockLength,setStockLength]=useState('39.37');
 const [stockWidth,setStockWidth]=useState('24');
 const [stockPrice,setStockPrice]=useState('160');
 const [productionLabour,setProductionLabour]=useState('0');
 const [transferTape,setTransferTape]=useState('0');
 const [applicationCost,setApplicationCost]=useState('0');
 const [design,setDesign]=useState('simple');
 const [quotedPrice,setQuotedPrice]=useState('');
 const multiplier=design==='simple'?1.3:design==='medium'?1.5:1.8;
 const calculation=useMemo(()=>{
  const l=Math.max(0,Number(length)||0);
  const w=Math.max(0,Number(width)||0);
  const stockL=Math.max(0,Number(stockLength)||0);
  const stockW=Math.max(0,Number(stockWidth)||0);
  const stock=Math.max(0,Number(stockPrice)||0);
  const area=l*w;
  const stockArea=stockL*stockW;
  const material=stockArea>0?area/stockArea*stock:0;
  const labour=Math.max(0,Number(productionLabour)||0);
  const tape=Math.max(0,Number(transferTape)||0);
  const application=Math.max(0,Number(applicationCost)||0);
  const direct=material+labour+tape+application;
  const baseline=area>0?100*(area/25):0;
  const difficultyPrice=baseline*multiplier;
  const minimum=direct>0?direct/0.7:0;
  const suggested=wholeKsh(Math.max(difficultyPrice,minimum));
  const guide=wholeKsh(baseline*1.8);
  const quote=quotedPrice.trim()===''?suggested:Math.max(0,Number(quotedPrice)||0);
  const profit=quote-direct;
  const margin=quote>0?profit/quote*100:0;
  return {l,w,area,stockArea,material,labour,tape,application,direct,baseline,difficultyPrice,minimum,suggested,guide,quote,profit,margin};
 },[length,width,stockLength,stockWidth,stockPrice,productionLabour,transferTape,applicationCost,multiplier,quotedPrice]);
 return <div className="sticker-calculator">
  <div className="heading"><div><small className="eyebrow">QUICK PRICING TOOL</small><h1>Vinyl sticker calculator</h1><p>Enter sticker dimensions and job details. The calculator works out the material usage and suggested selling price.</p></div></div>
  <section className="panel">
   <h3>1. Sticker dimensions</h3>
   <p className="muted">Enter the finished sticker length and width in inches. Pricing starts from the approved 5 × 5-inch baseline of KSh 100 and scales by area.</p>
   <div className="op-grid">
    <label className="op-field">Sticker length (inches)<input type="number" min="0" step="0.01" value={length} onChange={e=>setLength(e.target.value)}/></label>
    <label className="op-field">Sticker width (inches)<input type="number" min="0" step="0.01" value={width} onChange={e=>setWidth(e.target.value)}/></label>
   </div>
   <div className="cost-preview">
    <div><small>Sticker area</small><b>{calculation.area.toFixed(2)} sq. in.</b></div>
    <div><small>Area-scaled baseline price</small><b>{money(calculation.baseline)}</b></div>
   </div>
   <h3>2. Vinyl stock details</h3>
   <p className="muted">Defaults use one metre of 24-inch-wide vinyl at KSh 160. Change these if the stock size or purchase price changes.</p>
   <div className="op-grid">
    <label className="op-field">Stock length (inches)<input type="number" min="0" step="0.01" value={stockLength} onChange={e=>setStockLength(e.target.value)}/></label>
    <label className="op-field">Stock width (inches)<input type="number" min="0" step="0.01" value={stockWidth} onChange={e=>setStockWidth(e.target.value)}/></label>
    <label className="op-field">Full stock price (KES)<input type="number" min="0" step="0.01" value={stockPrice} onChange={e=>setStockPrice(e.target.value)}/></label>
   </div>
   <h3>3. Other direct production costs</h3>
   <p className="muted">Enter only costs that apply to this job. For lettering-only work without weeding, tape or application, leave those fields at zero.</p>
   <div className="op-grid">
    <label className="op-field">Cutting / weeding labour (KES)<input type="number" min="0" step="0.01" value={productionLabour} onChange={e=>setProductionLabour(e.target.value)}/></label>
    <label className="op-field">Transfer tape (KES)<input type="number" min="0" step="0.01" value={transferTape} onChange={e=>setTransferTape(e.target.value)}/></label>
    <label className="op-field">Application labour / cost (KES)<input type="number" min="0" step="0.01" value={applicationCost} onChange={e=>setApplicationCost(e.target.value)}/></label>
   </div>
   <div className="cost-preview">
    <div><small>Vinyl material cost (area-based)</small><b>{money(calculation.material)}</b></div>
    <div><small>Other direct costs</small><b>{money(calculation.labour+calculation.tape+calculation.application)}</b></div>
    <div><small>Total direct production cost</small><b>{money(calculation.direct)}</b></div>
   </div>
   <h3>4. Select design difficulty</h3>
   <label className="op-field">Design difficulty<select value={design} onChange={e=>setDesign(e.target.value)}><option value="simple">Simple · 1.3×</option><option value="medium">Medium · 1.5×</option><option value="complicated">Complicated · 1.8×</option></select></label>
   <p className="muted">Difficulty multipliers determine the selling price from the area-scaled baseline. They are price multipliers, not labour hours.</p>
   <h3>5. Suggested selling prices</h3>
   <div className="cost-preview">
    <div><small>5 × 5-inch reference baseline</small><b>KSh 100.00</b></div>
    <div><small>Area-scaled baseline for this sticker</small><b>{money(calculation.baseline)}</b></div>
    <div><small>Selected difficulty price · {multiplier.toFixed(1)}×</small><b>{money(calculation.difficultyPrice)}</b></div>
    <div><small>Minimum price for 30% gross margin</small><b>{money(calculation.minimum)}</b></div>
    <div><small>Suggested selling price</small><b>{money(calculation.suggested)}</b></div>
    <div><small>Complicated-design guide · 1.8×</small><b>{money(calculation.guide)}</b></div>
   </div>
   <p className="muted">The suggested price is the greater of the area-scaled difficulty price and the price required to maintain a 30% gross margin on direct production cost. The 1.8× figure is a guide, not a hard ceiling.</p>
   <h3>6. Check the customer quotation</h3>
   <label className="op-field">Actual quoted price (KES)<input type="number" min="0" step="1" value={quotedPrice===''?String(calculation.suggested):quotedPrice} onChange={e=>setQuotedPrice(e.target.value)} placeholder="Enter customer price"/></label>
   <div className="cost-preview">
    <div><small>Quoted selling price</small><b>{money(calculation.quote)}</b></div>
    <div><small>Gross profit on direct cost</small><b>{money(calculation.profit)}</b></div>
    <div><small>Gross margin</small><b>{calculation.margin.toFixed(1)}%</b></div>
   </div>
   {calculation.direct>0&&calculation.quote<calculation.minimum?<p className="notice error">Below minimum: this quotation is under the 30% gross-margin floor. Increase the price or handle it as an authorised below-floor exception with a recorded reason.</p>:calculation.direct>0?<p className="muted">This quotation meets the minimum 30% gross-margin requirement.</p>:<p className="muted">Enter valid dimensions and stock details to calculate a selling price.</p>}
  </section>
 </div>;
}
