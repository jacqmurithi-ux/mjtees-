import { useCallback, useEffect, useState } from "react";
import { supabase } from "./lib/supabase";

type SizeRow = { id:string; person_name:string; jersey_number:string|null; size:string; colour:string|null; quantity:number; notes:string|null; created_at:string };
type ArtworkRow = { id:string; storage_path:string; file_name:string; version:number; proof_status:string; sent_at:string|null; approved_at:string|null; notes:string|null; created_at:string };
type SeparationRow = { id:string; artwork_id:string|null; colour_name:string; ink_reference:string|null; screen_reference:string|null; print_location:string; sequence_no:number; notes:string|null };

const requestId=()=>crypto.randomUUID();

export default function CustomOrderDetails({businessId,jobId}:{businessId:string;jobId:string}) {
 const [sizes,setSizes]=useState<SizeRow[]>([]);
 const [artworks,setArtworks]=useState<ArtworkRow[]>([]);
 const [separations,setSeparations]=useState<SeparationRow[]>([]);
 const [personName,setPersonName]=useState("");
 const [jerseyNumber,setJerseyNumber]=useState("");
 const [size,setSize]=useState("M");
 const [colour,setColour]=useState("");
 const [quantity,setQuantity]=useState("1");
 const [sizeNotes,setSizeNotes]=useState("");
 const [driveLink,setDriveLink]=useState("");
 const [fileName,setFileName]=useState("");
 const [artworkNotes,setArtworkNotes]=useState("");
 const [artworkId,setArtworkId]=useState("");
 const [colourName,setColourName]=useState("");
 const [inkReference,setInkReference]=useState("");
 const [screenReference,setScreenReference]=useState("");
 const [printLocation,setPrintLocation]=useState("front");
 const [sequenceNo,setSequenceNo]=useState("1");
 const [separationNotes,setSeparationNotes]=useState("");
 const [busy,setBusy]=useState(false);
 const [error,setError]=useState("");
 const [notice,setNotice]=useState("");

 const load=useCallback(async()=>{
  if(!supabase)return;
  const [s,a,c]=await Promise.all([
   supabase.from("sales_job_size_breakdown").select("id,person_name,jersey_number,size,colour,quantity,notes,created_at").eq("business_id",businessId).eq("job_id",jobId).order("created_at",{ascending:true}),
   supabase.from("sales_job_artworks").select("id,storage_path,file_name,version,proof_status,sent_at,approved_at,notes,created_at").eq("business_id",businessId).eq("job_id",jobId).order("version",{ascending:false}),
   supabase.from("sales_job_colour_separations").select("id,artwork_id,colour_name,ink_reference,screen_reference,print_location,sequence_no,notes").eq("business_id",businessId).eq("job_id",jobId).order("sequence_no",{ascending:true})
  ]);
  const failure=s.error||a.error||c.error;
  if(failure)throw failure;
  setSizes((s.data??[]) as SizeRow[]);
  setArtworks((a.data??[]) as ArtworkRow[]);
  setSeparations((c.data??[]) as SeparationRow[]);
  if(!artworkId&&a.data?.[0])setArtworkId(a.data[0].id);
 },[businessId,jobId,artworkId]);

 useEffect(()=>{void load().catch(e=>setError(e instanceof Error?e.message:"Could not load custom order details."));},[load]);

 const run=async(name:string,args:Record<string,unknown>,message:string)=>{
  if(!supabase)return;
  setBusy(true);setError("");setNotice("");
  const {error:rpcError}=await supabase.rpc(name,args);
  if(rpcError)setError(rpcError.message);
  else{setNotice(message);await load();}
  setBusy(false);
 };

 const addSize=async(e:React.FormEvent)=>{
  e.preventDefault();
  if(!personName.trim()||!size.trim()||!Number.isFinite(Number(quantity))||Number(quantity)<=0){setError("Enter the wearer name, size and a positive quantity.");return;}
  await run("owner_add_job_size_breakdown",{
   p_job_id:jobId,p_person_name:personName.trim(),p_jersey_number:jerseyNumber.trim()||null,
   p_size:size.trim(),p_colour:colour.trim()||null,p_quantity:Number(quantity),
   p_notes:sizeNotes.trim()||null,p_request_id:requestId()
  },"Garment size entry saved.");
  setPersonName("");setJerseyNumber("");setColour("");setQuantity("1");setSizeNotes("");
 };

 const addArtwork=async(e:React.FormEvent)=>{
  e.preventDefault();
  if(!/^https:\/\/(drive|docs)\.google\.com\//i.test(driveLink.trim())||!fileName.trim()){setError("Enter a Google Drive link and the artwork file name.");return;}
  await run("owner_add_job_artwork",{
   p_job_id:jobId,p_storage_path:driveLink.trim(),p_file_name:fileName.trim(),
   p_notes:artworkNotes.trim()||null,p_request_id:requestId()
  },"New artwork proof version recorded.");
  setDriveLink("");setFileName("");setArtworkNotes("");
 };

 const setProofStatus=(artwork:ArtworkRow,status:"sent"|"approved"|"rejected")=>void run(
  "owner_set_job_artwork_status",
  {p_artwork_id:artwork.id,p_proof_status:status,p_approved_by_contact_id:null,
   p_notes:null,p_request_id:requestId()},
  status==="sent"?"Proof marked as sent.":status==="approved"?"Customer proof approval recorded.":"Proof rejection recorded."
 );

 const addSeparation=async(e:React.FormEvent)=>{
  e.preventDefault();
  if(!colourName.trim()||!Number.isInteger(Number(sequenceNo))||Number(sequenceNo)<1){setError("Enter a colour name and valid separation sequence.");return;}
  await run("owner_add_job_colour_separation",{
   p_job_id:jobId,p_artwork_id:artworkId||null,p_colour_name:colourName.trim(),
   p_ink_reference:inkReference.trim()||null,p_screen_reference:screenReference.trim()||null,
   p_print_location:printLocation,p_sequence_no:Number(sequenceNo),
   p_notes:separationNotes.trim()||null,p_request_id:requestId()
  },"Colour separation saved.");
  setColourName("");setInkReference("");setScreenReference("");setSeparationNotes("");
 };

 return <section className="connected-panel custom-order-details">
  <div className="panel-toolbar"><div><b>Custom order details</b><small>Garment allocation, Google Drive artwork proofs and print separations</small></div><button type="button" className="secondary-action" onClick={()=>void load()}>Refresh</button></div>
  {error&&<div className="notice error">{error}</div>}{notice&&<div className="notice success">{notice}</div>}
  <section className="production-line">
   <b>Individual garment / player sizes</b>
   <p className="small-note">Allocated quantity: {sizes.reduce((sum,row)=>sum+Number(row.quantity),0)} · Entries: {sizes.length}</p>
   <form className="inline-controls" onSubmit={addSize}>
    <label>Person / player<input maxLength={180} required value={personName} onChange={e=>setPersonName(e.target.value)} placeholder="Name"/></label>
    <label>Jersey number<input maxLength={40} value={jerseyNumber} onChange={e=>setJerseyNumber(e.target.value)} placeholder="Optional"/></label>
    <label>Size<input maxLength={40} required value={size} onChange={e=>setSize(e.target.value)} placeholder="XS, S, M, L, XL"/></label>
    <label>Colour<input maxLength={80} value={colour} onChange={e=>setColour(e.target.value)} placeholder="Optional"/></label>
    <label>Qty<input type="number" min="0.001" step="0.001" required value={quantity} onChange={e=>setQuantity(e.target.value)}/></label>
    <label>Notes<input maxLength={1000} value={sizeNotes} onChange={e=>setSizeNotes(e.target.value)} placeholder="Optional"/></label>
    <button className="primary-action compact" disabled={busy}>Add size</button>
   </form>
   <div className="record-list">{sizes.map(row=><div className="record-row" key={row.id}><div><b>{row.person_name}{row.jersey_number?" · #"+row.jersey_number:""} · {row.size}</b><small>{row.quantity} · {row.colour||"Colour not specified"}{row.notes?" · "+row.notes:""}</small></div></div>)}{!sizes.length&&<p className="empty-records">No individual sizes recorded for this job.</p>}</div>
  </section>
  <section className="production-line">
   <b>Artwork and customer proof history</b>
   <p className="small-note">Artwork stays in Google Drive. The system stores the link, file name, proof version and approval history; it does not upload artwork files.</p>
   <form className="inline-controls" onSubmit={addArtwork}>
    <label>Google Drive link<input type="url" required value={driveLink} onChange={e=>setDriveLink(e.target.value)} placeholder="https://drive.google.com/..."/></label>
    <label>File name<input maxLength={255} required value={fileName} onChange={e=>setFileName(e.target.value)} placeholder="Artwork-proof-v1.png"/></label>
    <label>Notes<input maxLength={1000} value={artworkNotes} onChange={e=>setArtworkNotes(e.target.value)} placeholder="Design changes / revision notes"/></label>
    <button className="primary-action compact" disabled={busy}>Add proof version</button>
   </form>
   <div className="record-list">{artworks.map(art=><div className="record-row" key={art.id}><div><b>Version {art.version} · {art.file_name}</b><small>{art.proof_status.replaceAll("_"," ")}{art.sent_at?" · Sent "+new Date(art.sent_at).toLocaleString("en-KE"):""}{art.approved_at?" · Approved "+new Date(art.approved_at).toLocaleString("en-KE"):""}{art.notes?" · "+art.notes:""}</small><a href={art.storage_path} target="_blank" rel="noreferrer">Open artwork in Google Drive ↗</a></div><div className="quote-total">{art.proof_status==="pending"&&<button type="button" className="secondary-action" disabled={busy} onClick={()=>setProofStatus(art,"sent")}>Mark sent</button>}{art.proof_status==="sent"&&<><button type="button" className="primary-action compact" disabled={busy} onClick={()=>setProofStatus(art,"approved")}>Approve</button><button type="button" className="secondary-action" disabled={busy} onClick={()=>setProofStatus(art,"rejected")}>Reject</button></>}</div></div>)}{!artworks.length&&<p className="empty-records">No artwork proofs recorded.</p>}</div>
  </section>
  <section className="production-line">
   <b>Colour separations / screen setup</b>
   <form className="inline-controls" onSubmit={addSeparation}>
    <label>Artwork version<select value={artworkId} onChange={e=>setArtworkId(e.target.value)}><option value="">Not linked</option>{artworks.map(art=><option key={art.id} value={art.id}>Version {art.version} · {art.file_name}</option>)}</select></label>
    <label>Colour<input required maxLength={100} value={colourName} onChange={e=>setColourName(e.target.value)} placeholder="White / Red / Black"/></label>
    <label>Ink reference<input maxLength={100} value={inkReference} onChange={e=>setInkReference(e.target.value)} placeholder="Ink / mix reference"/></label>
    <label>Screen reference<input maxLength={100} value={screenReference} onChange={e=>setScreenReference(e.target.value)} placeholder="Screen number"/></label>
    <label>Print position<select value={printLocation} onChange={e=>setPrintLocation(e.target.value)}>{[["front","Front"],["back","Back"],["left_sleeve","Left sleeve"],["right_sleeve","Right sleeve"],["cap_front","Cap front"],["mug_wrap","Mug wrap"],["other","Other"]].map(([v,l])=><option key={v} value={v}>{l}</option>)}</select></label>
    <label>Sequence<input type="number" min="1" step="1" required value={sequenceNo} onChange={e=>setSequenceNo(e.target.value)}/></label>
    <label>Notes<input maxLength={1000} value={separationNotes} onChange={e=>setSeparationNotes(e.target.value)}/></label>
    <button className="primary-action compact" disabled={busy}>Add separation</button>
   </form>
   <div className="record-list">{separations.map(row=><div className="record-row" key={row.id}><div><b>{row.sequence_no}. {row.colour_name} · {row.print_location.replaceAll("_"," ")}</b><small>{row.ink_reference||"Ink not specified"} · {row.screen_reference||"Screen not specified"}{row.notes?" · "+row.notes:""}</small></div></div>)}{!separations.length&&<p className="empty-records">No colour separations recorded.</p>}</div>
  </section>
 </section>;
}
