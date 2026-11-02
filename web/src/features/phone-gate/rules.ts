// The phone number box (migration 0280), the pure part: shared by the browser, the server actions and the unit tests
// (rules.test.ts). The database checks the number again (app.phone_gate_number).
import { phoneCountry, toE164 } from '../auth/phone.ts';

export type GateKind = 'gallery' | 'dates' | 'request';
/** public.site_facts().phone_gate: the Admin settings (Settings, Phone number box). */
export interface GateRules { gallery: boolean; free_photos: number; dates: boolean; request: boolean; verify: boolean; allow_unverified: boolean; us_texts: boolean }
export const GATE_OFF: GateRules = { gallery: false, free_photos: 4, dates: false, request: false, verify: false, allow_unverified: false, us_texts: false };

/** The line in the box, by what it opens (the owner's words). */
export const GATE_TEXT: Record<GateKind, string> = {
  gallery: 'Put your phone number in to see more photos',
  dates: 'Put your phone number in to see full availability',
  request: 'Put your phone number in to start your request'
};
/** The one line under "What's your number?" (2026-11-06): what the number opens. */
export const GATE_WHY: Record<GateKind, string> = {
  gallery: 'See every photo of this car.',
  dates: 'See the full calendar, every day.',
  request: 'Then your request takes a minute.'
};
export const DEALS_TEXT = 'Also text me deals from CarmaCars. Reply STOP to any text to stop them.';

/** Is this box on? */
export function gateOn(r: GateRules | null | undefined, kind: GateKind): boolean {
  return !!r && !!r[kind];
}

/** Does tapping photo `index` (0-based) of `total` need the number? Never on a car with only the free photos. */
export function photoLocked(index: number, total: number, r: GateRules | null | undefined): boolean {
  if (!gateOn(r, 'gallery')) return false;
  const free = Math.max(1, Math.floor(r!.free_photos || 4));
  return total > free && index >= free;
}

/** How many photos a car card may show on hover or swipe, the cover included (2026-11-06): 5, or fewer when the photo
 *  box leaves fewer free (4 by default since migration 0490). */
export function cardPhotoCap(r: GateRules | null | undefined): number {
  if (!gateOn(r, 'gallery')) return 5;
  return Math.min(5, Math.max(1, Math.floor(r!.free_photos || 4)));
}

export type GateNumber = { ok: true; phone: string; country: 'CA' | 'US' } | { ok: false; message: string };
/** A Canadian or US mobile number from what was typed. */
export function gateNumber(input: string | null | undefined): GateNumber {
  const phone = toE164(input);
  const c = phoneCountry(input);
  if (!phone || !c) return { ok: false, message: 'Enter a mobile number with its area code, for example 647 555 1234.' };
  if (c !== 'CA' && c !== 'US') return { ok: false, message: 'Enter a Canadian or US mobile number.' };
  return { ok: true, phone, country: c };
}

/** "(647) 555-1234" as it is typed: digits only, a leading 1 dropped, at most 10 digits. */
export function formatAsTyped(input: string): string {
  let d = input.replace(/\D/g, '');
  if (d.length > 10 && d.startsWith('1')) d = d.slice(1);
  d = d.slice(0, 10);
  if (d.length === 0) return '';
  if (d.length < 4) return `(${d}`;
  if (d.length < 7) return `(${d.slice(0, 3)}) ${d.slice(3)}`;
  return `(${d.slice(0, 3)}) ${d.slice(3, 6)}-${d.slice(6)}`;
}

// ---------------------------------------------------------------- remembering a device (90 days)
/** The first-party cookie that says this device gave a number: "<visitor id>.<expiry, seconds>". No number in it. */
export const PASS_COOKIE = 'cc_pg';
export const PASS_DAYS = 90;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

export function passValue(visitorId: string, nowMs: number, days = PASS_DAYS): string {
  return `${visitorId}.${Math.floor(nowMs / 1000) + days * 86400}`;
}
/** The pass is this visitor's and not expired. A pass of another visitor id (the cookie of a cleared visitor) is not. */
export function passValid(value: string | null | undefined, visitorId: string | null | undefined, nowMs: number): boolean {
  const m = /^([0-9a-f-]{36})\.(\d{9,11})$/.exec(String(value ?? ''));
  if (!m || !UUID.test(m[1]!) || !visitorId || m[1] !== visitorId) return false;
  return Number(m[2]) * 1000 > nowMs;
}
/** A number this device already typed into the request form (its saved draft) counts as given. */
export function draftPhone(raw: string | null | undefined): string | null {
  try {
    const s = JSON.parse(raw ?? 'null') as { data?: { phone?: unknown } } | null;
    const p = typeof s?.data?.phone === 'string' ? s.data.phone : '';
    const n = gateNumber(p);
    return n.ok ? n.phone : null;
  } catch { return null; }
}
