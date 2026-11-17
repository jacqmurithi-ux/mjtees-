import { useCallback, useEffect, useState } from "react";
import type { FormEvent } from "react";
import { supabase } from "./lib/supabase";

type Category = { id: string; name: string };
type Customer = { id: string; display_name: string };
type Quote = { id: string; quote_number: string; customer_id: string; status: string; subtotal_amount: number; discount_amount: number; total_amount: number; created_at: string; expires_at: string | null };
type Order = { id: string; order_number: string; customer_id: string; status: string; total_amount: number; received_at: string; required_by: string | null; promised_turnaround_hours: number | null };
const rid = () => crypto.randomUUID();
const kes = (n: number) => new Intl.NumberFormat("en-KE", { style: "currency", currency: "KES", maximumFractionDigits: 0 }).format(n);

export default function QuoteWorkflow({ businessId, customers, enquiries, onChanged }: {
  businessId: string; customers: Customer[]; enquiries: {id:string;public_reference:string;contact_name:string;status:string}[]; onChanged:()=>void;
}) {
  const [categories,setCategories]=useState<Category[]>([]);
  const [quotes,setQuotes]=useState<Quote[]>([]);
  const [orders,setOrders]=useState<Order[]>([]);
  const [tab,setTab]=useState<"quotes"|"costing"|"orders">("quotes");
  const [busy,setBusy]=useState(false);
  const [error,setError]=useState("");
  const [notice,setNotice]=useState("");
  const [customerId,setCustomerId]=useState("");
  const [enquiryId,setEnquiryId]=useState("");
  const [categoryId,setCategoryId]=useState("");
  const [description,setDescription]=useState("");
  const [quantity,setQuantity]=useState("1");
  const [unit,setUnit]=useState("piece");
  const [unitPrice,setUnitPrice]=useState("");
  const [discount,setDiscount]=useState("0");
  const [customerSupplies,setCustomerSupplies]=useState(false);
  const [quoteExpiry,setQuoteExpiry]=useState("");
  const [customerNotes,setCustomerNotes]=useState("");
  const [internalNotes,setInternalNotes]=useState("");
  const [costCategory,setCostCategory]=useState("");
  const [costAmount,setCostAmount]=useState("");
  const [costSaleMode,setCostSaleMode]=useState("value_added");

  const load=useCallback(async()=>{
    if(!supabase)return;
    const [cat,q,o]=await Promise.all([
      supabase.from("service_categories").select("id,name").eq("business_id",businessId).eq("is_active",true).order("name"),
      supabase.from("quotations").select("id,quote_number,customer_id,status,subtotal_amount,discount_amount,total_amount,created_at,expires_at").eq("business_id",businessId).order("created_at",{ascending:false}).limit(100),
      supabase.from("orders").select("id,order_number,customer_id,status,total_amount,received_at,required_by,promised_turnaround_hours").eq("business_id",businessId).order("received_at",{ascending:false}).limit(100)
    ]);
    if(cat.error||q.error||o.error)throw cat.error||q.error||o.error;
    setCategories(cat.data??[]);setQuotes((q.data??[]) as Quote[]);setOrders((o.data??[]) as Order[]);
  },[businessId]);
  useEffect(()=>{void load().catch(e=>setError(e.message));},[load]);

  async function createCostProfile(e:FormEvent){
    e.preventDefault();if(!supabase)return;
    if(!costCategory||!costAmount||Number(costAmount)<0){setError("Choose a category and enter a valid estimated cost.");return;}
    setBusy(true);setError("");setNotice("");
    const {data,error:rpcError}=await supabase.rpc("owner_create_costing_profile",{
      p_business_id:businessId,p_catalogue_item_id:null,p_category_id:costCategory,p_sale_mode:costSaleMode,
      p_production_method_id:null,
      p_components:[{component_type:"other",stock_item_id:null,unit:"job",driver_type:"per_order",factor:1,expected_waste_percent:0,fixed_cost:Math.round(Number(costAmount))}],
      p_request_id:rid()
    });
    if(rpcError)setError(rpcError.message);
    else {setNotice("Costing profile v"+data.version+" saved. Earlier versions remain in the history.");setCostAmount("");await load();onChanged();}
    setBusy(false);
  }
  async function createQuote(e:FormEvent){
    e.preventDefault();if(!supabase)return;
    if(!customerId||!categoryId||!description.trim()||Number(quantity)<=0||Number(unitPrice)<0){setError("Complete the customer, category, description, quantity and price.");return;}
    setBusy(true);setError("");setNotice("");
    const line={catalogue_item_id:null,category_id:categoryId,stock_item_id:null,description:description.trim(),
      quantity:Number(quantity),unit,unit_price:Math.round(Number(unitPrice)),line_discount:Math.round(Number(discount)||0),
      sale_mode:"value_added",customer_supplies_item:customerSupplies,production_method_id:null,production_specification:{}};
    const {data,error:rpcError}=await supabase.rpc("owner_create_quotation",{
      p_business_id:businessId,p_customer_id:customerId,p_enquiry_id:enquiryId||null,p_lines:[line],
      p_expires_at:quoteExpiry?new Date(quoteExpiry+"T23:59:59").toISOString():null,
      p_customer_notes:customerNotes.trim()||null,p_internal_notes:internalNotes.trim()||null,p_request_id:rid()
    });
    if(rpcError)setError(rpcError.message);
    else {setNotice("Quotation "+data.quote_number+" created as draft. Total "+kes(Number(data.total_amount))+".");setDescription("");setQuantity("1");setUnitPrice("");setDiscount("0");setCustomerNotes("");setInternalNotes("");setEnquiryId("");await load();onChanged();}
    setBusy(false);
  }
  async function sendQuote(q:Quote){
    if(!supabase)return;
    setBusy(true);setError("");setNotice("");
    const {data,error:rpcError}=await supabase.rpc("owner_send_quotation",{p_quotation_id:q.id,p_expires_at:q.expires_at,p_request_id:rid()});
    if(rpcError)setError(rpcError.message);
    else setNotice("Quotation "+data.quote_number+" marked sent. Acceptance token created; customer-facing acceptance page still needs to be connected.");
    await load();setBusy(false);
  }
  const customerName=(id:string)=>customers.find(c=>c.id===id)?.display_name??"Customer";
  return <section className="connected-panel quote-workflow">
    <div className="panel-toolbar"><div><h2>Quotations and orders</h2><p>Live records and costing tools. Prices are in KES; tax is excluded.</p></div><button className="secondary-action" onClick={()=>void load()}>Refresh records</button></div>
    <div className="workflow-tabs"><button className={tab==="quotes"?"active":""} onClick={()=>setTab("quotes")}>Quotations</button><button className={tab==="costing"?"active":""} onClick={()=>setTab("costing")}>Costing profiles</button><button className={tab==="orders"?"active":""} onClick={()=>setTab("orders")}>Orders</button></div>
    {error&&<div className="notice error">{error}</div>}{notice&&<div className="notice success">{notice}</div>}
    {tab==="quotes"&&<><form className="record-form" onSubmit={createQuote}>
      <h3 className="wide-field">Create quotation</h3>
      <label>Customer *<select required value={customerId} onChange={e=>setCustomerId(e.target.value)}><option value="">Choose customer</option>{customers.map(c=><option key={c.id} value={c.id}>{c.display_name}</option>)}</select></label>
      <label>Related enquiry<select value={enquiryId} onChange={e=>setEnquiryId(e.target.value)}><option value="">No linked enquiry</option>{enquiries.filter(x=>x.status!=="spam").map(x=><option key={x.id} value={x.id}>{x.public_reference} · {x.contact_name}</option>)}</select></label>
      <label>Service category *<select required value={categoryId} onChange={e=>setCategoryId(e.target.value)}><option value="">Choose category</option>{categories.map(c=><option key={c.id} value={c.id}>{c.name}</option>)}</select></label>
      <label>Description *<input required maxLength={240} value={description} onChange={e=>setDescription(e.target.value)} placeholder="e.g. 20 branded T-shirts"/></label>
      <label>Quantity *<input required type="number" min="0.001" step="0.001" value={quantity} onChange={e=>setQuantity(e.target.value)}/></label>
      <label>Unit<input required maxLength={24} value={unit} onChange={e=>setUnit(e.target.value)}/></label>
      <label>Unit selling price (KES) *<input required type="number" min="0" step="1" value={unitPrice} onChange={e=>setUnitPrice(e.target.value)}/></label>
      <label>Line discount (KES)<input type="number" min="0" step="1" value={discount} onChange={e=>setDiscount(e.target.value)}/></label>
      <label className="check-field"><input type="checkbox" checked={customerSupplies} onChange={e=>setCustomerSupplies(e.target.checked)}/> Customer supplies the item</label>
      <label>Quote expiry<input type="date" value={quoteExpiry} onChange={e=>setQuoteExpiry(e.target.value)}/></label>
      <label className="wide-field">Customer notes<textarea value={customerNotes} onChange={e=>setCustomerNotes(e.target.value)}/></label>
      <label className="wide-field">Internal notes (not shown to customer)<textarea value={internalNotes} onChange={e=>setInternalNotes(e.target.value)}/></label>
      <div className="form-actions"><button className="primary-action compact" disabled={busy||!customers.length||!categories.length}>{busy?"Saving…":"Create draft quotation"}</button></div>
    </form><div className="record-list">{quotes.map(q=><article className="record-row quote-row" key={q.id}><div><b>{q.quote_number} · {customerName(q.customer_id)}</b><small>{new Date(q.created_at).toLocaleDateString("en-KE")} · {q.status}{q.expires_at?" · Expires "+new Date(q.expires_at).toLocaleDateString("en-KE"):""}</small></div><div className="quote-total"><b>{kes(Number(q.total_amount))}</b>{q.status==="draft"||q.status==="sent"?<button className="secondary-action" disabled={busy} onClick={()=>void sendQuote(q)}>{q.status==="sent"?"Resend":"Mark sent"}</button>:null}</div></article>)}{!quotes.length&&<p className="empty-records">No quotations yet.</p>}</div></>}
    {tab==="costing"&&<><form className="record-form" onSubmit={createCostProfile}><h3 className="wide-field">Create a costing profile version</h3><p className="wide-field form-help">This starter profile records a fixed per-order cost for a service category. New versions preserve older quotation cost snapshots. Detailed material, labour and machine drivers can be added as the costing editor is expanded.</p><label>Service category *<select required value={costCategory} onChange={e=>setCostCategory(e.target.value)}><option value="">Choose category</option>{categories.map(c=><option key={c.id} value={c.id}>{c.name}</option>)}</select></label><label>Costing applies to<select value={costSaleMode} onChange={e=>setCostSaleMode(e.target.value)}><option value="value_added">Value-added service</option><option value="blank">Blank product</option></select></label><label>Estimated direct cost per order (KES) *<input required type="number" min="0" step="1" value={costAmount} onChange={e=>setCostAmount(e.target.value)} placeholder="e.g. 850"/></label><div className="form-actions"><button className="primary-action compact" disabled={busy||!categories.length}>{busy?"Saving…":"Save new profile version"}</button></div></form></>}
    {tab==="orders"&&<div className="record-list">{orders.map(o=><article className="record-row" key={o.id}><div><b>{o.order_number} · {customerName(o.customer_id)}</b><small>Received {new Date(o.received_at).toLocaleDateString("en-KE")} · {o.required_by?"Required "+o.required_by:"No due date"}{o.promised_turnaround_hours?" · "+o.promised_turnaround_hours+"h promised":""}</small></div><div className="quote-total"><b>{kes(Number(o.total_amount))}</b><span className={"status-chip "+o.status}>{o.status.replace("_"," ")}</span></div></article>)}{!orders.length&&<p className="empty-records">No orders yet. An accepted customer quotation creates its order automatically.</p>}</div>}
  </section>;
}
