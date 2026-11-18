import { useEffect, useRef, useState } from "react";

const HOME_URL = import.meta.env.BASE_URL.endsWith("/") ? import.meta.env.BASE_URL : `${import.meta.env.BASE_URL}/`;
import { supabase, supabaseConfigured } from "./lib/supabase";

export default function QuoteAcceptance({ token }: { token: string }) {
  const started=useRef(false);
  const [state,setState]=useState<"loading"|"success"|"error">("loading");
  const [message,setMessage]=useState("Confirming quotation acceptance…");
  useEffect(()=>{
    if(started.current)return;started.current=true;
    if(!supabaseConfigured||!supabase){setState("error");setMessage("The acceptance service is not configured. Please contact MJ Printing & Branding.");return;}
    void supabase.rpc("accept_quotation",{p_token:token,p_request_id:crypto.randomUUID()}).then(({data,error})=>{
      if(error){setState("error");setMessage(error.message);}
      else{setState("success");setMessage("Thank you. Your quotation has been accepted and order "+data.order_number+" has been created.");}
      const url=new URL(window.location.href);url.searchParams.delete("accept_quote");window.history.replaceState({},"",url.toString());
    });
  },[token]);
  return <main className="owner-auth"><section className="auth-card"><span className="brand-mark">MJ</span><p className="eyebrow">MJ PRINTING & BRANDING</p><h1>{state==="success"?"Quotation accepted":state==="error"?"Unable to accept quotation":"Confirming your order"}</h1><p>{message}</p>{state==="error"&&<p>Please contact the shop if you believe this link should still be valid.</p>}<a className="primary-action" href={HOME_URL}>Back to MJ Printing & Branding</a></section></main>;
}
