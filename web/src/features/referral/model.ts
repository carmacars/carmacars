// Referral partners (migration 0164): the words, the link of a partner's own page and the RentalCoverage link, in one place with
// no imports so the Worker, the pages and `node --test` share them.
export type PartnerKind = 'body_shop' | 'tow_truck' | 'dealership' | 'insurance_broker';
export const KIND_OPTIONS: Array<[PartnerKind, string]> = [['body_shop', 'Body shop'], ['tow_truck', 'Tow truck company'], ['dealership', 'Dealership'], ['insurance_broker', 'Insurance broker']];
export const kindLabel = (k: string) => KIND_OPTIONS.find(([v]) => v === k)?.[1] ?? k.replace(/_/g, ' ');

export const STATUS_WORDS: Record<string, string> = { pending: 'Waiting for approval', active: 'Active', paused: 'Paused', ended: 'Ended', declined: 'Declined' };
export const EARNING_WORDS: Record<string, string> = { accruing: 'Rental not finished yet', pending_approval: 'Pending approval', approved: 'Approved, to pay', paid: 'Paid', reversed: 'Reversed', void: 'Void' };
export const PAYOUT_METHODS: Array<[string, string]> = [['e_transfer', 'e-Transfer'], ['cheque', 'Cheque'], ['bank_transfer', 'Bank transfer'], ['cash', 'Cash'], ['other', 'Another way']];

/** A partner's referral code as it is typed or scanned: letters and digits only, upper case. */
export const cleanCode = (s: string | null | undefined) => String(s ?? '').replace(/[^A-Za-z0-9]/g, '').toUpperCase();
export const isCode = (s: string | null | undefined) => /^[A-Z0-9]{4,12}$/.test(String(s ?? ''));
/** What a visitor typed in "Did someone refer you?": a code when it looks like one (the database ignores a code nobody holds). */
export function typedReferralCode(s: string | null | undefined): string | null {
  const t = String(s ?? '').trim();
  return /^[A-Za-z0-9]{4,12}$/.test(t) ? t.toUpperCase() : null;
}

export const REFERRAL_COOKIE_DAYS = 60;
/** The short link of a partner: carmacars.ca/r/<CODE>. */
export const referralLink = (base: string, code: string) => `${base.replace(/\/$/, '')}/r/${code}`;

export const dollars = (cents: number) => `$${(cents / 100).toLocaleString('en-CA', { minimumFractionDigits: cents % 100 ? 2 : 0, maximumFractionDigits: 2 })}`;
export const rateWords = (kind: string, flatCents: number, bps: number) => (kind === 'flat' ? `${dollars(flatCents)} per completed rental` : `${bps / 100}% of the rental charge`);

// ---------------------------------------------------------------- the partner's own page
const enc = new TextEncoder();
/** The key in the address of a partner's own page: an HMAC of the partner and the link's version (nothing secret is stored; "New link" raises the version). */
export async function portalKey(secret: string, partnerId: string, version: number): Promise<string> {
  const k = await crypto.subtle.importKey('raw', enc.encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const mac = new Uint8Array(await crypto.subtle.sign('HMAC', k, enc.encode(`carmacars-referral-portal-v1:${partnerId}:${version}`)));
  return Array.from(mac.slice(0, 20), (b) => b.toString(16).padStart(2, '0')).join('');
}
/** Constant time. */
export async function portalKeyOk(secret: string, partnerId: string, version: number, given: string | null | undefined): Promise<boolean> {
  const want = await portalKey(secret, partnerId, version);
  const got = String(given ?? '');
  let d = want.length ^ got.length;
  for (let i = 0; i < want.length; i++) d |= want.charCodeAt(i) ^ (got.charCodeAt(i) || 0);
  return d === 0;
}

// ---------------------------------------------------------------- the RentalCoverage link
export const PLACEMENTS = ['requirements', 'card_guide', 'booking_step', 'booking_page', 'other'] as const;
export type Placement = (typeof PLACEMENTS)[number];
export const PLACEMENT_WORDS: Record<string, string> = { requirements: 'Requirements and coverage page', card_guide: 'Credit card coverage guide', booking_step: 'Booking request, coverage step', booking_page: 'A renter\'s booking page', other: 'Elsewhere' };
export const asPlacement = (s: string | null | undefined): Placement => ((PLACEMENTS as readonly string[]).includes(String(s)) ? (s as Placement) : 'other');

/** The link on the site: through /go/coverage, which counts the click and then sends the visitor on. */
export const coverageGo = (placement: Placement, booking?: string | null) => `/go/coverage?p=${placement}${booking ? `&b=${encodeURIComponent(booking)}` : ''}`;

/**
 * Where a click lands: the pasted link (a {id} in it is replaced by the affiliate ID) with UTM tags added, the affiliate's own
 * parameters kept. null when the link is not a usable https address.
 */
export function affiliateDestination(link: string | null | undefined, id: string | null | undefined, placement: Placement): string | null {
  if (!link || !/^https:\/\//.test(link)) return null;
  const hasId = link.includes('{id}');
  if (hasId && !String(id ?? '').trim()) return null;
  let u: URL;
  try { u = new URL(hasId ? link.split('{id}').join(encodeURIComponent(String(id).trim())) : link); } catch { return null; }
  if (u.protocol !== 'https:') return null;
  const set = (k: string, v: string) => { if (!u.searchParams.has(k)) u.searchParams.set(k, v); };
  set('utm_source', 'carmacars'); set('utm_medium', 'referral'); set('utm_campaign', `coverage_${placement}`);
  return u.toString();
}
