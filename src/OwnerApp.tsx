import { useCallback, useEffect, useState } from "react";
import type { FormEvent } from "react";
import type { Session } from "@supabase/supabase-js";
import { supabase, supabaseConfigured } from "./lib/supabase";
import QuoteWorkflow from "./QuoteWorkflow";
import PaymentWorkflow from "./PaymentWorkflow";
import OrderProductionWorkflow from "./OrderProductionWorkflow";
import ShopOperationsWorkflow from "./ShopOperationsWorkflow";
import CatalogueManagement from "./CatalogueManagement";
import WebsiteContentManagement from "./WebsiteContentManagement";
import Milestone08Workflow from "./Milestone08Workflow";
import CustomerManagement from "./CustomerManagement";
import "./responsive-owner.css";

type Business = { id: string; name: string; trading_name: string | null };
type Customer = { id: string; display_name: string; business_name: string | null; phone: string | null; email: string | null; created_at: string };
type Enquiry = { id: string; public_reference: string; contact_name: string; phone: string | null; email: string | null; requested_service: string; description: string; quantity: number | null; desired_by: string | null; customer_supplies_item: boolean; artwork_drive_url: string | null; status: string; created_at: string };

const sections = ["Overview", "Enquiries", "Customers", "Catalogue", "Website Content", "Quotations", "Orders", "Payments", "Inventory", "Purchasing", "Production", "Expenses", "Daily Closing", "Reconciliation", "Deliveries", "Reports"] as const;
type Section = typeof sections[number];
const requestId = () => crypto.randomUUID();
const money = (n:number) => new Intl.NumberFormat("en-KE",{style:"currency",currency:"KES",maximumFractionDigits:0}).format(n);
const primaryMobile: Section[] = ["Overview", "Enquiries", "Orders", "Payments"];
const moreSections: Section[] = ["Customers", "Catalogue", "Quotations", "Inventory", "Purchasing", "Production", "Expenses", "Daily Closing", "Reconciliation", "Deliveries", "Reports"];
const navIcon: Record<Section,string> = { Overview:"⌂",Enquiries:"✉",Customers:"♙",Catalogue:"▦","Website Content":"✎",Quotations:"▤",Orders:"▣",Payments:"KSh",Inventory:"▥",Purchasing:"↗",Production:"⚙",Expenses:"−","Daily Closing":"▣",Reconciliation:"↔",Deliveries:"➜",Reports:"▥" };

