import { useState } from "react";
import OwnerApp from "./OwnerApp";

type ModuleKey = "Overview" | "Orders" | "Production" | "Payments" | "Inventory" | "Expenses" | "Reports";
const modules: ModuleKey[] = ["Overview", "Orders", "Production", "Payments", "Inventory", "Expenses", "Reports"];
const tasks = [
  { id: "MJ-001", title: "Dashboard and owner controls", detail: "Foundation milestone", status: "In progress", tone: "blue" },
  { id: "MJ-002", title: "Customer and quotation workflow", detail: "Next build area", status: "Planned", tone: "orange" },
  { id: "MJ-003", title: "Production and quality tracking", detail: "Artwork approvals and rework", status: "Planned", tone: "green" },
];
function OwnerDashboard({ onExit }: { onExit: () => void }) {
  const [active, setActive] = useState<ModuleKey>("Overview");
  const [period, setPeriod] = useState("Today");
  const [menuOpen, setMenuOpen] = useState(false);

  const descriptions: Record<ModuleKey, string> = {
    Overview: "A clear view of the shop's daily work and financial position.",
    Orders: "Customer enquiries, quotations, confirmed orders and balances.",
    Production: "Artwork approvals, production jobs, quality checks and rework.",
    Payments: "Cash and M-Pesa receipts, deposits, instalments and reconciliation.",
    Inventory: "Stock on hand, reserved materials, purchases and adjustments.",
    Expenses: "Shop expenses, supplier costs and job-related spending.",
    Reports: "Owner summaries, audit history and financial controls.",
  };

  return (
    <div className="dashboard-shell">
      <aside className={menuOpen ? "dash-sidebar menu-open" : "dash-sidebar"}>
        <a className="dash-brand" href="#dashboard" onClick={(e) => e.preventDefault()}>
          <span className="brand-mark">MJ</span><span><b>MJ PRINTING</b><small>OWNER WORKSPACE</small></span>
        </a>
        <div className="sidebar-label">WORKSPACE</div>
        <nav className="dash-nav" aria-label="Owner workspace">
          {modules.map((item, i) => (
            <button key={item} className={active === item ? "dash-nav-item active" : "dash-nav-item"} onClick={() => { setActive(item); setMenuOpen(false); }}>
              <span className="nav-symbol">{["▦","▤","⚙","↔","▧","−","▥"][i]}</span>{item}
            </button>
          ))}
        </nav>
        <div className="sidebar-bottom">
          <div className="account-chip"><span className="account-avatar">O</span><span><b>Owner account</b><small>Owner access</small></span></div>
          <button className="back-site" onClick={onExit}>← Back to website</button>
        </div>
      </aside>
      <main className="dash-main">
        <header className="dash-topbar">
          <button className="mobile-menu" onClick={() => setMenuOpen(!menuOpen)} aria-label="Toggle navigation">☰</button>
          <div className="breadcrumb">MJ Tees <span>/</span> {active}</div>
          <div className="preview-pill"><i /> PREVIEW — NOT LIVE DATA</div>
        </header>
        <div className="dash-content">
          <div className="dash-heading">
            <div><p className="eyebrow">OWNER WORKSPACE</p><h1>{active === "Overview" ? "Good day." : active}</h1><p>{descriptions[active]}</p></div>
            <label className="period-select">View period <select value={period} onChange={(e) => setPeriod(e.target.value)}><option>Today</option><option>This week</option><option>This month</option></select></label>
          </div>
          {active === "Overview" ? <>
            <div className="metric-grid">
              <article className="metric-card"><span>Sales recorded</span><strong>—</strong><small>Connect business records to view</small><i className="metric-accent orange" /></article>
              <article className="metric-card"><span>Payments received</span><strong>—</strong><small>Cash and M-Pesa receipts</small><i className="metric-accent blue" /></article>
              <article className="metric-card"><span>Outstanding balances</span><strong>—</strong><small>Customer balances due</small><i className="metric-accent green" /></article>
              <article className="metric-card"><span>Active production jobs</span><strong>—</strong><small>Jobs currently in progress</small><i className="metric-accent orange" /></article>
            </div>
            <div className="dash-panels">
              <section className="dash-panel work-panel">
                <div className="panel-heading"><div><h2>Build progress</h2><p>First-release implementation</p></div><span className="panel-tag">FOUNDATION</span></div>
                <div className="progress-row"><div><b>Owner dashboard foundation</b><span>Workspace and navigation</span></div><span className="progress-state">In progress</span></div>
                <div className="progress-track"><span /></div>
                {tasks.slice(1).map((task) => <div className="progress-row" key={task.id}><div><b>{task.title}</b><span>{task.detail}</span></div><span className={"task-state " + task.tone}>{task.status}</span></div>)}
              </section>
              <section className="dash-panel controls-panel">
                <div className="panel-heading"><div><h2>Owner controls</h2><p>Important operating safeguards</p></div></div>
                <div className="control-line"><span className="control-icon green-bg">✓</span><div><b>Payment before handover</b><small>Full payment required unless an owner-approved exception is recorded.</small></div></div>
                <div className="control-line"><span className="control-icon blue-bg">↗</span><div><b>Traceable transactions</b><small>Payments, expenses and stock changes will retain an audit trail.</small></div></div>
                <div className="control-line"><span className="control-icon orange-bg">◎</span><div><b>Artwork stored in Drive</b><small>The system will track links, versions and customer approvals.</small></div></div>
              </section>
            </div>
            <section className="dash-panel next-panel"><div><h2>Daily work at a glance</h2><p>Live jobs, due collections and payment follow-ups will appear here once the database is connected.</p></div><span className="empty-state">No live records connected</span></section>
          </> : <section className="dash-panel module-placeholder">
            <div className="module-icon">{modules.indexOf(active) + 1}</div>
            <h2>{active} workspace</h2><p>{descriptions[active]}</p>
            <div className="module-note"><b>Module not connected yet</b><span>This section will become operational when its workflow and approved database design are implemented. No sample transactions are being presented as real business records.</span></div>
          </section>}
          <footer className="dash-footer"><span>MJ Printing & Branding · Owner workspace</span><span>First release build · {period}</span></footer>
        </div>
      </main>
    </div>
  );
}

