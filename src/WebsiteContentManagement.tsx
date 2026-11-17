import { useCallback, useEffect, useState } from "react";
import type { ChangeEvent } from "react";
import { supabase } from "./lib/supabase";

type WebsiteContent = {
  brand: { name: string; legalName: string; tagline: string; logoPath: string };
  contact: { phone: string; whatsapp: string; email: string; address: string };
  hero: { eyebrow: string; title: string; description: string; imagePath?: string };
  social: { facebook: string; instagram: string; tiktok: string; x: string };
  theme: Record<string,string>;
  faq?: Array<{question:string;answer:string}>;
  clients?: string[];
};
const defaults: WebsiteContent = {
  brand:{name:"MJ Tees",legalName:"MJ Printing & Branding",tagline:"Design | Print | Brand",logoPath:"/assets/logo.png"},
  contact:{phone:"",whatsapp:"",email:"mjtees35@gmail.com",address:""},
  hero:{eyebrow:"YOUR IDEA. OUR PRINT. YOUR BRAND.",title:"Make it yours. Make it seen.",description:"Custom apparel, stickers and branded merchandise for teams, businesses, schools and individuals.",imagePath:""},
  social:{facebook:"",instagram:"",tiktok:"",x:""},
  theme:{blue:"#1F8ED6",deepBlue:"#0B5C9E",green:"#3BAA35",orange:"#F28C28",red:"#E5483B",pink:"#E84C9A",yellow:"#FFC414"},
  faq:[],clients:[]
};
type Props={businessId:string};
export default function WebsiteContentManagement({businessId}:Props){
 const [content,setContent]=useState<WebsiteContent>(defaults);
 const [rowId,setRowId]=useState<string|null>(null);
 const [published,setPublished]=useState(false);
 const [loading,setLoading]=useState(true);
 const [saving,setSaving]=useState(false);
 const [message,setMessage]=useState("");
 const [error,setError]=useState("");
 const [faqs,setFaqs]=useState<Array<{question:string;answer:string}>>([]);
 const [clientsText,setClientsText]=useState("");
 const load=useCallback(async()=>{
  if(!supabase)return;
  setLoading(true);setError("");
  const {data,error:loadError}=await supabase.from("website_content").select("id,content,is_published").eq("business_id",businessId).maybeSingle();
  if(loadError){setError(loadError.message);setLoading(false);return;}
  if(data){const merged={...defaults,...(data.content as Partial<WebsiteContent>),brand:{...defaults.brand,...(data.content as WebsiteContent).brand},contact:{...defaults.contact,...(data.content as WebsiteContent).contact},hero:{...defaults.hero,...(data.content as WebsiteContent).hero},social:{...defaults.social,...(data.content as WebsiteContent).social},theme:{...defaults.theme,...(data.content as WebsiteContent).theme}} as WebsiteContent;setContent(merged);setRowId(data.id);setPublished(data.is_published);setFaqs(merged.faq??[]);setClientsText((merged.clients??[]).join("\n"));}
  setLoading(false);
 },[businessId]);
 useEffect(()=>{void load()},[load]);
 const setGroup=(group:"brand"|"contact"|"hero"|"social"|"theme",key:string,value:string)=>setContent(prev=>({...prev,[group]:{...prev[group],[key]:value}}));
 async function uploadImage(event:ChangeEvent<HTMLInputElement>,kind:"logo"|"hero"){
  const file=event.target.files?.[0];if(!file||!supabase)return;
  if(!file.type.startsWith("image/")){setError("Choose an image file.");return;}
  if(file.size>10*1024*1024){setError("Images must be 10 MB or smaller.");return;}
  setSaving(true);setError("");setMessage("");
  const safeName=file.name.toLowerCase().replace(/[^a-z0-9.-]+/g,"-");
  const path=`${businessId}/${kind}-${Date.now()}-${safeName}`;
  const {error:uploadError}=await supabase.storage.from("website-media").upload(path,file,{upsert:false,contentType:file.type});
  if(uploadError){setError(uploadError.message);setSaving(false);return;}
  const {data}=supabase.storage.from("website-media").getPublicUrl(path);
  if(kind==="logo")setGroup("brand","logoPath",data.publicUrl);else setGroup("hero","imagePath",data.publicUrl);
  setMessage(kind==="logo"?"Logo uploaded. Save changes to keep it.":"Hero image uploaded. Save changes to keep it.");
  setSaving(false);event.target.value="";
 }
 async function save(nextPublished=published){
  if(!supabase)return;
  const faq=faqs.filter(item=>item.question.trim()&&item.answer.trim());
  const clients=clientsText.split("\n").map(item=>item.trim()).filter(Boolean);
  setSaving(true);setError("");setMessage("");
  const payload={...content,faq,clients};
  const record={business_id:businessId,content:payload,is_published:nextPublished};
  const result=rowId
   ? await supabase.from("website_content").update(record).eq("id",rowId).select("id").single()
   : await supabase.from("website_content").insert(record).select("id").single();
  if(result.error){setError(result.error.message);setSaving(false);return;}
  setRowId(result.data.id);setPublished(nextPublished);setMessage(nextPublished?"Website content saved and published.":"Website content saved as a draft.");
  setSaving(false);
 }
 if(loading)return <section className="connected-panel"><p>Loading website content…</p></section>;
 return <div className="website-content-admin">
  <section className="connected-panel"><div className="panel-toolbar"><div><h2>Website Content</h2><p>Manage the public MJ Tees website from this owner-only workspace.</p></div><span className={published?"website-publish-state live":"website-publish-state draft"}>{published?"Published":"Draft"}</span></div>
   <div className="website-content-actions"><button className="secondary-action" onClick={()=>void load()} disabled={saving}>↻ Reload</button><button className="secondary-action" onClick={()=>void save(false)} disabled={saving}>{saving?"Saving…":"Save draft"}</button><button className="primary-action" onClick={()=>void save(true)} disabled={saving}>{saving?"Saving…":published?"Save & publish":"Publish website"}</button></div>
   {error&&<div className="notice error" role="alert">{error}</div>}{message&&<div className="notice success" role="status">{message}</div>}
  </section>
  <section className="connected-panel"><h2>Business identity</h2><p className="website-admin-help">These details appear in the website header, footer and browser-facing content.</p><div className="website-admin-grid">
   <label>Website name<input value={content.brand.name} onChange={e=>setGroup("brand","name",e.target.value)}/></label>
   <label>Registered business name<input value={content.brand.legalName} onChange={e=>setGroup("brand","legalName",e.target.value)}/></label>
   <label className="wide-field">Tagline<input value={content.brand.tagline} onChange={e=>setGroup("brand","tagline",e.target.value)}/></label>
   <label>Logo image<input type="file" accept="image/png,image/jpeg,image/webp,image/svg+xml" onChange={e=>void uploadImage(e,"logo")}/><small>Current: {content.brand.logoPath||"No logo set"}</small></label>
   <label>Logo path / URL<input value={content.brand.logoPath} onChange={e=>setGroup("brand","logoPath",e.target.value)}/></label>
  </div></section>
  <section className="connected-panel"><h2>Homepage hero</h2><p className="website-admin-help">Update the main heading and introductory copy customers see first.</p><div className="website-admin-grid">
   <label>Eyebrow text<input value={content.hero.eyebrow} onChange={e=>setGroup("hero","eyebrow",e.target.value)}/></label>
   <label>Main heading<input value={content.hero.title} onChange={e=>setGroup("hero","title",e.target.value)}/></label>
   <label className="wide-field">Description<textarea value={content.hero.description} onChange={e=>setGroup("hero","description",e.target.value)}/></label>
   <label>Hero image<input type="file" accept="image/png,image/jpeg,image/webp" onChange={e=>void uploadImage(e,"hero")}/><small>Current: {content.hero.imagePath||"No hero image set"}</small></label>
   <label>Hero image path / URL<input value={content.hero.imagePath??""} onChange={e=>setGroup("hero","imagePath",e.target.value)}/></label>
  </div></section>
  <section className="connected-panel"><h2>Contact details</h2><div className="website-admin-grid">
   <label>Phone<input value={content.contact.phone} onChange={e=>setGroup("contact","phone",e.target.value)}/></label>
   <label>WhatsApp number<input placeholder="2547XXXXXXXX" value={content.contact.whatsapp} onChange={e=>setGroup("contact","whatsapp",e.target.value)}/></label>
   <label>Email<input type="email" value={content.contact.email} onChange={e=>setGroup("contact","email",e.target.value)}/></label>
   <label>Address / location<input value={content.contact.address} onChange={e=>setGroup("contact","address",e.target.value)}/></label>
  </div></section>
  <section className="connected-panel"><h2>Social media links</h2><div className="website-admin-grid">
   {(["facebook","instagram","tiktok","x"] as const).map(k=><label key={k}>{k==="x"?"X":k[0].toUpperCase()+k.slice(1)} URL<input type="url" placeholder="https://" value={content.social[k]} onChange={e=>setGroup("social",k,e.target.value)}/></label>)}
  </div></section>
  <section className="connected-panel"><h2>Brand colours</h2><p className="website-admin-help">Use HEX colour values. These are the approved MJ Tees website colours.</p><div className="website-colour-grid">{Object.entries(content.theme).map(([key,value])=><label key={key}><span>{key}</span><input type="color" value={/^#[0-9a-f]{6}$/i.test(value)?value:"#1F8ED6"} onChange={e=>setGroup("theme",key,e.target.value)}/><code>{value}</code></label>)}</div></section>
  <section className="connected-panel">
   <div className="panel-toolbar"><div><h2>Frequently asked questions</h2><p className="website-admin-help">Add or remove questions without editing code.</p></div><button type="button" className="secondary-action" onClick={()=>setFaqs(items=>[...items,{question:"",answer:""}])}>+ Add FAQ</button></div>
   <div className="website-faq-editor">{faqs.map((item,index)=><div className="website-faq-row" key={index}>
    <label>Question {index+1}<input value={item.question} onChange={e=>setFaqs(items=>items.map((row,i)=>i===index?{...row,question:e.target.value}:row))}/></label>
    <label>Answer<textarea value={item.answer} onChange={e=>setFaqs(items=>items.map((row,i)=>i===index?{...row,answer:e.target.value}:row))}/></label>
    <button type="button" className="text-action" onClick={()=>setFaqs(items=>items.filter((_,i)=>i!==index))}>Remove question</button>
   </div>)}{!faqs.length&&<p className="website-admin-help">No FAQs added yet.</p>}</div>
  </section>
  <section className="connected-panel"><h2>Client and partner names</h2><p className="website-admin-help">Enter one name per line. Only add organisations you have permission to feature.</p><div className="website-admin-grid"><label className="wide-field">Names<textarea value={clientsText} onChange={e=>setClientsText(e.target.value)} placeholder={"School name\\nSports club\\nBusiness name"}/></label></div></section>
  <section className="connected-panel"><h2>Product and service listings</h2><p className="website-admin-help">Use the existing Catalogue module to add, edit, publish, hide or reorder the products and services shown on the website.</p><p><b>Owner Workspace → Catalogue</b></p></section>
 </div>;
}
