// The rental agreement as one list of blocks, filled from the booking (public.server_agreement_facts).
// The screen (AgreementView) and the PDF (pdf.ts) both render these blocks, so what the renter reads
// is what the PDF holds. Text markup inside blocks: **bold** only.
// Relative imports with their extension: the unit tests render these documents in Node directly (render.test.ts).
import { companyParty, money, phone } from '../../lib/format.ts';
import { AGREEMENT_CLOSING, AGREEMENT_PARTS, AGREEMENT_TEMPLATE_VERSION } from './source.generated.ts';
import { carName, depositText, fuelLabel, km, paidText, stageLines, sum, type AgreementExtra, type VersionHeader } from './extra.ts';
import { shortWording, wordedPart, wordingNotice, type Wording } from './wording.ts';

export type Block =
  | { t: 'title'; text: string }
  | { t: 'h2'; text: string }
  | { t: 'h3'; text: string }
  | { t: 'p'; text: string }
  | { t: 'ul' | 'ol'; items: string[] }
  | { t: 'table'; head: string[]; rows: string[][]; kv?: boolean }
  | { t: 'signatures'; rows: SignatureRow[] }
  | { t: 'initials'; rows: InitialRow[] };

/** A key term the signer initialled (0154): the image is drawn from PdfExtras.initials by its code. */
export interface InitialRow { code: string; title: string; text: string; when: string; typed?: string | null }

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
  coverage: { coverage_option: number; insurer_name: string | null; policy_number: string | null; policy_expiry: string | null; card_issuer: string | null; card_last4: string | null; status: string;
    /** 0178: the card coverage's provider (usually Assurant) and the protection plan's activation reference */
    coverage_provider?: string | null; activation_ref?: string | null } | null;
  company: { legal_name: string | null; trade_name: string | null; email: string | null; phone: string | null; address: string | null; incident_line: string | null; deductible_cents: number | null };
  /** A long rental's period this version covers (long rentals, 0148); null or absent when the rental fits in one period. */
  period?: { seq: number; of: number; starts_at: string; ends_at: string; days: number; amount_cents: number } | null;
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

