import { useEffect, useState } from "react";
import { supabase } from "./lib/supabase";
import OwnerApp from "./OwnerApp";
import QuoteAcceptance from "./QuoteAcceptance";
import PublicEnquiryForm from "./PublicEnquiryForm";
import PublicCatalogue from "./PublicCatalogue";

const services = [
  { title: "Custom apparel", tag: "WEAR YOUR BRAND", description: "T-shirts, polos, jerseys, hoodies and caps for individuals, teams, schools and organisations." },
  { title: "Vinyl & heat transfer", tag: "CUT · PRESS · FINISH", description: "Names, numbers and custom graphics applied to garments and selected products." },
  { title: "Stickers & vehicle graphics", tag: "MAKE IT VISIBLE", description: "Custom vinyl stickers, decals and branding for vehicles, motorcycles and storefronts." },
  { title: "Screen printing", tag: "BUILT FOR RUNS", description: "A practical option for suitable artwork, materials and repeat or larger-quantity orders." },
  { title: "Sublimation & merchandise", tag: "PERSONALISED DETAILS", description: "Full-colour designs for suitable apparel, mugs and made-to-order merchandise." },
  { title: "Artwork & finishing", tag: "THE FINAL TOUCH", description: "Artwork preparation, print positioning, finishing and presentation for a polished result." },
];

const categories = [
  { number: "01", name: "Apparel", detail: "T-shirts · Jerseys · Hoodies", tone: "blue", symbol: "T" },
  { number: "02", name: "Vinyl & stickers", detail: "Names · Numbers · Decals", tone: "orange", symbol: "✳" },
  { number: "03", name: "Business branding", detail: "Signs · Labels · Promotions", tone: "green", symbol: "M" },
  { number: "04", name: "Custom merchandise", detail: "Mugs · Gifts · Teamwear", tone: "pink", symbol: "＋" },
];

function Brand({ footer = false, logoSrc = "/assets/mj-printing-branding.svg" }: { footer?: boolean; logoSrc?: string }) {
  return <a className={footer ? "brand footer-brand" : "brand"} href="#home" aria-label="MJ Printing and Branding home">
    <img src={logoSrc} onError={event => { event.currentTarget.onerror = null; event.currentTarget.src = "/assets/mj-printing-branding.svg"; }} alt="MJ Printing & Branding — Design, Print, Brand" />
  </a>;
}

