import { useCallback, useEffect, useState } from "react";
import type { FormEvent } from "react";
import { supabase } from "./lib/supabase";

type Order={id:string;order_number:string;customer_id:string;status:string;total_amount:number;received_at:string};
type Payment={id:string;payment_number:string;method:string;status:string;amount:number;received_at:string;payer_name:string|null;payer_phone:string|null;mpesa_reference:string|null;intended_order_id:string|null;notes:string|null};
type Receipt={id:string;receipt_number:string;payment_id:string;customer_name_snapshot:string;amount:number;issued_at:string};
type Allocation={id:string;payment_id:string;order_id:string;amount:number};
type Refund={id:string;payment_id:string;order_id:string|null;allocation_id:string|null;source_bucket:string;amount:number;status:string;reason:string;refund_method:string;external_reference:string|null;created_at:string};
type Balance={order_total:number;net_paid:number;balance_due:number;overpaid:number;currency_code:string};
const requestId=()=>crypto.randomUUID();
const money=(n:number)=>new Intl.NumberFormat("en-KE",{style:"currency",currency:"KES",maximumFractionDigits:0}).format(n);

export default function PaymentWorkflow({businessId,customers,onChanged}:{businessId:string;customers:{id:string;display_name:string}[];onChanged:()=>void}){
 const [orders,setOrders]=useState<Order[]>([]);const [payments,setPayments]=useState<Payment[]>([]);const [receipts,setReceipts]=useState<Receipt[]>([]);const [allocations,setAllocations]=useState<Allocation[]>([]);const [refunds,setRefunds]=useState<Refund[]>([]);
 const [balances,setBalances]=useState<Record<string,Balance>>({});const [selectedOrder,setSelectedOrder]=useState("");
 const [method,setMethod]=useState<"cash"|"mpesa_manual">("cash");const [amount,setAmount]=useState("");const [receivedAt,setReceivedAt]=useState(new Date().toISOString().slice(0,16));
 const [payerName,setPayerName]=useState("");const [payerPhone,setPayerPhone]=useState("");const [reference,setReference]=useState("");const [notes,setNotes]=useState("");
 const [refundPayment,setRefundPayment]=useState("");const [refundAllocation,setRefundAllocation]=useState("");const [refundBucket,setRefundBucket]=useState<"allocated"|"unallocated">("allocated");const [refundAmount,setRefundAmount]=useState("");const [refundReason,setRefundReason]=useState("");const [refundMethod,setRefundMethod]=useState<"cash"|"mpesa">("mpesa");const [refundReference,setRefundReference]=useState("");
 const [busy,setBusy]=useState(false);const [error,setError]=useState("");const [notice,setNotice]=useState("");const [receipt,setReceipt]=useState<Receipt|null>(null);
 const load=useCallback(async()=>{
  const client=supabase;if(!client)return;
  const [o,p,r]=await Promise.all([
   client.from("orders").select("id,order_number,customer_id,status,total_amount,received_at").eq("business_id",businessId).order("received_at",{ascending:false}).limit(150),
   client.from("payments").select("id,payment_number,method,status,amount,received_at,payer_name,payer_phone,mpesa_reference,intended_order_id,notes").eq("business_id",businessId).order("received_at",{ascending:false}).limit(200),
   client.from("receipts").select("id,receipt_number,payment_id,customer_name_snapshot,amount,issued_at").eq("business_id",businessId).order("issued_at",{ascending:false}).limit(200)
  ]);
  if(o.error||p.error||r.error)throw o.error||p.error||r.error;
  const [a,rf]=await Promise.all([client.from("payment_allocations").select("id,payment_id,order_id,amount").eq("business_id",businessId).limit(500),client.from("payment_refunds").select("id,payment_id,order_id,allocation_id,source_bucket,amount,status,reason,refund_method,external_reference,created_at").eq("business_id",businessId).order("created_at",{ascending:false}).limit(200)]);
  if(a.error||rf.error)throw a.error||rf.error;
  const orderRows=(o.data??[]) as Order[];setOrders(orderRows);setPayments((p.data??[]) as Payment[]);setReceipts((r.data??[]) as Receipt[]);setAllocations((a.data??[]) as Allocation[]);setRefunds((rf.data??[]) as Refund[]);
  const result=await Promise.all(orderRows.map(async order=>{const {data,error}=await client.rpc("owner_get_order_balance",{p_order_id:order.id});if(error)throw error;return [order.id,data as Balance] as const;}));
  setBalances(Object.fromEntries(result));if(!selectedOrder&&orderRows.length)setSelectedOrder(orderRows[0].id);
 },[businessId,selectedOrder]);
 useEffect(()=>{void load().catch(e=>setError(e.message));},[load]);
 const customerName=(id:string|null)=>customers.find(c=>c.id===id)?.display_name??"Customer";
 async function recordPayment(e:FormEvent){
  e.preventDefault();if(!supabase)return;
  if(!selectedOrder||!amount||!Number.isSafeInteger(Number(amount))||Number(amount)<=0){setError("Choose an order and enter a positive whole-KES amount.");return;}
  setBusy(true);setError("");setNotice("");
  const {data,error:rpcError}=await supabase.rpc("owner_record_payment",{
   p_business_id:businessId,p_order_id:selectedOrder,p_method:method,p_amount:Number(amount),
   p_received_at:new Date(receivedAt).toISOString(),p_payer_name:payerName.trim()||null,p_payer_phone:payerPhone.trim()||null,
   p_mpesa_reference:method==="mpesa_manual"?reference.trim():null,p_notes:notes.trim()||null,p_request_id:requestId()
  });
  if(rpcError)setError(rpcError.message);
  else{setNotice(method==="cash"?"Cash payment posted. Receipt "+data.receipt_number+" issued.":"M-Pesa evidence recorded as pending. It does not reduce the order balance until verified.");setAmount("");setPayerName("");setPayerPhone("");setReference("");setNotes("");await load();onChanged();}
  setBusy(false);
 }
 async function verifyPayment(payment:Payment,outcome:"verified"|"rejected"){
  if(!supabase)return;
  const reason=outcome==="verified"?"M-Pesa transaction checked against customer confirmation":"M-Pesa transaction could not be verified";
  setBusy(true);setError("");setNotice("");
  const {data,error:rpcError}=await supabase.rpc("owner_verify_mpesa_payment",{p_payment_id:payment.id,p_outcome:outcome,p_reason:reason,p_request_id:requestId()});
  if(rpcError)setError(rpcError.message);else setNotice(outcome==="verified"?"Payment verified. Receipt "+data.receipt_number+" issued.":"Payment evidence rejected; order balance unchanged.");
  await load();onChanged();setBusy(false);
 }

 async function recordRefund(e:FormEvent){
  e.preventDefault();if(!supabase)return;
  const amountValue=Number(refundAmount);
  if(!refundPayment||!Number.isSafeInteger(amountValue)||amountValue<=0||!refundReason.trim()){setError("Choose a posted payment and enter a positive amount and reason.");return;}
  if(refundBucket==="allocated"&&!refundAllocation){setError("Choose the order allocation being refunded.");return;}
  setBusy(true);setError("");setNotice("");
  const {data,error:rpcError}=await supabase.rpc("owner_record_refund",{p_payment_id:refundPayment,p_allocation_id:refundBucket==="allocated"?refundAllocation:null,p_source_bucket:refundBucket,p_amount:amountValue,p_reason:refundReason.trim(),p_refund_method:refundMethod,p_external_reference:refundReference.trim()||null,p_request_id:requestId()});
  if(rpcError)setError(rpcError.message);else{setNotice("Refund recorded as pending. It has not changed the order balance until posted.");setRefundAmount("");setRefundReason("");setRefundReference("");await load();onChanged();}
  setBusy(false);
 }
 async function refundAction(refund:Refund,action:"post"|"cancel"){
  if(!supabase)return;
  setBusy(true);setError("");setNotice("");
  const result=action==="post"
   ? await supabase.rpc("owner_post_refund",{p_refund_id:refund.id,p_request_id:requestId()})
   : await supabase.rpc("owner_cancel_refund",{p_refund_id:refund.id,p_reason:"Cancelled by owner after review",p_request_id:requestId()});
  if(result.error)setError(result.error.message);else setNotice(action==="post"?"Refund posted. The related order balance has been updated.":"Pending refund cancelled.");
  await load();onChanged();setBusy(false);
 }
 async function reverseAllocation(allocation:Allocation){
  if(!supabase)return;
  const amountValue=Number(window.prompt("Amount to reverse (KES)",String(allocation.amount)));
  if(!Number.isSafeInteger(amountValue)||amountValue<=0)return;
  const reason=window.prompt("Reason for reversing this payment allocation");
  if(!reason?.trim())return;
  setBusy(true);setError("");setNotice("");
  const {error:rpcError}=await supabase.rpc("owner_reverse_payment_allocation",{p_allocation_id:allocation.id,p_amount:amountValue,p_reason:reason.trim(),p_request_id:requestId()});
  if(rpcError)setError(rpcError.message);else setNotice("Payment allocation reversed. Order balance recalculated.");
  await load();onChanged();setBusy(false);
 }
 async function reversePayment(payment:Payment){
  if(!supabase)return;
  const reason=window.prompt("Reason for reversing this entire payment");
  if(!reason?.trim())return;
  setBusy(true);setError("");setNotice("");
  const {error:rpcError}=await supabase.rpc("owner_reverse_payment",{p_payment_id:payment.id,p_reason:reason.trim(),p_request_id:requestId()});
  if(rpcError)setError(rpcError.message);else setNotice("Payment reversed. Its allocations must already have been fully reversed and no active refunds remain.");
  await load();onChanged();setBusy(false);
 }

 function printReceipt(item:Receipt){
  setReceipt(item);window.setTimeout(()=>window.print(),100);
 }
 const pending=payments.filter(p=>p.status==="pending_verification");
 return <section className="connected-panel payment-workflow">
  <div className="panel-toolbar"><div><h2>Payments and receipts</h2><p>Record cash, verify M-Pesa evidence, issue receipts and track balances.</p></div><button className="secondary-action" onClick={()=>void load()}>Refresh</button></div>
  {error&&<div className="notice error">{error}</div>}{notice&&<div className="notice success">{notice}</div>}
  <div className="payment-metrics"><article><span>Orders with balances</span><b>{orders.filter(o=>(balances[o.id]?.balance_due??0)>0).length}</b></article><article><span>Pending M-Pesa checks</span><b>{pending.length}</b></article><article><span>Receipts issued</span><b>{receipts.length}</b></article></div>
  <form className="record-form" onSubmit={recordPayment}><h3 className="wide-field">Record a payment</h3>
   <label>Order *<select required value={selectedOrder} onChange={e=>setSelectedOrder(e.target.value)}><option value="">Choose order</option>{orders.filter(o=>!["cancelled","completed"].includes(o.status)).map(o=><option key={o.id} value={o.id}>{o.order_number} · {customerName(o.customer_id)} · Due {money(balances[o.id]?.balance_due??o.total_amount)}</option>)}</select></label>
   <label>Payment method<select value={method} onChange={e=>setMethod(e.target.value as "cash"|"mpesa_manual")}><option value="cash">Cash</option><option value="mpesa_manual">M-Pesa (manual verification)</option></select></label>
   <label>Amount (KES) *<input required type="number" min="1" step="1" value={amount} onChange={e=>setAmount(e.target.value)} /></label>
   <label>Received date and time<input required type="datetime-local" value={receivedAt} onChange={e=>setReceivedAt(e.target.value)}/></label>
   <label>Payer name<input value={payerName} onChange={e=>setPayerName(e.target.value)}/></label><label>Payer phone<input value={payerPhone} onChange={e=>setPayerPhone(e.target.value)}/></label>
   {method==="mpesa_manual"&&<label>M-Pesa transaction code *<input required minLength={6} maxLength={32} value={reference} onChange={e=>setReference(e.target.value.toUpperCase())} placeholder="e.g. QAB12CD34E"/></label>}
   <label className="wide-field">Notes<textarea value={notes} onChange={e=>setNotes(e.target.value)}/></label>
   {selectedOrder&&balances[selectedOrder]&&<p className="wide-field balance-inline">Outstanding balance: <b>{money(balances[selectedOrder].balance_due)}</b></p>}
   <div className="form-actions"><button className="primary-action compact" disabled={busy||!orders.length}>{busy?"Saving…":"Record payment"}</button></div>
  </form>
  {pending.length>0&&<div className="payment-section"><h3>Pending M-Pesa verification</h3>{pending.map(p=><article className="record-row" key={p.id}><div><b>{p.payment_number} · {money(p.amount)}</b><small>{p.mpesa_reference} · {p.payer_name||"Payer not named"} · {p.intended_order_id?orders.find(o=>o.id===p.intended_order_id)?.order_number:"Order not found"}</small></div><div className="payment-actions"><button className="primary-action compact" disabled={busy} onClick={()=>void verifyPayment(p,"verified")}>Verify</button><button className="secondary-action" disabled={busy} onClick={()=>void verifyPayment(p,"rejected")}>Reject</button></div></article>)}</div>}
  <div className="payment-section"><h3>Order balances</h3><div className="record-list">{orders.map(o=>{const b=balances[o.id];return <article className="record-row" key={o.id}><div><b>{o.order_number} · {customerName(o.customer_id)}</b><small>Total {money(o.total_amount)} · Paid {money(b?.net_paid??0)} · {o.status}</small></div><b>{money(b?.balance_due??o.total_amount)} due</b></article>;})}{!orders.length&&<p className="empty-records">No orders available to receive payments.</p>}</div></div>

  <div className="payment-section"><h3>Refunds and reversals</h3><p>Refunds are first recorded as pending. Posting is a separate owner action and changes the financial balance; cancellation preserves the audit trail.</p>
   <form className="record-form" onSubmit={recordRefund}>
    <label>Posted payment *<select required value={refundPayment} onChange={e=>{setRefundPayment(e.target.value);setRefundAllocation("");}}><option value="">Choose payment</option>{payments.filter(p=>p.status==="posted").map(p=><option key={p.id} value={p.id}>{p.payment_number} · {money(p.amount)}</option>)}</select></label>
    <label>Refund source<select value={refundBucket} onChange={e=>setRefundBucket(e.target.value as "allocated"|"unallocated")}><option value="allocated">Amount allocated to an order</option><option value="unallocated">Unallocated payment amount</option></select></label>
    {refundBucket==="allocated"&&<label>Order allocation *<select required value={refundAllocation} onChange={e=>setRefundAllocation(e.target.value)}><option value="">Choose allocation</option>{allocations.filter(a=>a.payment_id===refundPayment).map(a=><option key={a.id} value={a.id}>{orders.find(o=>o.id===a.order_id)?.order_number||"Order"} · {money(a.amount)}</option>)}</select></label>}
    <label>Amount (KES) *<input required type="number" min="1" step="1" value={refundAmount} onChange={e=>setRefundAmount(e.target.value)}/></label>
    <label>Refund method<select value={refundMethod} onChange={e=>setRefundMethod(e.target.value as "cash"|"mpesa")}><option value="mpesa">M-Pesa</option><option value="cash">Cash</option></select></label>
    <label>External reference<input value={refundReference} onChange={e=>setRefundReference(e.target.value)} placeholder="M-Pesa code / cash voucher"/></label>
    <label className="wide-field">Reason *<textarea required value={refundReason} onChange={e=>setRefundReason(e.target.value)}/></label>
    <div className="form-actions"><button className="primary-action compact" disabled={busy}>Record pending refund</button></div>
   </form>
   <div className="record-list">{refunds.map(r=><article className="record-row" key={r.id}><div><b>{money(r.amount)} · {r.refund_method.toUpperCase()} · {r.source_bucket}</b><small>{r.reason} · {new Date(r.created_at).toLocaleString("en-KE")} · {payments.find(p=>p.id===r.payment_id)?.payment_number||"Payment"}</small></div><div className="payment-actions"><span className={"status-chip "+r.status}>{r.status}</span>{r.status==="pending"&&<><button className="primary-action compact" disabled={busy} onClick={()=>void refundAction(r,"post")}>Post refund</button><button className="secondary-action" disabled={busy} onClick={()=>void refundAction(r,"cancel")}>Cancel</button></>}</div></article>)}{!refunds.length&&<p className="empty-records">No refunds recorded.</p>}</div>
   <h3>Reverse payment allocations</h3>{allocations.map(a=><article className="record-row" key={a.id}><div><b>{orders.find(o=>o.id===a.order_id)?.order_number||"Order allocation"} · {money(a.amount)}</b><small>{payments.find(p=>p.id===a.payment_id)?.payment_number||"Payment"}</small></div><button className="secondary-action" disabled={busy||payments.find(p=>p.id===a.payment_id)?.status!=="posted"} onClick={()=>void reverseAllocation(a)}>Reverse amount</button></article>)}
   <h3>Reverse whole payment</h3>{payments.filter(p=>p.status==="posted").map(p=><article className="record-row" key={p.id}><div><b>{p.payment_number} · {money(p.amount)}</b><small>Whole-payment reversal requires all remaining allocations to be reversed and pending/posted refunds resolved first.</small></div><button className="secondary-action" disabled={busy} onClick={()=>void reversePayment(p)}>Reverse payment</button></article>)}
  </div>

  <div className="payment-section"><h3>Payment history and receipts</h3><div className="record-list">{payments.map(p=>{const rec=receipts.find(r=>r.payment_id===p.id);return <article className="record-row" key={p.id}><div><b>{p.payment_number} · {money(p.amount)}</b><small>{p.method==="mpesa_manual"?"M-Pesa":"Cash"} · {p.received_at?new Date(p.received_at).toLocaleString("en-KE"):""} · {p.mpesa_reference||p.payer_name||"—"}</small></div><div className="payment-actions"><span className={"status-chip "+p.status}>{p.status.replace("_"," ")}</span>{rec&&<button className="secondary-action" onClick={()=>printReceipt(rec)}>Receipt {rec.receipt_number}</button>}</div></article>;})}{!payments.length&&<p className="empty-records">No payments recorded.</p>}</div></div>
  {receipt&&<div className="receipt-print"><div className="receipt-paper"><p className="eyebrow">MJ PRINTING & BRANDING</p><h2>OFFICIAL RECEIPT</h2><h3>{receipt.receipt_number}</h3><hr/><p>Received from: <b>{receipt.customer_name_snapshot}</b></p><p>Amount received: <b>{money(receipt.amount)}</b></p><p>Date: {new Date(receipt.issued_at).toLocaleString("en-KE")}</p><p>Payment reference: {payments.find(p=>p.id===receipt.payment_id)?.payment_number}</p><p>Thank you for your business.</p><button className="secondary-action no-print" onClick={()=>setReceipt(null)}>Close receipt</button></div></div>}
 </section>;
}
