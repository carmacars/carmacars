// A request to book that is refused or fails (migration 2670). The database turns each refusal into a code, the form field
// to change and a plain message (app.request_refusal); this module shapes the reply for the form and holds the rules the
// server applies around the send: the same driver named twice is sent once, a failure that is worth one more try, and the
// add-ons named for staff when a request is sent without them.

export interface Refusal { code: string; field: string | null; message: string; unexpected: boolean; logged?: boolean }

/** Shown when the reason could not even be read (the database did not answer): nothing is promised that we cannot keep. */
export const KEPT_HERE = 'We could not send your request just now. Your answers are saved on this device: wait a minute and press Send request again.';

/** The reply the form gets: the message, and the same message beside its field when there is one. */
export function refusalResult(r: Refusal | null | undefined): { ok: false; code: string; message: string; fieldErrors?: Record<string, string> } {
  if (!r || typeof r.message !== 'string' || !r.message) return { ok: false, code: 'unexpected', message: KEPT_HERE };
  // an unexpected error whose follow-up could not be kept (nobody to contact, or a flood): no promise that staff will call
  if (r.unexpected && r.logged === false) return { ok: false, code: 'unexpected', message: KEPT_HERE };
  return { ok: false, code: r.code || 'refused', message: r.message, ...(r.field ? { fieldErrors: { [r.field]: r.message } } : {}) };
}

const norm = (s: string) => s.trim().replace(/\s+/g, ' ').toLowerCase();
/** The additional drivers without the renter and without a driver listed twice (same name and date of birth): the
 *  database refuses the whole request for a copy, and a copy is never what the person meant. */
export function uniqueDrivers<T extends { full_name: string; date_of_birth: string }>(renter: { full_name: string; date_of_birth: string }, drivers: T[]): T[] {
  const seen = new Set([`${norm(renter.full_name)}|${renter.date_of_birth}`]);
  return drivers.filter((d) => { const k = `${norm(d.full_name)}|${d.date_of_birth}`; if (seen.has(k)) return false; seen.add(k); return true; });
}

/** Worth one more try with the same request key (the key makes a second send safe): the database was busy or did not answer. */
export function transient(e: unknown): boolean {
  const code = (e as { code?: unknown } | null)?.code;
  if ((e as { name?: unknown } | null)?.name !== 'DbError') return true;
  return typeof code === 'string' && ['40001', '40P01', '57014', '55P03', '53300', '08006', '08000'].includes(code);
}

/** The add-ons asked for, as a line for staff, when the request is sent without them (an add-on never stops a request). */
export function addonsNote(note: string | null, addons: Array<{ code: string; quantity: number; hours?: number | null }>, max: number): string {
  const list = addons.filter((a) => a.quantity > 0).map((a) => `${a.quantity} x ${a.code.replace(/_/g, ' ')}${a.hours ? ` (${a.hours} h)` : ''}`).join(', ');
  const line = `Add-ons asked for, not added online, please confirm: ${list}.`;
  const rest = (note ?? '').trim();
  const out = rest ? `${line} ${rest}` : line;
  return out.length <= max ? out : out.slice(0, max);
}