export default function OwnerApp({ onExit }: { onExit: () => void }) {
  const [session, setSession] = useState<Session | null>(null);
  const [authReady, setAuthReady] = useState(false);
  const [business, setBusiness] = useState<Business | null>(null);
  const [section, setSection] = useState<Section>("Overview");
  const [customers, setCustomers] = useState<Customer[]>([]);
  const [enquiries, setEnquiries] = useState<Enquiry[]>([]);
  const [operational, setOperational] = useState({orders:0,activeOrders:0,postedPayments:0,expenses:0,stockItems:0});
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [search, setSearch] = useState("");
  const [moreOpen, setMoreOpen] = useState(false);

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
      const [customerResult, enquiryResult, orderResult, paymentResult, expenseResult, stockResult] = await Promise.all([
        supabase.from("customers").select("id,display_name,business_name,phone,email,created_at").eq("business_id", membership.business_id).is("archived_at", null).order("created_at", { ascending: false }).limit(1000),
        supabase.from("enquiries").select("id,public_reference,contact_name,phone,email,requested_service,description,quantity,desired_by,customer_supplies_item,artwork_drive_url,status,created_at").eq("business_id", membership.business_id).order("created_at", { ascending: false }).limit(100),
        supabase.from("orders").select("id,status,total_amount").eq("business_id", membership.business_id).limit(500),
        supabase.from("payments").select("amount,status").eq("business_id", membership.business_id).limit(1000),
        supabase.from("expenses").select("amount").eq("business_id", membership.business_id).limit(1000),
        supabase.from("stock_items").select("id").eq("business_id", membership.business_id).is("archived_at", null).limit(1000),
      ]);
      if (customerResult.error) throw customerResult.error;
      if (enquiryResult.error) throw enquiryResult.error;
      if (orderResult.error) throw orderResult.error;
      if (paymentResult.error) throw paymentResult.error;
      if (expenseResult.error) throw expenseResult.error;
      if (stockResult.error) throw stockResult.error;
      setCustomers((customerResult.data ?? []) as Customer[]);
      setEnquiries((enquiryResult.data ?? []) as Enquiry[]);
      const orderRows = orderResult.data ?? []; const paymentRows = paymentResult.data ?? []; const expenseRows = expenseResult.data ?? [];
      setOperational({orders:orderRows.length,activeOrders:orderRows.filter(x=>!["completed","cancelled"].includes(x.status)).length,postedPayments:paymentRows.filter(x=>x.status==="posted").reduce((sum,x)=>sum+Number(x.amount),0),expenses:expenseRows.reduce((sum,x)=>sum+Number(x.amount),0),stockItems:stockResult.data?.length??0});
    } catch (e) { setError(e instanceof Error ? e.message : "Could not load owner workspace."); }
    finally { setLoading(false); }
  }, [session]);

  useEffect(() => { if (session) void loadWorkspace(); else { setBusiness(null); setCustomers([]); setEnquiries([]); setOperational({orders:0,activeOrders:0,postedPayments:0,expenses:0,stockItems:0}); } }, [session, loadWorkspace]);

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
  const filteredEnquiries = enquiries.filter(item => [item.contact_name,item.public_reference,item.phone,item.email,item.requested_service,item.description].filter(Boolean).join(" ").toLowerCase().includes(search.toLowerCase()));
  const navigate = (next: Section) => { setSection(next); setSearch(""); setMoreOpen(false); };
  const navButton = (item: Section, mobile = false) => <button key={item} type="button" className={(section === item ? "connected-nav active" : "connected-nav") + (mobile ? " mobile-nav-item" : "")} aria-current={section === item ? "page" : undefined} onClick={() => navigate(item)}><span className="nav-icon" aria-hidden="true">{navIcon[item]}</span><span>{item}</span></button>;
  return <div className="connected-workspace responsive-workspace">
    <aside className="connected-sidebar"><a className="dash-brand" href="#owner"><span className="brand-mark">MJ</span><span><b>MJ PRINTING</b><small>OWNER WORKSPACE</small></span></a><p className="sidebar-label">SHOP OPERATIONS</p><nav aria-label="Shop operations">{sections.map(item => navButton(item))}</nav><div className="connected-account"><b>{session.user.email}</b><small>{business?.trading_name || business?.name || "Owner account"}</small><button onClick={signOut}>Sign out</button><button onClick={onExit}>Public website</button></div></aside>
    <main className="connected-main responsive-main">
      <header className="connected-header responsive-header"><div><p className="eyebrow">MJ PRINTING & BRANDING</p><h1>{section === "Overview" ? "Your shop at a glance" : section}</h1><p>{business?.trading_name || business?.name || "Loading business…"}</p></div><button className="secondary-action refresh-action" onClick={() => void loadWorkspace()} disabled={loading}>{loading ? "Refreshing…" : "↻ Refresh"}</button></header>
      {(section === "Customers" || section === "Enquiries") && <div className="mobile-search-row"><label className="workspace-search"><span aria-hidden="true">⌕</span><input aria-label={"Search " + section.toLowerCase()} placeholder={"Search " + section.toLowerCase() + "…"} value={search} onChange={e => setSearch(e.target.value)} /></label></div>}
      {error && <div className="notice error" role="alert">{error}</div>}{notice && <div className="notice success" role="status">{notice}</div>}
      {loading && <p className="loading-line" role="status">Updating records…</p>}
      {section === "Overview" && <>
        <section className="welcome-panel"><div><span className="welcome-kicker">SHOP OVERVIEW</span><h2>Good {new Date().getHours()<12?"morning":new Date().getHours()<17?"afternoon":"evening"}</h2><p>Here is the latest information available from your shop records.</p></div><span className="welcome-mark" aria-hidden="true">MJ</span></section>
        <div className="connected-metrics overview-metrics">
          <button type="button" className="overview-card orange-card" onClick={() => navigate("Enquiries")}><span className="overview-icon">✉</span><span className="metric-label">Open enquiries</span><strong>{activeEnquiries.length}</strong><small>New and under review · View enquiries →</small></button>
          <button type="button" className="overview-card blue-card" onClick={() => navigate("Orders")}><span className="overview-icon">▣</span><span className="metric-label">Active orders</span><strong>{operational.activeOrders}</strong><small>{operational.orders} total orders recorded · View orders →</small></button>
          <button type="button" className="overview-card green-card" onClick={() => navigate("Payments")}><span className="overview-icon">KSh</span><span className="metric-label">Payments posted</span><strong>{money(operational.postedPayments)}</strong><small>Recorded receipts · View payments →</small></button>
          <button type="button" className="overview-card neutral-card" onClick={() => navigate("Expenses")}><span className="overview-icon">−</span><span className="metric-label">Expenses recorded</span><strong>{money(operational.expenses)}</strong><small>Recorded shop expenses · View expenses →</small></button>
          <button type="button" className="overview-card neutral-card" onClick={() => navigate("Inventory")}><span className="overview-icon">▥</span><span className="metric-label">Stock items tracked</span><strong>{operational.stockItems}</strong><small>Items in inventory · View stock →</small></button>
        </div>
        <section className="connected-panel overview-actions"><div className="panel-toolbar"><div><h2>Quick actions</h2><p>Jump straight into common shop tasks.</p></div></div><div className="quick-action-grid"><button className="primary-action" onClick={() => navigate("Enquiries")}>＋ Review enquiries</button><button className="secondary-action" onClick={() => navigate("Quotations")}>＋ Create quotation</button><button className="secondary-action" onClick={() => navigate("Payments")}>＋ Record payment</button><button className="secondary-action" onClick={() => navigate("Production")}>▣ View production</button></div><p className="data-honesty-note">Weekly trends and due-date alerts will appear when existing records provide reliable dates and status data. No sample figures are displayed.</p></section>
      </>}
      {section === "Customers" && business && <CustomerManagement businessId={business.id} onChanged={() => void loadWorkspace()} />}
      {section === "Enquiries" && <section className="connected-panel"><div className="panel-toolbar"><div><h2>Website enquiries</h2><p>Requests received through the public enquiry endpoint.</p></div><span className="count-chip">{activeEnquiries.length} open</span></div><div className="record-list">{filteredEnquiries.map(item => <article className="enquiry-card" key={item.id}><div className="enquiry-top"><div><b>{item.contact_name}</b><small>{item.public_reference} · {new Date(item.created_at).toLocaleString("en-KE")}</small></div><span className={"status-chip " + item.status}>{item.status}</span></div><p><b>{item.requested_service}</b> · {item.quantity ?? "Quantity not given"}</p><p>{item.description}</p><small>{[item.phone,item.email].filter(Boolean).join(" · ") || "No contact"}{item.desired_by ? " · Needed by " + item.desired_by : ""}{item.customer_supplies_item ? " · Customer supplies item" : ""}</small>{item.artwork_drive_url && <a href={item.artwork_drive_url} target="_blank" rel="noreferrer">Open artwork reference ↗</a>}<div className="enquiry-actions"><select aria-label="Update enquiry status" value={item.status} onChange={e => void updateEnquiry(item,e.target.value)}><option value="new">New</option><option value="reviewing">Reviewing</option><option value="quoted">Quoted</option><option value="closed">Closed</option><option value="spam">Spam</option></select></div></article>)}{!filteredEnquiries.length && <p className="empty-records">{search ? "No enquiries match your search." : "No enquiries have been received."}</p>}</div></section>}
      {section === "Catalogue" && business && <CatalogueManagement businessId={business.id} onChanged={() => void loadWorkspace()} />}
      {section === "Website Content" && business && <WebsiteContentManagement businessId={business.id} />}
      {section === "Quotations" && business && <QuoteWorkflow businessId={business.id} customers={customers} enquiries={enquiries} onChanged={() => void loadWorkspace()} />}
      {section === "Orders" && business && <OrderProductionWorkflow businessId={business.id} customers={customers} onChanged={() => void loadWorkspace()} />}
      {section === "Production" && business && <OrderProductionWorkflow businessId={business.id} customers={customers} onChanged={() => void loadWorkspace()} />}
      {section === "Payments" && business && <PaymentWorkflow businessId={business.id} customers={customers} onChanged={() => void loadWorkspace()} />}
      {["Inventory","Purchasing","Expenses"].includes(section) && business && <ShopOperationsWorkflow businessId={business.id} section={section as "Inventory"|"Purchasing"|"Expenses"} onChanged={() => void loadWorkspace()} />}
      {["Daily Closing","Reconciliation","Deliveries","Reports"].includes(section) && business && <Milestone08Workflow businessId={business.id} section={section as "Daily Closing"|"Reconciliation"|"Deliveries"|"Reports"} onChanged={() => void loadWorkspace()} /> }
      <footer className="connected-footer">MJ Printing & Branding · KES · Africa/Nairobi</footer>
    </main>
    <nav className="mobile-bottom-nav" aria-label="Primary navigation">{primaryMobile.map(item => navButton(item,true))}<button type="button" className={moreSections.includes(section) ? "connected-nav active mobile-nav-item" : "connected-nav mobile-nav-item"} aria-expanded={moreOpen} onClick={() => setMoreOpen(v => !v)}><span className="nav-icon" aria-hidden="true">•••</span><span>More</span></button></nav>
    {moreOpen && <><button className="more-backdrop" aria-label="Close More menu" onClick={() => setMoreOpen(false)} /><section className="mobile-more-sheet" aria-label="More shop modules"><div className="more-sheet-heading"><strong>More modules</strong><button type="button" onClick={() => setMoreOpen(false)} aria-label="Close menu">✕</button></div><div className="more-grid">{moreSections.map(item => <button type="button" className={section===item?"more-module active":"more-module"} key={item} onClick={() => navigate(item)}><span aria-hidden="true">{navIcon[item]}</span>{item}</button>)}</div><div className="more-account"><span>{session.user.email}</span><button type="button" onClick={signOut}>Sign out</button><button type="button" onClick={onExit}>Public website</button></div></section></>}
  </div>;
}
