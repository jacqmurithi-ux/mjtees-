export type DtfLayoutRow = { id: number | string; label?: string; widthCm: number; heightCm: number; quantity: number; allowRotation?: boolean };
export type DtfPlacement = { rowId: number | string; label: string; pieceNo: number; xCm: number; yCm: number; widthCm: number; heightCm: number; rotated: boolean };
export type DtfLayoutResult = { error: string; placements: DtfPlacement[]; usedWidthCm: number; usedLengthCm: number; materialAreaCm2: number; stickerAreaCm2: number; pieceCount: number; rollWidthCm?: number; gapCm?: number; utilisationPercent?: number };
export const DTF_ROLL_WIDTH_CM: number;
export const DTF_RATE_PER_METRE_KES: number;
export const DTF_RATE_PER_CM2_KES: number;
export function layoutDtfStickers(rows: DtfLayoutRow[], options?: { rollWidthCm?: number; gapCm?: number }): DtfLayoutResult;
