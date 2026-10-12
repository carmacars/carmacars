// The rental agreement as one list of blocks, filled from the booking (public.server_agreement_facts).
// The screen (AgreementView) and the PDF (pdf.ts) both render these blocks, so what the renter reads
// is what the PDF holds. Text markup inside blocks: **bold** only.
import { money } from '@/lib/format';
import { AGREEMENT_CLOSING, AGREEMENT_PARTS, AGREEMENT_TEMPLATE_VERSION } from './source.generated';

export type Block =
  | { t: 'title'; text: string }
  | { t: 'h2'; text: string }
  | { t: 'h3'; text: string }
  | { t: 'p'; text: string }
  | { t: 'ul' | 'ol'; items: string[] }
  | { t: 'table'; head: string[]; rows: string[][]; kv?: boolean }
  | { t: 'signatures'; rows: SignatureRow[] };

export interface SignatureRow { party: string; name: string; signature: string; when: string; image?: string | null }

export interface AgreementFacts {
  booking: {
    id: string; booking_number: string; agreement_number: string | null; booking_type: string; booked_at: string | null; requested_at: string | null;
    pickup_at: string; return_at: string; pickup_place: string | null; return_place: string | null; pickup_method: string; return_method: string;
    billable_days: number; rate_applied: string | null; daily_days: number | null; weekend_days: number | null;
    daily_rate_cents: number | null; weekend_rate_cents: number | null; weekly_rate_cents: number | null; monthly_rate_cents: number | null;
    rental_charge_cents: number; km_allowance_per_day: number | null; km_allowance_total: number | null; overage_cents_per_km: number | null;
    deposit_cents: number; deductible_cents: number | null; coverage_option: number | null; subtotal_at_booking_cents: number;
    hst_at_booking_cents: number; total_due_at_booking_cents: number; renter_due_at_booking_cents: number; offer_approved_version: number | null;
    offer_approved_at: string | null; renews_booking_id: string | null;
  };
  renter: { legal_name: string | null; date_of_birth: string | null; mobile: string | null; email: string | null; address_line1: string | null;
    address_line2: string | null; city: string | null; province: string | null; postal_code: string | null; country: string | null } | null;
  drivers: Array<{ id: string; driver_id: string; role: string; full_name: string; date_of_birth: string | null; licence_number: string | null;
    licence_class: string | null; licence_issuer: string | null; licence_expiry: string | null; identity_method: string | null; identity_verified_on: string | null }>;
  vehicle: { year: number; make: string; model: string; trim: string | null; colour: string | null; fuel: string | null; plate: string | null; vin: string | null } | null;
  lines: Array<{ charge_type: string; description: string; amount_cents: number; hst_cents: number; stage: string }>;
  card: { brand: string; last4: string; cardholder_name: string | null } | null;
  coverage: { coverage_option: number; insurer_name: string | null; policy_number: string | null; policy_expiry: string | null; card_issuer: string | null; card_last4: string | null; status: string } | null;
  company: { legal_name: string | null; trade_name: string | null; email: string | null; phone: string | null; address: string | null; incident_line: string | null; deductible_cents: number | null };
}

const TZ = 'America/Toronto';
export function when(iso: string | null | undefined, withTime = true): string {
  if (!iso) return '';
  const d = new Date(iso);
  const date = new Intl.DateTimeFormat('en-CA', { timeZone: TZ, weekday: 'short', month: 'short', day: 'numeric', year: 'numeric' }).format(d);
  if (!withTime) return date;
  const time = new Intl.DateTimeFormat('en-CA', { timeZone: TZ, hour: 'numeric', minute: '2-digit', hour12: true }).format(d)
    .replace(/\s?a\.?m\.?/i, ' a.m.').replace(/\s?p\.?m\.?/i, ' p.m.');
  return `${date}, ${time}`;
}
const day = (iso: string | null | undefined) => (iso ? when(`${iso.slice(0, 10)}T12:00:00Z`, false) : '');
const LATER = 'To be given before pickup';
const or = (v: string | null | undefined, fallback = LATER) => (v && String(v).trim() ? String(v) : fallback);
const ISSUERS: Record<string, string> = { ON: 'Ontario', QC: 'Quebec', BC: 'British Columbia', AB: 'Alberta', MB: 'Manitoba', SK: 'Saskatchewan', NS: 'Nova Scotia', NB: 'New Brunswick', NL: 'Newfoundland and Labrador', PE: 'Prince Edward Island', YT: 'Yukon', NT: 'Northwest Territories', NU: 'Nunavut' };
export const issuerName = (c: string | null | undefined) => (c ? ISSUERS[c] ?? c : '');

export const CONSENT_VERSION = AGREEMENT_TEMPLATE_VERSION;
export interface Consent { n: number; code: 'tracking_disabling' | 'identity_verification' | 'electronic_signature' | 'card_authorization'; title: string; text: string }
const CODES: Consent['code'][] = ['tracking_disabling', 'identity_verification', 'electronic_signature', 'card_authorization'];

