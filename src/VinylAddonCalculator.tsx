import { useEffect, useMemo, useState } from 'react';
import { supabase } from './lib/supabase';

type StockItem={id:string;item_name:string;unit:string;quantity_on_hand:number;average_unit_cost:number};
type Line=Record<string,any>;

export default function VinylAddonCalculator({line,onChange}:{line:Line;onChange:(patch:Line)=>void}){
 const [stock,setStock]=useState<StockItem[]>([]);
 const [loadError,setLoadError]=useState('');
 useEffect(()=>{let active=true;void(async()=>{if(!supabase)return;const{data,error}=await supabase.from('stock_items').select('id,item_name,unit,quantity_on_hand,average_unit_cost').eq('active',true).eq('category','Vinyl sticker material').eq('unit','metre').order('item_name');if(!active)return;if(error){setLoadError(error.message);return;}setStock((data||[]) as StockItem[]);})();return()=>{active=false}},[]);
 const length=Number(line.vinylLengthInches??12),width=Number(line.vinylWidthInches??4),rollWidth=Number(line.vinylRollWidthInches??24),quantity=Number(line.quantity||1);
 const selected=stock.find(item=>item.id===line.vinylStockItemId);
 const calculation=useMemo(()=>{const area=Math.max(0,length*width);const consumed=rollWidth>0?Math.ceil((area*quantity/(rollWidth*39.37))*1e6)/1e6:0;const materialPerPiece=line.supplyArrangement==='mj_supplies'&&selected&&rollWidth>0?area/(rollWidth*39.37)*Number(selected.average_unit_cost||0):0;const labour=Math.max(0,Number(line.vinylDirectLabour||0));const tape=Math.max(0,Number(line.vinylTransferTapeCost||0));const application=Math.max(0,Number(line.vinylApplicationCost||0));const other=Math.max(0,Number(line.otherDirectCosts||0));return{area,consumed,materialPerPiece,totalPerPiece:materialPerPiece+labour+tape+application+other,available:Number(selected?.quantity_on_hand||0),labour,tape,application,other}},[length,width,rollWidth,quantity,line.supplyArrangement,line.vinylDirectLabour,line.vinylTransferTapeCost,line.vinylApplicationCost,line.otherDirectCosts,selected]);
 const update=(key:string,value:string)=>onChange({[key]:value});
 return <div className="op-card">
  <b>Vinyl add-on calculator</b>
  <p className="op-empty">Capture the actual finished size, selected vinyl colour and roll width. Stock consumption is checked and posted by the combined-sale database transaction.</p>
  <div className="op-grid">
   <label className="op-field">Sticker length (inches)<input type="number" min="0.01" step="0.01" value={line.vinylLengthInches??'12'} onChange={e=>update('vinylLengthInches',e.target.value)}/></label>
   <label className="op-field">Sticker width (inches)<input type="number" min="0.01" step="0.01" value={line.vinylWidthInches??'4'} onChange={e=>update('vinylWidthInches',e.target.value)}/></label>
   <label className="op-field">Roll width (inches)<input type="number" min="0.01" step="0.01" value={line.vinylRollWidthInches??'24'} onChange={e=>update('vinylRollWidthInches',e.target.value)}/></label>
   {line.supplyArrangement==='mj_supplies'&&<label className="op-field">Vinyl colour / stock item<select value={line.vinylStockItemId||''} onChange={e=>update('vinylStockItemId',e.target.value)}><option value="">Select active vinyl stock</option>{stock.map(item=><option key={item.id} value={item.id}>{item.item_name} · {Number(item.quantity_on_hand).toFixed(3)} m available</option>)}</select></label>}
  </div>
  {loadError&&<p className="op-error">Could not load vinyl stock: {loadError}</p>}
  {line.supplyArrangement==='mj_supplies'&&selected&&<p className="op-empty">Selected colour: <b>{selected.item_name}</b> · Current average cost {Number(selected.average_unit_cost||0).toFixed(2)} KES/metre.</p>}
  <div className="op-grid">
   <label className="op-field">Cutting / weeding labour per piece (KES)<input type="number" min="0" step="0.01" value={line.vinylDirectLabour??'0'} onChange={e=>update('vinylDirectLabour',e.target.value)}/></label>
   <label className="op-field">Transfer tape per piece (KES)<input type="number" min="0" step="0.01" value={line.vinylTransferTapeCost??'0'} onChange={e=>update('vinylTransferTapeCost',e.target.value)}/></label>
   <label className="op-field">Application labour per piece (KES)<input type="number" min="0" step="0.01" value={line.vinylApplicationCost??'0'} onChange={e=>update('vinylApplicationCost',e.target.value)}/></label>
  </div>
  <div className="cost-preview">
   <div><small>Finished area per piece</small><b>{calculation.area.toFixed(2)} sq. in.</b></div>
   {line.supplyArrangement==='mj_supplies'&&<><div><small>Estimated stock consumption</small><b>{calculation.consumed.toFixed(6)} m</b></div><div><small>Available selected stock</small><b>{calculation.available.toFixed(6)} m</b></div><div><small>Estimated material cost per piece</small><b>{calculation.materialPerPiece.toFixed(2)} KES</b></div></>}
   <div><small>Direct cost per piece before margin</small><b>{calculation.totalPerPiece.toFixed(2)} KES</b></div>
  </div>
  {line.supplyArrangement==='customer_supplies'&&<p className="op-empty">Customer-supplied vinyl: no MJ stock item is selected or deducted. Enter only MJ's actual direct labour and other direct costs.</p>}
 </div>;
}
