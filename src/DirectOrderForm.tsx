import { useEffect, useMemo, useState } from "react";
import type { FormEvent } from "react";
import { supabase } from "./lib/supabase";

type Customer={id:string;display_name:string;customer_status:string};
type Address={id:string;label:string|null;recipient_name:string|null;phone:string|null;address_text:string;locality:string|null;is_default:boolean};
type Contact={id:string;full_name:string;position_title:string|null;phone:string|null;email:string|null;is_primary:boolean};
type Category={id:string;name:string};
type Catalogue={id:string;name:string;category_id:string|null;item_type:"product"|"service"};
type Stock={id:string;sku:string;name:string;base_unit:string;stock_kind:string};
type Method={id:string;name:string;code:string};
type Line={catalogueItemId:string;categoryId:string;description:string;quantity:string;unit:string;unitPrice:string;discount:string;customerSupplies:boolean;stockItemId:string;saleMode:string;productionMethodId:string;printPosition:string;garmentType:string;artworkReference:string;instructions:string};
const rid=()=>crypto.randomUUID();
const blank=():Line=>({catalogueItemId:"",categoryId:"",description:"",quantity:"1",unit:"piece",unitPrice:"",discount:"0",customerSupplies:false,stockItemId:"",saleMode:"value_added",productionMethodId:"",printPosition:"",garmentType:"",artworkReference:"",instructions:""});
const kes=(n:number)=>new Intl.NumberFormat("en-KE",{style:"currency",currency:"KES",maximumFractionDigits:0}).format(n);