/** The four statements of Part 6, word for word, in order. */
export function consents(): Consent[] {
  return AGREEMENT_PARTS['6'].body.split('\n').map((l) => l.match(/^(\d)\. ☐ \*\*(.+?)\*\* (.+)$/)).filter((m): m is RegExpMatchArray => !!m)
    .map((m) => ({ n: Number(m[1]), code: CODES[Number(m[1]) - 1]!, title: m[2]!.replace(/\.$/, ''), text: m[3]! }));
}
export const consentLine = (c: Consent) => `${c.title}. ${c.text}`;
export const SIGN_STATEMENT = 'I have read this Rental Agreement and I sign it electronically.';

function markdown(body: string, values: Record<string, string>): Block[] {
  const out: Block[] = [];
  const lines = body.replace(/\{\{(\w+)\}\}/g, (_, k: string) => values[k] ?? '').split('\n');
  let i = 0;
  while (i < lines.length) {
    const l = lines[i]!;
    if (!l.trim()) { i++; continue; }
    if (l.startsWith('### ')) { out.push({ t: 'h3', text: l.slice(4) }); i++; continue; }
    if (l.startsWith('|')) {
      const rows: string[][] = [];
      while (i < lines.length && lines[i]!.startsWith('|')) { rows.push(lines[i]!.split('|').slice(1, -1).map((c) => c.trim())); i++; }
      const [head, , ...body2] = rows;
      out.push({ t: 'table', head: head ?? [], rows: body2 });
      continue;
    }
    if (/^- /.test(l)) { const items: string[] = []; while (i < lines.length && /^- /.test(lines[i]!)) { items.push(lines[i]!.slice(2)); i++; } out.push({ t: 'ul', items }); continue; }
    if (/^\d\. /.test(l)) { const items: string[] = []; while (i < lines.length && /^\d\. /.test(lines[i]!)) { items.push(lines[i]!.replace(/^\d\. /, '')); i++; } out.push({ t: 'ol', items }); continue; }
    out.push({ t: 'p', text: l }); i++;
  }
  return out;
}

const BOOKING_TYPE: Record<string, string> = { standard: 'Standard', non_refundable: 'Non-refundable (10% discount)', owner: 'Owner Rental (Part 5 applies)' };
const COVERAGE: Record<number, string> = { 1: '1: OPCF 27 on your own auto policy', 2: '2: rental coverage on your credit card', 3: '3: purchased through CarmaCars' };

export interface BuildOptions { signatures?: SignatureRow[]; privacyUrl: string }

