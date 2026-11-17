import { useState } from "react";
import OwnerApp from "./OwnerApp";
import QuoteAcceptance from "./QuoteAcceptance";
import PublicEnquiryForm from "./PublicEnquiryForm";

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
      <nav aria-label="Main navigation"><a href="#services">Services</a><a href="#process">How it works</a><a href="#enquire">Get a quote</a><button className="nav-portal" onClick={onOwner}>Owner workspace</button></nav>
    </header>
    <section className="hero" id="home">
      <div className="hero-copy"><p className="eyebrow">PRINTING · APPAREL · BRANDING</p><h1>Make your idea<br /><span>stand out.</span></h1><p className="hero-intro">Custom apparel, printing and branded merchandise for people, teams, schools, businesses and organisations.</p><a className="primary-link" href="#services">Explore our services <span aria-hidden="true">↗</span></a></div>
      <div className="hero-art" aria-label="MJ Printing and Branding artwork"><div className="art-circle art-circle-one" /><div className="art-circle art-circle-two" /><div className="art-word">YOUR<br />IDENTITY.</div><div className="art-caption">DESIGNED TO BE SEEN</div></div>
    </section>
    <section className="section services-section" id="services"><div className="section-heading"><p className="eyebrow">WHAT WE DO</p><h2>Ideas into<br />something tangible.</h2><p>From a single customised item to a larger group order, each job is quoted according to its requirements.</p></div><div className="service-grid">{services.map((service, index) => <article className="service-card" key={service.title}><span className="service-number">0{index + 1}</span><h3>{service.title}</h3><p>{service.description}</p></article>)}</div></section>
    <PublicEnquiryForm />
    <section className="process-section" id="process"><div><p className="eyebrow">A CLEAR PROCESS</p><h2>From enquiry<br />to finished order.</h2></div><ol className="process-list"><li><span>01</span><div><strong>Share your idea</strong><p>Tell us what you need, quantities, sizes, colours and your deadline.</p></div></li><li><span>02</span><div><strong>Review the quote</strong><p>We assess the artwork, materials and production method before confirming the price.</p></div></li><li><span>03</span><div><strong>Approve and produce</strong><p>Once the order details and payment arrangements are confirmed, production can begin.</p></div></li><li><span>04</span><div><strong>Collect or arrange delivery</strong><p>We confirm completion and the outstanding balance before handover.</p></div></li></ol></section>
    <section className="portal-section" id="shop-access"><div><p className="eyebrow">SHOP OPERATIONS</p><h2>Built around the work.</h2><p>The private owner workspace is accessed separately. Only an account with an active owner membership can enter business operations.</p></div><button className="portal-status" onClick={onOwner}>Open owner workspace ↗</button></section>
    <footer className="site-footer"><a className="brand" href="#home"><span className="brand-mark">MJ</span><span>MJ PRINTING & BRANDING</span></a><p>Printing, apparel and branding.</p><span>© {new Date().getFullYear()} MJ Printing & Branding</span></footer>
  </main>;
}

function App() {
  const [view, setView] = useState<"website" | "owner">("website");
  const acceptanceToken = new URLSearchParams(window.location.search).get("accept_quote");
  if (acceptanceToken) return <QuoteAcceptance token={acceptanceToken} />;
  return view === "owner" ? <OwnerApp onExit={() => setView("website")} /> : <Website onOwner={() => setView("owner")} />;
}
export default App;
