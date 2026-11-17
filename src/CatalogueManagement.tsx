import { useCallback, useEffect, useState } from "react";
import type { FormEvent } from "react";
import { supabase } from "./lib/supabase";

type Category={id:string;name:string};
type Item={id:string;category_id:string|null;name:string;slug:string;item_type:"product"|"service";description:string|null;public_starting_price:number|null;is_published:boolean;display_order:number};
const empty={id:"",category_id:"",name:"",slug:"",item_type:"product" as "product"|"service",description:"",price:"",is_published:true,display_order:"0"};
const slugify=(value:string)=>value.toLowerCase().normalize("NFKD").replace(/[^a-z0-9]+/g,"-").replace(/^-|-$/g,"");

export default function CatalogueManagement({businessId,onChanged}:{businessId:string;onChanged:()=>void}){
 const [items,setItems]=useState<Item[]>([]);const [categories,setCategories]=useState<Category[]>([]);
 const [form,setForm]=useState(empty);const [editing,setEditing]=useState(false);const [loading,setLoading]=useState(false);const [error,setError]=useState("");const [notice,setNotice]=useState("");
 const load=useCallback(async()=>{
  if(!supabase)return;setLoading(true);setError("");
  const [a,b]=await Promise.all([
   supabase.from("catalogue_items").select("id,category_id,name,slug,item_type,description,public_starting_price,is_published,display_order").eq("business_id",businessId).eq("is_active",true).order("display_order").order("name"),
   supabase.from("service_categories").select("id,name").eq("business_id",businessId).eq("is_active",true).order("name")
  ]);
  if(a.error||b.error)setError(a.error?.message||b.error?.message||"Could not load catalogue.");
  else{setItems((a.data??[]) as Item[]);setCategories((b.data??[]) as Category[]);}
  setLoading(false);
 },[businessId]);
 useEffect(()=>{void load();},[load]);
 const save=async(e:FormEvent)=>{
  e.preventDefault();if(!supabase)return;
  const price=form.price.trim()===""?null:Number(form.price);
  if(!form.name.trim()||!slugify(form.slug)|| (price!==null&&(!Number.isSafeInteger(price)||price<0))){setError("Enter a name, valid URL slug and a whole-KES starting price.");return;}
  setLoading(true);setError("");setNotice("");
  const {error:rpcError}=await supabase.rpc("owner_upsert_catalogue_item",{
   p_business_id:businessId,p_catalogue_item_id:form.id||null,p_category_id:form.category_id||null,
   p_name:form.name.trim(),p_slug:slugify(form.slug),p_item_type:form.item_type,
   p_description:form.description.trim()||null,p_public_starting_price:price,p_is_published:form.is_published,
   p_display_order:Number(form.display_order)||0,p_request_id:crypto.randomUUID()
  });
  if(rpcError)setError(rpcError.message);
  else{setNotice(form.id?"Catalogue item updated.":"Catalogue item created.");setForm(empty);setEditing(false);await load();onChanged();}
  setLoading(false);
 };
 const edit=(item:Item)=>{setForm({id:item.id,category_id:item.category_id||"",name:item.name,slug:item.slug,item_type:item.item_type,description:item.description||"",price:item.public_starting_price===null?"":String(item.public_starting_price),is_published:item.is_published,display_order:String(item.display_order)});setEditing(true);setError("");setNotice("");};
 return <section className="connected-panel catalogue-management">
  <div className="panel-toolbar"><div><h2>Products and services</h2><p>Publish selected products and services on the public website. Prices are indicative starting prices.</p></div><button className="primary-action compact" onClick={()=>{setForm(empty);setEditing(v=>!v);}}>Add catalogue item</button></div>
  {error&&<div className="notice error">{error}</div>}{notice&&<div className="notice success">{notice}</div>}
  {editing&&<form className="record-form" onSubmit={save}>
   <label>Name *<input required maxLength={160} value={form.name} onChange={e=>setForm(v=>({...v,name:e.target.value,slug:v.id?v.slug:slugify(e.target.value)}))}/></label>
   <label>URL slug *<input required maxLength={160} pattern="[a-z0-9]+(-[a-z0-9]+)*" value={form.slug} onChange={e=>setForm(v=>({...v,slug:e.target.value}))}/></label>
   <label>Type<select value={form.item_type} onChange={e=>setForm(v=>({...v,item_type:e.target.value as "product"|"service"}))}><option value="product">Product</option><option value="service">Service</option></select></label>
   <label>Category<select value={form.category_id} onChange={e=>setForm(v=>({...v,category_id:e.target.value}))}><option value="">No category</option>{categories.map(c=><option key={c.id} value={c.id}>{c.name}</option>)}</select></label>
   <label>Starting price (KES)<input type="number" min="0" step="1" value={form.price} onChange={e=>setForm(v=>({...v,price:e.target.value}))} placeholder="Leave blank for quote"/></label>
   <label>Display order<input type="number" step="1" value={form.display_order} onChange={e=>setForm(v=>({...v,display_order:e.target.value}))}/></label>
   <label className="wide-field">Description<textarea maxLength={2000} value={form.description} onChange={e=>setForm(v=>({...v,description:e.target.value}))}/></label>
   <label className="wide-field checkbox-field"><input type="checkbox" checked={form.is_published} onChange={e=>setForm(v=>({...v,is_published:e.target.checked}))}/> Publish on public website</label>
   <div className="form-actions"><button className="primary-action compact" disabled={loading}>{loading?"Saving…":"Save catalogue item"}</button><button type="button" className="secondary-action" onClick={()=>{setEditing(false);setForm(empty);}}>Cancel</button></div>
  </form>}
  <div className="record-list">{items.map(item=><article className="record-row" key={item.id}><div><b>{item.name}</b><small>{item.item_type} · {item.slug} · {item.public_starting_price===null?"Quote required":"KES "+Number(item.public_starting_price).toLocaleString("en-KE")}</small></div><div className="catalogue-item-actions"><span className={"status-chip "+(item.is_published?"reviewing":"")}>{item.is_published?"Published":"Hidden"}</span><button className="secondary-action" onClick={()=>edit(item)}>Edit</button></div></article>)}{!items.length&&!loading&&<p className="empty-records">No catalogue entries yet. Add products and services you want customers to see.</p>}</div>
 </section>;
}
