import { useEffect, useState } from "react";
import { supabase } from "./lib/supabase";

type CatalogueItem = {
  id:string; name:string; slug:string; item_type:"product"|"service";
  description:string|null; public_starting_price:number|null; category_name:string|null;
  display_order:number;
};

const businessSlug = import.meta.env.VITE_BUSINESS_SLUG as string|undefined;
const kes = (amount:number) => new Intl.NumberFormat("en-KE",{style:"currency",currency:"KES",maximumFractionDigits:0}).format(amount);

export default function PublicCatalogue(){
  const [items,setItems]=useState<CatalogueItem[]>([]);
  const [loading,setLoading]=useState(true);
  const [failed,setFailed]=useState(false);
  useEffect(()=>{
    let active=true;
    async function load(){
      if(!supabase||!businessSlug){setLoading(false);return;}
      const {data,error}=await supabase.rpc("get_public_catalogue",{p_business_slug:businessSlug});
      if(!active)return;
      if(error){setFailed(true);setItems([]);}
      else setItems((data??[]) as CatalogueItem[]);
      setLoading(false);
    }
    void load();
    return ()=>{active=false;};
  },[]);
  if(loading)return <section className="section catalogue-section" id="catalogue"><div className="section-heading"><p className="eyebrow">OUR CATALOGUE</p><h2>Made to order.</h2></div><p className="notice">Loading the catalogue…</p></section>;
  if(failed)return <section className="section catalogue-section" id="catalogue"><div className="section-heading"><p className="eyebrow">OUR CATALOGUE</p><h2>Made to order.</h2><p>Ask us about available products and custom options.</p></div></section>;
  if(!items.length)return null;
  return <section className="section catalogue-section" id="catalogue">
    <div className="section-heading"><p className="eyebrow">OUR CATALOGUE</p><h2>Explore what<br/>we can make.</h2><p>Published items are a starting point. Final pricing depends on sizes, artwork, quantity and production method.</p></div>
    <div className="catalogue-grid">{items.map(item=><article className="catalogue-card" key={item.id}>
      <span className="catalogue-kind">{item.category_name||item.item_type}</span>
      <h3>{item.name}</h3>
      {item.description&&<p>{item.description}</p>}
      {item.public_starting_price!==null&&<strong>From {kes(Number(item.public_starting_price))}</strong>}
      <a href="#enquire" onClick={()=>{const service=document.querySelector<HTMLSelectElement>(".public-enquiry-form select");if(service){const match=Array.from(service.options).find(o=>o.text.toLowerCase()===item.name.toLowerCase());if(match)service.value=match.value;}}}>Enquire about this ↗</a>
    </article>)}</div>
  </section>;
}
