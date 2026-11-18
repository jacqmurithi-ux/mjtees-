import { useCallback, useEffect, useState } from "react";
import { supabase } from "./lib/supabase";

type Order={id:string;order_number:string;customer_id:string;status:string;total_amount:number;received_at:string;required_by:string|null;promised_turnaround_hours:number|null};
type Item={id:string;order_id:string;description:string;quantity:number;unit:string;sale_mode:string;customer_supplies_item:boolean;stock_item_id:string|null;production_method_id:string|null;production_specification:unknown};
type Method={id:string;code:string;name:string};
type Job={id:string;order_item_id:string;status:string;planned_quantity:number;due_at:string|null;notes:string|null};
type Check={id:string;job_id:string;result:string;inspection_mode:string;checked_at:string;notes:string|null};
type Stock={id:string;name:string;base_unit:string};
type Location={id:string;name:string};
type Rework={id:string;job_id:string;quality_check_id:string;reason:string;opened_at:string;closed_at:string|null;notes:string|null};
type CostEntry={id:string;job_id:string;cost_type:string;description:string;quantity:number;unit:string;unit_rate:number;amount:number;occurred_at:string};
type OutputEntry={id:string;job_id:string;quantity_printed:number;quantity_accepted:number;quantity_rejected:number;quantity_reworked:number;worker_type:string;worker_name:string|null;labour_cost:number;occurred_at:string;notes:string|null};
type OutputForm={printed:string;rejected:string;reworked:string;workerType:"owner"|"staff"|"temporary";workerName:string;labourCost:string;occurredAt:string;notes:string};
type OutputSummary={order_value:number;orders_received:number;daily_printed:number;daily_accepted:number;daily_rejected:number;daily_reworked:number;all_time_printed:number;all_time_accepted:number;all_time_rejected:number};
const localDateTime=()=>{const d=new Date();return new Date(d.getTime()-d.getTimezoneOffset()*60000).toISOString().slice(0,16)};
const businessDate=()=>new Date().toLocaleDateString("en-CA",{timeZone:"Africa/Nairobi"});
const rid=()=>crypto.randomUUID();
const money=(n:number)=>new Intl.NumberFormat("en-KE",{style:"currency",currency:"KES",maximumFractionDigits:0}).format(n);