const services = [
  { title: "Custom apparel", description: "T-shirts, polos, caps and other garments for individuals, teams, schools and organisations." },
  { title: "Screen printing", description: "In-house screen printing for suitable artwork, quantities and production requirements." },
  { title: "Heat-applied branding", description: "Vinyl and sublimation customisation for apparel and selected merchandise." },
  { title: "Stickers and decals", description: "Custom DTF stickers and vinyl graphics, including vehicle and motorcycle branding." },
  { title: "Custom merchandise", description: "Personalised items such as mugs, reflector jackets and other made-to-order products." },
  { title: "Artwork preparation", description: "Artwork setup and preparation for print and cutting workflows." },
];

function Website({ onOwner }: { onOwner: () => void }) {
  return <main className="public-site">
    <header className="site-header">
      <a className="brand" href="#home" aria-label="MJ Printing & Branding home"><span className="brand-mark">MJ</span><span>MJ PRINTING & BRANDING</span></a>
      <nav aria-label="Main navigation"><a href="#services">Services</a><a href="#process">How it works</a><button className="nav-portal" onClick={onOwner}>Owner workspace</button></nav>
    </header>
    <section className="hero" id="home">
      <div className="hero-copy"><p className="eyebrow">PRINTING · APPAREL · BRANDING</p><h1>Make your idea<br /><span>stand out.</span></h1><p className="hero-intro">Custom apparel, printing and branded merchandise for people, teams, schools, businesses and organisations.</p><a className="primary-link" href="#services">Explore our services <span aria-hidden="true">↗</span></a></div>
      <div className="hero-art" aria-label="MJ Printing and Branding artwork"><div className="art-circle art-circle-one" /><div className="art-circle art-circle-two" /><div className="art-word">YOUR<br />IDENTITY.</div><div className="art-caption">DESIGNED TO BE SEEN</div></div>
    </section>
    <section className="section services-section" id="services"><div className="section-heading"><p className="eyebrow">WHAT WE DO</p><h2>Ideas into<br />something tangible.</h2><p>From a single customised item to a larger group order, each job is quoted according to its requirements.</p></div><div className="service-grid">{services.map((service, index) => <article className="service-card" key={service.title}><span className="service-number">0{index + 1}</span><h3>{service.title}</h3><p>{service.description}</p></article>)}</div></section>
    <section className="process-section" id="process"><div><p className="eyebrow">A CLEAR PROCESS</p><h2>From enquiry<br />to finished order.</h2></div><ol className="process-list"><li><span>01</span><div><strong>Share your idea</strong><p>Tell us what you need, quantities, sizes, colours and your deadline.</p></div></li><li><span>02</span><div><strong>Review the quote</strong><p>We assess the artwork, materials and production method before confirming the price.</p></div></li><li><span>03</span><div><strong>Approve and produce</strong><p>Once the order details and payment arrangements are confirmed, production can begin.</p></div></li><li><span>04</span><div><strong>Collect or arrange delivery</strong><p>We confirm completion and the outstanding balance before handover.</p></div></li></ol></section>
    <section className="portal-section" id="shop-access"><div><p className="eyebrow">SHOP OPERATIONS</p><h2>Built around the work.</h2><p>The MJ owner workspace is taking shape. Operational records will be connected after the database and access controls are reviewed and approved.</p></div><button className="portal-status" onClick={onOwner}>View owner workspace preview ↗</button></section>
    <footer className="site-footer"><a className="brand" href="#home"><span className="brand-mark">MJ</span><span>MJ PRINTING & BRANDING</span></a><p>Printing, apparel and branding.</p><span>© {new Date().getFullYear()} MJ Printing & Branding</span></footer>
  </main>;
}

function App() {
  const [view, setView] = useState<"website" | "owner">("website");
  return view === "owner" ? <OwnerApp onExit={() => setView("website")} /> : <Website onOwner={() => setView("owner")} />;
}
export default App;
