// "Already paid outside the platform" on an owner invoice (migration 0780): the way it was paid, as the person sees it, and the
// payment the database records. Card outside the platform is recorded as "other" with that said in the note.
export const OUTSIDE_METHODS: Array<[string, string]> = [['e_transfer', 'e-Transfer'], ['cash', 'Cash'], ['cheque', 'Cheque'], ['bank_transfer', 'Bank transfer'], ['card_outside', 'Card, outside the platform']];

export interface OutsideInput { method: string; received_on: string; reference: string; note: string; amount: string }
export interface OutsidePayment { method: string; reference: string | null; note: string | null; received_on: string; amount_cents: number | null }

export function outsidePayment(i: OutsideInput, today: string): { ok: true; payment: OutsidePayment } | { ok: false; errors: Record<string, string> } {
  const errors: Record<string, string> = {};
  if (!OUTSIDE_METHODS.some(([v]) => v === i.method)) errors.method = 'Choose how it was paid.';
  if (!/^\d{4}-\d{2}-\d{2}$/.test(i.received_on)) errors.received_on = 'Enter the date it was paid.';
  else if (i.received_on > today) errors.received_on = 'The date paid cannot be in the future.';
  const ref = i.reference.trim();
  if (['e_transfer', 'cheque', 'bank_transfer'].includes(i.method) && ref.length < 3) errors.reference = i.method === 'cheque' ? 'Enter the cheque number.' : 'Enter the reference.';
  const raw = i.amount.trim();
  let amount: number | null = null;
  if (raw) {
    amount = Math.round(Number(raw.replace(/[$,\s]/g, '')) * 100);
    if (!Number.isFinite(amount) || amount <= 0) errors.amount = 'Enter the amount paid, or leave it empty for the full balance.';
  }
  if (Object.keys(errors).length) return { ok: false, errors };
  const card = i.method === 'card_outside';
  const note = [card ? 'Paid by card outside the platform' : '', i.note.trim()].filter(Boolean).join('. ');
  return { ok: true, payment: { method: card ? 'other' : i.method, reference: ref || null, note: note || null, received_on: i.received_on, amount_cents: amount } };
}