export function agreementBlocks(f: AgreementFacts, o: BuildOptions): Block[] {
  const b = f.booking;
  const r = f.renter;
  const renter = f.drivers.find((d) => d.role === 'renter');
  const extra = f.drivers.filter((d) => d.role === 'additional');
  const v = f.vehicle;
  const address = r ? [r.address_line1, r.address_line2, r.city, [r.province, r.postal_code].filter(Boolean).join(' '), r.country].filter((x) => x && String(x).trim()).join(', ') : '';
  const rate = b.rate_applied === 'monthly' ? `30 days: monthly rate ${money(b.monthly_rate_cents)}`
    : b.rate_applied === 'weekly' ? `7 to 29 days: weekly rate ${money(b.weekly_rate_cents)} ÷ 7 × ${b.billable_days} days`
    : `1 to 6 days: ${b.daily_days ?? 0} daily days × ${money(b.daily_rate_cents)}, plus ${b.weekend_days ?? 0} weekend days × ${money(b.weekend_rate_cents)}`;
  const licence = (d?: AgreementFacts['drivers'][number]) => d ? `No.: ${or(d.licence_number)}  Class: ${or(d.licence_class)}  Issued by: ${or(issuerName(d.licence_issuer))}  Expiry: ${or(day(d.licence_expiry))}` : LATER;
  const cov = f.coverage;
  const coverageText = b.coverage_option ? `${COVERAGE[b.coverage_option] ?? b.coverage_option}${cov?.coverage_option === 1 && cov.insurer_name ? ` (${cov.insurer_name}, policy ${cov.policy_number ?? ''}, expiry ${day(cov.policy_expiry)})` : ''}${cov?.coverage_option === 2 && cov.card_issuer ? ` (${cov.card_issuer}, last four digits ${cov.card_last4 ?? ''})` : ''}. Proof confirmed: ${cov?.status === 'approved' ? 'yes' : 'not yet'}` : 'To be chosen before pickup';
  const deductible = b.deductible_cents ?? f.company.deductible_cents;

  const summary: string[][] = [
    ...(b.agreement_number ? [['Agreement number', b.agreement_number]] : []),
    ['Booking number / made on', `${b.booking_number} / ${when(b.booked_at ?? b.requested_at)}`],
    ['Booking type', `${BOOKING_TYPE[b.booking_type] ?? b.booking_type}${b.renews_booking_id ? ', renewal of an earlier agreement' : ''}`],
    ['Renter', `Name: ${or(r?.legal_name)}  Date of birth: ${or(day(r?.date_of_birth ?? renter?.date_of_birth))}  Address: ${or(address)}  Mobile: ${or(r?.mobile)}  Email: ${or(r?.email)}`],
    ['Renter licence', licence(renter)],
    ...(extra.length ? extra.map((d) => ['Additional Driver', `Name: ${d.full_name}  Date of birth: ${or(day(d.date_of_birth))}  Licence: ${licence(d)}`]) : [['Additional Drivers', 'None']]),
    ['Identity verified', f.drivers.map((d) => `${d.full_name}: ${d.identity_verified_on ? `${d.identity_method === 'identity_service' ? 'identity check service' : 'staff review'}, ${day(d.identity_verified_on)}` : 'before pickup'}`).join('; ')],
    ['Vehicle', v ? `${v.year} ${v.make} ${v.model}${v.trim ? ` ${v.trim}` : ''}${v.colour ? `, ${v.colour}` : ''}${v.fuel ? `, ${v.fuel.replace(/_/g, ' ')}` : ''}  Plate: ${or(v.plate, 'given at pickup')}  VIN: ${or(v.vin, 'given at pickup')}` : ''],
    ['Pickup', `${when(b.pickup_at)}, ${b.pickup_place ?? 'our location'}. ${b.pickup_method === 'delivered' ? 'Delivered by us' : 'Collected by you'}`],
    ['Return', `${when(b.return_at)}, ${b.return_place ?? 'our location'}. ${b.return_method === 'picked_up' ? 'Picked up by us' : 'Returned by you'}`],
    ['Length', `${b.billable_days} days (30 days maximum)`],
    ['Rate', rate],
    ['Mileage', `Allowance: ${b.km_allowance_per_day ?? 0} km per day × ${b.billable_days} days = ${b.km_allowance_total ?? 0} km  Overage: ${money(b.overage_cents_per_km, { cents: true })} per km`],
    ['Deposit', `${money(b.deposit_cents)}, taken at pickup: a card hold for rentals of 7 days or less, otherwise charged and refunded`],
    ['Coverage Option', coverageText],
    ['Deductible', money(deductible)],
    ['Card on File', f.card ? `${f.card.brand.toUpperCase()} ending ${f.card.last4}  Cardholder: ${or(f.card.cardholder_name, '')}` : 'Saved when you pay at booking']
  ];
  const charges: string[][] = f.lines.map((l) => [l.description, money(l.amount_cents, { cents: true })]);
  charges.push(['HST', money(b.hst_at_booking_cents, { cents: true })]);
  charges.push(['**Total due at booking** (the Deposit is taken at pickup)', `**${money(b.total_due_at_booking_cents, { cents: true })}**`]);

  const values = { privacyUrl: o.privacyUrl };
  const company = f.company;
  const sigRows: SignatureRow[] = o.signatures ?? [
    { party: 'Renter', name: or(r?.legal_name, renter?.full_name ?? ''), signature: '', when: '' },
    ...extra.map((d) => ({ party: 'Additional Driver', name: d.full_name, signature: '', when: '' })),
    { party: 'CarmaCars', name: '', signature: 'Applied when the booking is confirmed', when: '' }
  ];
  const blocks: Block[] = [
    { t: 'title', text: 'CarmaCars Rental Agreement' },
    { t: 'h2', text: 'Part 1: Rental Summary' },
    { t: 'p', text: 'This Agreement is between CarmaCars ("CarmaCars", "we", "us") and the Renter named below ("you").' },
    { t: 'table', head: ['Item', 'Details'], rows: summary, kv: true },
    { t: 'table', head: ['Charge', 'Amount'], rows: charges, kv: true },
    { t: 'p', text: 'Other Charges may arise during or after the rental under Parts 2 and 3.' },
    { t: 'p', text: AGREEMENT_CLOSING },
    { t: 'signatures', rows: sigRows },
    { t: 'p', text: [company.phone && `CarmaCars: phone ${company.phone}`, company.email && `email ${company.email}`, company.address && `address ${company.address}`].filter(Boolean).join(', ') + (company.incident_line ? `. 24-hour incident and roadside line: ${company.incident_line}.` : '.') }
  ];
  const parts: Array<'2' | '3' | '5' | '6'> = b.booking_type === 'owner' ? ['2', '3', '5', '6'] : ['2', '3', '6'];
  for (const n of parts) {
    blocks.push({ t: 'h2', text: `Part ${n}: ${AGREEMENT_PARTS[n].title}` });
    blocks.push(...markdown(n === '6' ? AGREEMENT_PARTS[n].body.replace(/☐ /g, '') : AGREEMENT_PARTS[n].body, values));
  }
  return blocks;
}

export { AGREEMENT_TEMPLATE_VERSION };
