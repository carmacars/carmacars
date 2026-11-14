import type { RequestData, RequestRules } from './schema';

// Release 45 (2860): a signed-in renter's request fills itself from their profile (public.server_request_profile), and
// staff picking an existing renter see the same profile (ops_read renter_profile_fill). Only empty fields are filled, so
// a draft or what the person typed always wins; what is out of date is flagged for them to update.
export interface ProfileDriver { full_name: string; first: string; last: string; date_of_birth: string | null; email: string | null; licence_class: string | null }
export interface RenterProfile {
  renter_id: string; legal_name: string; first: string; last: string; date_of_birth: string | null; email: string | null; mobile: string | null;
  notify_channel: 'email' | 'text' | 'both' | null;
  address: { line1: string; line2: string | null; city: string | null; province: string | null; postal_code: string | null; country: string | null; updated_at: string | null } | null;
  licence: { class: string | null; issuer: string | null; expiry: string | null; number?: string | null; number_end: string | null } | null;
  drivers: ProfileDriver[];
  stale: { licence_expired: boolean; address_old: boolean; address_max_months: number };
}

const dobParts = (iso: string | null) => {
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(iso ?? '');
  return m ? { dobY: m[1]!, dobM: String(Number(m[2])), dobD: String(Number(m[3])) } : null;
};

/** The request with every empty field the profile has filled; `filled` names the fields it filled. */
export function fillFromProfile(d: RequestData, p: RenterProfile, rules: Pick<RequestRules, 'licenceClasses' | 'otherLicence'>): { data: RequestData; filled: string[] } {
  const x: RequestData = { ...d };
  const filled: string[] = [];
  if (!x.first && p.first) { x.first = p.first; filled.push('first'); }
  if (!x.last && p.last) { x.last = p.last; filled.push('last'); }
  const dob = dobParts(p.date_of_birth);
  if (dob && !x.dobY && !x.dobM && !x.dobD) { Object.assign(x, dob); filled.push('dob'); }
  const cls = (p.licence?.class ?? '').trim();
  if (!x.licClass && cls) {
    const known = rules.licenceClasses.find((c) => c.toUpperCase() === cls.toUpperCase());
    if (known) { x.licClass = known; filled.push('licClass'); }
    else if (rules.otherLicence) { x.licClass = 'other'; filled.push('licClass'); if (!x.licIssuer && p.licence?.issuer) { x.licIssuer = p.licence.issuer; filled.push('licIssuer'); } }
  }
  if (!x.notifyChannel && p.notify_channel) { x.notifyChannel = p.notify_channel; filled.push('notifyChannel'); }
  return { data: x, filled };
}

/** The additional drivers on file not on the request yet (the person adds them with one tap: each may add a fee). */
export function driversToOffer(d: RequestData, p: RenterProfile): ProfileDriver[] {
  const on = new Set(d.drivers.map((x) => `${x.first} ${x.last}`.trim().toLowerCase()));
  return p.drivers.filter((x) => x.full_name && !on.has(`${x.first} ${x.last}`.trim().toLowerCase()));
}

/** A driver on file as a row of the request's drivers. */
export function driverRow(x: ProfileDriver): RequestData['drivers'][number] {
  const dob = dobParts(x.date_of_birth) ?? { dobY: '', dobM: '', dobD: '' };
  return { first: x.first, last: x.last, email: x.email ?? '', licClass: x.licence_class ?? '', ...dob };
}

const day = (iso: string) => new Intl.DateTimeFormat('en-CA', { timeZone: 'UTC', month: 'long', day: 'numeric', year: 'numeric' }).format(new Date(`${iso.slice(0, 10)}T12:00:00Z`));

/** What on file is out of date (an expired licence, one that expires before the return, an old address), in the words of
 *  the renter's own form, or of staff (staff: true) who ask the renter about it. */
export function profileFlags(p: RenterProfile, ctx: { todayIso: string; returnIso?: string | null; staff?: boolean }): Array<{ key: 'licence' | 'address'; message: string }> {
  const out: Array<{ key: 'licence' | 'address'; message: string }> = [];
  const your = ctx.staff ? 'The renter\'s' : 'Your';
  const where = ctx.staff ? 'Ask them for the new one.' : 'Update it in your profile before pickup.';
  const exp = p.licence?.expiry ?? null;
  if (exp && (p.stale.licence_expired || exp < ctx.todayIso)) out.push({ key: 'licence', message: `${your} licence on file expired on ${day(exp)}. ${where}` });
  else if (exp && ctx.returnIso && /^\d{4}-\d{2}-\d{2}$/.test(ctx.returnIso) && exp < ctx.returnIso) out.push({ key: 'licence', message: `${your} licence on file expires on ${day(exp)}, before the return. ${where}` });
  if (p.address && p.stale.address_old) out.push({ key: 'address', message: `${your} home address on file was last updated over ${p.stale.address_max_months} months ago. ${ctx.staff ? 'Check it with them.' : 'Check it in your profile.'}` });
  return out;
}

/** The licence on file in a few words: "Class G, ON, ending 1234, expires March 3, 2030". */
export function licenceWords(l: RenterProfile['licence'], full = false): string {
  if (!l) return '';
  return [l.class ? `Class ${l.class}` : '', l.issuer ?? '', full && l.number ? l.number : l.number_end ? `ending ${l.number_end}` : '', l.expiry ? `expires ${day(l.expiry)}` : ''].filter(Boolean).join(', ');
}

/** The address on file in one line. */
export function addressWords(a: RenterProfile['address']): string {
  if (!a) return '';
  return [a.line1, a.line2, a.city, a.province, a.postal_code].filter((x) => x && String(x).trim()).join(', ');
}
