import { useEffect, useMemo, useState } from 'react';
import { supabase } from './lib/supabase';

type Row = Record<string, any>;
type Method = { production_method: string; costing_profile_id: string | null; is_preferred: boolean; is_active: boolean; suitability_notes: string };
const METHODS = ['screen_printing','sublimation','dtf','vinyl_cutting','embroidery','other'];
const methodLabel = (v:string) => v.replaceAll('_',' ').replace(/\b\w/g,c=>c.toUpperCase());
const cash = (n:number) => new Intl.NumberFormat('en-KE',{style:'currency',currency:'KES',maximumFractionDigits:2}).format(n);
const blank = () => ({id:'',item_code:'',name:'',description:'',item_type:'product',category:'Apparel',shop_location:'shop_1',selling_method:'job_costed',standard_unit_price:'',price_unit:'piece',minimum_quantity:'',is_active:true,methods:[] as Method[]});

export default function Catalogue(){
 const [items,setItems]=useState<Row[]>([]);
 const [profiles,setProfiles]=useState<Row[]>([]);
 const [form,setForm]=useState<Row>(blank());
 const [loading,setLoading]=useState(false);
 const [error,setError]=useState('');
 const [notice,setNotice]=useState('');
 const [filter,setFilter]=useState('all');
 const [search,setSearch]=useState('');
 const [showForm,setShowForm]=useState(false);
 const patch=(v:Row)=>setForm((current:Row)=>({...current,...v}));
 async function refresh(){
  if(!supabase)return;
  setLoading(true);setError('');
  const [catalogueResult,profileResult]=await Promise.all([
   supabase.from('catalogue_items').select('id,item_code,name,description,item_type,category,shop_location,selling_method,standard_unit_price,price_unit,minimum_quantity,quantity_rules,is_active,catalogue_item_methods(id,production_method,costing_profile_id,is_preferred,is_active,suitability_notes)').order('category').order('name'),
   supabase.from('costing_profiles').select('id,profile_name,version,is_active').eq('is_active',true).order('profile_name')
  ]);
  setLoading(false);
  const failed=[catalogueResult,profileResult].find(x=>x.error);
  if(failed?.error){setError(failed.error.message);return;}
  setItems(catalogueResult.data||[]);setProfiles(profileResult.data||[]);
 }
 useEffect(()=>{void refresh()},[]);
 function startNew(){setForm(blank());setShowForm(true);setError('');setNotice('')}
 function edit(item:Row){setForm({...item,standard_unit_price:item.standard_unit_price==null?'':String(item.standard_unit_price),minimum_quantity:item.minimum_quantity==null?'':String(item.minimum_quantity),methods:(item.catalogue_item_methods||[]).map((m:Row)=>({production_method:m.production_method,costing_profile_id:m.costing_profile_id||null,is_preferred:m.is_preferred,is_active:m.is_active,suitability_notes:m.suitability_notes||''}))});setShowForm(true);setError('');setNotice('')}
 function toggleMethod(method:string,checked:boolean){
  const current:Method[]=form.methods||[];
  if(checked){patch({methods:[...current,{production_method:method,costing_profile_id:null,is_preferred:current.length===0,is_active:true,suitability_notes:''}]});}
  else patch({methods:current.filter(m=>m.production_method!==method).map((m,i)=>({...m,is_preferred:i===0}))});
 }
 async function save(e:React.FormEvent){
  e.preventDefault();
  if(!supabase)return;
  if(!String(form.name||'').trim()||!String(form.category||'').trim())return setError('Enter an item name and category.');
  const price=form.standard_unit_price===''?null:Number(form.standard_unit_price);
  const minimum=form.minimum_quantity===''?null:Number(form.minimum_quantity);
  if(price!==null&&(!Number.isFinite(price)||price<=0))return setError('Approved price must be greater than zero, or leave it blank until approved.');
  if(minimum!==null&&(!Number.isFinite(minimum)||minimum<=0))return setError('Minimum quantity must be greater than zero, or leave it blank.');
  setLoading(true);setError('');setNotice('');
  const {data,error:saveError}=await supabase.rpc('owner_save_catalogue_item_v2',{
   p_item_id:form.id||null,p_item_code:form.item_code||null,p_name:String(form.name).trim(),
   p_description:form.description||'',p_item_type:form.item_type,p_category:String(form.category).trim(),
   p_shop_location:form.shop_location||null,p_selling_method:form.selling_method,
   p_standard_unit_price:price,p_price_unit:form.price_unit||'piece',p_minimum_quantity:minimum,
   p_quantity_rules:{customer_supplied_bulk_pricing_minimum:10,bulk_discount_automatic:false},
   p_is_active:!!form.is_active,p_methods:form.methods||[]
  });
  setLoading(false);
  if(saveError){setError(saveError.message);return;}
  setNotice('Catalogue item saved.');setShowForm(false);await refresh();
 }
 const visible=useMemo(()=>items.filter(item=>(filter==='all'||(filter==='active'?item.is_active:!item.is_active))&&[item.name,item.item_code,item.category,item.item_type].join(' ').toLowerCase().includes(search.toLowerCase())),[items,filter,search]);
 return <><div className="heading"><div><small className="eyebrow">PRODUCTS & SERVICES</small><h1>Catalogue</h1><p>Manage saleable products and printing services used by Quick Sales and quotations.</p></div><button className="primary" onClick={startNew}>＋ Add catalogue item</button></div>
  {error&&<div className="op-error">{error}</div>}{notice&&<div className="notice">{notice}</div>}
  <div className="toolbar"><input placeholder="Search products and services…" value={search} onChange={e=>setSearch(e.target.value)}/><select value={filter} onChange={e=>setFilter(e.target.value)}><option value="all">All items</option><option value="active">Active</option><option value="inactive">Inactive</option></select><button type="button" onClick={()=>void refresh()}>Refresh</button></div>
  {showForm&&<section className="panel op-panel"><h3>{form.id?'Edit catalogue item':'Add catalogue item'}</h3><form className="op-form" onSubmit={save}>
   <div className="op-grid"><label className="op-field">Item name<input value={form.name} onChange={e=>patch({name:e.target.value})} required/></label><label className="op-field">Item code<input value={form.item_code} onChange={e=>patch({item_code:e.target.value})} placeholder="Optional unique code"/></label><label className="op-field">Type<select value={form.item_type} onChange={e=>patch({item_type:e.target.value})}><option value="product">Product</option><option value="service">Service</option></select></label><label className="op-field">Category<input value={form.category} onChange={e=>patch({category:e.target.value})} required placeholder="e.g. Apparel, Stickers, Branding"/></label><label className="op-field">Selling method<select value={form.selling_method} onChange={e=>patch({selling_method:e.target.value})}><option value="job_costed">Job costed</option><option value="fixed_price">Fixed price</option><option value="quantity_tier">Quantity tier (not yet enabled for checkout)</option></select></label><label className="op-field">Selling unit<input value={form.price_unit} onChange={e=>patch({price_unit:e.target.value})} placeholder="piece, metre, print, job"/></label><label className="op-field">Approved selling price (KES)<input type="number" min="0.01" step="0.01" value={form.standard_unit_price} onChange={e=>patch({standard_unit_price:e.target.value})} placeholder="Leave blank until approved"/></label><label className="op-field">Minimum order quantity (optional)<input type="number" min="0.001" step="0.001" value={form.minimum_quantity} onChange={e=>patch({minimum_quantity:e.target.value})} placeholder="No minimum set"/></label><label className="op-field">Shop location<select value={form.shop_location||''} onChange={e=>patch({shop_location:e.target.value})}><option value="shop_1">Shop 1 — Apparel, vinyl & stickers</option><option value="shop_2">Shop 2 — Inks, screens & consumables</option><option value="">Not assigned</option></select></label></div>
   <label className="op-field">Description<textarea rows={2} value={form.description} onChange={e=>patch({description:e.target.value})}/></label>
   <fieldset className="catalogue-methods"><legend>Production methods and costing profiles</legend>{METHODS.map(method=>{const selected:Method|undefined=(form.methods||[]).find((m:Method)=>m.production_method===method);return <div className="op-record" key={method}><label><input type="checkbox" checked={!!selected} onChange={e=>toggleMethod(method,e.target.checked)}/> {methodLabel(method)}</label>{selected&&<div className="op-grid"><label className="op-field">Costing profile<select value={selected.costing_profile_id||''} onChange={e=>patch({methods:form.methods.map((m:Method)=>m.production_method===method?{...m,costing_profile_id:e.target.value||null}:m)})}><option value="">Select active profile</option>{profiles.map(p=><option key={p.id} value={p.id}>{p.profile_name} · v{p.version}</option>)}</select></label><label className="op-field">Preferred method<select value={selected.is_preferred?'yes':'no'} onChange={e=>patch({methods:form.methods.map((m:Method)=>({...m,is_preferred:m.production_method===method?e.target.value==='yes':false}))})}><option value="no">No</option><option value="yes">Yes</option></select></label></div>}</div>})}</fieldset>
   <label className="op-field"><span><input type="checkbox" checked={!!form.is_active} onChange={e=>patch({is_active:e.target.checked})}/> Active catalogue item</span></label>
   <p className="op-empty">A job-costed item can be saved before its costing profile is linked, but Quick Sales and quotations will remain blocked until an active profile is assigned. Customer-supplied items: the blank garment/item cost is excluded; printing, setup, labour and other direct costs remain. Ten or more customer-supplied pieces qualify for bulk-pricing consideration only; no discount is automatic. The 30% gross-margin floor and authorised exception controls remain in force.</p>
   <div className="op-actions"><button type="button" onClick={()=>setShowForm(false)}>Cancel</button><button className="primary" disabled={loading}>{loading?'Saving…':'Save catalogue item'}</button></div>
  </form></section>}
  <section className="panel op-panel"><h3>Products and services · {visible.length}</h3><div className="op-list">{visible.length?visible.map(item=><article className="op-record" key={item.id}><div><b>{item.name}</b><small>{item.item_code||'No code'} · {item.item_type} · {item.category} · {item.price_unit} · {item.selling_method.replaceAll('_',' ')}</small><small>{item.standard_unit_price==null?'Price not approved':cash(Number(item.standard_unit_price))} · {item.is_active?'Active':'Inactive'} · {item.minimum_quantity==null?'No minimum order quantity':'Minimum '+item.minimum_quantity+' '+item.price_unit}</small><small>Methods: {(item.catalogue_item_methods||[]).filter((m:Row)=>m.is_active).map((m:Row)=>methodLabel(m.production_method)+' — '+(profiles.find(p=>p.id===m.costing_profile_id)?.profile_name||'No costing profile linked')).join('; ')||'No production method configured'}</small></div><button type="button" onClick={()=>edit(item)}>Edit</button></article>):<p className="op-empty">No matching catalogue items.</p>}</div></section>
 </>;
}
