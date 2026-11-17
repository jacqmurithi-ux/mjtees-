import { useCallback, useEffect, useState } from "react";
import type { FormEvent } from "react";
import type { Session } from "@supabase/supabase-js";
import { supabase, supabaseConfigured } from "./lib/supabase";
import QuoteWorkflow from "./QuoteWorkflow";
import PaymentWorkflow from "./PaymentWorkflow";
import OrderProductionWorkflow from "./OrderProductionWorkflow";

type Business = { id: string; name: string; trading_name: string | null };
type Customer = { id: string; display_name: string; business_name: string | null; phone: string | null; email: string | null; created_at: string };
type Enquiry = { id: string; public_reference: string; contact_name: string; phone: string | null; email: string | null; requested_service: string; description: string; quantity: number | null; desired_by: string | null; customer_supplies_item: boolean; artwork_drive_url: string | null; status: string; created_at: string };

const sections = ["Overview", "Enquiries", "Customers", "Quotations", "Orders", "Payments", "Inventory", "Purchasing", "Production", "Expenses", "Reports"] as const;
type Section = typeof sections[number];
const requestId = () => crypto.randomUUID();

export default function OwnerApp({ onExit }: { onExit: () => void }) {
  const [session, setSession] = useState<Session | null>(null);
  const [authReady, setAuthReady] = useState(false);
  const [business, setBusiness] = useState<Business | null>(null);
  const [section, setSection] = useState<Section>("Overview");
  const [customers, setCustomers] = useState<Customer[]>([]);
  const [enquiries, setEnquiries] = useState<Enquiry[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [customerForm, setCustomerForm] = useState({ display_name: "", business_name: "", phone: "", email: "", notes: "" });
  const [showCustomerForm, setShowCustomerForm] = useState(false);

  useEffect(() => {
    if (!supabase) { setAuthReady(true); return; }
    supabase.auth.getSession().then(({ data, error: authError }) => {
      if (authError) setError(authError.message);
      setSession(data.session);
      setAuthReady(true);
    });
    const { data } = supabase.auth.onAuthStateChange((_event, next) => setSession(next));
    return () => data.subscription.unsubscribe();
  }, []);

  const loadWorkspace = useCallback(async () => {
    if (!supabase || !session) return;
    setLoading(true); setError("");
    try {
      const { data: membership, error: membershipError } = await supabase
        .from("business_memberships")
        .select("business_id, businesses(id,name,trading_name)")
        .eq("user_id", session.user.id).eq("role", "owner").eq("status", "active").maybeSingle();
      if (membershipError) throw membershipError;
      if (!membership?.businesses) throw new Error("This account does not have an active owner membership.");
      const businessRecord = Array.isArray(membership.businesses) ? membership.businesses[0] : membership.businesses;
      setBusiness(businessRecord as Business);
      const [customerResult, enquiryResult] = await Promise.all([
        supabase.from("customers").select("id,display_name,business_name,phone,email,created_at").eq("business_id", membership.business_id).is("archived_at", null).order("created_at", { ascending: false }).limit(100),
        supabase.from("enquiries").select("id,public_reference,contact_name,phone,email,requested_service,description,quantity,desired_by,customer_supplies_item,artwork_drive_url,status,created_at").eq("business_id", membership.business_id).order("created_at", { ascending: false }).limit(100),
      ]);
      if (customerResult.error) throw customerResult.error;
      if (enquiryResult.error) throw enquiryResult.error;
      setCustomers((customerResult.data ?? []) as Customer[]);
      setEnquiries((enquiryResult.data ?? []) as Enquiry[]);
    } catch (e) { setError(e instanceof Error ? e.message : "Could not load owner workspace."); }
    finally { setLoading(false); }
  }, [session]);

  useEffect(() => { if (session) void loadWorkspace(); else { setBusiness(null); setCustomers([]); setEnquiries([]); } }, [session, loadWorkspace]);

  async function signIn(event: FormEvent) {
    event.preventDefault(); if (!supabase) return;
    setLoading(true); setError("");
    const { error: signInError } = await supabase.auth.signInWithPassword({ email: email.trim(), password });
    if (signInError) setError(signInError.message);
    setLoading(false);
  }
  async function signOut() {
    if (!supabase) return;
    const { error: signOutError } = await supabase.auth.signOut();
    if (signOutError) setError(signOutError.message);
  }
  async function saveCustomer(event: FormEvent) {
    event.preventDefault(); if (!supabase || !business) return;
    setLoading(true); setError(""); setNotice("");
    const { error: saveError } = await supabase.rpc("owner_upsert_customer", {
      p_business_id: business.id, p_customer_id: null, p_display_name: customerForm.display_name.trim(),
      p_business_name: customerForm.business_name.trim() || null, p_phone: customerForm.phone.trim() || null,
      p_email: customerForm.email.trim() || null, p_notes: customerForm.notes.trim() || null, p_request_id: requestId(),
    });
    if (saveError) setError(saveError.message);
    else { setCustomerForm({ display_name: "", business_name: "", phone: "", email: "", notes: "" }); setShowCustomerForm(false); setNotice("Customer saved."); await loadWorkspace(); }
    setLoading(false);
  }
  async function updateEnquiry(enquiry: Enquiry, status: string) {
    if (!supabase) return;
    setLoading(true); setError(""); setNotice("");
    const { error: updateError } = await supabase.rpc("owner_update_enquiry_status", {
      p_enquiry_id: enquiry.id, p_status: status, p_notes: null, p_request_id: requestId(),
    });
    if (updateError) setError(updateError.message);
    else { setNotice("Enquiry updated."); await loadWorkspace(); }
    setLoading(false);
  }

  if (!authReady) return <main className="owner-auth"><p>Loading secure owner session…</p></main>;
  if (!supabaseConfigured) return <main className="owner-auth"><section className="auth-card"><span className="brand-mark">MJ</span><p className="eyebrow">OWNER WORKSPACE</p><h1>Connect the shop database</h1><p>Set VITE_SUPABASE_URL and VITE_SUPABASE_PUBLISHABLE_KEY in the local environment or GitHub Pages build settings. No secret service-role key belongs in the browser.</p><button className="secondary-action" onClick={onExit}>Back to website</button></section></main>;
  if (!session) return <main className="owner-auth"><form className="auth-card" onSubmit={signIn}><span className="brand-mark">MJ</span><p className="eyebrow">OWNER ACCESS</p><h1>Sign in to MJ Tees</h1><p>Use the owner account created through the trusted setup process. Public registration is disabled.</p>{error && <div className="notice error">{error}</div>}<label>Email address<input type="email" autoComplete="username" required value={email} onChange={e => setEmail(e.target.value)} /></label><label>Password<input type="password" autoComplete="current-password" required value={password} onChange={e => setPassword(e.target.value)} /></label><button className="primary-action" disabled={loading}>{loading ? "Signing in…" : "Sign in"}</button><button type="button" className="text-action" onClick={onExit}>Back to public website</button></form></main>;

  const activeEnquiries = enquiries.filter(item => item.status === "new" || item.status === "reviewing");
  return <div className="connected-workspace">
    <aside className="connected-sidebar"><a className="dash-brand" href="#owner"><span className="brand-mark">MJ</span><span><b>MJ PRINTING</b><small>OWNER WORKSPACE</small></span></a><p className="sidebar-label">SHOP OPERATIONS</p><nav>{sections.map(item => <button key={item} className={section === item ? "connected-nav active" : "connected-nav"} onClick={() => setSection(item)}>{item}</button>)}</nav><div className="connected-account"><b>{session.user.email}</b><small>{business?.trading_name || business?.name || "Owner account"}</small><button onClick={signOut}>Sign out</button><button onClick={onExit}>Public website</button></div></aside>
    <main className="connected-main"><header className="connected-header"><div><p className="eyebrow">MJ PRINTING & BRANDING</p><h1>{section}</h1><p>{business?.trading_name || business?.name || "Loading business…"}</p></div><button className="secondary-action" onClick={() => void loadWorkspace()} disabled={loading}>Refresh</button></header>
      {error && <div className="notice error">{error}</div>}{notice && <div className="notice success">{notice}</div>}
      {loading && <p className="loading-line">Updating records…</p>}
      {section === "Overview" && <><div className="connected-metrics"><article><span>Open enquiries</span><strong>{activeEnquiries.length}</strong><small>Awaiting review or quotation</small></article><article><span>Customers</span><strong>{customers.length}</strong><small>Active customer records</small></article><article><span>Enquiries received</span><strong>{enquiries.length}</strong><small>Latest 100 records</small></article><article><span>Live financial totals</span><strong>—</strong><small>Connect order and payment workflows next</small></article></div><section className="connected-panel"><h2>Today’s work</h2><p>Start with new enquiries, follow up on quotes and keep customer details together.</p><button className="primary-action compact" onClick={() => setSection("Enquiries")}>Review enquiries</button></section></>}
      {section === "Customers" && <section className="connected-panel"><div className="panel-toolbar"><div><h2>Customers</h2><p>Customer records saved to the business database.</p></div><button className="primary-action compact" onClick={() => setShowCustomerForm(v => !v)}>Add customer</button></div>{showCustomerForm && <form className="record-form" onSubmit={saveCustomer}><label>Customer name *<input required value={customerForm.display_name} onChange={e => setCustomerForm(v => ({...v,display_name:e.target.value}))}/></label><label>Business / organisation<input value={customerForm.business_name} onChange={e => setCustomerForm(v => ({...v,business_name:e.target.value}))}/></label><label>Phone<input value={customerForm.phone} onChange={e => setCustomerForm(v => ({...v,phone:e.target.value}))}/></label><label>Email<input type="email" value={customerForm.email} onChange={e => setCustomerForm(v => ({...v,email:e.target.value}))}/></label><label className="wide-field">Notes<textarea value={customerForm.notes} onChange={e => setCustomerForm(v => ({...v,notes:e.target.value}))}/></label><div className="form-actions"><button className="primary-action compact" disabled={loading}>Save customer</button><button type="button" className="secondary-action" onClick={() => setShowCustomerForm(false)}>Cancel</button></div></form>}<div className="record-list">{customers.map(c => <article className="record-row" key={c.id}><div><b>{c.display_name}</b><small>{c.business_name || "Individual"} · {c.phone || c.email || "No contact details"}</small></div><span>{c.email || "—"}</span></article>)}{!customers.length && <p className="empty-records">No customers yet. Add the first customer to begin.</p>}</div></section>}
      {section === "Enquiries" && <section className="connected-panel"><div className="panel-toolbar"><div><h2>Website enquiries</h2><p>Requests received through the public enquiry endpoint.</p></div><span className="count-chip">{activeEnquiries.length} open</span></div><div className="record-list">{enquiries.map(item => <article className="enquiry-card" key={item.id}><div className="enquiry-top"><div><b>{item.contact_name}</b><small>{item.public_reference} · {new Date(item.created_at).toLocaleString("en-KE")}</small></div><span className={"status-chip " + item.status}>{item.status}</span></div><p><b>{item.requested_service}</b> · {item.quantity ?? "Quantity not given"}</p><p>{item.description}</p><small>{[item.phone,item.email].filter(Boolean).join(" · ") || "No contact"}{item.desired_by ? " · Needed by " + item.desired_by : ""}{item.customer_supplies_item ? " · Customer supplies item" : ""}</small>{item.artwork_drive_url && <a href={item.artwork_drive_url} target="_blank" rel="noreferrer">Open artwork reference ↗</a>}<div className="enquiry-actions"><select aria-label="Update enquiry status" value={item.status} onChange={e => void updateEnquiry(item,e.target.value)}><option value="new">New</option><option value="reviewing">Reviewing</option><option value="quoted">Quoted</option><option value="closed">Closed</option><option value="spam">Spam</option></select></div></article>)}{!enquiries.length && <p className="empty-records">No enquiries have been received.</p>}</div></section>}
      {section === "Quotations" && business && <QuoteWorkflow businessId={business.id} customers={customers} enquiries={enquiries} onChanged={() => void loadWorkspace()} />}
      {section === "Orders" && business && <OrderProductionWorkflow businessId={business.id} customers={customers} onChanged={() => void loadWorkspace()} />}
      {section === "Production" && business && <OrderProductionWorkflow businessId={business.id} customers={customers} onChanged={() => void loadWorkspace()} />}
      {section === "Payments" && business && <PaymentWorkflow businessId={business.id} customers={customers} onChanged={() => void loadWorkspace()} />}
      {!["Overview","Customers","Enquiries","Quotations","Orders","Payments","Production"].includes(section) && <section className="connected-panel upcoming-panel"><h2>{section} workflow</h2><p>This section is not connected yet. It will be enabled only when its complete owner workflow, database actions and permission checks are implemented.</p><p>Customer and enquiry records are live. Other screens will not display invented sample transactions.</p></section>}
      <footer className="connected-footer">MJ Printing & Branding · KES · Africa/Nairobi</footer>
    </main>
  </div>;
}
