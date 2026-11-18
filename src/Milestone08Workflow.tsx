import { useCallback, useEffect, useMemo, useState } from "react";
import type { FormEvent } from "react";
import { supabase } from "./lib/supabase";

type Section = "Daily Closing" | "Reconciliation" | "Deliveries" | "Reports";
type Closing = { id:string; business_date:string; status:string; opening_float:number; posted_cash_receipts:number; posted_cash_refunds:number; cash_expenses:number; cash_top_ups:number; cash_bank_deposits:number; cash_owner_withdrawals:number; other_cash_in:number; other_cash_out:number; expected_cash:number; actual_cash:number|null; difference:number|null; notes:string|null; variance_reason:string|null };
type Movement = { id:string; movement_type:string; direction:string; amount:number; notes:string; reference:string|null; created_at:string };
type Reconciliation = { id:string; method:string; status:string; system_receipts:number; system_refunds:number; statement_receipts:number; statement_refunds:number; net_system:number; net_statement:number; difference:number; statement_reference:string|null; notes:string|null; variance_reason:string|null };
type Delivery = { id:string; order_id:string; method:string; carrier:string|null; tracking_reference:string|null; customer_paid_charge:number; recipient_name:string|null; dispatched_at:string|null; handed_over_at:string|null; created_at:string; attempt_status:string; failed_at:string|null; failure_reason:string|null; orders:{order_number:string;status:string}|null };
type ReadyOrder = { id:string; order_number:string; status:string };
type Summary = { orders_in_progress:number; ready_awaiting_collection:number; courier_outstanding:number; failed_delivery_attempts:number; overdue_orders:number; pending_mpesa:number; order_value:number; posted_receipts:number; posted_refunds:number; expenses:number; cash_expenses:number; production_costs:number; daily_closing:Closing|null; mpesa_reconciliation:Reconciliation|null };
const rid=()=>crypto.randomUUID();
const money=(n:number|null|undefined)=>new Intl.NumberFormat("en-KE",{style:"currency",currency:"KES",maximumFractionDigits:0}).format(Number(n??0));
const todayNairobi=()=>new Intl.DateTimeFormat("en-CA",{timeZone:"Africa/Nairobi",year:"numeric",month:"2-digit",day:"2-digit"}).format(new Date());