export default function DirectOrderForm({businessId,customer,addresses,onCreated,onCancel}:{businessId:string;customer:Customer;addresses:Address[];contacts:Contact[];onCreated:()=>void;onCancel:()=>void}){
 const [categories,setCategories]=useState<Category[]>([]),[catalogue,setCatalogue]=useState<Catalogue[]>([]),[stock,setStock]=useState<Stock[]>([]),[methods,setMethods]=useState<Method[]>([]);
 const [lines,setLines]=useState<Line[]>([blank()]),[discount,setDiscount]=useState("0"),[customerNotes,setCustomerNotes]=useState(""),[internalNotes,setInternalNotes]=useState(""),[requiredBy,setRequiredBy]=useState(""),[turnaround,setTurnaround]=useState(""),[addressId,setAddressId]=useState(addresses.find(a=>a.is_default)?.id||""),[contactId,setContactId]=useState(contacts.find(c=>c.is_primary)?.id||"");
 const [marginReason,setMarginReason]=useState(""),[busy,setBusy]=useState(false),[error,setError]=useState(""),[notice,setNotice]=useState("");
 useEffect(()=>{if(!supabase)return;let live=true;void Promise.all([
  supabase.from("service_categories").select("id,name").eq("business_id",businessId).eq("is_active",true).order("name"),
  supabase.from("catalogue_items").select("id,name,category_id,item_type").eq("business_id",businessId).eq("is_active",true).order("name").limit(500),
  supabase.from("stock_items").select("id,sku,name,base_unit,stock_kind").eq("business_id",businessId).eq("is_active",true).order("name").limit(500),
  supabase.from("production_methods").select("id,name,code").eq("is_active",true).order("name")
 ]).then(([c,ci,s,m])=>{if(!live)return;const e=c.error||ci.error||s.error||m.error;if(e){setError(e.message);return;}setCategories(c.data||[]);setCatalogue(ci.data||[]);setStock(s.data||[]);setMethods(m.data||[]);}).catch(e=>live&&setError(e.message));return()=>{live=false;};},[businessId]);
 const subtotal=useMemo(()=>lines.reduce((sum,l)=>sum+Math.max(0,Number(l.quantity)||0)*Math.max(0,Number(l.unitPrice)||0)-Math.max(0,Number(l.discount)||0),0),[lines]);
 const update=(i:number,patch:Partial<Line>)=>setLines(v=>v.map((line,index)=>index===i?{...line,...patch}:line));
 async function submit(e:FormEvent){
  e.preventDefault();if(!supabase)return;
  if(customer.customer_status!=="active"){setError("Only active customer profiles can receive a new order.");return;}
  if(!lines.length||lines.some(l=>!l.categoryId||!l.description.trim()||!Number.isFinite(Number(l.quantity))||Number(l.quantity)<=0||(l.unitPrice.trim()!==""&&(!Number.isSafeInteger(Number(l.unitPrice))||Number(l.unitPrice)<0))||!Number.isSafeInteger(Number(l.discount))||Number(l.discount)<0||(l.saleMode==="blank"&&!l.customerSupplies&&!l.stockItemId)||(l.saleMode==="value_added"&&catalogue.find(x=>x.id===l.catalogueItemId)?.item_type==="product"&&!l.productionMethodId))){
   setError("Complete every order line: category, description, positive quantity, valid price and supply source.");return;
  }
  if(!Number.isSafeInteger(Number(discount))||Number(discount)<0||Number(discount)>subtotal){setError("Enter a valid order discount not exceeding the line total.");return;}
  const hours=turnaround.trim()?Number(turnaround):null;if(hours!==null&&(!Number.isInteger(hours)||hours<1||hours>8760)){setError("Turnaround must be between 1 and 8,760 hours.");return;}
  setBusy(true);setError("");setNotice("");
  const payload=lines.map(l=>({catalogue_item_id:l.catalogueItemId||null,category_id:l.categoryId,stock_item_id:l.customerSupplies?null:(l.stockItemId||null),description:l.description.trim(),quantity:Number(l.quantity),unit:l.unit.trim(),unit_price:l.unitPrice.trim()?Number(l.unitPrice):null,line_discount:Number(l.discount),sale_mode:l.saleMode,customer_supplies_item:l.customerSupplies,production_method_id:l.saleMode==="blank"?null:(l.productionMethodId||null),production_specification:{print_position:l.printPosition.trim()||null,garment_type:l.garmentType.trim()||null,artwork_reference:l.artworkReference.trim()||null,artwork_instructions:l.instructions.trim()||null}}));
  const selectedAddress=addresses.find(a=>a.id===addressId);const selectedContact=contacts.find(c=>c.id===contactId);\n  const orderInternalNotes=[internalNotes.trim(),selectedContact?"Order contact: "+selectedContact.full_name+" · "+[selectedContact.position_title,selectedContact.phone,selectedContact.email].filter(Boolean).join(" · "):"",selectedAddress?"Delivery address reference: "+[selectedAddress.label,selectedAddress.recipient_name,selectedAddress.phone,selectedAddress.address_text,selectedAddress.locality].filter(Boolean).join(", "):""].filter(Boolean).join("\\n\\n");\n  const {data,error:rpcError}=await supabase.rpc("owner_create_direct_order",{p_business_id:businessId,p_customer_id:customer.id,p_enquiry_id:null,p_lines:payload,p_order_discount:Number(discount),p_customer_notes:customerNotes.trim()||null,p_internal_notes:orderInternalNotes||null,p_request_id:rid(),p_margin_exception_reason:marginReason.trim()||null});
  if(rpcError){setError(rpcError.message);setBusy(false);return;}
  const orderNumber=String(data?.order_number||"");
  if(orderNumber){
   const {data:order}=await supabase.from("orders").select("id").eq("business_id",businessId).eq("order_number",orderNumber).maybeSingle();
   if(order?.id&&(requiredBy||hours!==null)){
    const {error:scheduleError}=await supabase.rpc("owner_update_order_schedule",{p_order_id:order.id,p_required_by:requiredBy||null,p_promised_turnaround_hours:hours,p_request_id:rid()});
    if(scheduleError)setNotice("Order "+orderNumber+" created, but its turnaround schedule needs saving: "+scheduleError.message);
   }
  }
  const address=addresses.find(a=>a.id===addressId);
  setNotice("Order "+(orderNumber||"created")+" for "+customer.display_name+" is confirmed. "+(address?"Selected delivery address: "+[address.label,address.address_text,address.locality].filter(Boolean).join(", ")+". Add/confirm it in Delivery & Collection when arranging handover.":""));
  setBusy(false);onCreated();
 }
 return <form className="record-form direct-customer-order" onSubmit={submit}>
  <div className="wide-field direct-order-heading"><div><h3>Create order for {customer.display_name}</h3><p>Order will be linked to this customer and use the existing order, invoice and production records.</p></div><button type="button" className="secondary-action" onClick={onCancel}>Close</button></div>
  {error&&<div className="notice error wide-field" role="alert">{error}</div>}{notice&&<div className="notice success wide-field" role="status">{notice}</div>}
  <label className="wide-field">Customer <input value={customer.display_name} readOnly/></label>
  <label>Required by<input type="date" value={requiredBy} onChange={e=>setRequiredBy(e.target.value)}/></label>
  <label>Promised turnaround (hours)<input type="number" min="1" max="8760" step="1" value={turnaround} onChange={e=>setTurnaround(e.target.value)} placeholder="e.g. 72"/></label>
  <div className="wide-field"><b>Order items</b>{lines.map((line,index)=><div className="quote-line-editor" key={index}>
   <label>Catalogue item<select value={line.catalogueItemId} onChange={e=>{const item=catalogue.find(x=>x.id===e.target.value);update(index,{catalogueItemId:e.target.value,categoryId:item?.category_id||line.categoryId,description:item?.name||line.description});}}><option value="">Custom / not listed</option>{catalogue.map(x=><option key={x.id} value={x.id}>{x.name} · {x.item_type}</option>)}</select></label>
   <label>Service category *<select required value={line.categoryId} onChange={e=>update(index,{categoryId:e.target.value})}><option value="">Choose category</option>{categories.map(x=><option key={x.id} value={x.id}>{x.name}</option>)}</select></label>
   <label>Description *<input required maxLength={240} value={line.description} onChange={e=>update(index,{description:e.target.value})} placeholder="e.g. 20 branded T-shirts"/></label>
   <label>Quantity *<input required type="number" min="0.001" step="0.001" value={line.quantity} onChange={e=>update(index,{quantity:e.target.value})}/></label>
   <label>Unit *<input required maxLength={24} value={line.unit} onChange={e=>update(index,{unit:e.target.value})}/></label>
   <label>Agreed unit price (KES)<input type="number" min="0" step="1" value={line.unitPrice} onChange={e=>update(index,{unitPrice:e.target.value})} placeholder="Leave blank for suggested price"/></label>
   <label>Line discount (KES)<input type="number" min="0" step="1" value={line.discount} onChange={e=>update(index,{discount:e.target.value})}/></label>
   <label>Sale type<select value={line.saleMode} onChange={e=>update(index,{saleMode:e.target.value,productionMethodId:e.target.value==="blank"?"":line.productionMethodId})}><option value="value_added">Printed / branded item</option><option value="blank">Blank item sale</option></select></label>
   {line.saleMode==="value_added"&&<label>Printing / production method<select value={line.productionMethodId} onChange={e=>update(index,{productionMethodId:e.target.value})}><option value="">Choose method / general service</option>{methods.map(x=><option key={x.id} value={x.id}>{x.name}</option>)}</select></label>}
   <label>Garment / item type<input maxLength={100} value={line.garmentType} onChange={e=>update(index,{garmentType:e.target.value})} placeholder="T-shirt, hoodie, mug…"/></label>
   <label>Print position<input maxLength={80} value={line.printPosition} onChange={e=>update(index,{printPosition:e.target.value})} placeholder="Front, back, sleeve…"/></label>
   <label>Artwork reference / link<input maxLength={1000} value={line.artworkReference} onChange={e=>update(index,{artworkReference:e.target.value})} placeholder="Drive link or artwork reference"/></label>
   <label className="wide-field">Printing / production instructions<textarea maxLength={2000} value={line.instructions} onChange={e=>update(index,{instructions:e.target.value})}/></label>
   <label>Shop stock item<select disabled={line.customerSupplies} value={line.stockItemId} onChange={e=>update(index,{stockItemId:e.target.value})}><option value="">No stock item linked</option>{stock.filter(x=>line.saleMode!=="blank"||x.stock_kind==="blank_product").map(x=><option key={x.id} value={x.id}>{x.name} · {x.sku} ({x.base_unit})</option>)}</select></label>
   <label className="check-field"><input type="checkbox" checked={line.customerSupplies} onChange={e=>update(index,{customerSupplies:e.target.checked,stockItemId:e.target.checked?"":line.stockItemId})}/> Customer supplies the item (no shop stock deduction)</label>
   <button type="button" className="secondary-action" disabled={lines.length===1} onClick={()=>setLines(v=>v.filter((_,i)=>i!==index))}>Remove item</button>
  </div>)}<button type="button" className="secondary-action" onClick={()=>setLines(v=>[...v,blank()])}>＋ Add another item</button></div>
  <label>Order discount (KES)<input type="number" min="0" step="1" value={discount} onChange={e=>setDiscount(e.target.value)}/></label>
  <div className="purchase-totals"><div><span>Indicative line total</span><b>{kes(subtotal)}</b></div><div className="purchase-grand-total"><span>Before order discount</span><strong>{kes(subtotal)}</strong></div></div>
  <label>Order contact<select value={contactId} onChange={e=>setContactId(e.target.value)}><option value="">Use main customer contact</option>{contacts.map(c=><option key={c.id} value={c.id}>{c.full_name}{c.is_primary?" · Primary":""} · {c.phone||c.email||"No details"}</option>)}</select></label>\n  <label className="wide-field">Saved delivery address<select value={addressId} onChange={e=>setAddressId(e.target.value)}><option value="">Choose later in Delivery & Collection</option>{addresses.map(a=><option key={a.id} value={a.id}>{a.label||"Address"} · {a.address_text}{a.is_default?" · Default":""}</option>)}</select><small>Address selection is a handover reference; final delivery details are confirmed in Delivery & Collection.</small></label>
  <label className="wide-field">Customer notes<textarea value={customerNotes} onChange={e=>setCustomerNotes(e.target.value)}/></label>
  <label className="wide-field">Internal notes (not shown to customer)<textarea value={internalNotes} onChange={e=>setInternalNotes(e.target.value)}/></label>
  <label className="wide-field">Owner margin exception reason (only if required)<textarea maxLength={1000} value={marginReason} onChange={e=>setMarginReason(e.target.value)} placeholder="Explain an approved exception to the 30% gross-margin floor, if applicable."/></label>
  <div className="form-actions wide-field"><button className="primary-action compact" disabled={busy||!categories.length}>{busy?"Creating order…":"Create confirmed order"}</button><button type="button" className="secondary-action" onClick={onCancel} disabled={busy}>Cancel</button></div>
 </form>;
}
