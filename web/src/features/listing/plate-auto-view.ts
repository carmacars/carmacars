// Release 41 (2530): how the listing review shows a plate decision made by itself, and whether it can still be undone.
export interface AutoPlate { who?: string; decision?: 'covered' | 'not_visible' | 'unsure'; confidence?: number | null; model?: string | null; at?: string; path?: string | null; undone?: boolean }

/** The automatic decision is the photo's current one: made by itself, not undone, for this file, and no person decided since. */
export function autoShown(p: { plate_status: string; processed_path: string | null; plate_auto?: AutoPlate | null; plate_checked_by?: string | null }): boolean {
  const a = p.plate_auto;
  return !!a && a.who === 'auto' && !a.undone && !p.plate_checked_by && p.plate_status !== 'unchecked' && a.path === p.processed_path
    && (a.decision === 'covered' || a.decision === 'not_visible');
}
/** The badge: "Covered by itself (88%)", "No plate seen by itself (95%)"; an unsure answer: "Checked by itself: not sure". */
export function autoText(a: AutoPlate | null | undefined): string | null {
  if (!a || a.who !== 'auto' || a.undone) return null;
  const c = typeof a.confidence === 'number' ? ` (${Math.round(a.confidence)}% sure)` : '';
  if (a.decision === 'covered') return `Covered automatically${c}`;
  if (a.decision === 'not_visible') return `No plate seen automatically${c}`;
  if (a.decision === 'unsure') return 'Checked automatically: not sure, check it yourself';
  return null;
}