export default function OrderProductionWorkflow({businessId,customers,onChanged}:{businessId:string;customers:{id:string;display_name:string}[];onChanged:()=>void}){
 const [orders,setOrders]=useState<Order[]>([]);const [items,setItems]=useState<Item[]>([]);const [methods,setMethods]=useState<Method[]>([]);const [outputEntries,setOutputEntries]=useState<OutputEntry[]>([]);const [outputForms,setOutputForms]=useState<Record<string,OutputForm>>({});const [reportDate,setReportDate]=useState(businessDate);const [outputSummary,setOutputSummary]=useState<OutputSummary>({order_value:0,orders_received:0,daily_printed:0,daily_accepted:0,daily_rejected:0,daily_reworked:0,all_time_printed:0,all_time_accepted:0,all_time_rejected:0});
 const [jobs,setJobs]=useState<Job[]>([]);const [checks,setChecks]=useState<Check[]>([]);const [reworks,setReworks]=useState<Rework[]>([]);const [costs,setCosts]=useState<CostEntry[]>([]);const [stock,setStock]=useState<Stock[]>([]);const [locations,setLocations]=useState<Location[]>([]);const [currentUserId,setCurrentUserId]=useState("");
 const [jobCost,setJobCost]=useState<Record<string,{type:string;description:string;quantity:string;unit:string;rate:string}>>({});
 const [busy,setBusy]=useState(false);const [error,setError]=useState("");const [notice,setNotice]=useState("");
 const [requiredBy,setRequiredBy]=useState<Record<string,string>>({});const [turnaround,setTurnaround]=useState<Record<string,string>>({});
 const [methodByItem,setMethodByItem]=useState<Record<string,string>>({});const [jobDue,setJobDue]=useState<Record<string,string>>({});
 const [material,setMaterial]=useState<Record<string,{stock:string;location:string;quantity:string;reason:string}>>({});
 const [qc,setQc]=useState<Record<string,{result:"pass"|"fail";mode:"self"|"second_person";inspector:string;notes:string}>>({});
 const [handover,setHandover]=useState<Record<string,{method:"collection"|"courier";recipient:string;carrier:string;tracking:string;charge:string;exception:string}>>({});
 const load=useCallback(async()=>{
  const client=supabase;if(!client)return;
  const [o,i,m,j,q,rw,ce,s,l,out,summary]=await Promise.all([
   client.from("orders").select("id,order_number,customer_id,status,total_amount,received_at,required_by,promised_turnaround_hours").eq("business_id",businessId).order("received_at",{ascending:false}).limit(200),
   client.from("order_items").select("id,order_id,description,quantity,unit,sale_mode,customer_supplies_item,stock_item_id,production_method_id,production_specification").eq("business_id",businessId).limit(500),
   client.from("production_methods").select("id,code,name").eq("is_active",true).order("name"),
   client.from("production_jobs").select("id,order_item_id,status,planned_quantity,due_at,notes").eq("business_id",businessId).order("created_at",{ascending:false}).limit(300),
   client.from("quality_checks").select("id,job_id,result,inspection_mode,checked_at,notes").eq("business_id",businessId).order("checked_at",{ascending:false}).limit(500),
   client.from("rework_events").select("id,job_id,quality_check_id,reason,opened_at,closed_at,notes").eq("business_id",businessId).order("opened_at",{ascending:false}).limit(300),
   client.from("production_cost_entries").select("id,job_id,cost_type,description,quantity,unit,unit_rate,amount,occurred_at").eq("business_id",businessId).order("occurred_at",{ascending:false}).limit(500),
   client.from("stock_items").select("id,name,base_unit").eq("business_id",businessId).eq("is_active",true).order("name").limit(500),
   client.from("inventory_locations").select("id,name").eq("business_id",businessId).eq("is_active",true).order("name"),
   client.rpc("owner_list_production_output",{p_business_id:businessId}),
   client.rpc("owner_get_bulk_printing_daily_summary",{p_business_id:businessId,p_business_date:reportDate})
  ]);
  const failure=o.error||i.error||m.error||j.error||q.error||rw.error||ce.error||s.error||l.error||out.error||summary.error;if(failure)throw failure;
  setOrders((o.data??[]) as Order[]);setItems((i.data??[]) as Item[]);setMethods((m.data??[]) as Method[]);setJobs((j.data??[]) as Job[]);setChecks((q.data??[]) as Check[]);setReworks((rw.data??[]) as Rework[]);setCosts((ce.data??[]) as CostEntry[]);setStock((s.data??[]) as Stock[]);setLocations((l.data??[]) as Location[]);setOutputEntries((out.data??[]) as OutputEntry[]);setOutputSummary((summary.data??{}) as OutputSummary);const {data:userData}=await client.auth.getUser();setCurrentUserId(userData.user?.id||"");
 },[businessId,reportDate]);
 useEffect(()=>{void load().catch(e=>setError(e.message));},[load]);
 const call=async(name:string,args:Record<string,unknown>,success:string)=>{
  if(!supabase)return;setBusy(true);setError("");setNotice("");
  const {error:rpcError}=await supabase.rpc(name,args);
  if(rpcError)setError(rpcError.message);else{setNotice(success);await load();onChanged();}
  setBusy(false);
 };
 const customer=(id:string)=>customers.find(c=>c.id===id)?.display_name??"Customer";
 const orderItems=(orderId:string)=>items.filter(i=>i.order_id===orderId);
 const jobFor=(itemId:string)=>jobs.find(j=>j.order_item_id===itemId&&j.status!=="cancelled");
 const latestCheck=(jobId:string)=>checks.filter(q=>q.job_id===jobId).sort((a,b)=>new Date(b.checked_at).getTime()-new Date(a.checked_at).getTime())[0];
 const latestRework=(jobId:string)=>reworks.filter(r=>r.job_id===jobId).sort((a,b)=>new Date(b.opened_at).getTime()-new Date(a.opened_at).getTime())[0];
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
  const inspector=v.mode==="self"?currentUserId:v.inspector.trim()||null;
  if(!inspector){setError("Could not identify the inspector. Confirm the signed-in owner or enter a second inspector user ID.");return;}
  void call("owner_record_quality_check",{p_job_id:job.id,p_result:v.result,p_inspection_mode:v.mode,p_inspector_user_id:inspector,p_notes:v.notes.trim()||null,p_request_id:rid()}, "Quality check recorded.");
 };
 const addCost=(job:Job)=>{const v=jobCost[job.id]||{type:"labour",description:"",quantity:"1",unit:"hour",rate:""};if(!v.description.trim()||Number(v.quantity)<=0||!v.unit.trim()||!Number.isSafeInteger(Number(v.rate))||Number(v.rate)<0){setError("Enter a valid cost description, quantity, unit and whole-KES unit rate.");return;}void call("owner_add_production_cost",{p_job_id:job.id,p_cost_type:v.type,p_description:v.description.trim(),p_quantity:Number(v.quantity),p_unit:v.unit.trim(),p_unit_rate:Number(v.rate),p_request_id:rid()},"Production cost recorded.");};
 const openRework=(job:Job)=>{const failed=latestCheck(job.id);if(!failed||failed.result!=="fail"){setError("A failed quality check is required to open rework.");return;}const reason=window.prompt("What corrective work is required?");if(!reason?.trim())return;void call("owner_open_rework_event",{p_job_id:job.id,p_quality_check_id:failed.id,p_reason:reason.trim(),p_request_id:rid()},"Rework opened and linked to the failed inspection.");};
 const closeRework=(event:Rework)=>{const notes=window.prompt("Describe the corrective work completed");if(!notes?.trim())return;void call("owner_close_rework_event",{p_rework_event_id:event.id,p_notes:notes.trim(),p_request_id:rid()},"Rework closed. Record a fresh quality check before completing the job.");};
 const recordProductionOutput=async(job:Job)=>{
  const v=outputForms[job.id]||{printed:"",rejected:"0",reworked:"0",workerType:"owner" as const,workerName:"",labourCost:"0",occurredAt:localDateTime(),notes:""};
  const printed=Number(v.printed),rejected=Number(v.rejected),reworked=Number(v.reworked),labourCost=Number(v.labourCost);
  if(!Number.isFinite(printed)||printed<=0||!Number.isFinite(rejected)||rejected<0||rejected>printed||!Number.isFinite(reworked)||reworked<0||reworked>printed||!Number.isSafeInteger(labourCost)||labourCost<0||(v.workerType!=="owner"&&!v.workerName.trim())||!v.occurredAt){
   setError("Enter valid printed, rejected and reworked quantities, worker details and actual labour cost.");return;
  }
  if(!supabase)return;setBusy(true);setError("");setNotice("");
  const {error:rpcError}=await supabase.rpc("owner_record_production_output",{
   p_job_id:job.id,p_quantity_printed:printed,p_quantity_rejected:rejected,p_quantity_reworked:reworked,
   p_worker_type:v.workerType,p_worker_name:v.workerType==="owner"?null:v.workerName.trim(),
   p_labour_cost:labourCost,p_occurred_at:new Date(v.occurredAt).toISOString(),
   p_notes:v.notes.trim()||null,p_request_id:rid()
  });
  if(rpcError)setError(rpcError.message);else{setNotice("Actual production output saved. Daily printed units and accepted quantities have been refreshed.");setOutputForms(x=>({...x,[job.id]:{...v,printed:"",rejected:"0",reworked:"0",labourCost:"0",notes:""}}));await load();onChanged();}
  setBusy(false);
 };
 const handoverOrder=async(order:Order)=>{
  const v=handover[order.id]||{method:"collection",recipient:"",carrier:"",tracking:"",charge:"0",exception:""};
  if(!v.recipient.trim()){setError("Enter the person receiving the order.");return;}
  if(v.method==="courier"&&!v.carrier.trim()){setError("Enter the parcel carrier.");return;}
  if(!Number.isSafeInteger(Number(v.charge))||Number(v.charge)<0){setError("Enter the actual carrier charge in whole KES.");return;}
  if(!supabase)return;setBusy(true);setError("");setNotice("");
  const {error:deliveryError}=await supabase.rpc("owner_record_delivery",{p_order_id:order.id,p_method:v.method,p_carrier:v.carrier.trim()||null,p_tracking_reference:v.tracking.trim()||null,p_customer_paid_charge:Number(v.charge),p_recipient_name:v.recipient.trim(),p_request_id:rid()});
  if(deliveryError){setError(deliveryError.message);setBusy(false);return;}
  if(v.method==="courier"){
   setNotice("Courier dispatched. The parcel remains outstanding until receipt is confirmed in Deliveries.");
   await load();onChanged();setBusy(false);return;
  }
  const {error:handoverError}=await supabase.rpc("owner_handover_order",{p_order_id:order.id,p_method:v.method,p_recipient_name:v.recipient.trim(),p_tracking_reference:v.tracking.trim()||null,p_payment_exception_reason:v.exception.trim()||null,p_request_id:rid()});
  if(handoverError)setError(handoverError.message);else setNotice("Customer collection confirmed. Any payment exception was approved and audited.");
  await load();onChanged();setBusy(false);
 };
 return <section className="connected-panel order-production">
  <div className="panel-toolbar"><div><h2>Orders and production</h2><p>Track accepted orders, promised turnaround, production, inspection and customer handover.</p></div><button className="secondary-action" onClick={()=>void load()}>Refresh</button></div>
  {error&&<div className="notice error">{error}</div>}{notice&&<div className="notice success">{notice}</div>}
  <section className="connected-panel production-daily-summary">
   <div className="panel-toolbar"><div><h3>Daily sales and printed output</h3><p>Sales follow order received dates; printed units follow actual production entries.</p></div><label>Business date<input type="date" value={reportDate} onChange={e=>setReportDate(e.target.value)}/></label></div>
   <div className="connected-metrics">
    <div className="overview-card orange-card"><span className="metric-label">Orders received</span><strong>{Number(outputSummary.orders_received||0)}</strong><small>On selected date</small></div>
    <div className="overview-card green-card"><span className="metric-label">Daily sales value</span><strong>{money(Number(outputSummary.order_value||0))}</strong><small>Order value, not cash collected</small></div>
    <div className="overview-card blue-card"><span className="metric-label">Pieces printed today</span><strong>{Number(outputSummary.daily_printed||0)}</strong><small>Actual print attempts</small></div>
    <div className="overview-card neutral-card"><span className="metric-label">Accepted pieces today</span><strong>{Number(outputSummary.daily_accepted||0)}</strong><small>After rejected quantity</small></div>
   </div>
   <p className="small-note">All-time printed units: <b>{Number(outputSummary.all_time_printed||0)}</b> · All-time accepted units: <b>{Number(outputSummary.all_time_accepted||0)}</b> · Rejected: <b>{Number(outputSummary.all_time_rejected||0)}</b>. Posted payments remain in Payments and are not inferred from order sales.</p>
  </section>
  <div className="record-list">{orders.map(order=>{
   const lines=orderItems(order.id);
   const hand=handover[order.id]||{method:"collection" as const,recipient:"",carrier:"",tracking:"",charge:"0",exception:""};
   return <article className="enquiry-card" key={order.id}>
    <div className="enquiry-top"><div><b>{order.order_number} · {customer(order.customer_id)}</b><small>{new Date(order.received_at).toLocaleDateString("en-KE")} · {money(order.total_amount)}</small></div><span className={"status-chip "+order.status}>{order.status.replaceAll("_"," ")}</span></div>
    <div className="schedule-editor"><label>Required by<input type="date" value={requiredBy[order.id]??order.required_by??""} onChange={e=>setRequiredBy(v=>({...v,[order.id]:e.target.value}))}/></label><label>Promised turnaround (hours)<input type="number" min="1" max="8760" value={turnaround[order.id]??(order.promised_turnaround_hours?.toString()||"")} onChange={e=>setTurnaround(v=>({...v,[order.id]:e.target.value}))}/></label><button className="secondary-action" disabled={busy} onClick={()=>updateSchedule(order)}>Save schedule</button></div>
    {["confirmed","in_production"].includes(order.status)&&lines.some(i=>i.stock_item_id&&!i.customer_supplies_item&&["blank","value_added"].includes(i.sale_mode))&&<div className="handover-panel"><p>Reserve the shop-supplied blank garments or materials before production and handover.</p><button className="secondary-action" disabled={busy} onClick={()=>void call("owner_reserve_order_stock",{p_order_id:order.id,p_request_id:rid()},"Available stock reserved for this order.")}>Reserve order stock</button></div>}
    <h3>Order lines</h3>{lines.map(item=>{const job=jobFor(item.id);const check=job?latestCheck(job.id):undefined;const selectedMethod=methodByItem[item.id]||methods.find(m=>m.id===item.production_method_id)?.code||"";const specification=item.production_specification&&typeof item.production_specification==="object"?item.production_specification as Record<string,unknown>:{};const materialValue=material[job?.id||""]||{stock:typeof specification.vinyl_stock_item_id==="string"?specification.vinyl_stock_item_id:(item.stock_item_id||""),location:"",quantity:typeof specification.linear_metres==="number"?String(specification.linear_metres):"",reason:"Vinyl sticker production material issue"};
     return <div className="production-line" key={item.id}><b>{item.description}</b><small>{item.quantity} {item.unit} · {item.sale_mode.replaceAll("_"," ")} · {item.customer_supplies_item?"Customer-supplied item":"Shop-supplied item"}</small>{(typeof specification.contract_school_name==="string"||typeof specification.garment_type==="string"||typeof specification.print_position==="string")&&<small>Contract job: {[specification.contract_school_name,specification.garment_type,specification.print_position].filter(Boolean).join(" · ")}</small>}
      {!job&&item.sale_mode==="value_added"&&<div className="inline-controls"><select value={selectedMethod} onChange={e=>setMethodByItem(v=>({...v,[item.id]:e.target.value}))}><option value="">Production method</option>{methods.map(m=><option key={m.id} value={m.code}>{m.name}</option>)}</select><input type="datetime-local" aria-label="Production due date" value={jobDue[item.id]||""} onChange={e=>setJobDue(v=>({...v,[item.id]:e.target.value}))}/><button className="primary-action compact" disabled={busy} onClick={()=>startJob(item)}>Start production</button></div>}
      {job&&<div className="job-card"><div className="enquiry-top"><b>Production job · {job.status.replaceAll("_"," ")}</b><small>{job.due_at?new Date(job.due_at).toLocaleString("en-KE"):"No job due date"}</small></div>
       <div className="output-entry-panel">
        <div className="panel-toolbar"><div><b>Record actual printing</b><small>Planned {job.planned_quantity} · Accepted so far {outputEntries.filter(e=>e.job_id===job.id).reduce((n,e)=>n+Number(e.quantity_accepted),0)}</small></div></div>
        {(()=>{const v=outputForms[job.id]||{printed:"",rejected:"0",reworked:"0",workerType:"owner" as const,workerName:"",labourCost:"0",occurredAt:localDateTime(),notes:""};return <div className="inline-controls">
         <label>Pieces printed<input type="number" min="0.001" step="0.001" value={v.printed} onChange={e=>setOutputForms(x=>({...x,[job.id]:{...v,printed:e.target.value}}))}/></label>
         <label>Rejected pieces<input type="number" min="0" step="0.001" value={v.rejected} onChange={e=>setOutputForms(x=>({...x,[job.id]:{...v,rejected:e.target.value}}))}/></label>
         <label>Reworked pieces<input type="number" min="0" step="0.001" value={v.reworked} onChange={e=>setOutputForms(x=>({...x,[job.id]:{...v,reworked:e.target.value}}))}/></label>
         <label>Worker<select value={v.workerType} onChange={e=>setOutputForms(x=>({...x,[job.id]:{...v,workerType:e.target.value as OutputForm["workerType"]}}))}><option value="owner">Owner</option><option value="temporary">Temporary worker</option><option value="staff">Staff</option></select></label>
         {v.workerType!=="owner"&&<label>Worker name<input maxLength={180} value={v.workerName} onChange={e=>setOutputForms(x=>({...x,[job.id]:{...v,workerName:e.target.value}}))}/></label>}
         <label>Actual labour cost (KES)<input type="number" min="0" step="1" value={v.labourCost} onChange={e=>setOutputForms(x=>({...x,[job.id]:{...v,labourCost:e.target.value}}))}/></label>
         <label>Production date and time<input type="datetime-local" value={v.occurredAt} onChange={e=>setOutputForms(x=>({...x,[job.id]:{...v,occurredAt:e.target.value}}))}/></label>
         <label>Notes<input maxLength={2000} value={v.notes} onChange={e=>setOutputForms(x=>({...x,[job.id]:{...v,notes:e.target.value}}))} placeholder="Optional batch / shift note"/></label>
         <button className="primary-action compact" disabled={busy||["completed","cancelled"].includes(job.status)} onClick={()=>void recordProductionOutput(job)}>Save production entry</button>
        </div>})()}
        <div className="small-note">Labour entered here is added to production costs. Do not enter the same worker cost again under Add cost. No customer payment or blank-garment stock movement is created.</div>
        <div className="record-list">{outputEntries.filter(e=>e.job_id===job.id).slice(0,8).map(e=><div className="record-row" key={e.id}><div><b>{new Date(e.occurred_at).toLocaleString("en-KE")} · {e.quantity_printed} printed</b><small>{e.quantity_accepted} accepted · {e.quantity_rejected} rejected · {e.quantity_reworked} reworked · {e.worker_type==="owner"?"Owner":e.worker_name||e.worker_type}</small></div><b>{money(e.labour_cost)}</b></div>)}</div>
       </div>
       {["planned","in_progress","rework"].includes(job.status)&&<div className="inline-controls"><select value={materialValue.stock} onChange={e=>setMaterial(v=>({...v,[job.id]:{...materialValue,stock:e.target.value}}))}><option value="">Material</option>{stock.map(s=><option key={s.id} value={s.id}>{s.name} ({s.base_unit})</option>)}</select><select value={materialValue.location} onChange={e=>setMaterial(v=>({...v,[job.id]:{...materialValue,location:e.target.value}}))}><option value="">Stock location</option>{locations.map(l=><option key={l.id} value={l.id}>{l.name}</option>)}</select><input type="number" min="0.001" step="any" placeholder="Qty" value={materialValue.quantity} onChange={e=>setMaterial(v=>({...v,[job.id]:{...materialValue,quantity:e.target.value}}))}/><input placeholder="Issue reason" value={materialValue.reason} onChange={e=>setMaterial(v=>({...v,[job.id]:{...materialValue,reason:e.target.value}}))}/><button className="secondary-action" disabled={busy} onClick={()=>issueMaterial(job)}>Issue material</button></div>}
       {!["completed","cancelled"].includes(job.status)&&<><div className="inline-controls"><select value={(qc[job.id]||{result:"pass"}).result} onChange={e=>setQc(v=>({...v,[job.id]:{...(v[job.id]||{mode:"self",inspector:"",notes:""}),result:e.target.value as "pass"|"fail"}}))}><option value="pass">Pass inspection</option><option value="fail">Fail inspection</option></select><select value={(qc[job.id]||{mode:"self"}).mode} onChange={e=>setQc(v=>({...v,[job.id]:{...(v[job.id]||{result:"pass",inspector:"",notes:""}),mode:e.target.value as "self"|"second_person"}}))}><option value="self">Self-inspection</option><option value="second_person">Second-person inspection</option></select>{(qc[job.id]||{mode:"self"}).mode==="second_person"&&<input placeholder="Inspector user ID" value={(qc[job.id]||{inspector:""}).inspector} onChange={e=>setQc(v=>({...v,[job.id]:{...(v[job.id]||{result:"pass",mode:"second_person",notes:""}),inspector:e.target.value}}))}/>}<input placeholder="Inspection notes" value={(qc[job.id]||{notes:""}).notes} onChange={e=>setQc(v=>({...v,[job.id]:{...(v[job.id]||{result:"pass",mode:"self",inspector:""}),notes:e.target.value}}))}/><button className="secondary-action" disabled={busy} onClick={()=>qualityCheck(job)}>Record QC</button></div><p className="small-note">Latest QC: {check?check.result+" · "+check.inspection_mode+" · "+new Date(check.checked_at).toLocaleString("en-KE"):"Not inspected yet"}</p>{check?.result==="fail"&&<>{latestRework(job.id)&&!latestRework(job.id)?.closed_at?<div className="small-note">Rework open: {latestRework(job.id)?.reason} <button className="secondary-action" disabled={busy} onClick={()=>closeRework(latestRework(job.id)!)}>Close rework</button></div>:<button className="secondary-action" disabled={busy} onClick={()=>openRework(job)}>Open rework record</button>}</>}
       {["planned","in_progress","rework"].includes(job.status)&&<><div className="inline-controls"><select value={(jobCost[job.id]||{type:"labour"}).type} onChange={e=>setJobCost(v=>({...v,[job.id]:{...(v[job.id]||{description:"",quantity:"1",unit:"hour",rate:""}),type:e.target.value}}))}><option value="labour">Labour</option><option value="machine">Machine</option><option value="setup">Setup</option><option value="outsourced">Outsourced</option><option value="other">Other</option></select><input placeholder="Cost description" value={(jobCost[job.id]||{description:""}).description} onChange={e=>setJobCost(v=>({...v,[job.id]:{...(v[job.id]||{type:"labour",quantity:"1",unit:"hour",rate:""}),description:e.target.value}}))}/><input type="number" min="0.001" step="any" placeholder="Qty" value={(jobCost[job.id]||{quantity:"1"}).quantity} onChange={e=>setJobCost(v=>({...v,[job.id]:{...(v[job.id]||{type:"labour",description:"",unit:"hour",rate:""}),quantity:e.target.value}}))}/><input placeholder="Unit" value={(jobCost[job.id]||{unit:"hour"}).unit} onChange={e=>setJobCost(v=>({...v,[job.id]:{...(v[job.id]||{type:"labour",description:"",quantity:"1",rate:""}),unit:e.target.value}}))}/><input type="number" min="0" step="1" placeholder="KES per unit" value={(jobCost[job.id]||{rate:""}).rate} onChange={e=>setJobCost(v=>({...v,[job.id]:{...(v[job.id]||{type:"labour",description:"",quantity:"1",unit:"hour"}),rate:e.target.value}}))}/><button className="secondary-action" disabled={busy} onClick={()=>addCost(job)}>Add cost</button></div>
       <p className="small-note">Recorded production costs: {money(costs.filter(x=>x.job_id===job.id).reduce((sum,x)=>sum+x.amount,0))}</p></>}<button className="primary-action compact" disabled={busy||check?.result!=="pass"} onClick={()=>void call("owner_complete_production_job",{p_job_id:job.id,p_request_id:rid()},"Production job completed. Order moves to ready when all required jobs pass.")}>Complete job</button></>}
       {job.status==="completed"&&<p className="small-note">Production completed · Latest QC {check?.result||"not available"}</p>}
      </div>}
     </div>;
    })}
    {!lines.length&&<p className="empty-records">No order lines found.</p>}
    {order.status==="confirmed"&&!lines.some(i=>i.sale_mode==="value_added"&&i.production_method_id)&&<div className="handover-panel"><p>No production job is required for these order lines.</p><button className="primary-action compact" disabled={busy} onClick={()=>void call("owner_mark_order_ready",{p_order_id:order.id,p_reason:"Owner confirmed that no production work is required.",p_request_id:rid()},"Order marked ready for customer handover.")}>Mark ready for handover</button></div>}
    {order.status==="ready"&&<div className="handover-panel"><h3>Customer handover</h3><div className="inline-controls"><select value={hand.method} onChange={e=>setHandover(v=>({...v,[order.id]:{...hand,method:e.target.value as "collection"|"courier"}}))}><option value="collection">Customer collection</option><option value="courier">Courier delivery</option></select><input placeholder="Recipient name" value={hand.recipient} onChange={e=>setHandover(v=>({...v,[order.id]:{...hand,recipient:e.target.value}}))}/>{hand.method==="courier"&&<input placeholder="Parcel carrier" value={hand.carrier} onChange={e=>setHandover(v=>({...v,[order.id]:{...hand,carrier:e.target.value}}))}/>}<input placeholder="Tracking reference" value={hand.tracking} onChange={e=>setHandover(v=>({...v,[order.id]:{...hand,tracking:e.target.value}}))}/><input type="number" min="0" step="1" placeholder="Actual carrier charge (KES)" value={hand.charge} onChange={e=>setHandover(v=>({...v,[order.id]:{...hand,charge:e.target.value}}))}/><input placeholder="Payment exception reason (owner approval)" value={hand.exception} onChange={e=>setHandover(v=>({...v,[order.id]:{...hand,exception:e.target.value}}))}/><button className="primary-action compact" disabled={busy} onClick={()=>handoverOrder(order)}>Confirm handover</button></div><p className="small-note">Full payment is required. Enter the actual courier charge paid by the customer (collection is KES 0). Only enter a reason when the owner is approving a payment exception.</p></div>}
   </article>;
  })}{!orders.length&&<p className="empty-records">No orders yet. Accepted quotations will appear here automatically.</p>}</div>
 </section>;
}
