import { useCallback, useEffect, useState } from "react";
import type { FormEvent } from "react";
import { supabase } from "./lib/supabase";
import VinylStickerCalculator from "./VinylStickerCalculator";

type Category = { id: string; name: string };
type ProductionMethod = { id: string; name: string; code: string };
type StockLocation = { id:string; name:string; code:string };
type StockItem = { id: string; sku: string; name: string; base_unit: string; stock_kind:string; is_active: boolean; current_average_unit_cost:number; roll_width_mm:number|null; usable_width_mm:number|null };
type CatalogueItem = {id:string;name:string;category_id:string|null;item_type:"product"|"service"};
type CostComponentForm = { componentType:string; stockItemId:string; unit:string; driverType:string; factor:string; waste:string; fixedCost:string };
type Customer = { id: string; display_name: string };
type Quote = { id: string; quote_number: string; customer_id: string; status: string; revision_of: string | null; subtotal_amount: number; discount_amount: number; total_amount: number; created_at: string; expires_at: string | null };
type Order = { id: string; order_number: string; customer_id: string; status: string; total_amount: number; received_at: string; required_by: string | null; promised_turnaround_hours: number | null };
type SalesInvoice = { id: string; quotation_id: string | null; invoice_number: string; status: string };
const rid = () => crypto.randomUUID();
const kes = (n: number) => new Intl.NumberFormat("en-KE", { style: "currency", currency: "KES", maximumFractionDigits: 0 }).format(n);

