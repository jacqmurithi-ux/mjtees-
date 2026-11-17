import { useEffect, useRef, useState } from "react";
import type { FormEvent } from "react";
import { supabase } from "./lib/supabase";

declare global {
  interface Window {
    turnstile?: {
      render: (container: HTMLElement, options: {
        sitekey: string;
        callback: (token: string) => void;
        "expired-callback"?: () => void;
        "error-callback"?: () => void;
      }) => string;
      reset: (widgetId?: string) => void;
      remove: (widgetId?: string) => void;
    };
  }
}

const siteKey = import.meta.env.VITE_TURNSTILE_SITE_KEY as string | undefined;
const businessSlug = import.meta.env.VITE_BUSINESS_SLUG as string | undefined;

export default function PublicEnquiryForm() {
  const widgetHost = useRef<HTMLDivElement>(null);
  const widgetId = useRef<string | null>(null);
  const [token, setToken] = useState("");
  const [loading, setLoading] = useState(false);
  const [message, setMessage] = useState("");
  const [error, setError] = useState("");
  const [fields, setFields] = useState({
    contact_name: "", phone: "", email: "", requested_service: "",
    description: "", quantity: "", desired_by: "", customer_supplies_item: false,
    artwork_drive_url: "",
  });

  useEffect(() => {
    if (!siteKey || !widgetHost.current) return;
    let cancelled = false;
    const render = () => {
      if (cancelled || !widgetHost.current || !window.turnstile || widgetId.current) return;
      widgetId.current = window.turnstile.render(widgetHost.current, {
        sitekey: siteKey,
        callback: value => { setToken(value); setError(""); },
        "expired-callback": () => setToken(""),
        "error-callback": () => { setToken(""); setError("Verification could not load. Please refresh and try again."); },
      });
    };
    if (window.turnstile) render();
    else {
      let script = document.querySelector<HTMLScriptElement>('script[data-mj-turnstile="true"]');
      if (!script) {
        script = document.createElement("script");
        script.src = "https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit";
        script.async = true;
        script.defer = true;
        script.dataset.mjTurnstile = "true";
        document.head.appendChild(script);
      }
      script.addEventListener("load", render);
      script.addEventListener("error", () => setError("Verification service could not load."));
    }
    return () => {
      cancelled = true;
      if (widgetId.current && window.turnstile) window.turnstile.remove(widgetId.current);
      widgetId.current = null;
    };
  }, []);

  async function submit(event: FormEvent) {
    event.preventDefault();
    if (!supabase || !businessSlug || !siteKey) {
      setError("The enquiry service is not configured yet. Please contact the shop directly.");
      return;
    }
    if (!token) { setError("Complete the verification check before sending."); return; }
    setLoading(true); setError(""); setMessage("");
    const { data, error: invokeError } = await supabase.functions.invoke("submit-public-enquiry", {
      body: {
        business_slug: businessSlug,
        ...fields,
        quantity: fields.quantity ? Number(fields.quantity) : null,
        desired_by: fields.desired_by || null,
        artwork_drive_url: fields.artwork_drive_url.trim() || null,
        turnstile_token: token,
        request_id: crypto.randomUUID(),
      },
    });
    if (invokeError) setError(invokeError.message || "We could not send your enquiry. Please try again.");
    else if (!data?.ok || typeof data.public_reference !== "string") setError(data?.message || "We could not send your enquiry. Please try again.");
    else {
      setMessage("Thank you. Your enquiry reference is " + data.public_reference + ". We will review your request.");
      setFields({ contact_name: "", phone: "", email: "", requested_service: "", description: "", quantity: "", desired_by: "", customer_supplies_item: false, artwork_drive_url: "" });
      setToken("");
      if (widgetId.current && window.turnstile) window.turnstile.reset(widgetId.current);
    }
    setLoading(false);
  }

  const update = (key: keyof typeof fields, value: string | boolean) => setFields(current => ({ ...current, [key]: value }));

  return <section className="section enquiry-section" id="enquire">
    <div className="section-heading"><p className="eyebrow">START YOUR ORDER</p><h2>Tell us what<br />you have in mind.</h2><p>Share the service, quantity, deadline and artwork reference. We will review the details and prepare a quotation.</p></div>
    {!supabase || !businessSlug || !siteKey
      ? <p className="notice">Online enquiries are being configured. Please contact MJ Printing & Branding directly for now.</p>
      : <form className="record-form public-enquiry-form" onSubmit={submit}>
        <label>Your name *<input required maxLength={120} value={fields.contact_name} onChange={e => update("contact_name", e.target.value)} /></label>
        <label>Phone<input type="tel" maxLength={40} value={fields.phone} onChange={e => update("phone", e.target.value)} /></label>
        <label>Email<input type="email" maxLength={254} value={fields.email} onChange={e => update("email", e.target.value)} /></label>
        <label>Service required *<select required value={fields.requested_service} onChange={e => update("requested_service", e.target.value)}><option value="">Choose a service</option>{["Custom apparel","Screen printing","Heat-applied branding","Stickers and decals","Custom merchandise","Artwork preparation","Other"].map(x => <option key={x}>{x}</option>)}</select></label>
        <label>Quantity<input type="number" min="1" max="100000" step="any" value={fields.quantity} onChange={e => update("quantity", e.target.value)} /></label>
        <label>Needed by<input type="date" min={new Date().toISOString().slice(0,10)} value={fields.desired_by} onChange={e => update("desired_by", e.target.value)} /></label>
        <label className="wide-field">Describe your order *<textarea required maxLength={4000} rows={4} value={fields.description} onChange={e => update("description", e.target.value)} placeholder="Items, sizes, colours, print locations and any other requirements" /></label>
        <label className="wide-field checkbox-field"><input type="checkbox" checked={fields.customer_supplies_item} onChange={e => update("customer_supplies_item", e.target.checked)} /> I will bring my own items for printing or branding</label>
        <label className="wide-field">Artwork Google Drive link (optional)<input type="url" maxLength={2048} placeholder="https://drive.google.com/…" value={fields.artwork_drive_url} onChange={e => update("artwork_drive_url", e.target.value)} /></label>
        <div className="wide-field"><div ref={widgetHost} />{!token && <small>Complete the security check to send your enquiry.</small>}</div>
        {error && <p className="notice error wide-field">{error}</p>}{message && <p className="notice success wide-field">{message}</p>}
        <div className="form-actions wide-field"><button className="primary-action" disabled={loading || !token}>{loading ? "Sending…" : "Send enquiry"}</button></div>
      </form>}
  </section>;
}
