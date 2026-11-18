import "./vinyl-calculator.css";
import { useEffect, useMemo, useState } from "react";
import { supabase } from "./lib/supabase";

type StockItem = {
  id: string; sku: string; name: string; base_unit: string; stock_kind: string;
  is_active: boolean; current_average_unit_cost: number; roll_width_mm: number | null;
  usable_width_mm: number | null;
};
type Category = { id: string; name: string };
type Method = { id: string; name: string; code: string };
type Props = {
  businessId: string; stockItems: StockItem[]; categories: Category[]; methods: Method[];
  onApply: (line: { categoryId: string; description: string; quantity: string; unitPrice: string;
    stockItemId: string; productionMethodId: string; linearMetres: string; machineMinutes: string;
    labourHours: string; specification: Record<string, unknown> }) => void;
  onMessage: (message: string, error?: boolean) => void; onInventoryConfigSaved: () => void;
};
const money = (n: number) => new Intl.NumberFormat("en-KE", { style: "currency", currency: "KES", maximumFractionDigits: 0 }).format(n);
const cm = (value: number, unit: string) => unit === "in" ? value * 2.54 : value;
const round = (n: number, places = 4) => Number(n.toFixed(places));

export default function VinylStickerCalculator({ businessId, stockItems, categories, methods, onApply, onMessage, onInventoryConfigSaved }: Props) {
  const vinylItems = stockItems.filter(x => x.is_active && x.stock_kind === "material" && /vinyl|sticker/i.test(x.name + " " + x.sku) && x.base_unit.toLowerCase().includes("met"));
  const tapeItems = stockItems.filter(x => x.is_active && /tape/i.test(x.name + " " + x.sku) && x.base_unit.toLowerCase().includes("met"));
  const [stockId, setStockId] = useState(vinylItems[0]?.id ?? "");
  const [categoryId, setCategoryId] = useState(categories.find(x => /sticker|vinyl|vehicle/i.test(x.name))?.id ?? "");
  const [methodId, setMethodId] = useState(methods.find(x => /cut|plotter|vinyl/i.test(x.name + " " + x.code))?.id ?? "");
  const [width, setWidth] = useState("5");
  const [height, setHeight] = useState("5");
  const [unit, setUnit] = useState("in");
  const [quantity, setQuantity] = useState("1");
  const [rollWidth, setRollWidth] = useState("");
  const [usableWidth, setUsableWidth] = useState("");
  const [gap, setGap] = useState("0.3");
  const [waste, setWaste] = useState("5");
  const [complexity, setComplexity] = useState("simple");
  const [machineMinutes, setMachineMinutes] = useState("2");
  const [machineRate, setMachineRate] = useState("5");
  const [designMinutes, setDesignMinutes] = useState("0");
  const [weedingMinutes, setWeedingMinutes] = useState("2");
  const [applicationMinutes, setApplicationMinutes] = useState("0");
  const [labourRate, setLabourRate] = useState("300");
  const [includeTape, setIncludeTape] = useState(false);
  const [tapeStockId, setTapeStockId] = useState("");
  const [includeApplication, setIncludeApplication] = useState(false);
  const [miscCost, setMiscCost] = useState("0");
  const [ceilingMarkup, setCeilingMarkup] = useState("400");
  const [finalPrice, setFinalPrice] = useState("");
  const [savingCeiling, setSavingCeiling] = useState(false);

  const vinyl = vinylItems.find(x => x.id === stockId);
  const tape = tapeItems.find(x => x.id === tapeStockId);
  const effectiveRollWidth = Number(rollWidth || (vinyl?.roll_width_mm ? vinyl.roll_width_mm / 10 : 0));
  const effectiveUsableWidth = Number(usableWidth || (vinyl?.usable_width_mm ? vinyl.usable_width_mm / 10 : effectiveRollWidth));
  const w = cm(Number(width), unit), h = cm(Number(height), unit), q = Number(quantity);
  const spacing = Number(gap), wastePct = Number(waste);
  const layout = useMemo(() => {
    if (!(effectiveUsableWidth > 0 && w > 0 && h > 0 && q > 0)) return null;
    const option = (itemW: number, itemH: number) => {
      const across = Math.floor((effectiveUsableWidth + spacing) / (itemW + spacing));
      if (across < 1) return null;
      const rows = Math.ceil(q / across);
      return { across, rows, lengthCm: rows * itemH + Math.max(0, rows - 1) * spacing };
    };
    const a = option(w, h), b = option(h, w);
    if (!a && !b) return null;
    return !b || (a && a.lengthCm <= b.lengthCm) ? { ...a!, rotated: false } : { ...b, rotated: true };
  }, [effectiveUsableWidth, w, h, q, spacing]);
  const linearMetres = layout ? layout.lengthCm / 100 * (1 + wastePct / 100) : 0;
  const materialCost = vinyl ? linearMetres * Number(vinyl.current_average_unit_cost) : 0;
  const machineCost = Math.max(0, Number(machineMinutes) || 0) * Math.max(0, Number(machineRate) || 0);
  const labourHours = ((Math.max(0, Number(designMinutes) || 0) + Math.max(0, Number(weedingMinutes) || 0) + (includeApplication ? Math.max(0, Number(applicationMinutes) || 0) : 0)) / 60);
  const labourCost = labourHours * Math.max(0, Number(labourRate) || 0);
  const tapeLength = includeTape ? linearMetres : 0;
  const tapeCost = tape && includeTape ? tapeLength * Number(tape.current_average_unit_cost) : 0;
  const directCost = materialCost + machineCost + labourCost + tapeCost + Math.max(0, Number(miscCost) || 0);
  const unitDirectCost = q > 0 ? directCost / q : 0;
  const floorPrice = unitDirectCost / 0.7;
  const ceilingPrice = unitDirectCost * (1 + Math.max(0, Number(ceilingMarkup) || 0) / 100);
  const recommendedPrice = floorPrice + Math.max(0, ceilingPrice - floorPrice) * 0.65;
  const suggested = Math.ceil(recommendedPrice / 5) * 5;
  const final = Number(finalPrice || suggested);
  const valid = Boolean(vinyl && categoryId && methodId && layout && directCost > 0 && ceilingPrice >= floorPrice && final >= floorPrice - 0.001 && final <= ceilingPrice + 0.001);
  const selectedMethod = methods.find(x => x.id === methodId);

  useEffect(() => {
    if (!supabase || !categoryId) return;
    const category = categories.find(x => x.id === categoryId);
    if (!category) return;
    let active = true;
    void supabase.from("pricing_rules").select("markup_value").eq("business_id", businessId).eq("category_id", categoryId)
      .eq("name", "Vinyl sticker price ceiling · " + category.name).eq("is_active", true)
      .order("created_at", { ascending: false }).limit(1).maybeSingle()
      .then(({ data, error }) => { if (active && !error && data?.markup_value != null) setCeilingMarkup(String(data.markup_value)); });
    return () => { active = false; };
  }, [businessId, categoryId, categories]);

  function setComplexityState(value: string) {
    setComplexity(value);
    if (value === "simple") { setDesignMinutes("0"); setWeedingMinutes("2"); }
    if (value === "medium") { setDesignMinutes("3"); setWeedingMinutes("6"); }
    if (value === "complex") { setDesignMinutes("10"); setWeedingMinutes("15"); }
  }
  async function saveCeiling() {
    if (!supabase || !categoryId || !Number.isFinite(Number(ceilingMarkup)) || Number(ceilingMarkup) < 0 || Number(ceilingMarkup) > 2000) {
      onMessage("Choose a sticker category and enter an owner ceiling markup between 0% and 2,000%.", true); return;
    }
    setSavingCeiling(true);
    const category = categories.find(x => x.id === categoryId);
    if (vinyl && effectiveRollWidth > 0 && effectiveUsableWidth > 0) {
      const { error: stockError } = await supabase.from("stock_items").update({ roll_width_mm: Math.round(effectiveRollWidth * 10), usable_width_mm: Math.round(effectiveUsableWidth * 10) }).eq("business_id", businessId).eq("id", vinyl.id);
      if (stockError) { onMessage(stockError.message, true); setSavingCeiling(false); return; }
    }
    const { error } = await supabase.rpc("owner_upsert_pricing_rule", {
      p_business_id: businessId, p_rule_id: null, p_category_id: categoryId, p_catalogue_item_id: null,
      p_name: "Vinyl sticker price ceiling · " + (category?.name || "Stickers"),
      p_markup_method: "percentage_on_cost", p_markup_value: Number(ceilingMarkup),
      p_effective_from: new Date().toISOString().slice(0, 10), p_effective_to: null,
      p_is_active: true, p_request_id: crypto.randomUUID()
    });
    if (error) onMessage(error.message, true);
    else { onMessage("Owner ceiling rule saved for this category. The calculator uses it as the upper pricing boundary."); onInventoryConfigSaved(); }
    setSavingCeiling(false);
  }
  function apply() {
    if (!valid || !vinyl) { onMessage("Complete the vinyl, dimensions, category and price fields. The final price must be within the permitted range.", true); return; }
    onApply({
      categoryId, description: `Plotter-cut vinyl sticker ${width} × ${height} ${unit} · ${vinyl.name}`,
      quantity, unitPrice: String(Math.round(final)), stockItemId: vinyl.id,
      productionMethodId: methodId, linearMetres: String(round(linearMetres)),
      machineMinutes: String(round(Number(machineMinutes) || 0)),
      labourHours: String(round(labourHours, 3)),
      specification: {
        type: "vinyl_sticker", width: w, height: h, dimension_unit: "cm", quantity: q,
        roll_width_cm: effectiveRollWidth, usable_width_cm: effectiveUsableWidth,
        layout_across: layout?.across, layout_rows: layout?.rows, rotated: layout?.rotated,
        linear_metres_estimated: round(linearMetres), vinyl_stock_item_id: vinyl.id,
        transfer_tape_stock_item_id: includeTape ? tapeStockId || null : null,
        transfer_tape_linear_metres: round(tapeLength), include_application: includeApplication,
        complexity, direct_cost_estimate: round(directCost, 2), direct_cost_per_unit: round(unitDirectCost, 2), minimum_price: round(floorPrice, 2),
        recommended_price: round(suggested, 2), ceiling_price: round(ceilingPrice, 2),
        operator_final_price: Math.round(final), owner_ceiling_markup_percent: Number(ceilingMarkup)
      }
    });
  }

  return <section className="vinyl-calculator">
    <div className="vinyl-calculator-heading"><div><p className="eyebrow">MJ TEES · PRODUCTION PRICING</p><h3>Vinyl sticker calculator</h3><p>Inventory-linked costing for plotter-cut self-adhesive vinyl. Quoting does not consume stock; material is issued against the production job.</p></div><span className="vinyl-tag">KES</span></div>
    <div className="vinyl-grid">
      <label>Vinyl colour / stock item<select value={stockId} onChange={e => { setStockId(e.target.value); setRollWidth(""); setUsableWidth(""); }}><option value="">Choose vinyl inventory</option>{vinylItems.map(x => <option key={x.id} value={x.id}>{x.name} · {x.sku} · {money(Number(x.current_average_unit_cost))}/{x.base_unit}</option>)}</select></label>
      <label>Service category<select value={categoryId} onChange={e => setCategoryId(e.target.value)}><option value="">Choose category</option>{categories.map(x => <option key={x.id} value={x.id}>{x.name}</option>)}</select></label>
      <label>Production method<select value={methodId} onChange={e => setMethodId(e.target.value)}><option value="">Choose cutting method</option>{methods.map(x => <option key={x.id} value={x.id}>{x.name}</option>)}</select></label>
      <label>Quantity<input type="number" min="1" step="1" value={quantity} onChange={e => { setQuantity(e.target.value); setFinalPrice(""); }}/></label>
      <label>Sticker width<input type="number" min="0.1" step="0.1" value={width} onChange={e => { setWidth(e.target.value); setFinalPrice(""); }}/></label>
      <label>Sticker height<input type="number" min="0.1" step="0.1" value={height} onChange={e => { setHeight(e.target.value); setFinalPrice(""); }}/></label>
      <label>Dimensions<select value={unit} onChange={e => setUnit(e.target.value)}><option value="in">Inches</option><option value="cm">Centimetres</option></select></label>
      <label>Roll width (cm)<input type="number" min="1" step="0.1" value={rollWidth || (vinyl?.roll_width_mm ? String(vinyl.roll_width_mm / 10) : "")} onChange={e => setRollWidth(e.target.value)} placeholder="Set from stock specification"/></label>
      <label>Usable width (cm)<input type="number" min="1" step="0.1" value={usableWidth || (vinyl?.usable_width_mm ? String(vinyl.usable_width_mm / 10) : "")} onChange={e => setUsableWidth(e.target.value)} placeholder="Usually roll width minus edge margin"/></label>
      <label>Cut gap between designs (cm)<input type="number" min="0" step="0.1" value={gap} onChange={e => setGap(e.target.value)}/></label>
      <label>Material wastage (%)<input type="number" min="0" max="100" step="0.1" value={waste} onChange={e => setWaste(e.target.value)}/></label>
      <label>Design complexity<select value={complexity} onChange={e => setComplexityState(e.target.value)}><option value="simple">Simple</option><option value="medium">Medium</option><option value="complex">Complex</option></select></label>
      <label>Machine cutting time (minutes)<input type="number" min="0" step="0.1" value={machineMinutes} onChange={e => setMachineMinutes(e.target.value)}/></label>
      <label>Machine rate (KES/minute)<input type="number" min="0" step="0.1" value={machineRate} onChange={e => setMachineRate(e.target.value)}/></label>
      <label>Design preparation (minutes)<input type="number" min="0" step="0.1" value={designMinutes} onChange={e => setDesignMinutes(e.target.value)}/></label>
      <label>Weeding labour (minutes)<input type="number" min="0" step="0.1" value={weedingMinutes} onChange={e => setWeedingMinutes(e.target.value)}/></label>
      <label>Labour rate (KES/hour)<input type="number" min="0" step="1" value={labourRate} onChange={e => setLabourRate(e.target.value)}/></label>
      <label className="vinyl-check"><input type="checkbox" checked={includeTape} onChange={e => setIncludeTape(e.target.checked)}/> Include transfer tape</label>
      {includeTape && <label>Transfer tape stock item<select value={tapeStockId} onChange={e => setTapeStockId(e.target.value)}><option value="">No tape inventory link</option>{tapeItems.map(x => <option key={x.id} value={x.id}>{x.name} · {money(Number(x.current_average_unit_cost))}/{x.base_unit}</option>)}</select></label>}
      <label className="vinyl-check"><input type="checkbox" checked={includeApplication} onChange={e => setIncludeApplication(e.target.checked)}/> Include application</label>
      {includeApplication && <label>Application labour (minutes)<input type="number" min="0" step="0.1" value={applicationMinutes} onChange={e => setApplicationMinutes(e.target.value)}/></label>}
      <label>Other direct job costs (KES)<input type="number" min="0" step="1" value={miscCost} onChange={e => setMiscCost(e.target.value)}/></label>
      <label>Owner ceiling markup on direct cost (%)<input type="number" min="0" max="2000" step="1" value={ceilingMarkup} onChange={e => setCeilingMarkup(e.target.value)}/></label>
    </div>
    <div className="vinyl-summary">
      <div><span>Estimated vinyl usage</span><b>{layout ? `${round(linearMetres, 3)} linear metres` : "Check roll width / dimensions"}</b><small>{layout ? `${layout.across} across · ${layout.rows} rows · ${layout.rotated ? "rotated layout" : "normal layout"}` : "Sticker must fit the usable roll width."}</small></div>
      <div><span>Direct production cost · whole job</span><b>{money(directCost)}</b><small>Vinyl {money(materialCost)} · Machine {money(machineCost)} · Labour {money(labourCost)} · Tape {money(tapeCost)} · {money(unitDirectCost)} per sticker</small></div>
      <div><span>Minimum selling price · per sticker</span><b>{money(floorPrice)}</b><small>30% minimum gross margin on direct production cost</small></div>
      <div><span>Recommended selling price · per sticker</span><b>{money(suggested)}</b><small>Within owner-configured ceiling</small></div>
      <div><span>Owner-configured ceiling · per sticker</span><b>{money(ceilingPrice)}</b><small>{Number(ceilingMarkup)}% markup on direct cost</small></div>
    </div>
    <div className="vinyl-final-row">
      <label>Operator final selling price per sticker (KES)<input type="number" min={Math.ceil(floorPrice)} max={Math.floor(ceilingPrice)} step="1" value={finalPrice || String(suggested)} onChange={e => setFinalPrice(e.target.value)}/></label>
      <div><span>Expected gross profit · whole job</span><b>{money(final * q - directCost)}</b><small>{final * q > 0 ? `${((final * q - directCost) / (final * q) * 100).toFixed(1)}% gross margin` : "—"}</small></div>
    </div>
    {ceilingPrice < floorPrice && <p className="notice error">The owner ceiling is below the 30% minimum margin price. Increase the ceiling before applying this quotation.</p>}
    {!layout && <p className="notice error">The selected sticker cannot fit the usable vinyl width. Check dimensions and roll width.</p>}
    <div className="vinyl-actions"><button type="button" className="secondary-action" disabled={savingCeiling || !categoryId} onClick={() => void saveCeiling()}>{savingCeiling ? "Saving…" : "Save owner price ceiling"}</button><button type="button" className="primary-action" disabled={!valid} onClick={apply}>Apply price to quotation</button></div>
    <p className="form-help">Saving the owner ceiling also saves the selected vinyl roll and usable widths to its inventory record. Market reference: a simple 5 × 5-inch word decal is commonly priced at KSh 100 in your stated market. It is a reference, not a forced system price. Actual material use is estimated by roll-width nesting; production issues record actual stock consumption.</p>
  </section>;
}