export default function QuoteWorkflow({ businessId, customers, enquiries, onChanged }: {
  businessId: string; customers: Customer[]; enquiries: {id:string;public_reference:string;contact_name:string;status:string}[]; onChanged:()=>void;
}) {
  const [categories,setCategories]=useState<Category[]>([]);
  const [productionMethods,setProductionMethods]=useState<ProductionMethod[]>([]);
  const [stockItems,setStockItems]=useState<StockItem[]>([]);
  const [stockLocations,setStockLocations]=useState<StockLocation[]>([]);
  const [stockLocationId,setStockLocationId]=useState("");
  const [catalogueItems,setCatalogueItems]=useState<CatalogueItem[]>([]);
  const [quotes,setQuotes]=useState<Quote[]>([]);
  const [orders,setOrders]=useState<Order[]>([]);
  const [salesInvoices,setSalesInvoices]=useState<SalesInvoice[]>([]);
  const [tab,setTab]=useState<"quotes"|"costing"|"orders"|"vinyl">("quotes");
  const [busy,setBusy]=useState(false);
  const [error,setError]=useState("");
  const [notice,setNotice]=useState("");
  const [customerId,setCustomerId]=useState("");
  const [revisionOf,setRevisionOf]=useState<string|null>(null);
  const [enquiryId,setEnquiryId]=useState("");
  const [quoteLines,setQuoteLines]=useState([{catalogueItemId:"",categoryId:"",description:"",quantity:"1",unit:"piece",unitPrice:"",discount:"0",customerSupplies:false,stockItemId:"",saleMode:"value_added",productionMethodId:"",linearMetres:"",areaSquareMetres:"",machineMinutes:"",labourHours:"",stickerSpecification:{} as Record<string,unknown>}]);
  const [quoteExpiry,setQuoteExpiry]=useState("");
  const [customerNotes,setCustomerNotes]=useState("");
  const [internalNotes,setInternalNotes]=useState("");
  const [marginExceptionReasons,setMarginExceptionReasons]=useState<Record<string,string>>({});
  const [costCategory,setCostCategory]=useState("");
  const [costCatalogueItemId,setCostCatalogueItemId]=useState("");
  const [pricingCategory,setPricingCategory]=useState("");
  const [costComponents,setCostComponents]=useState<CostComponentForm[]>([{componentType:"other",stockItemId:"",unit:"job",driverType:"per_order",factor:"1",waste:"0",fixedCost:"0"}]);
  const [costSaleMode,setCostSaleMode]=useState("value_added");
  const [costProductionMethodId,setCostProductionMethodId]=useState("");
  const [markupMethod,setMarkupMethod]=useState("percentage_on_cost");
  const [markupValue,setMarkupValue]=useState("50");
  const [acceptanceLink,setAcceptanceLink]=useState("");

  const load=useCallback(async()=>{
    if(!supabase)return;
    const [cat,q,o,stock,catalogue,methods,invoices,locations]=await Promise.all([
      supabase.from("service_categories").select("id,name").eq("business_id",businessId).eq("is_active",true).order("name"),
      supabase.from("quotations").select("id,quote_number,customer_id,status,revision_of,subtotal_amount,discount_amount,total_amount,created_at,expires_at").eq("business_id",businessId).order("created_at",{ascending:false}).limit(100),
      supabase.from("orders").select("id,order_number,customer_id,status,total_amount,received_at,required_by,promised_turnaround_hours").eq("business_id",businessId).order("received_at",{ascending:false}).limit(100),
      supabase.from("stock_items").select("id,sku,name,base_unit,stock_kind,is_active,current_average_unit_cost,roll_width_mm,usable_width_mm").eq("business_id",businessId).eq("is_active",true).order("name").limit(500),
      supabase.from("catalogue_items").select("id,name,category_id,item_type").eq("business_id",businessId).eq("is_active",true).order("name").limit(500),
      supabase.from("production_methods").select("id,name,code").eq("is_active",true).order("name"),
      supabase.from("sales_invoices").select("id,quotation_id,invoice_number,status").eq("business_id",businessId).order("issue_date",{ascending:false}).limit(200),
      supabase.from("inventory_locations").select("id,name,code").eq("business_id",businessId).eq("is_active",true).order("name")
    ]);
    if(cat.error||q.error||o.error||stock.error||catalogue.error||methods.error||invoices.error||locations.error)throw cat.error||q.error||o.error||stock.error||catalogue.error||methods.error||invoices.error||locations.error;
    setCategories(cat.data??[]);setStockLocations((locations.data??[]) as StockLocation[]);setStockLocationId(current=>current&&locations.data?.some(location=>location.id===current)?current:(locations.data?.[0]?.id??""));setProductionMethods((methods.data??[]) as ProductionMethod[]);setStockItems((stock.data??[]) as StockItem[]);setCatalogueItems((catalogue.data??[]) as CatalogueItem[]);setQuotes((q.data??[]) as Quote[]);setOrders((o.data??[]) as Order[]);setSalesInvoices((invoices.data??[]) as SalesInvoice[]);
  },[businessId]);
  useEffect(()=>{void load().catch(e=>setError(e.message));},[load]);

  useEffect(()=>{
    if(!supabase)return;
    const channel=supabase.channel("quote-workflow-"+businessId)
      .on("postgres_changes",{event:"*",schema:"public",table:"quotations",filter:"business_id=eq."+businessId},()=>{void load();})
      .on("postgres_changes",{event:"*",schema:"public",table:"orders",filter:"business_id=eq."+businessId},()=>{void load();})
      .on("postgres_changes",{event:"*",schema:"public",table:"sales_invoices",filter:"business_id=eq."+businessId},()=>{void load();})
      .subscribe();
    return ()=>{void supabase.removeChannel(channel);};
  },[businessId,load]);

  async function createCostProfile(e:FormEvent){
    e.preventDefault();if(!supabase)return;
    const stockTypes=["blank_item","meter_material","area_material","consumable","packaging"];
    if((!costCatalogueItemId&&!costCategory)||!costComponents.length||costComponents.some(x=>!x.unit.trim()||!Number.isFinite(Number(x.factor))||Number(x.factor)<0||!Number.isFinite(Number(x.waste))||Number(x.waste)<0||Number(x.waste)>100||!Number.isSafeInteger(Number(x.fixedCost))||Number(x.fixedCost)<0||(stockTypes.includes(x.componentType)&&!stockItems.some(item=>item.id===x.stockItemId&&(x.componentType!=="blank_item"||item.stock_kind==="blank_product")) ))){
      setError("Choose a catalogue item or category and complete each costing component. Stock-linked materials need a stock item; costs and waste must be valid.");return;
    }
    setBusy(true);setError("");setNotice("");
    const {data,error:rpcError}=await supabase.rpc("owner_create_costing_profile",{
      p_business_id:businessId,p_catalogue_item_id:costCatalogueItemId||null,p_category_id:costCatalogueItemId?null:costCategory,p_sale_mode:costSaleMode,
      p_production_method_id:costProductionMethodId||null,
      p_components:costComponents.map(x=>({component_type:x.componentType,stock_item_id:x.stockItemId||null,unit:x.unit.trim(),
        driver_type:x.driverType,factor:Number(x.factor),expected_waste_percent:Number(x.waste),fixed_cost:Number(x.fixedCost)})),
      p_request_id:rid()
    });
    if(rpcError)setError(rpcError.message);
    else {setNotice("Costing profile v"+data.version+" saved with "+data.component_count+" components. Earlier versions remain in history.");setCostCatalogueItemId("");setCostCategory("");setCostProductionMethodId("");setCostComponents([{componentType:"other",stockItemId:"",unit:"job",driverType:"per_order",factor:"1",waste:"0",fixedCost:"0"}]);await load();onChanged();}
    setBusy(false);
  }
  function prepareScreenPrintingCostProfile(){
    const category=categories.find(item=>item.name.toLowerCase()==="screen printing");
    const method=productionMethods.find(item=>item.code==="screen_printing");
    if(!category||!method){setError("Screen Printing category or production method is not configured. Check the catalogue setup.");return;}
    setCostCatalogueItemId("");setCostCategory(category.id);setCostSaleMode("value_added");setCostProductionMethodId(method.id);
    setCostComponents([{componentType:"outsourced_service",stockItemId:"",unit:"job",driverType:"per_order",factor:"1",waste:"0",fixedCost:"200"}]);
    setTab("costing");setError("");setNotice("Screen-printing service profile prepared: KES 200 outsourced labour per order. Confirm or edit the actual cost, then save a new version before pricing.");
  }
  async function savePricingRule(e:FormEvent){
    e.preventDefault();if(!supabase)return;
    if(!pricingCategory||!markupValue||Number(markupValue)<0||(markupMethod==="margin_on_price"&&Number(markupValue)>=100)){setError("Choose a category and enter a valid markup. Margin must be below 100%.");return;}
    setBusy(true);setError("");setNotice("");
    const {error:rpcError}=await supabase.rpc("owner_upsert_pricing_rule",{
      p_business_id:businessId,p_rule_id:null,p_category_id:pricingCategory,p_catalogue_item_id:null,
      p_name:"Category pricing · "+(categories.find(x=>x.id===pricingCategory)?.name||"Service"),
      p_markup_method:markupMethod,p_markup_value:Number(markupValue),p_effective_from:new Date().toISOString().slice(0,10),
      p_effective_to:null,p_is_active:true,p_request_id:rid()
    });
    if(rpcError)setError(rpcError.message);else setNotice("Cost-based pricing recommendation saved. You can still negotiate and enter each final agreed order price.");
    setBusy(false);
  }
  async function createQuote(e:FormEvent){
    e.preventDefault();if(!supabase)return;
    if(!customerId||!quoteLines.length||quoteLines.some(line=>!line.categoryId||!line.description.trim()||!Number.isFinite(Number(line.quantity))||Number(line.quantity)<=0||(line.unitPrice.trim()!==""&&(!Number.isSafeInteger(Number(line.unitPrice))||Number(line.unitPrice)<0))||(line.stickerSpecification?.type==="vinyl_sticker"&&line.unitPrice.trim()!==""&&(Number(line.unitPrice)<Number(line.stickerSpecification.minimum_price)||Number(line.unitPrice)>Number(line.stickerSpecification.ceiling_price)))||!Number.isSafeInteger(Number(line.discount))||Number(line.discount)<0||(line.saleMode==="blank"&&!line.customerSupplies&&!line.stockItemId)||(line.saleMode==="value_added"&&catalogueItems.find(item=>item.id===line.catalogueItemId)?.item_type==="product"&&!line.productionMethodId))){
      setError("Complete the customer and every quotation line with a category, description, positive quantity and valid whole-KES price/discount.");return;
    }
    setBusy(true);setError("");setNotice("");
    const lines=quoteLines.map(line=>({catalogue_item_id:line.catalogueItemId||null,category_id:line.categoryId,stock_item_id:line.customerSupplies?null:(line.stockItemId||null),description:line.description.trim(),
      quantity:Number(line.quantity),unit:line.unit,unit_price:line.unitPrice.trim()?Number(line.unitPrice):null,line_discount:Number(line.discount),
      sale_mode:line.saleMode,customer_supplies_item:line.customerSupplies,production_method_id:line.saleMode==="blank"?null:(line.productionMethodId||null),production_specification:{...line.stickerSpecification,linear_metres:line.linearMetres.trim()?Number(line.linearMetres):null,area_square_metres:line.areaSquareMetres.trim()?Number(line.areaSquareMetres):null,machine_minutes:line.machineMinutes.trim()?Number(line.machineMinutes):null,labour_hours:line.labourHours.trim()?Number(line.labourHours):null}}));
    const {data,error:rpcError}=revisionOf
      ? await supabase.rpc("owner_create_quotation_revision",{
          p_original_quotation_id:revisionOf,p_lines:lines,
          p_expires_at:quoteExpiry?new Date(quoteExpiry+"T23:59:59").toISOString():null,
          p_customer_notes:customerNotes.trim()||null,p_internal_notes:internalNotes.trim()||null,p_request_id:rid()
        })
      : await supabase.rpc("owner_create_quotation",{
          p_business_id:businessId,p_customer_id:customerId,p_enquiry_id:enquiryId||null,p_lines:lines,
          p_expires_at:quoteExpiry?new Date(quoteExpiry+"T23:59:59").toISOString():null,
          p_customer_notes:customerNotes.trim()||null,p_internal_notes:internalNotes.trim()||null,p_request_id:rid()
        });
    if(rpcError)setError(rpcError.message);
    else {setNotice((revisionOf?"Quotation revision ":"Quotation ")+data.quote_number+" created as draft. Total "+kes(Number(data.total_amount))+".");setRevisionOf(null);setQuoteLines([{catalogueItemId:"",categoryId:"",description:"",quantity:"1",unit:"piece",unitPrice:"",discount:"0",customerSupplies:false,stockItemId:"",saleMode:"value_added",productionMethodId:"",linearMetres:"",areaSquareMetres:"",machineMinutes:"",labourHours:"",stickerSpecification:{}}]);setCustomerNotes("");setInternalNotes("");setEnquiryId("");await load();onChanged();}
    setBusy(false);
  }
  async function issueInvoice(q:Quote){
    if(!supabase)return;
    setBusy(true);setError("");setNotice("");
    const args={
      p_business_id:businessId,p_quotation_id:q.id,p_payment_terms:"due_on_receipt",
      p_due_date:null,p_stock_location_id:stockLocationId||null,p_allow_oversell:false,
      p_oversell_reason:null,p_request_id:rid()
    };
    let result=await supabase.rpc("owner_convert_accepted_quote_to_invoice",args);
    if(result.error&&/stock|inventory|available/i.test(result.error.message)){
      const proceed=window.confirm("The available shop stock may be insufficient. Do you want to proceed with an owner-authorised stock override?");
      if(proceed){
        const reason=window.prompt("Record the reason for issuing this invoice despite the stock shortage:");
        if(reason?.trim()){
          result=await supabase.rpc("owner_convert_accepted_quote_to_invoice",{
            ...args,p_allow_oversell:true,p_oversell_reason:reason.trim(),p_request_id:rid()
          });
        }
      }
    }
    if(result.error)setError(result.error.message);
    else{
      setNotice("Invoice "+result.data.invoice_number+" issued from "+q.quote_number+".");
      await load();onChanged();
    }
    setBusy(false);
  }
  async function updateSchedule(orderId:string, form:FormData){
    if(!supabase)return;
    const requiredBy=String(form.get("required_by")||"");
    const hoursRaw=String(form.get("promised_turnaround_hours")||"");
    const hours=hoursRaw?Number(hoursRaw):null;
    if(hours!==null&&(!Number.isInteger(hours)||hours<1||hours>8760)){setError("Turnaround hours must be between 1 and 8,760.");return;}
    setBusy(true);setError("");setNotice("");
    const {error:rpcError}=await supabase.rpc("owner_update_order_schedule",{
      p_order_id:orderId,p_required_by:requiredBy||null,p_promised_turnaround_hours:hours,p_request_id:rid()
    });
    if(rpcError)setError(rpcError.message);else{setNotice("Order turnaround schedule saved.");await load();}
    setBusy(false);
  }
  async function startRevision(q:Quote){
    if(!supabase)return;
    setBusy(true);setError("");setNotice("");
    const {data,error:readError}=await supabase.from("quotation_items")
      .select("catalogue_item_id,description,quantity,unit,unit_price,line_discount,category_id,customer_supplies_item,stock_item_id,sale_mode,production_method_id,production_specification")
      .eq("business_id",businessId).eq("quotation_id",q.id).order("created_at",{ascending:true}).order("id",{ascending:true});
    if(readError||!data?.length){setError(readError?.message||"Could not load the quotation lines.");setBusy(false);return;}
    setCustomerId(q.customer_id);setEnquiryId("");setQuoteLines(data.map(line=>({catalogueItemId:line.catalogue_item_id||"",categoryId:line.category_id||"",description:line.description,
      quantity:String(line.quantity),unit:line.unit,unitPrice:line.unit_price==null?"":String(line.unit_price),discount:String(line.line_discount),
      customerSupplies:Boolean(line.customer_supplies_item),stockItemId:line.stock_item_id||"",saleMode:line.sale_mode||"value_added",productionMethodId:line.production_method_id||"",linearMetres:line.production_specification?.linear_metres==null?"":String(line.production_specification.linear_metres),areaSquareMetres:line.production_specification?.area_square_metres==null?"":String(line.production_specification.area_square_metres),machineMinutes:line.production_specification?.machine_minutes==null?"":String(line.production_specification.machine_minutes),labourHours:line.production_specification?.labour_hours==null?"":String(line.production_specification.labour_hours),stickerSpecification:(line.production_specification&&typeof line.production_specification==="object"?line.production_specification:{}) as Record<string,unknown>})));setQuoteExpiry(q.expires_at?q.expires_at.slice(0,10):"");
    setRevisionOf(q.id);setTab("quotes");setNotice("Revision form loaded from "+q.quote_number+". Update the details and save the new version.");
    setBusy(false);
  }
  async function sendQuote(q:Quote){
    if(!supabase)return;
    setBusy(true);setError("");setNotice("");
    const {data,error:rpcError}=await supabase.rpc("owner_send_quotation",{p_quotation_id:q.id,p_expires_at:q.expires_at,p_request_id:rid(),p_margin_exception_reason:marginExceptionReasons[q.id]?.trim()||null});
    if(rpcError)setError(rpcError.message);
    else {const link=window.location.origin+window.location.pathname+"?accept_quote="+encodeURIComponent(data.acceptance_token);setAcceptanceLink(link);setMarginExceptionReasons(v=>({...v,[q.id]:""}));setNotice("Quotation "+data.quote_number+" marked sent. Share the secure acceptance link with the customer.");}
    await load();setBusy(false);
  }
  const customerName=(id:string)=>customers.find(c=>c.id===id)?.display_name??"Customer";
  return <section className="connected-panel quote-workflow">
    <div className="panel-toolbar"><div><h2>Quotations and orders</h2><p>Live records and costing tools. Prices are in KES; tax is excluded.</p></div><button className="secondary-action" onClick={()=>void load()}>Refresh records</button></div>
    <div className="stock-location-picker"><label>Stock location for blank-garment sales<select value={stockLocationId} onChange={event=>setStockLocationId(event.target.value)}><option value="">Choose stock location</option>{stockLocations.map(location=><option key={location.id} value={location.id}>{location.name} · {location.code}</option>)}</select></label><small>Required only when an invoice issues MJ Tees stock. Customer-supplied items do not use shop stock.</small></div>
    <div className="workflow-tabs"><button className={tab==="quotes"?"active":""} onClick={()=>setTab("quotes")}>Quotations</button><button className={tab==="costing"?"active":""} onClick={()=>setTab("costing")}>Costing profiles</button><button className={tab==="orders"?"active":""} onClick={()=>setTab("orders")}>Orders</button><button className={tab==="vinyl"?"active":""} onClick={()=>setTab("vinyl")}>Vinyl calculator</button></div>
    {error&&<div className="notice error">{error}</div>}{notice&&<div className="notice success">{notice}</div>}{acceptanceLink&&<div className="acceptance-link"><input readOnly value={acceptanceLink}/><button className="secondary-action" onClick={()=>void navigator.clipboard.writeText(acceptanceLink)}>Copy customer link</button></div>}
    {tab==="vinyl"&&<VinylStickerCalculator businessId={businessId} stockItems={stockItems} categories={categories} methods={productionMethods} onMessage={(message,isError)=>{setNotice(isError?"":message);setError(isError?message:"");}} onApply={line=>{setQuoteLines(v=>{const blank=v.length===1&&!v[0].description.trim()&&!v[0].categoryId;const next={...v[0],catalogueItemId:"",categoryId:line.categoryId,description:line.description,quantity:line.quantity,unit:"piece",unitPrice:line.unitPrice,discount:"0",customerSupplies:false,stockItemId:"",saleMode:"value_added",productionMethodId:line.productionMethodId,linearMetres:line.linearMetres,areaSquareMetres:"",machineMinutes:line.machineMinutes,labourHours:line.labourHours,stickerSpecification:line.specification};return blank?[next]:[...v,next];});setTab("quotes");setNotice("Vinyl sticker price and production specification added to the quotation. Inventory will be deducted when material is issued to its production job.");}}/>}
    {tab==="quotes"&&<><div className="handover-panel"><b>Customer-supplied printing service</b><p>For Baraka Uniform's example, prepare the Screen Printing costing profile first. Record the garments as customer-supplied, price only the printing service, and keep outsourced labour in production cost—not on the customer quotation.</p><button type="button" className="secondary-action" onClick={prepareScreenPrintingCostProfile}>Set up screen-printing costing</button></div><form className="record-form" onSubmit={createQuote}>
      <h3 className="wide-field">{revisionOf?"Create quotation revision":"Create quotation"}</h3>
      <label>Customer *<select required value={customerId} onChange={e=>setCustomerId(e.target.value)}><option value="">Choose customer</option>{customers.map(c=><option key={c.id} value={c.id}>{c.display_name}</option>)}</select></label>
      <label>Related enquiry<select value={enquiryId} onChange={e=>setEnquiryId(e.target.value)}><option value="">No linked enquiry</option>{enquiries.filter(x=>x.status!=="spam").map(x=><option key={x.id} value={x.id}>{x.public_reference} · {x.contact_name}</option>)}</select></label>
      <div className="wide-field"><b>Quotation items</b>{quoteLines.map((line,index)=><div className="quote-line-editor" key={index}>
        <label>Catalogue item<select value={line.catalogueItemId} onChange={e=>{const item=catalogueItems.find(x=>x.id===e.target.value);setQuoteLines(v=>v.map((x,i)=>i===index?{...x,catalogueItemId:e.target.value,categoryId:item?.category_id||x.categoryId,description:item?.name||x.description}:x));}}><option value="">Custom / not listed</option>{catalogueItems.map(item=><option key={item.id} value={item.id}>{item.name} · {item.item_type}</option>)}</select></label>
        <label>Service category *<select required value={line.categoryId} onChange={e=>setQuoteLines(v=>v.map((x,i)=>i===index?{...x,categoryId:e.target.value}:x))}><option value="">Choose category</option>{categories.map(cat=><option key={cat.id} value={cat.id}>{cat.name}</option>)}</select></label>
        <label>Description *<input required maxLength={240} value={line.description} onChange={e=>setQuoteLines(v=>v.map((x,i)=>i===index?{...x,description:e.target.value}:x))} placeholder="e.g. 20 branded T-shirts"/></label>
        <label>School / institution (bulk printing)<input maxLength={180} value={String(line.stickerSpecification.contract_school_name??"")} onChange={e=>setQuoteLines(v=>v.map((x,i)=>i===index?{...x,stickerSpecification:{...x.stickerSpecification,contract_school_name:e.target.value}}:x))} placeholder="e.g. Ngenia Senior School"/></label>
        <label>Garment type<input maxLength={100} value={String(line.stickerSpecification.garment_type??"")} onChange={e=>setQuoteLines(v=>v.map((x,i)=>i===index?{...x,stickerSpecification:{...x.stickerSpecification,garment_type:e.target.value}}:x))} placeholder="e.g. T-shirt / tracksuit"/></label>
        <label>Print position<input maxLength={80} value={String(line.stickerSpecification.print_position??"")} onChange={e=>setQuoteLines(v=>v.map((x,i)=>i===index?{...x,stickerSpecification:{...x.stickerSpecification,print_position:e.target.value}}:x))} placeholder="e.g. Front"/></label>
        <label>Quantity *<input required type="number" min="0.001" step="0.001" value={line.quantity} onChange={e=>setQuoteLines(v=>v.map((x,i)=>i===index?{...x,quantity:e.target.value}:x))}/></label>
        <label>Unit<input required maxLength={24} value={line.unit} onChange={e=>setQuoteLines(v=>v.map((x,i)=>i===index?{...x,unit:e.target.value}:x))}/></label>
        <label>Final agreed unit selling price (KES)<input type="number" min="0" step="1" value={line.unitPrice} onChange={e=>setQuoteLines(v=>v.map((x,i)=>i===index?{...x,unitPrice:e.target.value}:x))} placeholder="Leave blank for cost-based suggested price"/></label>
        <label>Line discount (KES)<input type="number" min="0" step="1" value={line.discount} onChange={e=>setQuoteLines(v=>v.map((x,i)=>i===index?{...x,discount:e.target.value}:x))}/></label>
        <label>Sale type<select value={line.saleMode} onChange={e=>setQuoteLines(v=>v.map((x,i)=>i===index?{...x,saleMode:e.target.value,productionMethodId:e.target.value==="blank"?"":x.productionMethodId}:x))}><option value="value_added">Printed / branded item</option><option value="blank">Blank item sale</option></select></label>
        {line.saleMode==="value_added"&&<><label>Production method{catalogueItems.find(item=>item.id===line.catalogueItemId)?.item_type==="product"?" *":""}<select required={catalogueItems.find(item=>item.id===line.catalogueItemId)?.item_type==="product"} value={line.productionMethodId} onChange={e=>setQuoteLines(v=>v.map((x,i)=>i===index?{...x,productionMethodId:e.target.value}:x))}><option value="">Choose method / general service</option>{productionMethods.map(method=><option key={method.id} value={method.id}>{method.name}</option>)}</select></label><label>Material length (metres)<input type="number" min="0" step="0.001" value={line.linearMetres} onChange={e=>setQuoteLines(v=>v.map((x,i)=>i===index?{...x,linearMetres:e.target.value}:x))} placeholder="If required by profile"/></label><label>Material area (m²)<input type="number" min="0" step="0.001" value={line.areaSquareMetres} onChange={e=>setQuoteLines(v=>v.map((x,i)=>i===index?{...x,areaSquareMetres:e.target.value}:x))} placeholder="If required by profile"/></label><label>Machine time (minutes)<input type="number" min="0" step="0.1" value={line.machineMinutes} onChange={e=>setQuoteLines(v=>v.map((x,i)=>i===index?{...x,machineMinutes:e.target.value}:x))} placeholder="If required by profile"/></label><label>Labour time (hours)<input type="number" min="0" step="0.01" value={line.labourHours} onChange={e=>setQuoteLines(v=>v.map((x,i)=>i===index?{...x,labourHours:e.target.value}:x))} placeholder="If required by profile"/></label></>}
        <label>Shop stock item<select disabled={line.customerSupplies} value={line.stockItemId} onChange={e=>setQuoteLines(v=>v.map((x,i)=>i===index?{...x,stockItemId:e.target.value}:x))}><option value="">No stock item linked</option>{stockItems.filter(item=>line.saleMode!=="blank"||item.stock_kind==="blank_product").map(item=><option key={item.id} value={item.id}>{item.name} · {item.sku} ({item.base_unit})</option>)}</select></label>
        <label className="check-field"><input type="checkbox" checked={line.customerSupplies} onChange={e=>setQuoteLines(v=>v.map((x,i)=>i===index?{...x,customerSupplies:e.target.checked,stockItemId:e.target.checked?"":x.stockItemId}:x))}/> Customer supplies the item</label>
        <button type="button" className="secondary-action" disabled={quoteLines.length===1} onClick={()=>setQuoteLines(v=>v.filter((_,i)=>i!==index))}>Remove item</button>
      </div>)}<button type="button" className="secondary-action" onClick={()=>setQuoteLines(v=>[...v,{catalogueItemId:"",categoryId:"",description:"",quantity:"1",unit:"piece",unitPrice:"",discount:"0",customerSupplies:false,stockItemId:"",saleMode:"value_added",productionMethodId:"",linearMetres:"",areaSquareMetres:"",machineMinutes:"",labourHours:"",stickerSpecification:{}}])}>Add another item</button></div>
      <label>Quote expiry<input type="date" value={quoteExpiry} onChange={e=>setQuoteExpiry(e.target.value)}/></label>
      <label className="wide-field">Customer notes<textarea value={customerNotes} onChange={e=>setCustomerNotes(e.target.value)}/></label>
      <label className="wide-field">Internal notes (not shown to customer)<textarea value={internalNotes} onChange={e=>setInternalNotes(e.target.value)}/></label>
      
      <div className="form-actions"><button className="primary-action compact" disabled={busy||!customers.length||!categories.length}>{busy?"Saving…":revisionOf?"Save quotation revision":"Create draft quotation"}</button></div>
    </form><div className="record-list">{quotes.map(q=><article className="record-row quote-row" key={q.id}><div><b>{q.quote_number} · {customerName(q.customer_id)}</b><small>{new Date(q.created_at).toLocaleDateString("en-KE")} · {q.status}{q.expires_at?" · Expires "+new Date(q.expires_at).toLocaleDateString("en-KE"):""}</small>{(q.status==="draft"||q.status==="sent")&&<label className="quote-exception-reason">Owner approval reason (only required if this quotation is below the 30% margin floor)<textarea maxLength={1000} value={marginExceptionReasons[q.id]||""} onChange={e=>setMarginExceptionReasons(v=>({...v,[q.id]:e.target.value}))} placeholder="Enter the reason for this quotation, if an exception is needed."/></label>}</div><div className="quote-total"><b>{kes(Number(q.total_amount))}</b>{q.status==="draft"||q.status==="sent"?<button className="secondary-action" disabled={busy} onClick={()=>void sendQuote(q)}>{q.status==="sent"?"Resend":"Mark sent"}</button>:null}{q.status==="accepted"&&!salesInvoices.some(invoice=>invoice.quotation_id===q.id)?<button className="primary-action compact" disabled={busy} onClick={()=>void issueInvoice(q)}>Issue invoice</button>:null}{salesInvoices.filter(invoice=>invoice.quotation_id===q.id).map(invoice=><span className="status-chip posted" key={invoice.id}>{invoice.invoice_number} · {invoice.status.replace("_"," ")}</span>)}{["draft","sent","declined","expired"].includes(q.status)?<button className="secondary-action" disabled={busy} onClick={()=>void startRevision(q)}>Create revision</button>:null}</div></article>)}{!quotes.length&&<p className="empty-records">No quotations yet.</p>}</div></>}
    {tab==="costing"&&<><div className="wide-field"><button type="button" className="secondary-action" onClick={prepareScreenPrintingCostProfile}>Prepare customer-supplied screen-printing profile (KES 200 outsourced labour)</button><p className="form-help">For service-only jobs: customer supplies the garments; MJ records only printing income and its own production costs. The KES 200 is an editable example cost for this Baraka Uniform scenario.</p></div><form className="record-form" onSubmit={createCostProfile}><h3 className="wide-field">Create a costing profile version</h3><p className="wide-field form-help">Build a profile from the actual materials, blank garments, consumables, labour, machine time, setup, packaging and outsourced work used by this service. Each component keeps its own unit driver and waste allowance; saved versions preserve existing quotation cost snapshots.</p><label>Catalogue item (exact product/service)<select value={costCatalogueItemId} onChange={e=>{setCostCatalogueItemId(e.target.value);if(e.target.value)setCostCategory("");}}><option value="">Use category-level profile</option>{catalogueItems.map(item=><option key={item.id} value={item.id}>{item.name} · {item.item_type}</option>)}</select></label>{!costCatalogueItemId&&<label>Service category *<select required value={costCategory} onChange={e=>setCostCategory(e.target.value)}><option value="">Choose category</option>{categories.map(c=><option key={c.id} value={c.id}>{c.name}</option>)}</select></label>}<label>Costing applies to<select value={costSaleMode} onChange={e=>setCostSaleMode(e.target.value)}><option value="value_added">Value-added service</option><option value="blank">Blank product</option></select></label><label>Production method<select value={costProductionMethodId} onChange={e=>setCostProductionMethodId(e.target.value)}><option value="">General profile (any method)</option>{productionMethods.map(method=><option key={method.id} value={method.id}>{method.name}</option>)}</select></label><div className="wide-field"><b>Cost components</b>{costComponents.map((component,index)=><div className="quote-line-editor" key={index}><label>Component type<select value={component.componentType} onChange={e=>setCostComponents(v=>v.map((x,i)=>i===index?{...x,componentType:e.target.value}:x))}>{["blank_item","meter_material","area_material","consumable","machine_time","labour_time","outsourced_service","setup","packaging","other"].map(x=><option key={x} value={x}>{x.replaceAll("_"," ")}</option>)}</select></label><label>Stock item{["blank_item","meter_material","area_material","consumable","packaging"].includes(component.componentType)&&" *"}<select value={component.stockItemId} onChange={e=>setCostComponents(v=>v.map((x,i)=>i===index?{...x,stockItemId:e.target.value}:x))}><option value="">No stock link</option>{stockItems.map(item=><option key={item.id} value={item.id}>{item.name} · {item.sku} ({item.base_unit})</option>)}</select></label><label>Unit *<input required value={component.unit} onChange={e=>setCostComponents(v=>v.map((x,i)=>i===index?{...x,unit:e.target.value}:x))} placeholder="piece, metre, hour"/></label><label>Cost driver<select value={component.driverType} onChange={e=>setCostComponents(v=>v.map((x,i)=>i===index?{...x,driverType:e.target.value}:x))}>{["per_piece","per_order","per_metre","per_square_metre","per_minute","per_hour","fixed_setup","manual"].map(x=><option key={x} value={x}>{x.replaceAll("_"," ")}</option>)}</select></label><label>Factor per driver<input required type="number" min="0" step="any" value={component.factor} onChange={e=>setCostComponents(v=>v.map((x,i)=>i===index?{...x,factor:e.target.value}:x))}/></label><label>Expected waste (%)<input required type="number" min="0" max="100" step="0.01" value={component.waste} onChange={e=>setCostComponents(v=>v.map((x,i)=>i===index?{...x,waste:e.target.value}:x))}/></label><label>Fixed cost (KES)<input required type="number" min="0" step="1" value={component.fixedCost} onChange={e=>setCostComponents(v=>v.map((x,i)=>i===index?{...x,fixedCost:e.target.value}:x))}/></label><button type="button" className="secondary-action" disabled={costComponents.length===1} onClick={()=>setCostComponents(v=>v.filter((_,i)=>i!==index))}>Remove component</button></div>)}<button type="button" className="secondary-action" onClick={()=>setCostComponents(v=>[...v,{componentType:"other",stockItemId:"",unit:"job",driverType:"per_order",factor:"1",waste:"0",fixedCost:"0"}])}>Add cost component</button></div><div className="form-actions"><button className="primary-action compact" disabled={busy||!categories.length}>{busy?"Saving…":"Save new profile version"}</button></div></form><form className="record-form pricing-rule-form" onSubmit={savePricingRule}><h3 className="wide-field">Cost-based price recommendation</h3><p className="wide-field form-help">Uses actual costing data to recommend a starting price. The 30% gross-margin floor is enforced; the owner can negotiate and enter the final agreed price. Customer category never fixes the selling price.</p><label>Category *<select required value={pricingCategory} onChange={e=>setPricingCategory(e.target.value)}><option value="">Choose category</option>{categories.map(c=><option key={c.id} value={c.id}>{c.name}</option>)}</select></label><label>Pricing method<select value={markupMethod} onChange={e=>setMarkupMethod(e.target.value)}><option value="percentage_on_cost">Markup on cost (%)</option><option value="margin_on_price">Margin on selling price (%)</option><option value="fixed_amount">Fixed amount added to cost (KES)</option><option value="manual">Manual pricing only</option></select></label><label>{markupMethod==="margin_on_price"?"Target margin (%)":markupMethod==="fixed_amount"?"Amount added (KES)":"Markup (%)"}<input type="number" min="0" step="0.01" value={markupValue} onChange={e=>setMarkupValue(e.target.value)} disabled={markupMethod==="manual"}/></label><div className="form-actions"><button className="primary-action compact" disabled={busy||!categories.length}>Save pricing rule</button></div></form></>}
    {tab==="orders"&&<div className="record-list">{orders.map(o=><article className="order-card" key={o.id}><div className="order-card-heading"><div><b>{o.order_number} · {customerName(o.customer_id)}</b><small>Received {new Date(o.received_at).toLocaleDateString("en-KE")} · {o.required_by?"Due "+o.required_by:"Due date not set"}{o.promised_turnaround_hours?" · "+o.promised_turnaround_hours+"h promised":""}</small></div><div className="quote-total"><b>{kes(Number(o.total_amount))}</b><span className={"status-chip "+o.status}>{o.status.replace("_"," ")}</span></div></div><form className="order-schedule-form" onSubmit={e=>{e.preventDefault();void updateSchedule(o.id,new FormData(e.currentTarget));}}><label>Required by<input name="required_by" type="date" defaultValue={o.required_by||""}/></label><label>Promised turnaround (hours)<input name="promised_turnaround_hours" type="number" min="1" max="8760" step="1" defaultValue={o.promised_turnaround_hours||""} placeholder="e.g. 72"/></label><button className="secondary-action" disabled={busy}>Save schedule</button></form></article>)}{!orders.length&&<p className="empty-records">No orders yet. An accepted customer quotation creates its order automatically.</p>}</div>}
  </section>;
}