export function markdown(body: string, values: Record<string, string>): Block[] {
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
const COVERAGE: Record<number, string> = { 1: '1: OPCF 27 on your own auto policy', 2: '2: rental coverage on your credit card', 3: '3: the CarmaCars Protection Plan', 4: '4: insurance included with the car (no personal auto policy needed)' };

export interface BuildOptions {
  signatures?: SignatureRow[]; privacyUrl: string;
  /** 0154: the facts beyond the booking's own (deposit, payments, every line, the pickup and return records...) */
  extra?: AgreementExtra | null;
  /** 0154: the insurance replacement (a booking billed to an insurer), from public.server_blindspot_facts */
  insurer?: { name: string | null; claim_number: string | null; adjuster_name: string | null; adjuster_phone: string | null; authorized_days: number | null; authorized_daily_rate_cents: number | null } | null;
  /** 0154: the 3+ day rate (rate applied multi_day) */
  multiDayRateCents?: number | null;
  /** 0154: a version after the signed original: what changed */
  version?: VersionHeader | null;
  /** 0154: the key terms initialled (the signed copy) */
  initials?: InitialRow[] | null;
  /** 0198: the booking's own wording of clauses (an Admin's change), merged into Parts 2, 3 and 5 */
  wording?: Wording | null;
}

const KIND_LABEL: Record<string, string> = { pickup: 'as picked up', return: 'as returned', change: 'changed', correction: 'corrected' };

/** The version's header: which version, what it replaces, what changed. */
function versionBlocks(v: VersionHeader): Block[] {
  const out: Block[] = [{ t: 'h2', text: `Version ${v.version_no} (${KIND_LABEL[v.kind] ?? v.kind})` }];
  const lead = v.kind === 'pickup' ? `This copy records the car as it was handed over (the Pickup record below). The agreement the Renter signed${v.original_signed_at ? ` on ${when(v.original_signed_at)}` : ''} stays as signed; this copy replaces version ${v.previous_no} as the current record and is countersigned by CarmaCars staff who did the check-out.`
    : v.kind === 'return' ? `This is the closing copy: the car as it came back, the kilometres, the fuel, the lateness, the return charges and the final totals (the Return record below). The agreement as signed stays as signed; this copy replaces version ${v.previous_no} as the current record and is countersigned by CarmaCars staff who did the check-in.`
    : v.material ? `The booking changed after the agreement was signed. This version replaces version ${v.previous_no}${v.amendment_number ? `; the Renter signed the change as amendment ${v.amendment_number}` : ' once the Renter (and each driver it affects) signs it; until then version ' + v.previous_no + ' applies'}.`
    : `Details were corrected after the agreement was signed. Nothing the Renter agreed to changes, so this version is filed without signing again; it replaces version ${v.previous_no} as the current record.`;
  out.push({ t: 'p', text: lead });
  if (v.changes.length) out.push({ t: 'table', head: ['What changed', 'Before', 'Now'], rows: v.changes.map((c) => c.key?.startsWith('wording.')
    ? [c.label + (c.material ? ' (signed again)' : ''), shortWording(c.before), shortWording(c.after)]
    : [c.label + (c.material ? ' (signed again)' : ''), c.before, c.after]) });
  return out;
}

/** The pickup record: the car as handed over. */
function pickupBlocks(f: AgreementFacts, x: AgreementExtra): Block[] {
  const p = x.pickup!;
  const v = p.vehicle ?? x.vehicle;
  const rows: string[][] = [
    ['Time out', when(p.at) + (p.completed ? '' : ' (check-out in progress; readings taken before signing)')],
    ['Odometer out (K/M out)', km(p.odometer_km)],
    ['Fuel or charge out', fuelLabel(p.fuel_pct)],
    ['Car handed over', `${carName(v)}${v?.colour ? `, ${v.colour}` : ''}  Plate: ${v?.plate ?? ''}  VIN: ${v?.vin ?? ''}${v?.fleet_number ? `  Fleet no.: ${v.fleet_number}` : ''}`],
    ['Keys handed over', p.keys === null ? '' : String(p.keys)],
    ['Damage noted at pickup', p.damages.length ? p.damages.map((d) => `${d.label}: ${[d.location, d.description].filter(Boolean).join(', ')}`).join('; ') : 'None marked'],
    ['Condition report', `Check-out report ${p.report_id.slice(0, 8).toUpperCase()} with ${p.photos} photos (in the booking's Photo reports)`],
    ['Checked out by', p.staff_name ?? 'CarmaCars staff']
  ];
  void f;
  return [{ t: 'h3', text: 'Pickup record' }, { t: 'table', head: ['Item', 'At pickup'], rows, kv: true }];
}

/** The return record: the car as it came back, the return charges and the final totals. */
function returnBlocks(f: AgreementFacts, x: AgreementExtra): Block[] {
  const r = x.return!;
  const late = r.minutes_late > 0 ? `${Math.floor(r.minutes_late / 60)} h ${r.minutes_late % 60} min after the due-back time${r.extra_days ? `: ${r.extra_days} extra day${r.extra_days === 1 ? '' : 's'} charged` : ' (within the grace period)'}` : 'On time';
  const rows: string[][] = [
    ['Time in', when(r.at)],
    ['Odometer in (K/M in)', km(r.odometer_km)],
    ['Kilometres driven', km(r.km_driven)],
    ['Kilometres included', r.km_allowed === null ? 'Unlimited' : km(r.km_allowed)],
    ['Kilometres charged', `${km(r.km_charged)}${r.km_charged && f.booking.overage_cents_per_km ? ` at ${money(f.booking.overage_cents_per_km, { cents: true })} per km` : ''}`],
    ['Fuel or charge in', `${fuelLabel(r.fuel_pct)}${r.fuel_out_pct !== null ? ` (out: ${fuelLabel(r.fuel_out_pct)})` : ''}`],
    ['Late', late],
    ['Keys returned', r.keys === null ? '' : String(r.keys)],
    ['New damage', r.new_damages.length ? r.new_damages.map((d) => `${d.label}: ${[d.location, d.description].filter(Boolean).join(', ')}`).join('; ') : 'None'],
    ['Condition report', `Check-in report ${r.report_id.slice(0, 8).toUpperCase()} with ${r.photos} photos (in the booking's Photo reports)`],
    ['Checked in by', r.staff_name ?? 'CarmaCars staff']
  ];
  const ret = stageLines(x, ['check_in', 'after_return']);
  const all = x.lines;
  const paid = x.payments.filter((p) => p.purpose !== 'deposit').reduce((s, p) => s + p.amount_cents, 0);
  const total = sum(all) + sum(all, 'hst_cents');
  const out: Block[] = [{ t: 'h3', text: 'Return record' }, { t: 'table', head: ['Item', 'At return'], rows, kv: true }];
  out.push({ t: 'table', head: ['Return charge', 'Amount'], kv: true, rows: ret.length
    ? [...ret.map((l) => [l.description, money(l.amount_cents, { cents: true })]), ['HST on return charges', money(sum(ret, 'hst_cents'), { cents: true })]]
    : [['None', money(0, { cents: true })]] });
  out.push({ t: 'table', head: ['Final totals', 'Amount'], kv: true, rows: [
    ['All charges before HST', money(sum(all), { cents: true })],
    ['HST', money(sum(all, 'hst_cents'), { cents: true })],
    ['**Total charges**', `**${money(total, { cents: true })}**`],
    ['Paid', money(paid, { cents: true })],
    ['Deposit', depositText(x)],
    [total - paid >= 0 ? '**Balance due from the Renter**' : '**Balance due to the Renter**', `**${money(Math.abs(total - paid), { cents: true })}**`]
  ] });
  return out;
}

export function agreementBlocks(f: AgreementFacts, o: BuildOptions): Block[] {
  const b = f.booking;
  const r = f.renter;
  const renter = f.drivers.find((d) => d.role === 'renter');
  const extra = f.drivers.filter((d) => d.role === 'additional');
  const v = f.vehicle;
  const address = r ? [r.address_line1, r.address_line2, r.city, [r.province, r.postal_code].filter(Boolean).join(' '), r.country].filter((x) => x && String(x).trim()).join(', ') : '';
  const x = o.extra ?? null;
  const rate = b.rate_applied === 'monthly' ? (b.billable_days === 30 ? `30 days: monthly rate ${money(b.monthly_rate_cents)}` : `${b.billable_days} days at the monthly rate: ${money(b.monthly_rate_cents)} ÷ 30 × ${b.billable_days} days`)
    : b.rate_applied === 'weekly' ? `7 to 29 days: weekly rate ${money(b.weekly_rate_cents)} ÷ 7 × ${b.billable_days} days`
    : b.rate_applied === 'multi_day' && o.multiDayRateCents ? `3 days or more: ${b.billable_days} days × ${money(o.multiDayRateCents)}`
    : b.rate_applied === 'manual' || b.rate_applied === 'custom' ? `${b.billable_days} days, rental charge ${money(b.rental_charge_cents, { cents: true })} as agreed`
    : `1 to 6 days: ${b.daily_days ?? 0} daily days × ${money(b.daily_rate_cents)}, plus ${b.weekend_days ?? 0} weekend days × ${money(b.weekend_rate_cents)}`;
  const licence = (d?: AgreementFacts['drivers'][number]) => d ? `No.: ${or(d.licence_number)}  Class: ${or(d.licence_class)}  Issued by: ${or(issuerName(d.licence_issuer))}  Expiry: ${or(day(d.licence_expiry))}` : LATER;
  const cov = f.coverage;
  const coverageText = b.coverage_option ? `${COVERAGE[b.coverage_option] ?? b.coverage_option}${cov?.coverage_option === 1 && cov.insurer_name ? ` (${cov.insurer_name}, policy ${cov.policy_number ?? ''}, expiry ${day(cov.policy_expiry)})` : ''}${cov?.coverage_option === 2 && cov.card_issuer ? ` (${cov.card_issuer}, last four digits ${cov.card_last4 ?? ''})` : ''}. Proof confirmed: ${cov?.status === 'approved' ? 'yes' : 'not yet'}` : 'To be chosen before pickup';
  const deductible = b.deductible_cents ?? f.company.deductible_cents;

  const summary: string[][] = [
    ...(b.agreement_number ? [['Agreement number', b.agreement_number]] : []),
    ['Booking number / made on', `${b.booking_number} / ${when(b.booked_at ?? b.requested_at)}`],
    ['Booking type', `${BOOKING_TYPE[b.booking_type] ?? b.booking_type}${b.renews_booking_id ? ', renewal of an earlier agreement' : ''}`],
    ['Renter', `Name: ${or(r?.legal_name)}  Date of birth: ${or(day(r?.date_of_birth ?? renter?.date_of_birth))}  Address: ${or(address)}  Mobile: ${or(phone(r?.mobile))}  Email: ${or(r?.email)}`],
    ['Renter licence', licence(renter)],
    ...(extra.length ? extra.map((d) => ['Additional Driver', `Name: ${d.full_name}  Date of birth: ${or(day(d.date_of_birth))}${x ? `  Address: ${or(x.drivers[d.id]?.address)}` : ''}  Licence: ${licence(d)}`]) : [['Additional Drivers', 'None']]),
    ['Identity verified', f.drivers.map((d) => `${d.full_name}: ${d.identity_verified_on ? `${d.identity_method === 'identity_service' ? 'identity check service' : 'staff review'}, ${day(d.identity_verified_on)}` : 'before pickup'}`).join('; ')],
    ['Vehicle', v ? `${v.year} ${v.make} ${v.model}${v.trim ? ` ${v.trim}` : ''}${v.colour ? `, ${v.colour}` : ''}${v.fuel ? `, ${v.fuel.replace(/_/g, ' ')}` : ''}  Plate: ${or(v.plate, 'given at pickup')}  VIN: ${or(v.vin, 'given at pickup')}${x?.vehicle?.fleet_number ? `  Fleet no.: ${x.vehicle.fleet_number}` : ''}` : ''],
    // a car swapped during the rental: the car it started with, and each swap
    ...(x && x.swaps.length ? x.swaps.map((s) => ['Car swapped', `${when(s.at)}: ${carName(s.from)} (plate ${s.from.plate ?? ''}${s.from_km_in !== null ? `, in at ${km(s.from_km_in)}` : ''}) replaced by ${carName(s.to)} (plate ${s.to.plate ?? ''}, VIN ${s.to.vin ?? ''}${s.to_km_out !== null ? `, out at ${km(s.to_km_out)}` : ''}). Reason: ${s.reason}`]) : []),
    ['Pickup', `${when(b.pickup_at)}, ${b.pickup_place ?? 'our location'}. ${b.pickup_method === 'delivered' ? 'Delivered by us' : 'Collected by you'}`],
    ['Return', `${when(b.return_at)}, ${b.return_place ?? 'our location'}. ${b.return_method === 'picked_up' ? 'Picked up by us' : 'Returned by you'}`],
    ['Length', f.period ? `${b.billable_days} days in all, in ${f.period.of} periods, each with its own agreement` : `${b.billable_days} day${b.billable_days === 1 ? '' : 's'}`],
    ...(f.period ? [['This agreement covers', `Period ${f.period.seq} of ${f.period.of}: ${when(f.period.starts_at)} to ${when(f.period.ends_at)} (${f.period.days} days). Rent and fees for this period, with HST: ${money(f.period.amount_cents)}. The terms of the earlier periods' agreements continue unchanged.`]] : []),
    ['Rate', rate],
    ['Mileage', b.km_allowance_per_day === null ? 'Unlimited kilometres' : `Allowance: ${b.km_allowance_per_day} km per day × ${b.billable_days} days = ${b.km_allowance_total ?? 0} km  Overage: ${money(b.overage_cents_per_km, { cents: true })} per km`],
    ['Deposit', x ? depositText(x) : `${money(b.deposit_cents)}, taken at pickup: a card hold for rentals of 7 days or less, otherwise charged and refunded`],
    ...(x ? [['Payment', paidText(x, f.card)]] : []),
    ...(x && x.late.grace_minutes !== null ? [['Late return', `After a grace period of ${x.late.grace_minutes} minutes, each extra day or part day at the daily rate${x.late.fee_cents ? `, plus a late fee of ${money(x.late.fee_cents)}` : ''}`]] : []),
    ['Coverage Option', coverageText + (b.coverage_option === 3 ? (() => { const pp = f.lines.filter((l) => l.charge_type === 'coverage_sold').reduce((t, l) => t + l.amount_cents, 0); return pp ? ` (${money(pp, { cents: true })} for the rental)` : ''; })() : '')],
    // an insurance replacement rental: who pays, the claim, the insured's policy and vehicle
    ...(o.insurer ? [['Billed to', `${or(o.insurer.name, '')}  Claim: ${or(o.insurer.claim_number)}  Adjuster: ${or(o.insurer.adjuster_name)}${o.insurer.adjuster_phone ? `, ${phone(o.insurer.adjuster_phone)}` : ''}${o.insurer.authorized_days ? `  Authorized: ${o.insurer.authorized_days} days${o.insurer.authorized_daily_rate_cents ? ` at ${money(o.insurer.authorized_daily_rate_cents)} a day` : ''}` : ''}${x?.insurer_policy ? `  Insured's policy: ${or(x.insurer_policy.policy_number)}${x.insurer_policy.province ? ` (${x.insurer_policy.province})` : ''}${x.insurer_policy.expiry ? `, expires ${day(x.insurer_policy.expiry)}` : ''}  Insured vehicle: ${or(x.insurer_policy.insured_vehicle)}` : ''}`]] : []),
    ['Deductible', money(deductible)],
    // add-ons (0066): named in the summary; each is a charge line below
    ...(() => { const ad = f.lines.filter((l) => ['addon', 'baby_seat', 'winter_tire'].includes(l.charge_type) && l.stage === 'booking').map((l) => l.description);
      return ad.length ? [['Add-ons', ad.join('; ')]] : []; })(),
    ['Card on File', f.card ? `${f.card.brand.toUpperCase()} ending ${f.card.last4}  Cardholder: ${or(f.card.cardholder_name, '')}` : 'Saved when you pay at booking']
  ];
  const charges: string[][] = f.lines.map((l) => [l.description, money(l.amount_cents, { cents: true })]);
  charges.push(['HST', money(b.hst_at_booking_cents, { cents: true })]);
  charges.push([`**Total due at booking**${x && (x.deposit.pay_method === 'none' || !x.deposit.amount_cents) ? '' : ' (the Deposit is taken at pickup)'}`, `**${money(b.total_due_at_booking_cents, { cents: true })}**`]);
  // 0154: charges added since booking (an extension, a fee added at pickup), each with its HST
  const since = x ? stageLines(x, ['extension', 'pickup', 'monthly']) : [];

  const values = { privacyUrl: o.privacyUrl };
  const company = f.company;
  const sigRows: SignatureRow[] = o.signatures ?? [
    { party: 'Renter', name: or(r?.legal_name, renter?.full_name ?? ''), signature: '', when: '' },
    ...extra.map((d) => ({ party: 'Additional Driver', name: d.full_name, signature: '', when: '' })),
    { party: 'CarmaCars', name: '', signature: 'Applied when the booking is confirmed', when: '' }
  ];
  const blocks: Block[] = [
    { t: 'title', text: 'CarmaCars Rental Agreement' },
    ...(o.version ? versionBlocks(o.version) : []),
    { t: 'h2', text: 'Part 1: Rental Summary' },
    { t: 'p', text: `This Agreement is between ${companyParty(f.company.legal_name, f.company.trade_name)} ("CarmaCars", "we", "us") and the Renter named below ("you").` },
    { t: 'table', head: ['Item', 'Details'], rows: summary, kv: true },
    { t: 'table', head: ['Charge', 'Amount'], rows: charges, kv: true },
    ...(since.length ? [{ t: 'table' as const, head: ['Added since booking', 'Amount'], kv: true, rows: [...since.map((l) => [l.description, money(l.amount_cents, { cents: true })]),
      ['HST on these', money(sum(since, 'hst_cents'), { cents: true })], ['**Total with the additions**', `**${money(b.total_due_at_booking_cents + sum(since) + sum(since, 'hst_cents'), { cents: true })}**`]] }] : []),
    ...(x?.pickup ? pickupBlocks(f, x) : []),
    ...(x?.return ? returnBlocks(f, x) : []),
    { t: 'p', text: 'Other Charges may arise during or after the rental under Parts 2 and 3.' },
    ...(() => { const n = wordingNotice(o.wording, b.booking_type); return n ? [{ t: 'p' as const, text: `**${n}**` }] : []; })(),
    { t: 'p', text: AGREEMENT_CLOSING },
    ...(o.initials?.length ? [{ t: 'h3' as const, text: 'Key terms initialled' }, { t: 'initials' as const, rows: o.initials }] : []),
    { t: 'signatures', rows: sigRows },
    { t: 'p', text: [company.phone && `CarmaCars: phone ${company.phone}`, company.email && `email ${company.email}`, company.address && `address ${company.address}`].filter(Boolean).join(', ') + (company.incident_line ? `. 24-hour incident and roadside line: ${company.incident_line}.` : '.') }
  ];
  const parts: Array<'2' | '3' | '5' | '6'> = b.booking_type === 'owner' ? ['2', '3', '5', '6'] : ['2', '3', '6'];
  for (const n of parts) {
    const part = wordedPart(n, o.wording);
    blocks.push({ t: 'h2', text: `Part ${n}: ${part.title}` });
    blocks.push(...markdown(n === '6' ? part.body.replace(/☐ /g, '') : part.body, values));
  }
  return blocks;
}

export { AGREEMENT_TEMPLATE_VERSION };
