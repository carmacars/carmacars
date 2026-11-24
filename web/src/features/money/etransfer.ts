// Release 49 (3610): "Renter sent an e-Transfer" (Sales) and "Check e-Transfer" (Finance and the Admins). The words and
// the checks the booking page, the server action and the To do share; the database checks everything again.

export type Covers = 'rental' | 'deposit' | 'both';
export type ReportStatus = 'open' | 'confirmed' | 'declined';
export interface EtransferReport {
  id: string; report_number: string; amount_cents: number; covers: Covers; sender_name: string | null; note: string | null; status: ReportStatus;
  reported_at: string; reported_by_name: string | null; decided_at: string | null; decided_by_name: string | null; decline_reason: string | null;
  reference: string | null; proof_document_id: string | null;
}
export interface EtransferPlan {
  amount_cents: number; covers: Covers; rental_cents: number; deposit_cents: number; rental_open_cents: number; deposit_owed_cents: number; over_cents: number; problem: string | null;
}
export interface EtransferView {
  booking_id: string; booking_number: string; status: string; has_deposit: boolean;
  may_report: boolean; may_decide: boolean; own_report: boolean; plan: EtransferPlan | null; reports: EtransferReport[];
}

/** The largest single e-Transfer the form takes ($100,000; the database refuses more too). */
export const MAX_ETRANSFER_CENTS = 10_000_000;
/** The proof file: a screenshot or a PDF, at most 10 MB. */
export const MAX_PROOF_BYTES = 10 * 1024 * 1024;
export const PROOF_TYPES: Record<string, 'jpg' | 'png' | 'pdf'> = { 'image/jpeg': 'jpg', 'image/png': 'png', 'application/pdf': 'pdf' };

export const COVERS: Array<[Covers, string]> = [['rental', 'The rental and fees'], ['deposit', 'The deposit'], ['both', 'Both']];
export const coversWords = (c: string): string => ({ rental: 'the rental and fees', deposit: 'the deposit', both: 'the rental and the deposit' } as Record<string, string>)[c] ?? c;
export const statusWords = (s: string): string => ({ open: 'Waiting for Finance', confirmed: 'Confirmed received', declined: 'Not received' } as Record<string, string>)[s] ?? s;
/** The badge class of a report's status (the admin badge tones: amber waits, dark is done, light is closed). */
export const statusTone = (s: string): string => ({ open: 'ad-b--amber', confirmed: 'ad-b--dark', declined: 'ad-b--light' } as Record<string, string>)[s] ?? 'ad-b--light';

/** Dollars as typed ("1,240.50", "$600") in cents; null when it is not an amount. */
export function cents(s: string): number | null {
  const t = String(s ?? '').replace(/[$,\s]/g, '');
  if (!/^\d+(\.\d{1,2})?$/.test(t)) return null;
  return Math.round(Number(t) * 100);
}

/** Why the Sales form cannot be sent yet, or '' when it can (the button says it). */
export function reportProblem(f: { amount: string; covers: string; file: { size: number; type: string } | null; hasDeposit: boolean }): string {
  const c = cents(f.amount);
  if (c === null || c <= 0) return 'Enter the amount the renter sent.';
  if (c > MAX_ETRANSFER_CENTS) return 'That amount is too large for one e-Transfer: check it.';
  if (!['rental', 'deposit', 'both'].includes(f.covers)) return 'Choose what it covers.';
  if (f.covers !== 'rental' && !f.hasDeposit) return 'This booking has no deposit: choose the rental and fees.';
  if (!f.file) return 'Add the screenshot or proof of the e-Transfer.';
  if (f.file.size > MAX_PROOF_BYTES) return 'The proof must be under 10 MB.';
  if (f.file.type && !PROOF_TYPES[f.file.type]) return 'Add a screenshot (JPG or PNG) or a PDF.';
  return '';
}

/** The proof's kind by its first bytes (what the server keeps); null when it is not a JPG, PNG or PDF. */
export function proofKind(b: Uint8Array): { ext: 'jpg' | 'png' | 'pdf'; mime: string } | null {
  if (b.length >= 3 && b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff) return { ext: 'jpg', mime: 'image/jpeg' };
  if (b.length >= 4 && b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47) return { ext: 'png', mime: 'image/png' };
  if (b.length >= 5 && b[0] === 0x25 && b[1] === 0x50 && b[2] === 0x44 && b[3] === 0x46 && b[4] === 0x2d) return { ext: 'pdf', mime: 'application/pdf' };
  return null;
}

/** What Confirm received records, in one sentence for Finance. */
export function planWords(p: EtransferPlan, fmt: (c: number) => string): string {
  if (p.problem) return p.problem;
  const parts = [p.rental_cents > 0 ? `${fmt(p.rental_cents)} for the rental and fees (open ${fmt(p.rental_open_cents)})` : '',
    p.deposit_cents > 0 ? `${fmt(p.deposit_cents)} for the deposit (owed by e-Transfer ${fmt(p.deposit_owed_cents)})` : ''].filter(Boolean);
  const over = p.over_cents > 0 ? ` It is ${fmt(p.over_cents)} more than is owed: the extra is recorded as Record a payment does.` : '';
  return `Confirm received records ${parts.join(' and ')} by e-Transfer.${over}`;
}

/** The one line the booking shows while a report waits (every role). */
export const waitingLine = (r: Pick<EtransferReport, 'amount_cents' | 'covers' | 'reported_by_name'>, fmt: (c: number) => string) =>
  `e-Transfer reported, waiting for Finance: ${fmt(r.amount_cents)} for ${coversWords(r.covers)}${r.reported_by_name ? `, by ${r.reported_by_name}` : ''}.`;
