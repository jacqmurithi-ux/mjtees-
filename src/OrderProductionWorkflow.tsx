import { useCallback, useEffect, useState } from "react";
import { supabase } from "./lib/supabase";

type Order={id:string;order_number:string;customer_id:string;status:string;total_amount:number;received_at:string;required_by:string|null;promised_turnaround_hours:number|null};
type Item={id:string;order_id:string;description:string;quantity:number;unit:string;sale_mode:string;customer_supplies_item:boolean;production_method_id:string|null;production_specification:unknown};
type Method={id:string;code:string;name:string};
type Job={id:string;order_item_id:string;status:string;planned_quantity:number;due_at:string|null;notes:string|null};
type Check={id:string;job_id:string;result:string;inspection_mode:string;checked_at:string;notes:string|null};
type Stock={id:string;name:string;base_unit:string};
type Location={id:string;name:string};
const rid=()=>crypto.randomUUID();
const money=(n:number)=>new Intl.NumberFormat("en-KE",{style:"currency",currency:"KES",maximumFractionDigits:0}).format(n);

export default function OrderProductionWorkflow({businessId,customers,onChanged}:{businessId:string;customers:{id:string;display_name:string}[];onChanged:()=>void}){
 const [orders,setOrders]=useState<Order[]>([]);const [items,setItems]=useState<Item[]>([]);const [methods,setMethods]=useState<Method[]>([]);
 const [jobs,setJobs]=useState<Job[]>([]);const [checks,setChecks]=useState<Check[]>([]);const [stock,setStock]=useState<Stock[]>([]);const [locations,setLocations]=useState<Location[]>([]);
 const [busy,setBusy]=useState(false);const [error,setError]=useState("");const [notice,setNotice]=useState("");
 const [requiredBy,setRequiredBy]=useState<Record<string,string>>({});const [turnaround,setTurnaround]=useState<Record<string,string>>({});
 const [methodByItem,setMethodByItem]=useState<Record<string,string>>({});const [jobDue,setJobDue]=useState<Record<string,string>>({});
 const [material,setMaterial]=useState<Record<string,{stock:string;location:string;quantity:string;reason:string}>>({});
 const [qc,setQc]=useState<Record<string,{result:"pass"|"fail";mode:"self"|"second_person";inspector:string;notes:string}>>({});
 const [handover,setHandover]=useState<Record<string,{method:"collection"|"courier";recipient:string;tracking:string;exception:string}>>({});
 const load=useCallback(async()=>{
  const client=supabase;if(!client)return;
  const [o,i,m,j,q,s,l]=await Promise.all([
   client.from("orders").select("id,order_number,customer_id,status,total_amount,received_at,required_by,promised_turnaround_hours").eq("business_id",businessId).order("received_at",{ascending:false}).limit(200),
   client.from("order_items").select("id,order_id,description,quantity,unit,sale_mode,customer_supplies_item,production_method_id,production_specification").eq("business_id",businessId).limit(500),
   client.from("production_methods").select("id,code,name").eq("is_active",true).order("name"),
   client.from("production_jobs").select("id,order_item_id,status,planned_quantity,due_at,notes").eq("business_id",businessId).order("created_at",{ascending:false}).limit(300),
   client.from("quality_checks").select("id,job_id,result,inspection_mode,checked_at,notes").eq("business_id",businessId).order("checked_at",{ascending:false}).limit(500),
   client.from("stock_items").select("id,name,base_unit").eq("business_id",businessId).eq("is_active",true).order("name").limit(500),
   client.from("inventory_locations").select("id,name").eq("business_id",businessId).eq("is_active",true).order("name")
  ]);
  const failure=o.error||i.error||m.error||j.error||q.error||s.error||l.error;if(failure)throw failure;
  setOrders((o.data??[]) as Order[]);setItems((i.data??[]) as Item[]);setMethods((m.data??[]) as Method[]);setJobs((j.data??[]) as Job[]);setChecks((q.data??[]) as Check[]);setStock((s.data??[]) as Stock[]);setLocations((l.data??[]) as Location[]);
 },[businessId]);
 useEffect(()=>{void load().catch(e=>setError(e.message));},[load]);
 const call=async(name:string,args:Record<string,unknown>,success:string)=>{
  if(!supabase)return;setBusy(true);setError("");setNotice("");
  const {error:rpcError}=await supabase.rpc(name,args);
  if(rpcError)setError(rpcError.message);else{setNotice(success);await load();onChanged();}
  setBusy(false);
 };
 const customer=(id:string)=>customers.find(c=>c.id===id)?.display_name??"Customer";
 const orderItems=(orderId:string)=>items.filter(i=>i.order_id===orderId);
 const itemLabel=(id:string)=>{const item=items.find(i=>i.id===id);return item?item.description:"Order line";};
 const jobFor=(itemId:string)=>jobs.find(j=>j.order_item_id===itemId&&j.status!=="cancelled");
 const latestCheck=(jobId:string)=>checks.filter(q=>q.job_id===jobId).sort((a,b)=>new Date(b.checked_at).getTime()-new Date(a.checked_at).getTime())[0];
 const updateSchedule=(order:Order)=>void call("owner_update_order_schedule",{p_order_id:order.id,p_required_by:requiredBy[order.id]||null,p_promised_turnaround_hours:turnaround[order.id]?Number(turnaround[order.id]):null,p_request_id:rid()},"Order turnaround schedule saved.");
 const startJob=(item:Item)=>{
  const code=methodByItem[item.id]||methods.find(m=>m.id===item.production_method_id)?.code;
  if(!code){setError("Choose a production method matching the accepted quotation.");return;}
  void call("owner_start_production_job",{p_order_item_id:item.id,p_method_code:code,p_plan:jobDue[item.id]?{due_at:new Date(jobDue[item.id]).toISOString()}: {},p_request_id:rid()},"Production job started.");
 };
 const issueMaterial=(job:Job)=>{
  const v=material[job.id]||{stock:"",location:"",quantity:"",reason:"Production material issue"};
  if(!v.stock||!v.location||Number(v.quantity)<=0||!v.reason.trim()){setError("Choose stock, location, quantity and reason.");return;}
  void call("owner_issue_job_material",{p_job_id:job.id,p_stock_item_id:v.stock,p_location_id:v.location,p_quantity:Number(v.quantity),p_reason:v.reason.trim(),p_request_id:rid()},"Production material issued and inventory reduced.");
 };
 const qualityCheck=(job:Job)=>{
  const v=qc[job.id]||{result:"pass",mode:"self",inspector:"",notes:""};
  const inspector=v.mode==="self"?null:v.inspector.trim()||null;
  if(v.mode==="second_person"&&!inspector){setError("Enter the second inspector's registered user ID.");return;}
  void call("owner_record_quality_check",{p_job_id:job.id,p_result:v.result,p_inspection_mode:v.mode,p_inspector_user_id:inspector,p_notes:v.notes.trim()||null,p_request_id:rid()}, "Quality check recorded.");
 };
 const handoverOrder=(order:Order)=>{
  const v=handover[order.id]||{method:"collection",recipient:"",tracking:"",exception:""};
  if(!v.recipient.trim()){setError("Enter the person receiving the order.");return;}
  void call("owner_handover_order",{p_order_id:order.id,p_method:v.method,p_recipient_name:v.recipient.trim(),p_tracking_reference:v.tracking.trim()||null,p_payment_exception_reason:v.exception.trim()||null,p_request_id:rid()},"Order handed over. The system recorded the delivery and any approved payment exception.");
 };
 return <section className="connected-panel order-production">
  <div className="panel-toolbar"><div><h2>Orders and production</h2><p>Track accepted orders, promised turnaround, production, inspection and customer handover.</p></div><button className="secondary-action" onClick={()=>void load()}>Refresh</button></div>
  {error&&<div className="notice error">{error}</div>}{notice&&<div className="notice success">{notice}</div>}
  <div className="record-list">{orders.map(order=>{
   const lines=orderItems(order.id);const orderJobs=jobs.filter(j=>lines.some(i=>i.id===j.order_item_id));
   const hand=handover[order.id]||{method:"collection" as const,recipient:"",tracking:"",exception:""};
   return <article className="enquiry-card" key={order.id}>
    <div className="enquiry-top"><div><b>{order.order_number} · {customer(order.customer_id)}</b><small>{new Date(order.received_at).toLocaleDateString("en-KE")} · {money(order.total_amount)}</small></div><span className={"status-chip "+order.status}>{order.status.replaceAll("_"," ")}</span></div>
    <div className="schedule-editor"><label>Required by<input type="date" value={requiredBy[order.id]??order.required_by??""} onChange={e=>setRequiredBy(v=>({...v,[order.id]:e.target.value}))}/></label><label>Promised turnaround (hours)<input type="number" min="1" max="8760" value={turnaround[order.id]??(order.promised_turnaround_hours?.toString()||"")} onChange={e=>setTurnaround(v=>({...v,[order.id]:e.target.value}))}/></label><button className="secondary-action" disabled={busy} onClick={()=>updateSchedule(order)}>Save schedule</button></div>
    <h3>Order lines</h3>{lines.map(item=>{const job=jobFor(item.id);const check=job?latestCheck(job.id):undefined;const selectedMethod=methodByItem[item.id]||methods.find(m=>m.id===item.production_method_id)?.code||"";
     return <div className="production-line" key={item.id}><b>{item.description}</b><small>{item.quantity} {item.unit} · {item.sale_mode.replaceAll("_"," ")} · {item.customer_supplies_item?"Customer-supplied item":"Shop-supplied item"}</small>
      {!job&&item.sale_mode==="value_added"&&<div className="inline-controls"><select value={selectedMethod} onChange={e=>setMethodByItem(v=>({...v,[item.id]:e.target.value}))}><option value="">Production method</option>{methods.map(m=><option key={m.id} value={m.code}>{m.name}</option>)}</select><input type="datetime-local" aria-label="Production due date" value={jobDue[item.id]||""} onChange={e=>setJobDue(v=>({...v,[item.id]:e.target.value}))}/><button className="primary-action compact" disabled={busy} onClick={()=>startJob(item)}>Start production</button></div>}
      {job&&<div className="job-card"><div className="enquiry-top"><b>Production job · {job.status.replaceAll("_"," ")}</b><small>{job.due_at?new Date(job.due_at).toLocaleString("en-KE"):"No job due date"}</small></div>
       {["planned","in_progress","rework"].includes(job.status)&&<div className="inline-controls"><select value={(material[job.id]||{stock:""}).stock} onChange={e=>setMaterial(v=>({...v,[job.id]:{...(v[job.id]||{location:"",quantity:"",reason:"Production material issue"}),stock:e.target.value}}))}><option value="">Material</option>{stock.map(s=><option key={s.id} value={s.id}>{s.name} ({s.base_unit})</option>)}</select><select value={(material[job.id]||{location:""}).location} onChange={e=>setMaterial(v=>({...v,[job.id]:{...(v[job.id]||{stock:"",quantity:"",reason:"Production material issue"}),location:e.target.value}}))}><option value="">Stock location</option>{locations.map(l=><option key={l.id} value={l.id}>{l.name}</option>)}</select><input type="number" min="0.001" step="any" placeholder="Qty" value={(material[job.id]||{quantity:""}).quantity} onChange={e=>setMaterial(v=>({...v,[job.id]:{...(v[job.id]||{stock:"",location:"",reason:"Production material issue"}),quantity:e.target.value}}))}/><input placeholder="Issue reason" value={(material[job.id]||{reason:"Production material issue"}).reason} onChange={e=>setMaterial(v=>({...v,[job.id]:{...(v[job.id]||{stock:"",location:"",quantity:""}),reason:e.target.value}}))}/><button className="secondary-action" disabled={busy} onClick={()=>issueMaterial(job)}>Issue material</button></div>}
       {!["completed","cancelled"].includes(job.status)&&<><div className="inline-controls"><select value={(qc[job.id]||{result:"pass"}).result} onChange={e=>setQc(v=>({...v,[job.id]:{...(v[job.id]||{mode:"self",inspector:"",notes:""}),result:e.target.value as "pass"|"fail"}}))}><option value="pass">Pass inspection</option><option value="fail">Fail inspection</option></select><select value={(qc[job.id]||{mode:"self"}).mode} onChange={e=>setQc(v=>({...v,[job.id]:{...(v[job.id]||{result:"pass",inspector:"",notes:""}),mode:e.target.value as "self"|"second_person"}}))}><option value="self">Self-inspection</option><option value="second_person">Second-person inspection</option></select>{(qc[job.id]||{mode:"self"}).mode==="second_person"&&<input placeholder="Inspector user ID" value={(qc[job.id]||{inspector:""}).inspector} onChange={e=>setQc(v=>({...v,[job.id]:{...(v[job.id]||{result:"pass",mode:"second_person",notes:""}),inspector:e.target.value}}))}/>}<input placeholder="Inspection notes" value={(qc[job.id]||{notes:""}).notes} onChange={e=>setQc(v=>({...v,[job.id]:{...(v[job.id]||{result:"pass",mode:"self",inspector:""}),notes:e.target.value}}))}/><button className="secondary-action" disabled={busy} onClick={()=>qualityCheck(job)}>Record QC</button></div><p className="small-note">Latest QC: {check?check.result+" · "+check.inspection_mode+" · "+new Date(check.checked_at).toLocaleString("en-KE"):"Not inspected yet"}</p><button className="primary-action compact" disabled={busy||check?.result!=="pass"} onClick={()=>void call("owner_complete_production_job",{p_job_id:job.id,p_request_id:rid()},"Production job completed. Order moves to ready when all required jobs pass.")}>Complete job</button></>}
       {job.status==="completed"&&<p className="small-note">Production completed · Latest QC {check?.result||"not available"}</p>}
      </div>}
     </div>;
    })}
    {!lines.length&&<p className="empty-records">No order lines found.</p>}
    {order.status==="ready"&&<div className="handover-panel"><h3>Customer handover</h3><div className="inline-controls"><select value={hand.method} onChange={e=>setHandover(v=>({...v,[order.id]:{...hand,method:e.target.value as "collection"|"courier"}}))}><option value="collection">Customer collection</option><option value="courier">Courier delivery</option></select><input placeholder="Recipient name" value={hand.recipient} onChange={e=>setHandover(v=>({...v,[order.id]:{...hand,recipient:e.target.value}}))}/><input placeholder="Carrier / tracking reference" value={hand.tracking} onChange={e=>setHandover(v=>({...v,[order.id]:{...hand,tracking:e.target.value}}))}/><input placeholder="Payment exception reason (owner approval)" value={hand.exception} onChange={e=>setHandover(v=>({...v,[order.id]:{...hand,exception:e.target.value}}))}/><button className="primary-action compact" disabled={busy} onClick={()=>handoverOrder(order)}>Confirm handover</button></div><p className="small-note">Full payment is required. Only enter a reason when the owner is approving an exception; the backend records that approval.</p></div>}
   </article>;
  })}{!orders.length&&<p className="empty-records">No orders yet. Accepted quotations will appear here automatically.</p>}</div>
 </section>;
}
