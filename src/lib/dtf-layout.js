export const DTF_ROLL_WIDTH_CM = 58;
export const DTF_RATE_PER_METRE_KES = 700;
export const DTF_RATE_PER_CM2_KES = DTF_RATE_PER_METRE_KES / (DTF_ROLL_WIDTH_CM * 100);

export function layoutDtfStickers(rows, options = {}) {
  const rollWidth = Number(options.rollWidthCm ?? DTF_ROLL_WIDTH_CM);
  const gap = Math.max(0, Number(options.gapCm ?? 0));
  const empty = { error: '', placements: [], usedWidthCm: 0, usedLengthCm: 0, materialAreaCm2: 0, stickerAreaCm2: 0, pieceCount: 0 };
  if (!(rollWidth > 0)) return { ...empty, error: 'Roll width must be greater than zero.' };
  const pieces = [];
  let stickerAreaCm2 = 0;
  for (const row of rows || []) {
    const width = Number(row.widthCm), height = Number(row.heightCm);
    const quantity = Math.max(0, Math.floor(Number(row.quantity) || 0));
    if (!(width > 0 && height > 0 && quantity > 0)) continue;
    if (!Number.isInteger(Number(row.quantity))) return { ...empty, error: 'Sticker quantities must be whole numbers.' };
    stickerAreaCm2 += width * height * quantity;
    for (let i = 0; i < quantity; i++) {
      const normalFits = width <= rollWidth + 1e-9;
      const rotatedFits = row.allowRotation !== false && height <= rollWidth + 1e-9;
      if (!normalFits && !rotatedFits) return { ...empty, error: 'Sticker ' + (row.label || row.id || '') + ' cannot fit within the 58 cm roll width, even when rotated.', stickerAreaCm2, pieceCount: pieces.length };
      pieces.push({ rowId: row.id, label: row.label || '', pieceNo: i + 1, width, height, allowRotation: row.allowRotation !== false });
    }
  }
  if (!pieces.length) return { ...empty, stickerAreaCm2: 0, pieceCount: 0 };

  const strategies = [
    (a,b) => (b.width*b.height)-(a.width*a.height),
    (a,b) => Math.max(b.width,b.height)-Math.max(a.width,a.height),
    (a,b) => b.height-a.height || b.width-a.width,
    (a,b) => b.width-a.width || b.height-a.height,
    (a,b) => Math.min(b.width,b.height)-Math.min(a.width,a.height),
    (a,b) => (b.width+b.height)-(a.width+a.height)
  ];

  function pack(order) {
    const shelves = [];
    let runningY = 0, usedWidth = 0;
    const placements = [];
    for (const piece of order) {
      const orientations = [{ width: piece.width, height: piece.height, rotated: false }];
      if (piece.allowRotation && Math.abs(piece.width-piece.height)>1e-9) orientations.push({ width: piece.height, height: piece.width, rotated: true });
      const candidates = [];
      for (let si=0;si<shelves.length;si++) {
        const shelf=shelves[si];
        for (const o of orientations) {
          const packedW=o.width+gap, packedH=o.height+gap;
          if (shelf.usedWidth+o.width<=rollWidth+1e-9 && packedH<=shelf.height+1e-9) {
            const widthSlack=rollWidth-(shelf.usedWidth+o.width);
            const heightSlack=shelf.height-packedH;
            candidates.push({si,o,score:heightSlack*1000+widthSlack});
          }
        }
      }
      candidates.sort((a,b)=>a.score-b.score);
      if (candidates.length) {
        const chosen=candidates[0], shelf=shelves[chosen.si];
        placements.push({rowId:piece.rowId,label:piece.label,pieceNo:piece.pieceNo,xCm:shelf.usedWidth,yCm:shelf.y,widthCm:chosen.o.width,heightCm:chosen.o.height,rotated:chosen.o.rotated});
        shelf.usedWidth+=chosen.o.width+gap;
        usedWidth=Math.max(usedWidth,shelf.usedWidth-gap);
        continue;
      }
      const viable=orientations.filter(o=>o.width<=rollWidth+1e-9);
      if (!viable.length) return null;
      viable.sort((a,b)=>{
        const areaA=Math.max(usedWidth,a.width)*(runningY+a.height+gap);
        const areaB=Math.max(usedWidth,b.width)*(runningY+b.height+gap);
        return areaA-areaB || a.height-b.height || a.width-b.width;
      });
      const chosen=viable[0];
      const shelf={y:runningY,height:chosen.height+gap,usedWidth:chosen.width+gap};
      shelves.push(shelf);
      placements.push({rowId:piece.rowId,label:piece.label,pieceNo:piece.pieceNo,xCm:0,yCm:runningY,widthCm:chosen.width,heightCm:chosen.height,rotated:chosen.rotated});
      usedWidth=Math.max(usedWidth,chosen.width);
      runningY+=shelf.height;
    }
    const usedLength=Math.max(0,runningY-(shelves.length?gap:0));
    return {placements,usedWidthCm:usedWidth,usedLengthCm:usedLength,materialAreaCm2:usedWidth*usedLength};
  }

  let best=null;
  for (const compare of strategies) {
    const result=pack([...pieces].sort(compare));
    if (!result) continue;
    if (!best || result.materialAreaCm2<best.materialAreaCm2-1e-7 ||
      (Math.abs(result.materialAreaCm2-best.materialAreaCm2)<1e-7 && result.usedLengthCm<best.usedLengthCm)) best=result;
  }
  if (!best) return { ...empty, error: 'The stickers cannot be arranged within the fixed 58 cm roll width.', stickerAreaCm2, pieceCount: pieces.length };
  return { error: '', ...best, stickerAreaCm2, pieceCount: pieces.length, rollWidthCm: rollWidth, gapCm: gap, utilisationPercent: best.materialAreaCm2>0 ? stickerAreaCm2/best.materialAreaCm2*100 : 0 };
}