export default function Milestone08Workflow({businessId,section,onChanged}:{businessId:string;section:Section;onChanged:()=>void}){
 const [businessDate,setBusinessDate]=useState(todayNairobi());
 const [closing,setClosing]=useState<Closing|null>(null);
 const [movements,setMovements]=useState<Movement[]>([]);
 const [reconciliation,setReconciliation]=useState<Reconciliation|null>(null);
 const [deliveries,setDeliveries]=useState<Delivery[]>([]);
 const [readyOrders,setReadyOrders]=useState<ReadyOrder[]>([]);
 const [summary,setSummary]=useState<Summary|null>(null);
 const [openingFloat,setOpeningFloat]=useState("");
 const [actualCash,setActualCash]=useState("");
 const [closingNotes,setClosingNotes]=useState("");
 const [varianceReason,setVarianceReason]=useState("");
 const [movement,setMovement]=useState({type:"till_top_up",amount:"",source:"",destination:"",reference:"",notes:""});
 const [statement,setStatement]=useState({receipts:"",refunds:"0",reference:"",notes:"",varianceReason:""});
 const [deliveryForm,setDeliveryForm]=useState({order:"",method:"collection" as "collection"|"courier",carrier:"",tracking:"",recipient:"",charge:"0"});
 const [failureReasons,setFailureReasons]=useState<Record<string,string>>({});
 const [paymentExceptions,setPaymentExceptions]=useState<Record<string,string>>({});
 const [busy,setBusy]=useState(false);
 const [error,setError]=useState("");
 const [notice,setNotice]=useState("");

 const load=useCallback(async()=>{
  if(!supabase)return;
  setError("");
  const client=supabase;
  const [sum,close,movs,recon,delivery,ready]=await Promise.all([
   client.rpc("owner_get_daily_operations_summary",{p_business_id:businessId,p_business_date:businessDate}),
   client.from("daily_closings").select("*").eq("business_id",businessId).eq("business_date",businessDate).maybeSingle(),
   client.from("cash_movements").select("id,movement_type,direction,amount,notes,reference,created_at").eq("business_id",businessId).eq("business_date",businessDate).order("created_at",{ascending:false}),
   client.from("daily_payment_reconciliations").select("*").eq("business_id",businessId).eq("business_date",businessDate).eq("method","mpesa").maybeSingle(),
   client.from("deliveries").select("id,order_id,method,carrier,tracking_reference,customer_paid_charge,recipient_name,dispatched_at,handed_over_at,created_at,attempt_status,failed_at,failure_reason,orders(order_number,status)").eq("business_id",businessId).order("created_at",{ascending:false}).limit(200),
   client.from("orders").select("id,order_number,status").eq("business_id",businessId).eq("status","ready").order("received_at",{ascending:false}).limit(200)
  ]);
  const failure=sum.error||close.error||movs.error||recon.error||delivery.error||ready.error;
  if(failure)throw failure;
  const nextClose=(close.data??null) as Closing|null;
  setSummary(sum.data as Summary);setClosing(nextClose);setMovements((movs.data??[]) as Movement[]);
  const nextRecon=(recon.data??null) as Reconciliation|null;setReconciliation(nextRecon);
  setDeliveries((delivery.data??[]) as unknown as Delivery[]);setReadyOrders((ready.data??[]) as ReadyOrder[]);
  if(nextClose){setOpeningFloat(String(nextClose.opening_float));setActualCash(nextClose.actual_cash===null?"":String(nextClose.actual_cash));setClosingNotes(nextClose.notes??"");setVarianceReason(nextClose.variance_reason??"");}
  else {setOpeningFloat("");setActualCash("");setClosingNotes("");setVarianceReason("");}
  if(nextRecon){setStatement({receipts:String(nextRecon.statement_receipts),refunds:String(nextRecon.statement_refunds),reference:nextRecon.statement_reference??"",notes:nextRecon.notes??"",varianceReason:nextRecon.variance_reason??""});}
  else setStatement({receipts:"",refunds:"0",reference:"",notes:"",varianceReason:""});
 },[businessId,businessDate]);
 useEffect(()=>{void load().catch(e=>setError(e.message));},[load]);

 const closed=closing?.status==="closed";
 const currentMovements=useMemo(()=>movements.reduce((n,m)=>n+(m.direction==="in"?Number(m.amount):-Number(m.amount)),0),[movements]);
 async function saveClosing(close:boolean){
  if(!supabase)return;
  if(openingFloat!==""&&(!Number.isSafeInteger(Number(openingFloat))||Number(openingFloat)<0)){setError("Enter a valid opening float in whole KES.");return;}
  if(close&&(actualCash===""||!Number.isSafeInteger(Number(actualCash))||Number(actualCash)<0)){setError("Enter the physical cash count in whole KES.");return;}
  setBusy(true);setError("");setNotice("");
  const {data,error:e}=await supabase.rpc("owner_save_daily_closing",{p_business_id:businessId,p_business_date:businessDate,
   p_opening_float:openingFloat===""?null:Number(openingFloat),p_actual_cash:close?Number(actualCash):null,p_notes:closingNotes.trim()||null,
   p_variance_reason:varianceReason.trim()||null,p_close:close,p_request_id:rid()});
  if(e)setError(e.message);else{setNotice(close?"Daily closing confirmed and locked.":"Daily closing draft saved. You can resume it later.");await load();onChanged();}
  setBusy(false);
 }
 async function recordMovement(e:FormEvent){
  e.preventDefault();if(!supabase)return;
  const amount=Number(movement.amount);
  if(!Number.isSafeInteger(amount)||amount<=0||!movement.notes.trim()){setError("Enter a positive whole-KES amount and a reason.");return;}
  setBusy(true);setError("");setNotice("");
  const {error:e}=await supabase.rpc("owner_record_cash_movement",{p_business_id:businessId,p_business_date:businessDate,
   p_movement_type:movement.type,p_amount:amount,p_source_account:movement.source.trim()||null,
   p_destination_account:movement.destination.trim()||null,p_reference:movement.reference.trim()||null,
   p_notes:movement.notes.trim(),p_request_id:rid()});
  if(e)setError(e.message);else{setMovement({type:"till_top_up",amount:"",source:"",destination:"",reference:"",notes:""});setNotice("Cash movement recorded.");await load();onChanged();}
  setBusy(false);
 }
 async function saveReconciliation(confirm:boolean){
  if(!supabase)return;
  const receipts=Number(statement.receipts),refunds=Number(statement.refunds);
  if(!Number.isSafeInteger(receipts)||receipts<0||!Number.isSafeInteger(refunds)||refunds<0){setError("Enter valid whole-KES statement totals.");return;}
  setBusy(true);setError("");setNotice("");
  const {data,error:e2}=await supabase.rpc("owner_save_payment_reconciliation",{p_business_id:businessId,p_business_date:businessDate,
   p_method:"mpesa",p_statement_receipts:receipts,p_statement_refunds:refunds,p_statement_reference:statement.reference.trim()||null,
   p_notes:statement.notes.trim()||null,p_variance_reason:statement.varianceReason.trim()||null,p_confirm:confirm,p_request_id:rid()});
  if(e2)setError(e2.message);else{setNotice(confirm?"M-Pesa reconciliation confirmed and locked.":"M-Pesa reconciliation draft saved.");await load();onChanged();}
  setBusy(false);
 }
 async function recordDelivery(e:FormEvent){
  e.preventDefault();if(!supabase)return;
  if(!deliveryForm.order||!deliveryForm.recipient.trim()||(deliveryForm.method==="courier"&&!deliveryForm.carrier.trim())||!Number.isSafeInteger(Number(deliveryForm.charge))||Number(deliveryForm.charge)<0){setError("Complete the order, method, recipient and valid delivery charge.");return;}
  setBusy(true);setError("");setNotice("");
  const {error:e2}=await supabase.rpc("owner_record_delivery",{p_order_id:deliveryForm.order,p_method:deliveryForm.method,
   p_carrier:deliveryForm.carrier.trim()||null,p_tracking_reference:deliveryForm.tracking.trim()||null,
   p_customer_paid_charge:Number(deliveryForm.charge),p_recipient_name:deliveryForm.recipient.trim(),p_request_id:rid()});
  if(e2)setError(e2.message);else{setNotice("Delivery attempt recorded. Courier dispatch remains outstanding until receipt confirmation.");setDeliveryForm({order:"",method:"collection",carrier:"",tracking:"",recipient:"",charge:"0"});await load();onChanged();}
  setBusy(false);
 }
 async function confirmDelivery(delivery:Delivery){
  if(!supabase)return;
  setBusy(true);setError("");setNotice("");
  const {error:e}=await supabase.rpc("owner_handover_order",{p_order_id:delivery.order_id,p_method:delivery.method,
   p_recipient_name:delivery.recipient_name??"",p_tracking_reference:delivery.tracking_reference,
   p_payment_exception_reason:(paymentExceptions[delivery.id]??"").trim()||null,p_request_id:rid()});
  if(e)setError(e.message);else{setNotice(delivery.method==="courier"?"Courier receipt confirmed and order completed.":"Customer collection confirmed and order completed.");await load();onChanged();}
  setBusy(false);
 }
 async function failDelivery(delivery:Delivery){
  if(!supabase)return;const reason=(failureReasons[delivery.id]??"").trim();
  if(!reason){setError("Enter why this delivery attempt failed.");return;}
  setBusy(true);setError("");setNotice("");
  const {error:e}=await supabase.rpc("owner_mark_delivery_failed",{p_delivery_id:delivery.id,p_reason:reason,p_request_id:rid()});
  if(e)setError(e.message);else{setNotice("Failed attempt saved. It remains in history; create a new attempt for a retry.");await load();onChanged();}
  setBusy(false);
 }
 const card=(label:string,value:string)=> <article className="overview-card neutral-card" key={label}><span className="metric-label">{label}</span><strong>{value}</strong></article>;

 return <div className="milestone08-workflow">
  {section!=="Deliveries"&&<section className="connected-panel"><div className="panel-toolbar"><div><h2>Business date</h2><p>All dates and daily boundaries use Africa/Nairobi.</p></div><input aria-label="Business date" type="date" value={businessDate} max={todayNairobi()} onChange={e=>setBusinessDate(e.target.value)}/></div></section>}
  {error&&<div className="notice error" role="alert">{error}</div>}{notice&&<div className="notice success" role="status">{notice}</div>}
  {section==="Daily Closing"&&<>
   <div className="connected-metrics">{card("Posted cash receipts",money(closing?.posted_cash_receipts))}{card("Cash refunds",money(closing?.posted_cash_refunds))}{card("Cash expenses",money(closing?.cash_expenses))}{card("Expected till",money(closing?.expected_cash))}{card("Till movements net",money(currentMovements))}{card("Closing status",closed?"Closed":closing?"Draft":"Not started")}</div>
   <section className="connected-panel"><div className="panel-toolbar"><div><h2>Daily cash closing</h2><p>{closed?"This confirmed snapshot is locked.": "Save a draft as you work, then confirm the physical count at the end of the day."}</p></div>{closed&&<span className="status-chip completed">Closed</span>}</div>
    <div className="record-form">
     <label>Opening cash float (KES)<input type="number" min="0" step="1" disabled={closed} value={openingFloat} onChange={e=>setOpeningFloat(e.target.value)} placeholder="Opening till cash"/></label>
     <label>Physical cash count (KES)<input type="number" min="0" step="1" disabled={closed} value={actualCash} onChange={e=>setActualCash(e.target.value)} placeholder="Count cash in till"/></label>
     <label className="wide-field">Closing notes<textarea disabled={closed} value={closingNotes} onChange={e=>setClosingNotes(e.target.value)} placeholder="Optional notes"/></label>
     {closing?.difference!==null&&closing?.difference!==undefined&&closing.difference!==0&&<p className="wide-field small-note">Recorded difference: {money(closing.difference)}. Explain the shortage or excess before confirming.</p>}
     <label className="wide-field">Variance explanation (required if cash differs)<textarea disabled={closed} value={varianceReason} onChange={e=>setVarianceReason(e.target.value)} placeholder="Explain any cash shortage or excess"/></label>
     {!closed&&<div className="form-actions"><button className="secondary-action" disabled={busy} onClick={()=>void saveClosing(false)}>Save draft</button><button className="primary-action" disabled={busy} onClick={()=>void saveClosing(true)}>Confirm daily close</button></div>}
    </div>
    {closing&&<div className="record-list"><article className="record-row"><div><b>Expected cash</b><small>Opening float + posted cash receipts − posted cash refunds − cash expenses + top-ups − deposits − withdrawals + other movements</small></div><strong>{money(closing.expected_cash)}</strong></article>{closing.actual_cash!==null&&<article className="record-row"><div><b>Actual physical count</b></div><strong>{money(closing.actual_cash)}</strong></article>}{closing.difference!==null&&<article className="record-row"><div><b>Difference</b><small>{closing.variance_reason||"No variance"}</small></div><strong>{money(closing.difference)}</strong></article>}</div>}
   </section>
   {!closed&&<section className="connected-panel"><div className="panel-toolbar"><div><h2>Record till movement</h2><p>Banking and owner withdrawals are cash movements, not expenses or sales.</p></div></div>
    <form className="record-form" onSubmit={recordMovement}>
     <label>Movement type<select value={movement.type} onChange={e=>setMovement(v=>({...v,type:e.target.value}))}><option value="till_top_up">Till top-up</option><option value="bank_deposit">Cash bank deposit</option><option value="owner_withdrawal">Owner withdrawal</option><option value="other_cash_in">Other cash in</option><option value="other_cash_out">Other cash out</option></select></label>
     <label>Amount (KES)<input type="number" min="1" step="1" required value={movement.amount} onChange={e=>setMovement(v=>({...v,amount:e.target.value}))}/></label>
     <label>Source account<input value={movement.source} onChange={e=>setMovement(v=>({...v,source:e.target.value}))} placeholder="Optional"/></label>
     <label>Destination account<input value={movement.destination} onChange={e=>setMovement(v=>({...v,destination:e.target.value}))} placeholder="Optional"/></label>
     <label>Reference<input value={movement.reference} onChange={e=>setMovement(v=>({...v,reference:e.target.value}))} placeholder="Optional"/></label>
     <label className="wide-field">Reason / notes<textarea required value={movement.notes} onChange={e=>setMovement(v=>({...v,notes:e.target.value}))}/></label>
     <div className="form-actions"><button className="primary-action" disabled={busy}>Record movement</button></div>
    </form>
    <div className="record-list">{movements.map(m=><article className="record-row" key={m.id}><div><b>{m.movement_type.replaceAll("_"," ")}</b><small>{m.notes}{m.reference?" · "+m.reference:""}</small></div><strong>{m.direction==="in"?"+":"−"}{money(m.amount)}</strong></article>)}{!movements.length&&<p className="empty-records">No cash movements recorded for this date.</p>}</div>
   </section>}
  </>}
  {section==="Reconciliation"&&<section className="connected-panel"><div className="panel-toolbar"><div><h2>M-Pesa reconciliation</h2><p>Compare posted, verified M-Pesa receipts and refunds with the statement. Pending evidence must be verified or rejected first.</p></div>{reconciliation?.status==="confirmed"&&<span className="status-chip completed">Confirmed</span>}</div>
   {reconciliation&&<div className="connected-metrics">{card("System receipts",money(reconciliation.system_receipts))}{card("System refunds",money(reconciliation.system_refunds))}{card("Net statement",money(reconciliation.net_statement))}{card("Difference",money(reconciliation.difference))}</div>}
   <form className="record-form" onSubmit={e=>{e.preventDefault();void saveReconciliation(false);}}>
    <label>Statement receipts (KES)<input type="number" min="0" step="1" required disabled={reconciliation?.status==="confirmed"} value={statement.receipts} onChange={e=>setStatement(v=>({...v,receipts:e.target.value}))}/></label>
    <label>Statement refunds (KES)<input type="number" min="0" step="1" required disabled={reconciliation?.status==="confirmed"} value={statement.refunds} onChange={e=>setStatement(v=>({...v,refunds:e.target.value}))}/></label>
    <label>Statement reference<input disabled={reconciliation?.status==="confirmed"} value={statement.reference} onChange={e=>setStatement(v=>({...v,reference:e.target.value}))}/></label>
    <label className="wide-field">Notes<textarea disabled={reconciliation?.status==="confirmed"} value={statement.notes} onChange={e=>setStatement(v=>({...v,notes:e.target.value}))}/></label>
    <label className="wide-field">Variance explanation<textarea disabled={reconciliation?.status==="confirmed"} value={statement.varianceReason} onChange={e=>setStatement(v=>({...v,varianceReason:e.target.value}))} placeholder="Required if statement and system totals differ"/></label>
    {reconciliation?.status!=="confirmed"&&<div className="form-actions"><button className="secondary-action" type="submit" disabled={busy}>Save draft</button><button className="primary-action" type="button" disabled={busy||!statement.receipts} onClick={()=>void saveReconciliation(true)}>Confirm reconciliation</button></div>}
   </form>
   <p className="small-note">Bank and card reconciliation are not enabled until those receipt methods are added to the payment ledger. Transfers from M-Pesa to bank are not new receipts.</p>
  </section>}
  {section==="Deliveries"&&<>
   <section className="connected-panel"><div className="panel-toolbar"><div><h2>Record delivery / collection attempt</h2><p>Each retry creates a new attempt. Failed and completed attempts remain in the history.</p></div></div>
    <form className="record-form" onSubmit={recordDelivery}>
     <label>Ready order<select required value={deliveryForm.order} onChange={e=>setDeliveryForm(v=>({...v,order:e.target.value}))}><option value="">Select order</option>{readyOrders.map(o=><option key={o.id} value={o.id}>{o.order_number}</option>)}</select></label>
     <label>Method<select value={deliveryForm.method} onChange={e=>setDeliveryForm(v=>({...v,method:e.target.value as "collection"|"courier"}))}><option value="collection">Customer collection</option><option value="courier">Courier</option></select></label>
     <label>Recipient name<input required value={deliveryForm.recipient} onChange={e=>setDeliveryForm(v=>({...v,recipient:e.target.value}))}/></label>
     {deliveryForm.method==="courier"&&<label>Carrier<input required value={deliveryForm.carrier} onChange={e=>setDeliveryForm(v=>({...v,carrier:e.target.value}))}/></label>}
     <label>Tracking reference<input value={deliveryForm.tracking} onChange={e=>setDeliveryForm(v=>({...v,tracking:e.target.value}))}/></label>
     <label>Customer-paid courier charge (KES)<input type="number" min="0" step="1" value={deliveryForm.charge} onChange={e=>setDeliveryForm(v=>({...v,charge:e.target.value}))}/></label>
     <div className="form-actions"><button className="primary-action" disabled={busy||!readyOrders.length}>Record attempt</button></div>
    </form>
   </section>
   <section className="connected-panel"><div className="panel-toolbar"><div><h2>Delivery attempt history</h2><p>Dispatched parcels remain outstanding until receipt is confirmed.</p></div></div>
    <div className="record-list">{deliveries.map(d=><article className="record-row" key={d.id}><div><b>{d.orders?.order_number??"Order"} · {d.method}</b><small>{d.recipient_name??"Recipient pending"}{d.carrier?" · "+d.carrier:""}{d.tracking_reference?" · "+d.tracking_reference:""} · {new Date(d.created_at).toLocaleString("en-KE")}</small>{d.failure_reason&&<small>Failure: {d.failure_reason}</small>}{d.attempt_status==="dispatched"&&<small>Awaiting courier receipt confirmation</small>}</div><div><span className={"status-chip "+d.attempt_status}>{d.attempt_status.replaceAll("_"," ")}</span>{["prepared","dispatched"].includes(d.attempt_status)&&!d.handed_over_at&&<div className="inline-controls">
 {d.attempt_status==="dispatched"&&<input aria-label="Payment exception reason" placeholder="Payment exception reason (if needed)" value={paymentExceptions[d.id]??""} onChange={e=>setPaymentExceptions(v=>({...v,[d.id]:e.target.value}))}/>}
 <button className="primary-action compact" disabled={busy} onClick={()=>void confirmDelivery(d)}>{d.method==="courier"?"Confirm recipient received parcel":"Confirm collection"}</button>
 <input aria-label="Failure reason" placeholder="Failure reason" value={failureReasons[d.id]??""} onChange={e=>setFailureReasons(v=>({...v,[d.id]:e.target.value}))}/>
 <button className="secondary-action" disabled={busy} onClick={()=>void failDelivery(d)}>Mark failed</button></div>}</div></article>)}{!deliveries.length&&<p className="empty-records">No delivery attempts recorded yet.</p>}</div>
   </section>
  </>}
  {section==="Reports"&&<><div className="connected-metrics">
   {card("Orders in progress",String(summary?.orders_in_progress??0))}{card("Ready awaiting collection",String(summary?.ready_awaiting_collection??0))}{card("Courier parcels outstanding",String(summary?.courier_outstanding??0))}{card("Failed delivery attempts",String(summary?.failed_delivery_attempts??0))}{card("Overdue orders",String(summary?.overdue_orders??0))}{card("Pending M-Pesa",String(summary?.pending_mpesa??0))}
  </div><div className="connected-metrics">
   {card("Order value",money(summary?.order_value))}{card("Posted receipts",money(summary?.posted_receipts))}{card("Posted refunds",money(summary?.posted_refunds))}{card("Expenses",money(summary?.expenses))}{card("Cash expenses",money(summary?.cash_expenses))}{card("Production costs",money(summary?.production_costs))}
  </div><section className="connected-panel"><div className="panel-toolbar"><div><h2>Daily control status</h2><p>Operational and financial measures are deliberately kept separate.</p></div><input type="date" aria-label="Report date" value={businessDate} max={todayNairobi()} onChange={e=>setBusinessDate(e.target.value)}/></div><div className="record-list"><article className="record-row"><div><b>Daily cash close</b><small>{summary?.daily_closing?.status??"Not started"}</small></div><strong>{summary?.daily_closing?money(summary.daily_closing.difference):"—"}</strong></article><article className="record-row"><div><b>M-Pesa reconciliation</b><small>{summary?.mpesa_reconciliation?.status??"Not started"}</small></div><strong>{summary?.mpesa_reconciliation?money(summary.mpesa_reconciliation.difference):"—"}</strong></article></div><p className="small-note">Order value is not receipts. Receipts are not profit. Profit reporting requires fully reconciled production costs and expenses.</p></section></>}
 </div>;
}