function Website({ onOwner }: { onOwner: () => void }) {
  const [siteContent, setSiteContent] = useState<any>(null);
  useEffect(() => {
    if (!supabase) return;
    supabase.from("website_content").select("content").eq("business_id", "a5d48858-a75b-445d-ba23-8fcd65a5b891").eq("is_published", true).maybeSingle()
      .then(({ data, error }) => { if (!error && data?.content) setSiteContent(data.content); });
  }, []);
  const logoSrc = siteContent?.brand?.logoPath || "/assets/mj-printing-branding.svg";
  return <main className="public-site">
    <div className="announcement-bar"><span>DESIGN</span><i /> <span>PRINT</span><i /> <span>BRAND</span><b>Custom printing and branding, made around your idea.</b></div>
    <header className="site-header">
      <Brand logoSrc={logoSrc} />
      <nav aria-label="Main navigation"><a href="#services">Services</a><a href="#catalogue">Explore products</a><a href="#process">How it works</a><a href="#enquire">Contact</a><button className="nav-portal" onClick={onOwner}>Owner workspace <span>↗</span></button></nav>
    </header>
    <section className="hero" id="home">
      <div className="hero-copy">
        <p className="eyebrow"><span className="eyebrow-dot" /> {siteContent?.hero?.eyebrow || "YOUR IDEA. OUR PRINT. YOUR BRAND."}</p>
        <h1>{siteContent?.hero?.title || <>Make it yours.<br /><span>Make it seen.</span></>}</h1>
        <p className="hero-intro">{siteContent?.hero?.description || "From custom apparel and teamwear to stickers, signage and branded merchandise — we turn your ideas into things people can see, use and wear."}</p>
        <div className="hero-actions"><a className="primary-link" href="#enquire">Start a project <span aria-hidden="true">↗</span></a><a className="text-link" href="#catalogue">Explore what we make <span>↓</span></a></div>
        <div className="hero-proof"><span><b>01</b> Made to order</span><span><b>02</b> Your design, your way</span><span><b>03</b> Personal and business orders</span></div>
      </div>
      <div className="hero-art">
        <div className="hero-art-top"><span>MJ PRINTING & BRANDING</span><span>DESIGN / PRINT / BRAND</span></div>
        <div className="hero-logo-wrap"><img src={logoSrc} onError={event => { event.currentTarget.onerror = null; event.currentTarget.src = "/assets/mj-printing-branding.svg"; }} alt="MJ Printing & Branding logo" /></div>
        <div className="hero-colour-swatch"><i /><i /><i /><i /><i /></div>
        <div className="hero-art-bottom"><strong>YOUR BRAND,</strong><strong>IN EVERY DETAIL.</strong><span>MADE TO STAND OUT ↗</span></div>
        <span className="hero-stamp">MJ<br/>TEES</span>
      </div>
    </section>
    {siteContent?.clients?.length > 0 && <section className="website-client-strip" aria-label="Clients and partners"><p>TRUSTED BY TEAMS AND BUSINESSES</p><div>{siteContent.clients.map((client:string,index:number)=><span key={`${client}-${index}`}>{client}</span>)}</div></section>}
    <section className="category-section" aria-label="Product categories">
      <div className="category-intro"><p className="eyebrow">FIND YOUR STARTING POINT</p><h2>What are you<br/>looking to make?</h2></div>
      <div className="category-grid">{categories.map(item=><a className={`category-card ${item.tone}`} href="#enquire" key={item.number}><span className="category-number">{item.number}</span><span className="category-symbol">{item.symbol}</span><strong>{item.name}</strong><small>{item.detail}</small><span className="category-arrow">↗</span></a>)}</div>
    </section>
    <section className="section services-section" id="services">
      <div className="section-heading"><p className="eyebrow">WHAT WE DO</p><h2>Good ideas deserve<br/>great execution.</h2><p>Choose a service or bring us your idea. We help work out the right material, print method and finish for the job.</p><a className="section-cta" href="#enquire">Talk to us about your project ↗</a></div>
      <div className="service-grid">{services.map((service, index) => <article className="service-card" key={service.title}><span className="service-number">0{index + 1}</span><span className="service-tag">{service.tag}</span><h3>{service.title}</h3><p>{service.description}</p><a href="#enquire" aria-label={`Enquire about ${service.title}`}>Enquire <span>↗</span></a></article>)}</div>
    </section>
    <PublicCatalogue />
    <section className="bring-your-own"><div className="bring-icon">↗</div><div><p className="eyebrow">ALREADY HAVE THE ITEM?</p><h2>Bring it in. We’ll brand it.</h2><p>Have your own jersey, T-shirt, jacket, mug or other suitable item? Tell us what you have and what you want printed. We’ll review the material and the best way to customise it.</p></div><a href="#enquire">Print on my own item <span>↗</span></a></section>
    <PublicEnquiryForm />
    <section className="process-section" id="process"><div><p className="eyebrow">HOW IT WORKS</p><h2>From first idea<br/>to final finish.</h2><p className="process-intro">A straightforward process keeps your order clear from the first conversation to collection.</p></div><ol className="process-list"><li><span>01</span><div><strong>Tell us what you need</strong><p>Share the item, design, quantity, sizes, colours and your preferred deadline.</p></div></li><li><span>02</span><div><strong>We prepare your quote</strong><p>We review the artwork, materials, print positions and production method, then confirm the price.</p></div></li><li><span>03</span><div><strong>Approve and production begins</strong><p>Once the details and payment arrangements are confirmed, your job moves into production.</p></div></li><li><span>04</span><div><strong>Quality check and handover</strong><p>We confirm when your order is ready and arrange collection or delivery.</p></div></li></ol></section>
    {siteContent?.faq?.length > 0 && <section className="website-faq-section" id="faq"><div><p className="eyebrow">GOOD TO KNOW</p><h2>Frequently asked<br/>questions.</h2></div><div className="website-faq-list">{siteContent.faq.map((item:{question:string;answer:string},index:number)=><details key={`${item.question}-${index}`}><summary>{item.question}</summary><p>{item.answer}</p></details>)}</div></section>}
    <section className="portal-section" id="shop-access"><div><p className="eyebrow">BEHIND EVERY GOOD ORDER</p><h2>Organised from quote<br/>to production.</h2><p>Our private workspace keeps quotations, materials, purchasing and production connected so we can manage each job carefully.</p></div><button className="portal-status" onClick={onOwner}>Owner workspace ↗</button></section>
    <footer className="site-footer"><Brand footer logoSrc={logoSrc} /><p>{siteContent?.brand?.tagline || "Design. Print. Brand."}</p><span>{siteContent?.contact?.phone || ""} {siteContent?.contact?.email || "mjtees35@gmail.com"} · {siteContent?.contact?.address || ""}</span><div className="website-social-links">{Object.entries(siteContent?.social || {}).filter(([,url])=>typeof url==="string"&&url.trim()).map(([network,url])=><a key={network} href={url as string} target="_blank" rel="noreferrer">{network==="x"?"X":network[0].toUpperCase()+network.slice(1)}</a>)}{siteContent?.contact?.whatsapp && <a href={"https://wa.me/"+String(siteContent.contact.whatsapp).replace(/\D/g,"")} target="_blank" rel="noreferrer">WhatsApp</a>}</div><span>© {new Date().getFullYear()} {siteContent?.brand?.legalName || "MJ Printing & Branding"}</span></footer>
  </main>;
}

function App() {
  const [view, setView] = useState<"website" | "owner">("website");
  const acceptanceToken = new URLSearchParams(window.location.search).get("accept_quote");
  if (acceptanceToken) return <QuoteAcceptance token={acceptanceToken} />;
  return view === "owner" ? <OwnerApp onExit={() => setView("website")} /> : <Website onOwner={() => setView("owner")} />;
}
export default App;
