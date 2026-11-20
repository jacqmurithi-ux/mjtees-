import { useEffect, useMemo, useState } from 'react';
import { supabase } from './lib/supabase';

type Customer={id:string;customer_name:string};
type Receipt=Record<string,any>;
const money=(value:number)=>new Intl.NumberFormat('en-KE',{style:'currency',currency:'KES',maximumFractionDigits:2}).format(Number.isFinite(value)?value:0);
const wholeKsh=(value:number)=>Math.ceil(Math.max(0,value));
const today=()=>new Intl.DateTimeFormat('en-CA',{timeZone:'Africa/Nairobi',year:'numeric',month:'2-digit',day:'2-digit'}).format(new Date());
const nextNumber=(prefix:string)=>prefix+'-'+Date.now().toString().slice(-8);
const complexityFactors={simple:1,medium:1.15,complicated:1.3} as const;

export default function VinylStickerCalculator({onSaleSaved}:{onSaleSaved?:()=>void}){
 const [length,setLength]=useState('12');
 const [width,setWidth]=useState('4');
 const [stockLength,setStockLength]=useState('39.37');
 const [stockWidth,setStockWidth]=useState('24');
 const [stockPrice,setStockPrice]=useState('160');
 const [productionLabour,setProductionLabour]=useState('0');
 const [transferTape,setTransferTape]=useState('0');
 const [applicationCost,setApplicationCost]=useState('0');
 const [design,setDesign]=useState<keyof typeof complexityFactors>('simple');
 const [quantity,setQuantity]=useState('1');
 const [supply,setSupply]=useState<'mj_supplies'|'customer_supplies'>('mj_supplies');
 const [description,setDescription]=useState('Custom vinyl sticker');
 const [agreedPrice,setAgreedPrice]=useState('');
 const [customers,setCustomers]=useState<Customer[]>([]);
 const [customerId,setCustomerId]=useState('');
 const [invoiceNo,setInvoiceNo]=useState(()=>nextNumber('INV'));
 const [dueDate,setDueDate]=useState(today);
 const [paymentAmount,setPaymentAmount]=useState('');
 const [paymentMethod,setPaymentMethod]=useState<'cash'|'mpesa_paybill'>('cash');
 const [paymentReference,setPaymentReference]=useState('');
 const [belowFloor,setBelowFloor]=useState(false);
 const [exceptionReason,setExceptionReason]=useState('');
 const [loading,setLoading]=useState(false);
 const [error,setError]=useState('');
 const [notice,setNotice]=useState('');
 const [receipt,setReceipt]=useState<Receipt|null>(null);

 useEffect(()=>{let active=true;void(async()=>{if(!supabase)return;const{data,error}=await supabase.from('customers').select('id,customer_name').order('customer_name');if(active&&!error)setCustomers(data||[]);})();return()=>{active=false}},[]);
 const calculation=useMemo(()=>{
  const l=Math.max(0,Number(length)||0),w=Math.max(0,Number(width)||0);
  const stockL=Math.max(0,Number(stockLength)||0),stockW=Math.max(0,Number(stockWidth)||0);
  const stock=Math.max(0,Number(stockPrice)||0),qty=Math.max(0,Number(quantity)||0);
  const area=l*w,stockArea=stockL*stockW;
  const material=supply==='mj_supplies'&&stockArea>0?area/stockArea*stock:0;
  const labour=Math.max(0,Number(productionLabour)||0);
  const tape=Math.max(0,Number(transferTape)||0);
  const application=Math.max(0,Number(applicationCost)||0);
  const unitDirect=material+labour+tape+application;
  const marginFloorPrice=unitDirect/0.7;
  const complexityPrice=marginFloorPrice*complexityFactors[design];
  const suggested=wholeKsh(complexityPrice);
  const finalPrice=agreedPrice.trim()===''?suggested:Math.max(0,Number(agreedPrice)||0);
  const margin=finalPrice>0?((finalPrice-unitDirect)/finalPrice)*100:0;
  return {l,w,area,stockL,stockW,stock,stockArea,material,labour,tape,application,unitDirect,marginFloorPrice,complexityPrice,suggested,finalPrice,margin,quantity:qty,totalCost:unitDirect*qty,totalPrice:finalPrice*qty};
 },[length,width,stockLength,stockWidth,stockPrice,productionLabour,transferTape,applicationCost,design,quantity,supply,agreedPrice]);
 const updateSuggested=()=>setAgreedPrice(String(calculation.suggested));
 async function recordSale(){
  setError('');setNotice('');
  if(!supabase)return setError('Sales service is unavailable. Check the owner workspace connection.');
  if(calculation.area<=0)return setError('Enter valid sticker dimensions greater than zero.');\n  if(supply==='mj_supplies'&&(calculation.stockArea<=0||calculation.stock<=0))return setError('Enter the actual positive vinyl stock dimensions and purchase price.');
  if(!Number.isInteger(calculation.quantity)||calculation.quantity<1)return setError('Quantity must be a whole number of at least 1.');
  if(!description.trim())return setError('Enter a sticker or lettering description.');
  if(calculation.finalPrice<=0)return setError('Enter the final agreed customer price.');
  const paid=paymentAmount.trim()===''?0:Number(paymentAmount);
  if(!Number.isFinite(paid)||paid<0||paid>calculation.totalPrice)return setError('Payment must be zero or no greater than the sale total.');
  if(calculation.unitDirect>0&&calculation.margin<30&&(!belowFloor||exceptionReason.trim().length<8))return setError('The final price is below the 30% gross-margin floor. Record an authorised exception and reason to continue.');
  if(paid>0&&!['cash','mpesa_paybill'].includes(paymentMethod))return setError('Select a valid payment method.');
  setLoading(true);
  const breakdown=[
   {name:'Vinyl material by area',category:'material',basis:'per_piece',unit_cost:calculation.material,total_cost:calculation.material},
   {name:'Cutting / weeding labour',category:'labour',basis:'per_piece',unit_cost:calculation.labour,total_cost:calculation.labour},
   {name:'Transfer tape',category:'material',basis:'per_piece',unit_cost:calculation.tape,total_cost:calculation.tape},
   {name:'Application labour',category:'labour',basis:'per_piece',unit_cost:calculation.application,total_cost:calculation.application}
  ].filter(x=>x.unit_cost>0);
  const pricingDetails={
   unit:'inch',length:calculation.l,width:calculation.w,area_square_inches:calculation.area,
   stock_length_inches:calculation.stockL,stock_width_inches:calculation.stockW,
   stock_purchase_price:calculation.stock,material_cost_per_piece:calculation.material,
   design_complexity:design,complexity_factor:complexityFactors[design],
   margin_floor_percent:30,suggested_unit_price:calculation.suggested,
   final_agreed_unit_price:calculation.finalPrice,quantity:calculation.quantity
  };
  const {data,error}=await supabase.rpc('owner_create_vinyl_sticker_quick_sale',{
   p_customer_id:customerId||null,p_invoice_number:invoiceNo,p_due_date:dueDate,
   p_description:description.trim(),p_dimensions:calculation.l+' × '+calculation.w+' inches',
   p_quantity:calculation.quantity,p_agreed_price:calculation.finalPrice,
   p_supply_arrangement:supply,p_direct_cost_total:calculation.unitDirect,
   p_direct_cost_breakdown:breakdown,p_pricing_details:pricingDetails,
   p_allow_below_floor:belowFloor,p_exception_reason:belowFloor?exceptionReason.trim():null,
   p_payment_number:paid>0?nextNumber('PAY'):null,p_payment_method:paid>0?paymentMethod:null,
   p_payment_amount:paid,p_payment_reference:paymentReference.trim()||null
  });
  setLoading(false);
  if(error){setError(error.message);return;}
  setReceipt(data as Receipt);setNotice('Quick sale recorded. Invoice '+data.invoice_number+' created'+(paid>0?' and payment recorded.':'.'));
  setInvoiceNo(nextNumber('INV'));setPaymentAmount('');setPaymentReference('');setAgreedPrice('');
  setBelowFloor(false);setExceptionReason('');
  onSaleSaved?.();
 }

 return <div className="sticker-calculator">
  <div className="heading"><div><small className="eyebrow">QUICK PRICING & SALES</small><h1>Vinyl sticker calculator</h1><p>Price from actual material area, direct production costs and design complexity, then record the customer-agreed price as a Quick Sale here.</p></div></div>
  {error&&<div className="notice error">{error}</div>}{notice&&<div className="notice">{notice}</div>}
  <section className="panel">
   <h3>1. Sticker dimensions and quantity</h3>
   <p className="muted">No fixed 5 × 5-inch price baseline. Vinyl cost is calculated from the finished sticker area and the stock roll's dimensions and purchase price.</p>
   <div className="op-grid">
    <label className="op-field">Sticker length (inches)<input type="number" min="0.01" step="0.01" value={length} onChange={e=>setLength(e.target.value)}/></label>
    <label className="op-field">Sticker width (inches)<input type="number" min="0.01" step="0.01" value={width} onChange={e=>setWidth(e.target.value)}/></label>
    <label className="op-field">Quantity<input type="number" min="1" step="1" value={quantity} onChange={e=>setQuantity(e.target.value)}/></label>
   </div>
   <div className="cost-preview"><div><small>Area per sticker</small><b>{calculation.area.toFixed(2)} sq. in.</b></div><div><small>Total finished area</small><b>{(calculation.area*calculation.quantity).toFixed(2)} sq. in.</b></div></div>
   <h3>2. Vinyl stock and supply arrangement</h3>
   <div className="op-grid">
    <label className="op-field">Who supplies the vinyl?<select value={supply} onChange={e=>setSupply(e.target.value as 'mj_supplies'|'customer_supplies')}><option value="mj_supplies">MJ supplies the vinyl</option><option value="customer_supplies">Customer supplies the vinyl</option></select></label>
    <label className="op-field">Stock length (inches)<input type="number" min="0" step="0.01" value={stockLength} onChange={e=>setStockLength(e.target.value)}/></label>
    <label className="op-field">Stock width (inches)<input type="number" min="0" step="0.01" value={stockWidth} onChange={e=>setStockWidth(e.target.value)}/></label>
    <label className="op-field">Full stock purchase price (KES)<input type="number" min="0" step="0.01" value={stockPrice} onChange={e=>setStockPrice(e.target.value)}/></label>
   </div>
   <h3>3. Other direct production costs per sticker</h3>
   <p className="muted">Only include work actually done. For simple cut lettering with no weeding, transfer tape or application, leave those costs at zero.</p>
   <div className="op-grid">
    <label className="op-field">Cutting / weeding labour (KES)<input type="number" min="0" step="0.01" value={productionLabour} onChange={e=>setProductionLabour(e.target.value)}/></label>
    <label className="op-field">Transfer tape (KES)<input type="number" min="0" step="0.01" value={transferTape} onChange={e=>setTransferTape(e.target.value)}/></label>
    <label className="op-field">Application labour (KES)<input type="number" min="0" step="0.01" value={applicationCost} onChange={e=>setApplicationCost(e.target.value)}/></label>
   </div>
   <div className="cost-preview"><div><small>Vinyl material per sticker</small><b>{money(calculation.material)}</b></div><div><small>Other direct costs per sticker</small><b>{money(calculation.labour+calculation.tape+calculation.application)}</b></div><div><small>Total direct cost per sticker</small><b>{money(calculation.unitDirect)}</b></div><div><small>Total direct cost · quantity</small><b>{money(calculation.totalCost)}</b></div></div>
   <h3>4. Design complexity</h3>
   <label className="op-field">Design level<select value={design} onChange={e=>setDesign(e.target.value as keyof typeof complexityFactors)}><option value="simple">Simple · base complexity</option><option value="medium">Medium · +15%</option><option value="complicated">Complicated · +30%</option></select></label>
   <p className="muted">Complexity adjusts the price above the 30% direct-cost gross-margin floor. It does not add an invented material cost.</p>
   <h3>5. Suggested price and customer agreement</h3>
   <div className="cost-preview"><div><small>30% margin floor price per sticker</small><b>{money(calculation.marginFloorPrice)}</b></div><div><small>Complexity-adjusted suggested price</small><b>{money(calculation.suggested)}</b></div></div>
   <div className="op-grid">
    <label className="op-field">Final agreed customer price per sticker (KES)<input type="number" min="0.01" step="0.01" value={agreedPrice===''?String(calculation.suggested):agreedPrice} onChange={e=>setAgreedPrice(e.target.value)}/></label>
    <div className="op-field"><span>Agreed sale total</span><strong>{money(calculation.totalPrice)}</strong></div>
   </div>
   <div className="cost-preview"><div><small>Gross profit on direct cost</small><b>{money(calculation.totalPrice-calculation.totalCost)}</b></div><div><small>Gross margin</small><b>{calculation.margin.toFixed(1)}%</b></div></div>
   {calculation.unitDirect>0&&calculation.margin<30?<><p className="notice error">Below the 30% gross-margin floor. An authorised exception and reason are required.</p><label className="op-check"><input type="checkbox" checked={belowFloor} onChange={e=>setBelowFloor(e.target.checked)}/> Authorise below-floor exception</label>{belowFloor&&<label className="op-field">Reason for exception<input value={exceptionReason} onChange={e=>setExceptionReason(e.target.value)} minLength={8}/></label>}</>:<p className="muted">The agreed price meets the 30% direct-cost gross-margin floor.</p>}
  </section>
  <section className="panel">
   <h3>6. Record as Quick Sale — without leaving this calculator</h3>
   <label className="op-field">Sale description<input value={description} onChange={e=>setDescription(e.target.value)} required/></label>
   <div className="op-grid">
    <label className="op-field">Customer (optional)<select value={customerId} onChange={e=>setCustomerId(e.target.value)}><option value="">Walk-in customer</option>{customers.map(c=><option key={c.id} value={c.id}>{c.customer_name}</option>)}</select></label>
    <label className="op-field">Invoice number<input value={invoiceNo} onChange={e=>setInvoiceNo(e.target.value)} required/></label>
    <label className="op-field">Due date<input type="date" value={dueDate} onChange={e=>setDueDate(e.target.value)} required/></label>
   </div>
   <h3>Payment received now (optional)</h3>
   <div className="op-grid">
    <label className="op-field">Amount received (KES)<input type="number" min="0" step="0.01" value={paymentAmount} onChange={e=>setPaymentAmount(e.target.value)} placeholder="0 for unpaid sale"/></label>
    <label className="op-field">Payment method<select value={paymentMethod} onChange={e=>setPaymentMethod(e.target.value as 'cash'|'mpesa_paybill')}><option value="cash">Cash</option><option value="mpesa_paybill">M-Pesa Paybill</option></select></label>
    <label className="op-field">M-Pesa reference (optional)<input value={paymentReference} onChange={e=>setPaymentReference(e.target.value)}/></label>
   </div>
   <button className="primary" type="button" disabled={loading||calculation.finalPrice<=0||calculation.quantity<1||(calculation.unitDirect>0&&calculation.margin<30&&(!belowFloor||exceptionReason.trim().length<8))} onClick={()=>void recordSale()}>{loading?'Recording sale…':'Record Quick Sale · Create invoice'}</button>
   {receipt&&<div className="quick-sale-receipt"><h2>MJ Printing & Branding</h2><p>QUICK SALE INVOICE</p><div className="customer-history-row"><b>Invoice</b><strong>{receipt.invoice_number}</strong></div><div className="customer-history-row"><b>Customer</b><span>{receipt.customer_name}</span></div><div className="customer-history-row"><b>Item</b><span>{receipt.description}</span></div><div className="customer-history-row"><b>Quantity × price</b><span>{receipt.quantity} × {money(Number(receipt.unit_price))}</span></div><div className="customer-history-row"><b>Invoice total</b><strong>{money(Number(receipt.total))}</strong></div><div className="customer-history-row"><b>Paid</b><strong>{money(Number(receipt.amount_paid))}</strong></div><div className="customer-history-row"><b>Balance</b><strong>{money(Number(receipt.balance))}</strong></div><button type="button" onClick={()=>window.print()}>Print invoice / receipt</button></div>}
  </section>
 </div>;
}
