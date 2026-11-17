import { useCallback, useEffect, useState } from "react";
import type { FormEvent } from "react";
import { supabase } from "./lib/supabase";

type Category = { id: string; name: string };
type Customer = { id: string; display_name: string };
type Quote = { id: string; quote_number: string; customer_id: string; status: string; revision_of: string | null; subtotal_amount: number; discount_amount: number; total_amount: number; created_at: string; expires_at: string | null };
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
  const [revisionOf,setRevisionOf]=useState<string|null>(null);
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
  const [acceptanceLink,setAcceptanceLink]=useState("");

  const load=useCallback(async()=>{
    if(!supabase)return;
    const [cat,q,o]=await Promise.all([
      supabase.from("service_categories").select("id,name").eq("business_id",businessId).eq("is_active",true).order("name"),
      supabase.from("quotations").select("id,quote_number,customer_id,status,revision_of,subtotal_amount,discount_amount,total_amount,created_at,expires_at").eq("business_id",businessId).order("created_at",{ascending:false}).limit(100),
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
    const {data,error:rpcError}=revisionOf
      ? await supabase.rpc("owner_create_quotation_revision",{
          p_original_quotation_id:revisionOf,p_lines:[line],
          p_expires_at:quoteExpiry?new Date(quoteExpiry+"T23:59:59").toISOString():null,
          p_customer_notes:customerNotes.trim()||null,p_internal_notes:internalNotes.trim()||null,p_request_id:rid()
        })
      : await supabase.rpc("owner_create_quotation",{
          p_business_id:businessId,p_customer_id:customerId,p_enquiry_id:enquiryId||null,p_lines:[line],
          p_expires_at:quoteExpiry?new Date(quoteExpiry+"T23:59:59").toISOString():null,
          p_customer_notes:customerNotes.trim()||null,p_internal_notes:internalNotes.trim()||null,p_request_id:rid()
        });
    if(rpcError)setError(rpcError.message);
    else {setNotice((revisionOf?"Quotation revision ":"Quotation ")+data.quote_number+" created as draft. Total "+kes(Number(data.total_amount))+".");setRevisionOf(null);setDescription("");setQuantity("1");setUnitPrice("");setDiscount("0");setCustomerNotes("");setInternalNotes("");setEnquiryId("");await load();onChanged();}
    setBusy(false);
  }
  async function updateSchedule(orderId:string, form:FormData){
    if(!supabase)return;
    const requiredBy=String(form.get("required_by")||"");
    const hoursRaw=String(form.get("promised_turnaround_hours")||"");
    const hours=hoursRaw?Number(hoursRaw):null;
    if(hours!==null&&(!Number.isInteger(hours)||hours<1||hours>8760)){setError("Turnaround hours must be between 1 and 8,760.");return;}
    setBusy(true);setError("");setNotice("");
    const {error:rpcError}=await supabase.rpc("owner_update_order_schedule",{
      p_order_id:orderId,p_required_by:requiredBy||null,p_promised_turnaround_hours:hours,p_request_id:rid()
    });
    if(rpcError)setError(rpcError.message);else{setNotice("Order turnaround schedule saved.");await load();}
    setBusy(false);
  }
  async function startRevision(q:Quote){
    if(!supabase)return;
    setBusy(true);setError("");setNotice("");
    const {data,error:readError}=await supabase.from("quotation_items")
      .select("description,quantity,unit,unit_price,line_discount,category_id,customer_supplies_item")
      .eq("business_id",businessId).eq("quotation_id",q.id).order("created_at").limit(1).maybeSingle();
    if(readError||!data){setError(readError?.message||"Could not load the quotation lines.");setBusy(false);return;}
    setCustomerId(q.customer_id);setEnquiryId("");setCategoryId(data.category_id||"");setDescription(data.description);
    setQuantity(String(data.quantity));setUnit(data.unit);setUnitPrice(String(data.unit_price));setDiscount(String(data.line_discount));
    setCustomerSupplies(Boolean(data.customer_supplies_item));setQuoteExpiry(q.expires_at?q.expires_at.slice(0,10):"");
    setRevisionOf(q.id);setTab("quotes");setNotice("Revision form loaded from "+q.quote_number+". Update the details and save the new version.");
    setBusy(false);
  }
  async function sendQuote(q:Quote){
    if(!supabase)return;
    setBusy(true);setError("");setNotice("");
    const {data,error:rpcError}=await supabase.rpc("owner_send_quotation",{p_quotation_id:q.id,p_expires_at:q.expires_at,p_request_id:rid()});
    if(rpcError)setError(rpcError.message);
    else {const link=window.location.origin+window.location.pathname+"?accept_quote="+encodeURIComponent(data.acceptance_token);setAcceptanceLink(link);setNotice("Quotation "+data.quote_number+" marked sent. Share the secure acceptance link with the customer.");}
    await load();setBusy(false);
  }
  const customerName=(id:string)=>customers.find(c=>c.id===id)?.display_name??"Customer";
  return <section className="connected-panel quote-workflow">
    <div className="panel-toolbar"><div><h2>Quotations and orders</h2><p>Live records and costing tools. Prices are in KES; tax is excluded.</p></div><button className="secondary-action" onClick={()=>void load()}>Refresh records</button></div>
    <div className="workflow-tabs"><button className={tab==="quotes"?"active":""} onClick={()=>setTab("quotes")}>Quotations</button><button className={tab==="costing"?"active":""} onClick={()=>setTab("costing")}>Costing profiles</button><button className={tab==="orders"?"active":""} onClick={()=>setTab("orders")}>Orders</button></div>
    {error&&<div className="notice error">{error}</div>}{notice&&<div className="notice success">{notice}</div>}{acceptanceLink&&<div className="acceptance-link"><input readOnly value={acceptanceLink}/><button className="secondary-action" onClick={()=>void navigator.clipboard.writeText(acceptanceLink)}>Copy customer link</button></div>}
    {tab==="quotes"&&<><form className="record-form" onSubmit={createQuote}>
      <h3 className="wide-field">{revisionOf?"Create quotation revision":"Create quotation"}</h3>
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
      <div className="form-actions"><button className="primary-action compact" disabled={busy||!customers.length||!categories.length}>{busy?"Saving…":revisionOf?"Save quotation revision":"Create draft quotation"}</button></div>
    </form><div className="record-list">{quotes.map(q=><article className="record-row quote-row" key={q.id}><div><b>{q.quote_number} · {customerName(q.customer_id)}</b><small>{new Date(q.created_at).toLocaleDateString("en-KE")} · {q.status}{q.expires_at?" · Expires "+new Date(q.expires_at).toLocaleDateString("en-KE"):""}</small></div><div className="quote-total"><b>{kes(Number(q.total_amount))}</b>{q.status==="draft"||q.status==="sent"?<button className="secondary-action" disabled={busy} onClick={()=>void sendQuote(q)}>{q.status==="sent"?"Resend":"Mark sent"}</button>:null}{["draft","sent","declined","expired"].includes(q.status)?<button className="secondary-action" disabled={busy} onClick={()=>void startRevision(q)}>Create revision</button>:null}</div></article>)}{!quotes.length&&<p className="empty-records">No quotations yet.</p>}</div></>}
    {tab==="costing"&&<><form className="record-form" onSubmit={createCostProfile}><h3 className="wide-field">Create a costing profile version</h3><p className="wide-field form-help">This starter profile records a fixed per-order cost for a service category. New versions preserve older quotation cost snapshots. Detailed material, labour and machine drivers can be added as the costing editor is expanded.</p><label>Service category *<select required value={costCategory} onChange={e=>setCostCategory(e.target.value)}><option value="">Choose category</option>{categories.map(c=><option key={c.id} value={c.id}>{c.name}</option>)}</select></label><label>Costing applies to<select value={costSaleMode} onChange={e=>setCostSaleMode(e.target.value)}><option value="value_added">Value-added service</option><option value="blank">Blank product</option></select></label><label>Estimated direct cost per order (KES) *<input required type="number" min="0" step="1" value={costAmount} onChange={e=>setCostAmount(e.target.value)} placeholder="e.g. 850"/></label><div className="form-actions"><button className="primary-action compact" disabled={busy||!categories.length}>{busy?"Saving…":"Save new profile version"}</button></div></form></>}
    {tab==="orders"&&<div className="record-list">{orders.map(o=><article className="order-card" key={o.id}><div className="order-card-heading"><div><b>{o.order_number} · {customerName(o.customer_id)}</b><small>Received {new Date(o.received_at).toLocaleDateString("en-KE")} · {o.required_by?"Due "+o.required_by:"Due date not set"}{o.promised_turnaround_hours?" · "+o.promised_turnaround_hours+"h promised":""}</small></div><div className="quote-total"><b>{kes(Number(o.total_amount))}</b><span className={"status-chip "+o.status}>{o.status.replace("_"," ")}</span></div></div><form className="order-schedule-form" onSubmit={e=>{e.preventDefault();void updateSchedule(o.id,new FormData(e.currentTarget));}}><label>Required by<input name="required_by" type="date" defaultValue={o.required_by||""}/></label><label>Promised turnaround (hours)<input name="promised_turnaround_hours" type="number" min="1" max="8760" step="1" defaultValue={o.promised_turnaround_hours||""} placeholder="e.g. 72"/></label><button className="secondary-action" disabled={busy}>Save schedule</button></form></article>)}{!orders.length&&<p className="empty-records">No orders yet. An accepted customer quotation creates its order automatically.</p>}</div>}
  </section>;
}
