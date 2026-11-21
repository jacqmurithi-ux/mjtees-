import { useCallback, useEffect, useState } from 'react';
import { supabase } from './lib/supabase';

type Row = Record<string, any>;
const field=(label:string,value:string,onChange:(v:string)=>void,props:Record<string,unknown>={})=><label className="op-field">{label}<input value={value} onChange={e=>onChange(e.target.value)} {...props}/></label>;
const select=(label:string,value:string,onChange:(v:string)=>void,options:{value:string;label:string}[]) => <label className="op-field">{label}<select value={value} onChange={e=>onChange(e.target.value)}>{options.map(o=><option key={o.value} value={o.value}>{o.label}</option>)}</select></label>;
function Panel({title,children}:{title:string;children:React.ReactNode}){return <section className="panel op-panel"><h3>{title}</h3>{children}</section>}

export default function ApparelInventory({businessId,onChanged}:{businessId:string;onChanged:()=>Promise<void>|void}){
 const [catalogue,setCatalogue]=useState<Row[]>([]),[variants,setVariants]=useState<Row[]>([]),[jobs,setJobs]=useState<Row[]>([]),[reservations,setReservations]=useState<Row[]>([]);
 const [product,setProduct]=useState(''),[sku,setSku]=useState(''),[size,setSize]=useState(''),[colour,setColour]=useState(''),[style,setStyle]=useState(''),[capacity,setCapacity]=useState('');
 const [location,setLocation]=useState('shop_1'),[opening,setOpening]=useState('0'),[reorder,setReorder]=useState('0'),[cost,setCost]=useState('0');
 const [job,setJob]=useState(''),[variant,setVariant]=useState(''),[quantity,setQuantity]=useState('1'),[issue,setIssue]=useState('1'),[reason,setReason]=useState('Order cancelled');
 const [busy,setBusy]=useState(false),[error,setError]=useState(''),[notice,setNotice]=useState('');
 const refresh=useCallback(async()=>{
  const [c,v,j,r]=await Promise.all([
   supabase.from('catalogue_items').select('id,name,item_type').eq('is_active',true).order('name'),
   supabase.from('catalogue_item_variants').select('id,sku,size,colour,style,capacity,attributes,catalogue_item_id,stock_item_id,stock_items(item_name,quantity_on_hand,reorder_level,average_unit_cost,unit)').eq('business_id',businessId).eq('active',true).order('sku'),
   supabase.from('production_jobs').select('id,job_number,production_status,customer_supplied_items').eq('business_id',businessId).not('production_status','in','(cancelled,delivered)').order('created_at',{ascending:false}),
   supabase.from('apparel_variant_reservations').select('id,variant_id,job_id,quantity,issued_quantity,status,created_at').eq('business_id',businessId).in('status',['reserved','partially_issued']).order('created_at',{ascending:false})
  ]);
  const failure=[c.error,v.error,j.error,r.error].find(Boolean);if(failure)throw failure;
  setCatalogue(c.data||[]);setVariants(v.data||[]);setJobs((j.data||[]).filter((x:Row)=>!x.customer_supplied_items));setReservations(r.data||[]);
  if(!product&&c.data?.[0])setProduct(c.data[0].id);if(!variant&&v.data?.[0])setVariant(v.data[0].id);if(!job&&j.data?.[0])setJob(j.data[0].id);
 },[businessId,product,variant,job]);
 useEffect(()=>{void refresh().catch(e=>setError(e.message||String(e)))},[refresh]);
 async function run(name:string,args:Row,message:string){
  setBusy(true);setError('');setNotice('');
  const {error:e}=await supabase.rpc(name,args as never);setBusy(false);
  if(e){setError(e.message);return}
  setNotice(message);await refresh();await onChanged();
 }
 async function create(e:React.FormEvent){
  e.preventDefault();if(!product)return setError('Select an existing catalogue product.');
  if(!sku.trim())return setError('Enter a unique variant SKU.');
  if(![opening,reorder,cost].every(x=>Number.isFinite(Number(x))&&Number(x)>=0))return setError('Opening quantity, reorder level and cost must be non-negative.');
  await run('owner_create_apparel_variant',{p_catalogue_item_id:product,p_sku:sku.trim(),p_size:size.trim()||null,p_colour:colour.trim()||null,p_style:style.trim()||null,p_capacity:capacity.trim()||null,p_location_code:location,p_opening_quantity:Number(opening),p_reorder_level:Number(reorder),p_unit_cost:Number(cost)},'Variant created. Opening stock was recorded in the stock ledger.');
  setSku('');setSize('');setColour('');setStyle('');setCapacity('');setOpening('0');setCost('0');
 }
 const activeVariants=variants.map(v=>({value:v.id,label:v.sku+' · '+[v.size,v.colour,v.style,v.capacity].filter(Boolean).join(' / ')+' · '+(v.stock_items?.quantity_on_hand??0)+' '+(v.stock_items?.unit||'piece')}));
 return <div className="op-list">
  <Panel title="Apparel & merchandise variants">
   <p className="op-empty">Create variant SKUs against existing catalogue products. Each variant receives its own stock item in Shop 1 or Shop 2; no duplicate catalogue product is created.</p>
   {error&&<div className="op-error">{error}</div>}{notice&&<div className="notice">{notice}</div>}
   <form className="op-form" onSubmit={create}>
    {select('Existing catalogue product',product,setProduct,catalogue.map(x=>({value:x.id,label:x.name+' · '+x.item_type})))}
    <div className="op-grid">{field('Variant SKU',sku,setSku,{required:true,placeholder:'TEE-BLK-M'})}{field('Size',size,setSize,{placeholder:'S, M, L, XL'})}{field('Colour',colour,setColour,{placeholder:'Black, White, Navy'})}{field('Style',style,setStyle,{placeholder:'Regular, fitted, reflective'})}{field('Capacity / type',capacity,setCapacity,{placeholder:'350 ml, ceramic'})}</div>
    <div className="op-grid">{select('Stock location',location,setLocation,[{value:'shop_1',label:'Shop 1 — Apparel, vinyl & stickers'},{value:'shop_2',label:'Shop 2 — Inks, screens & consumables'}])}{field('Verified opening quantity',opening,setOpening,{type:'number',min:'0',step:'1'})}{field('Reorder level',reorder,setReorder,{type:'number',min:'0',step:'1'})}{field('Unit cost (KES)',cost,setCost,{type:'number',min:'0',step:'0.01'})}</div>
    <small className="op-empty">Only enter an opening quantity after physically counting that exact variant. New stock receipts remain on the existing Purchasing page.</small>
    <button className="primary" disabled={busy||!product||sku.trim().length<2}>Create variant</button>
   </form>
   <div className="op-list">{variants.length?variants.map(v=><article className="op-record" key={v.id}><div><b>{v.sku} · {catalogue.find(c=>c.id===v.catalogue_item_id)?.name||'Catalogue item'}</b><small>{[v.size,v.colour,v.style,v.capacity].filter(Boolean).join(' · ')||'No attributes'} · {v.stock_items?.item_name}</small><small>Cost {Number(v.stock_items?.average_unit_cost||0).toFixed(2)} KES · Reorder at {v.stock_items?.reorder_level||0}</small></div><strong>{v.stock_items?.quantity_on_hand??0} {v.stock_items?.unit||'piece'}</strong></article>):<p className="op-empty">No apparel variants yet.</p>}</div>
  </Panel>
  <Panel title="Reserve and issue branded-order stock">
   <p className="op-empty">Reserve exact variants against an open production job. Reservation reduces available-to-promise stock, not physical stock. Issue only when items are physically handed to production.</p>
   <form className="op-form" onSubmit={e=>{e.preventDefault();void run('owner_reserve_apparel_variant',{p_job_id:job,p_variant_id:variant,p_quantity:Number(quantity)},'Variant stock reserved for the production job.')}}>
    {select('Production job',job,setJob,jobs.map(j=>({value:j.id,label:j.job_number+' · '+(j.production_status||'open')})))}
    {select('Variant',variant,setVariant,activeVariants)}
    {field('Quantity to reserve',quantity,setQuantity,{type:'number',min:'1',step:'1'})}
    <button className="primary" disabled={busy||!job||!variant||Number(quantity)<=0}>Reserve variant</button>
   </form>
   <div className="op-list">{reservations.map(r=>{const v=variants.find(x=>x.id===r.variant_id);const j=jobs.find(x=>x.id===r.job_id);const remaining=Number(r.quantity)-Number(r.issued_quantity);return <article className="op-record" key={r.id}><div><b>{v?.sku||'Variant'} · {j?.job_number||'Production job'}</b><small>Reserved {r.quantity} · Issued {r.issued_quantity} · Remaining {remaining}</small><small>Status: {r.status}</small></div><div className="op-actions">{field('Issue now',issue,setIssue,{type:'number',min:'0.001',step:'1'})}<button type="button" disabled={busy||remaining<=0||Number(issue)<=0} onClick={()=>void run('owner_issue_apparel_variant_reservation',{p_reservation_id:r.id,p_quantity:Number(issue)},'Variant quantity issued to production and deducted from stock.')}>Issue</button><button type="button" disabled={busy} onClick={()=>void run('owner_release_apparel_variant_reservation',{p_reservation_id:r.id,p_reason:reason},'Unissued reservation released. Previously issued quantity remains consumed.')}>Release unissued</button></div></article>})}</div>
  </Panel>
 </div>;
}
