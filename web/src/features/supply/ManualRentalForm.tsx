'use client';
import { useEffect, useMemo, useRef, useState, useTransition } from 'react';
import { AddressInput } from '@/features/forms/AddressInput';
import { AddressLookup } from '@/features/forms/AddressFields';
import Link from 'next/link';
import { createManualRental, draftClose, draftSave, supplyRead, type ManualRentalResult } from '@/server/actions/supply';
import { money } from '@/lib/format';
import { SourcedChoice, priceFlags, type Choice } from '@/features/sales/SourcedChoice';
import { PRICE_TAX_OPTIONS, PRICE_TAX_LABEL, type PriceTaxSplit } from '@/features/sales/priceTax';
import { AddonPicker } from '@/features/addons/AddonPicker';
import { Info } from '@/features/forms/Info';
import { FEE_LABEL, lineHelp } from '@/features/offers/help';
import { addonsPayload, type AddonChoice, type AddonOption } from '@/features/addons/model';
import { DEPOSIT_PAY, PART_METHODS, RENTAL_LINE, RENTAL_PAID_BY, feeOverrides, lineKey, needsReference, paidSoFar, paymentOf, periodShares, type DepositPay, type PayPart, type RentalPaidBy } from '@/features/offers/model';

// Add a rental by hand (migration 0046): Admin > Bookings > Add a rental, the same screen for every assistant function
// and for field staff (0058). The database decides what each may do (staff: the rate sheet or a price typed with its
// reason, the promo codes and ways of payment the settings allow, never over a clash, never a past rental; field staff:
// a payment link or the saved card, the renter's details typed) and refuses with the reason. Staff choose "I sourced
// this client" or "Entered for CarmaCars". The dates decide the case (0074): upcoming, already underway (recorded as on
// trip) or past (an Admin's, kept as completed); the form says which, with nothing to tick.
type Car = { id: string; name: string; plate: string | null; car_code?: string | null; supply_type: string; bookable: boolean; retired: boolean; daily_rate_cents: number | null;
  has_rates?: boolean; listing_finished?: boolean; listing_status?: string; needs_policy_confirm?: boolean; status?: string };
type Renter = { id: string; legal_name: string; email: string | null; mobile: string | null; date_of_birth: string | null; is_blocked: boolean; card: { brand: string; last4: string } | null; bookings: number };
type Line = { description: string; amount_cents: number; hst_cents: number; charge_type: string; booking_addon_id?: string | null; detail?: { code?: string; addon_id?: string; set_by_hand?: boolean } | null; set_by_hand?: boolean };
type Period = { seq: number; starts_at: string; ends_at: string; days: number };
type Quote = { role: 'admin' | 'va' | 'field'; phase?: Phase | null; phase_note?: string; free: boolean; clashes: Array<{ kind: string; booking_number?: string; status?: string; starts_at: string; ends_at: string | null; renter?: string; reason?: string; overlaps: boolean }>;
  turnaround_minutes: number; payment_modes: string[]; may_override_price: boolean; rate_sheet_cents: number | null; billable_days: number | null;
  price_floor_daily_cents: number | null; price_max_discount_bps: number | null; choice_required: boolean; may_search_renters: boolean; may_override_clash: boolean; may_record_past: boolean; may_promo: boolean; single_limit_cents: number | null;
  card: { brand: string; last4: string } | null; vehicle: { name: string; supply_type: string; bookable: boolean; retired: boolean };
  /** 0145: the insurers an insurance replacement can bill. */
  insurers?: Array<{ id: string; name: string }>;
  /** 0132: fee lines this person may set by hand; the monthly periods of a long rental. */
  may_edit_fees?: boolean; periods?: Period[];
  has_rates?: boolean; listing_finished?: boolean; needs_policy_confirm?: boolean; notes?: string[]; price_typed_cents?: number | null;
  /** The price typed, split by the database (0112): plus tax or tax included. */
  price_tax?: PriceTaxSplit | null;
  quote: { lines: Line[]; total_due_at_booking_cents: number; deposit_cents: number; km_allowance_total: number; billable_days: number; rate_rule: string; problems: Array<{ message: string }>; promo: { problem?: string } | null } };

// what each way means for a rental already underway (0074): it is on trip from the start
const LIVE_MODE: Record<string, string> = {
  link: 'The renter gets an email to sign the agreement, then pay online from their booking. The rental is on trip already.',
  card: 'The renter\'s card on file is charged when the renter signs the agreement (Accept and sign). The rental is on trip already.',
  unpaid: 'Recorded on trip now; the balance is collected later.'
};
const SOURCES: Array<[string, string]> = [['phone', 'Phone'], ['walk_in', 'Walk-in'], ['turo', 'Turo'], ['partner', 'Partner'], ['insurer', 'Insurer'], ['email', 'Email'], ['other', 'Other']];
const pad = (n: number) => String(n).padStart(2, '0');
const local = (d: Date) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
const iso = (s: string | undefined) => (s ? new Date(s).toISOString() : '');
const fmt = (c: number | null | undefined) => money(Number(c ?? 0), { cents: true });
const cents = (s: string) => (s.trim() ? Math.round(Number(s.replace(/[$,\s]/g, '')) * 100) : undefined);

export type Phase = 'upcoming' | 'in_progress' | 'past';
/** The case the dates make, as the database decides it (app.manual_rental_phase, 0074). */
export function phaseOf(pickup: string | undefined, ret: string | undefined, now = Date.now()): Phase | null {
  const a = pickup ? new Date(pickup).getTime() : NaN;
  const b = ret ? new Date(ret).getTime() : NaN;
  if (Number.isNaN(a) || Number.isNaN(b) || b <= a) return null;
  return b <= now ? 'past' : a <= now ? 'in_progress' : 'upcoming';
}
const PHASE_NOTE: Record<Phase, string> = {
  upcoming: 'This rental starts in the future: it is confirmed now and the car is handed over at pickup as usual.',
  in_progress: 'This rental is already underway: it will be recorded as on trip, picked up at the time you entered. Anything still missing (signature, licence check, coverage proof, deposit, condition report) becomes a task.',
  past: 'This rental has already ended: it will be recorded as completed, for the history and the statements.'
};

/** What a draft keeps (0145): every field of the form as typed. */
export interface MrDraft { f?: Record<string, string>; flags?: { do_not_email: boolean; new_renter: boolean; policy: boolean }; paid_by?: RentalPaidBy; deposit_by?: DepositPay;
  agreement?: 'send' | 'paper'; blocks?: boolean; fees?: Record<string, string>; parts?: PayPart[]; customs?: Array<{ label: string; amount: string; hst: boolean }>;
  rent_mode?: 'trip' | 'day'; rent_day?: string; renter?: Renter | null; renter_id?: string | null; drivers?: Array<{ full_name: string; date_of_birth: string; email: string }>; addons?: AddonChoice[]; choice?: Choice }
const FUEL: Array<[string, string]> = [['100', 'Full'], ['88', '7/8'], ['75', '3/4'], ['63', '5/8'], ['50', '1/2'], ['38', '3/8'], ['25', '1/4'], ['13', '1/8'], ['0', 'Empty']];

export function ManualRentalForm({ cars, base, isAdmin, draft = null }: { cars: Car[]; base: '/admin' | '/va' | '/field'; isAdmin: boolean; draft?: { id: string; data: MrDraft; held: boolean; quick?: boolean } | null }) {
  const field = base === '/field';
  const [choice, setChoice] = useState<Choice>(isAdmin ? 'for_carmacars' : '');
  const start0 = useMemo(() => { const d = new Date(Date.now() + 86_400_000); d.setMinutes(0, 0, 0); d.setHours(10); return d; }, []);
  const [f, setF] = useState<Record<string, string>>({ vehicle_id: '', pickup_at: local(start0), return_at: local(new Date(start0.getTime() + 3 * 86_400_000)),
    pickup_method: 'collected', return_method: 'returned', booking_type: 'standard', coverage_option: '1', price_tax: 'plus', source: 'phone', mode: base === '/field' ? 'link' : 'other_way', method: 'e_transfer',
    received_on: new Date().toLocaleDateString('en-CA', { timeZone: 'America/Toronto' }) });
  const [flags, setFlags] = useState({ do_not_email: false, new_renter: field, policy: false });
  // 0129: the rental and the deposit each paid its own way, paper or online signing, the calendar switch
  const [paidBy, setPaidBy] = useState<RentalPaidBy>(field ? 'link' : 'e_transfer');
  const [depositBy, setDepositBy] = useState<DepositPay>('card');
  const [agreement, setAgreement] = useState<'send' | 'paper'>('send');
  const [blocks, setBlocks] = useState(true);
  // 0132: fee lines typed by hand ({key: dollars}), the rental paid in more than one part
  const [fees, setFees] = useState<Record<string, string>>({});
  const [parts, setParts] = useState<PayPart[]>([]);
  const [rentMode, setRentMode] = useState<'trip' | 'day'>('trip');
  const [rentDay, setRentDay] = useState('');
  const [customs, setCustoms] = useState<Array<{ label: string; amount: string; hst: boolean }>>([]);
  const offline = ['e_transfer', 'cash', 'cheque', 'bank_transfer'].includes(paidBy);
  // add-ons (0066): the car's, with what is left for the dates; priced in the check below
  const [addons, setAddons] = useState<AddonChoice[]>([]);
  const [addonOptions, setAddonOptions] = useState<AddonOption[]>([]);
  useEffect(() => {
    if (!f.vehicle_id) return;
    let live = true;
    supplyRead<AddonOption[]>('addons_for_car', { vehicle_id: f.vehicle_id, pickup_at: iso(f.pickup_at), return_at: iso(f.return_at) })
      .then((r) => { if (live && r.ok) setAddonOptions(r.data ?? []); });
    return () => { live = false; };
  }, [f.vehicle_id, f.pickup_at, f.return_at]);
  const [q, setQ] = useState('');
  const [found, setFound] = useState<Renter[]>([]);
  const [renter, setRenter] = useState<Renter | null>(null);
  const [drivers, setDrivers] = useState<Array<{ full_name: string; date_of_birth: string; email: string }>>([]);
  const [quote, setQuote] = useState<Quote | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [done, setDone] = useState<ManualRentalResult | null>(null);
  // 0145: the draft, saved as typed (server, and this device as a fallback); Hold the car; Quick start at pickup
  const [draftId, setDraftId] = useState<string | null>(draft?.id ?? null);
  const [savedAt, setSavedAt] = useState<string | null>(null);
  const [saveErr, setSaveErr] = useState<string | null>(null);
  const [hold, setHold] = useState<boolean>(draft?.held ?? false);
  const [quick, setQuick] = useState<boolean>(draft?.quick ?? false);
  const [quickDone, setQuickDone] = useState<boolean>(draft?.quick ?? false);
  const [pending, start] = useTransition();
  const set = (k: string) => (e: { target: { value: string } }) => { setF((s) => ({ ...s, [k]: e.target.value })); if (['vehicle_id', 'pickup_at', 'return_at', 'booking_type', 'promo_code', 'coverage_option', 'pickup_method', 'return_method', 'date_of_birth'].includes(k)) setQuote(null); };
  const flag = (k: keyof typeof flags) => (e: { target: { checked: boolean } }) => { setFlags((s) => ({ ...s, [k]: e.target.checked })); };
  // the case the dates make, kept current while the dates are typed (the clock moves too)
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => { const t = setInterval(() => setNow(Date.now()), 30_000); return () => clearInterval(t); }, []);
  const phase = phaseOf(f.pickup_at, f.return_at, now);
  const past = phase === 'past';
  // the price typed, as the database split it at the last check (0112); tax included: flagged on its amount before tax
  const typed = cents(f.rental_charge ?? '');
  const split = quote?.price_tax && typed !== undefined && quote.price_tax.tax === f.price_tax
    && (f.price_tax === 'included' ? quote.price_tax.with_tax_cents : quote.price_tax.before_tax_cents) === typed ? quote.price_tax : null;
  const typedBeforeTax = f.price_tax === 'included' ? split?.before_tax_cents : typed;
  const id = (k: string) => `mr-${k}`;
  const text = (k: string, label: string, o: { type?: string; hint?: string; inputMode?: 'decimal' | 'numeric' | 'tel' | 'email'; wide?: boolean } = {}) => (
    <div className={`field ad-field${o.wide ? ' ad-field--wide' : ''}`}><label className="label" htmlFor={id(k)}>{label}</label>
      <input className="input" id={id(k)} type={o.type ?? 'text'} inputMode={o.inputMode} value={f[k] ?? ''} onChange={set(k)} data-testid={`mr-${k}`} aria-describedby={o.hint ? `${id(k)}-h` : undefined} />
      {o.hint && <p className="hint" id={`${id(k)}-h`}>{o.hint}</p>}</div>);
  // a place or an address, with the address lookup (0130): the suggestion fills it, typing works too
  const addr = (k: string, label: string) => (
    <div className="field ad-field"><label className="label" htmlFor={id(k)}>{label}</label>
      <AddressInput id={id(k)} name={k} value={{ label: f[k] ?? '', placeId: '' }} onChange={(x) => setF((s) => ({ ...s, [k]: x.label }))} testId={`mr-${k}`} /></div>);
  const select = (k: string, label: string, options: Array<[string, string]>) => (
    <div className="field ad-field"><label className="label" htmlFor={id(k)}>{label}</label>
      <select className="select" id={id(k)} value={f[k] ?? ''} onChange={set(k)} data-testid={`mr-${k}`}>{options.map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select></div>);

  // Quick start at pickup: its own fields (the same values as the full form below)
  const qtext = (k: string, label: string, mode?: 'numeric' | 'tel') => (
    <div className="field ad-field"><label className="label" htmlFor={id(`q-${k}`)}>{label}</label>
      <input className="input" id={id(`q-${k}`)} type="text" inputMode={mode} value={f[k] ?? ''} onChange={set(k)} data-testid={`mr-q-${k}`} /></div>);
  const spec = () => ({ vehicle_id: f.vehicle_id, pickup_at: iso(f.pickup_at), return_at: iso(f.return_at), booking_type: f.booking_type, coverage_option: Number(f.coverage_option),
    pickup_method: f.pickup_method, return_method: f.return_method, promo_code: f.promo_code || undefined, renter_id: renter?.id, rental_charge_cents: cents(f.rental_charge ?? ''),
    price_tax: cents(f.rental_charge ?? '') !== undefined ? f.price_tax : undefined,
    addons: addonsPayload(addons),
    ...(Object.keys(feeOverrides(fees)).length ? { line_overrides: feeOverrides(fees), fee_reason: f.fee_reason || undefined } : {}),
    ...(customs.some((c) => c.label.trim() && cents(c.amount)) ? { custom_fees: customs.filter((c) => c.label.trim() && cents(c.amount)).map((c) => ({ label: c.label.trim(), amount_cents: cents(c.amount), hst: c.hst })) } : {}),
    ...(f.km && /^\d+$/.test(f.km.trim()) ? { km_allowance_per_day: Number(f.km) } : {}),
    drivers: [{ role: 'renter', date_of_birth: renter?.date_of_birth ?? (f.date_of_birth || undefined) }, ...drivers.filter((d) => d.date_of_birth).map((d) => ({ role: 'additional', date_of_birth: d.date_of_birth }))] });
  const specNow = useRef('');
  specNow.current = JSON.stringify(spec());
  const [recheck, setRecheck] = useState(0);
  const check = () => start(async () => {
    setErr(null);
    if (!f.vehicle_id) { setErr('Choose the car.'); return; }
    if (!f.pickup_at || !f.return_at) { setErr('Enter the pickup and the return, each with a date and a time.'); return; }
    if (!phase) { setErr('The return must be after the pickup: check both dates and times.'); return; }
    if (past && !isAdmin) { setErr('This rental has already ended. Only an Admin can record it: check the return date and time, or ask an Admin to add it.'); return; }
    const key = JSON.stringify(spec());
    const r = await supplyRead<Quote>('manual_rental_quote', spec());
    // the form changed while this check was out (a date of birth typed, the coverage changed): check again, never keep a stale price
    if (key !== specNow.current) { setRecheck((n) => n + 1); return; }
    if (!r.ok) { setErr(r.message); setQuote(null); return; }
    setQuote(r.data);
    if (!field && !['platform_payout', 'insurer'].includes(paidBy) && !r.data.payment_modes.includes(paymentOf(paidBy).mode)) setPaidBy(r.data.payment_modes.includes('other_way') ? 'e_transfer' : r.data.payment_modes.includes('link') ? 'link' : 'unpaid');
  });
  const search = () => start(async () => {
    const r = await supplyRead<Renter[]>('manual_rental_renters', { q });
    if (r.ok) setFound(r.data); else setErr(r.message);
  });
  // the renter search as you type (0129): name, email or phone, no button to press
  useEffect(() => {
    if (renter || flags.new_renter || q.trim().length < 3) return;
    const t = setTimeout(async () => { const r = await supplyRead<Renter[]>('manual_rental_renters', { q }); if (r.ok) setFound(r.data); }, 350);
    return () => clearTimeout(t);
  }, [q, renter, flags.new_renter]);
  // the calendar and the price, checked by themselves once the car and the dates are in (0129: no button to press first)
  const auto = useRef(0);
  useEffect(() => {
    if (!f.vehicle_id || !phase || (past && !isAdmin) || quote) return;
    const n = ++auto.current;
    const t = setTimeout(() => { if (n === auto.current) check(); }, 500);
    return () => clearTimeout(t);
  }, [f.vehicle_id, f.pickup_at, f.return_at, f.booking_type, f.promo_code, f.coverage_option, f.pickup_method, f.return_method, f.date_of_birth, renter, addons, quote]); // eslint-disable-line react-hooks/exhaustive-deps

  // a rate a day typed: the trip's total follows the days
  useEffect(() => { if (rentMode !== 'day' || !quote) return; const c = cents(rentDay); const t = c === undefined ? '' : ((c * (quote.quote.billable_days || 1)) / 100).toFixed(2); if (t !== (f.rental_charge ?? '')) setF((x) => ({ ...x, rental_charge: t })); }, [quote?.quote.billable_days]); // eslint-disable-line react-hooks/exhaustive-deps
  // a check that came back stale: once more with the form as it is now
  useEffect(() => { if (!recheck) return; const t = setTimeout(() => check(), 250); return () => clearTimeout(t); }, [recheck]); // eslint-disable-line react-hooks/exhaustive-deps
  // a fee typed by hand: the price again, with the table kept on screen while typing (0132)
  const feeKey = JSON.stringify([feeOverrides(fees), f.rental_charge ?? '', f.price_tax, f.deposit ?? '', customs, f.km ?? '']);
  const firstFees = useRef(true);
  useEffect(() => {
    if (firstFees.current) { firstFees.current = false; return; }
    if (!quote) return;
    const t = setTimeout(() => check(), 600);
    return () => clearTimeout(t);
  }, [feeKey]); // eslint-disable-line react-hooks/exhaustive-deps

  // a quick start for the common cases (0129): where it came from and what goes with it
  const preset = (k: 'phone' | 'walk_in' | 'turo' | 'insurer' | 'owner' | 'dummy') => {
    setQuote(null);
    if (k === 'phone' || k === 'walk_in') { setF((x) => ({ ...x, source: k })); setPaidBy(field ? 'link' : 'e_transfer'); setBlocks(true); }
    if (k === 'turo') { setF((x) => ({ ...x, source: 'turo' })); setPaidBy('platform_payout'); setBlocks(true); }
    if (k === 'insurer') { setF((x) => ({ ...x, source: 'insurer' })); setPaidBy('insurer'); }
    if (k === 'owner') { setF((x) => ({ ...x, source: 'other', source_note: 'The owner using their own car', rental_charge: '0', price_reason: 'Owner using their own car' })); setPaidBy(isAdmin ? 'unpaid' : 'e_transfer'); if (isAdmin) setDepositBy('none'); setFlags((x) => ({ ...x, do_not_email: true })); }
    if (k === 'dummy') { setF((x) => ({ ...x, source: 'other', source_note: 'Placeholder booking (insurance or a hold)', rental_charge: '0', price_reason: 'Placeholder booking' })); setPaidBy(isAdmin ? 'unpaid' : 'e_transfer'); if (isAdmin) setDepositBy('none'); setFlags((x) => ({ ...x, do_not_email: true })); }
  };

  // a draft opened again: every field as it was left
  const restored = useRef(false);
  useEffect(() => {
    if (restored.current || !draft) return;
    restored.current = true;
    const d = draft.data;
    if (d.f) setF((x) => ({ ...x, ...d.f }));
    if (d.flags) setFlags(d.flags);
    if (d.paid_by) setPaidBy(d.paid_by);
    if (d.deposit_by) setDepositBy(d.deposit_by);
    if (d.agreement) setAgreement(d.agreement);
    if (typeof d.blocks === 'boolean') setBlocks(d.blocks);
    if (d.fees) setFees(d.fees);
    if (d.parts) setParts(d.parts);
    if (d.customs) setCustoms(d.customs);
    if (d.rent_mode) setRentMode(d.rent_mode);
    if (d.rent_day) setRentDay(d.rent_day);
    if (d.renter) setRenter(d.renter);
    if (d.drivers) setDrivers(d.drivers);
    if (d.addons) setAddons(d.addons);
    if (d.choice) setChoice(d.choice);
  }, [draft]);
  const snapshot: MrDraft = { f, flags, paid_by: paidBy, deposit_by: depositBy, agreement, blocks, fees, parts, customs, rent_mode: rentMode, rent_day: rentDay, renter, renter_id: renter?.id ?? null, drivers, addons, choice };
  const snapKey = JSON.stringify(snapshot);
  const localKey = `cc-draft-rental${base}`;
  const firstSnap = useRef(snapKey);
  const saveDraft = async (opts: { hold?: boolean; quick?: boolean } = {}) => {
    const title = [renter?.legal_name ?? f.full_name, cars.find((c) => c.id === f.vehicle_id)?.name].filter(Boolean).join(', ');
    try { localStorage.setItem(localKey, JSON.stringify({ id: draftId, data: snapshot, at: Date.now() })); } catch { /* private window */ }
    const r = await draftSave({ id: draftId, kind: 'rental', data: snapshot as Record<string, unknown>, title, hold: opts.hold ?? hold, quick: opts.quick ?? quick });
    if (r.ok) { setDraftId(r.data.id); setSavedAt(r.data.updated_at); setSaveErr(null); } else setSaveErr(r.message);
    return r;
  };
  useEffect(() => {
    if (done || snapKey === firstSnap.current) return;
    if (!f.vehicle_id && !(f.full_name ?? '').trim() && !(f.mobile ?? '').trim() && !renter) return;   // nothing worth keeping yet
    const t = setTimeout(() => { void saveDraft(); }, 1500);
    return () => clearTimeout(t);
  }, [snapKey, hold]); // eslint-disable-line react-hooks/exhaustive-deps
  // what this device kept when the last save could not reach the server
  const [localDraft, setLocalDraft] = useState<{ id: string | null; data: MrDraft; at: number } | null>(null);
  useEffect(() => { if (draft) return; try { const raw = localStorage.getItem(localKey); if (raw) { const x = JSON.parse(raw); if (x?.data && Date.now() - x.at < 86_400_000) setLocalDraft(x); } } catch { /* none */ } }, []); // eslint-disable-line react-hooks/exhaustive-deps
  // Quick start at pickup: the renter's name and phone, the car, the readings; the pickup now; the car held; a task to finish
  const startQuick = () => start(async () => {
    setErr(null);
    if (!f.vehicle_id) { setErr('Choose the car.'); return; }
    if (!(f.full_name ?? '').trim() && !renter) { setErr('Type the renter\'s name.'); return; }
    const r = await saveDraft({ hold: true, quick: true });
    if (r.ok) { setHold(true); setQuickDone(true); }
  });

  const submit = () => start(async () => {
    if (paidBy === 'insurer' && !(f.insurer_id && (f.insurer_id !== 'new' || (f.insurer_name ?? '').trim()))) { setErr('Insurance replacement: choose the insurer (or Not listed, and type its name).'); return; }
    setErr(null);
    if (!blocks && !(f.blocks_reason ?? '').trim()) { setErr('Say why it does not block the calendar (for example: insurance replacement, dates not known yet).'); return; }
    if (needsReference(paidBy) && !(f.reference ?? '').trim()) { setErr('Enter the reference of the payment (the e-Transfer, cheque or transfer number).'); return; }
    if (!choice) { setErr('Choose "I sourced this client" or "Entered for CarmaCars".'); return; }
    if (quote && quote.has_rates === false && cents(f.rental_charge ?? '') === undefined) { setErr('This car has no rates yet: type the rental charge for the whole rental and the reason.'); return; }
    if (quote?.needs_policy_confirm && !past && !flags.policy) { setErr('This car is not on the fleet insurance policy yet: tick the confirmation that it is insured for this rental.'); return; }
    if (parts.length) {
      if (cents(f.amount ?? '') === undefined) { setErr('With more than one payment, enter the amount of the first one too.'); return; }
      const bad = parts.findIndex((x) => !cents(x.amount) || (needsReference(x.method) && x.reference.trim().length < 3));
      if (bad >= 0) { setErr(`Payment ${bad + 2}: enter the amount${needsReference(parts[bad]!.method) ? ' and the reference' : ''}.`); return; }
    }
    const p = { ...spec(), sales_choice: choice, pickup_place: f.pickup_place || undefined, return_place: f.return_place || undefined, source: f.source, source_note: f.source_note || undefined, note: f.note || undefined,
      do_not_email: flags.do_not_email, additional_drivers: drivers.filter((d) => d.full_name.trim()),
      renter: renter ? undefined : { full_name: f.full_name, email: f.email, mobile: f.mobile, date_of_birth: f.date_of_birth, licence_number: f.licence_number, licence_class: f.licence_class || 'G',
        licence_issuer: f.licence_issuer || 'ON', licence_expiry: f.licence_expiry || undefined, address_line1: f.address_line1 || undefined, city: f.city || undefined, postal_code: f.postal_code || undefined },
      price_reason: f.price_reason || f.fee_reason || (cents(f.rental_charge ?? '') !== undefined ? 'Agreed with the renter' : undefined), fleet_policy_confirmed: flags.policy || undefined,
      deposit_cents: isAdmin ? cents(f.deposit ?? '') : undefined, clash_reason: isAdmin ? f.clash_reason || undefined : undefined,
      payment: { ...paymentOf(paidBy), reference: f.reference || undefined, received_on: f.received_on, amount_cents: cents(f.amount ?? ''), note: f.payment_note || undefined },
      ...(parts.length && offline ? { more_payments: parts.map((x) => ({ method: x.method, amount_cents: cents(x.amount), reference: x.reference.trim() || undefined, received_on: f.received_on })) } : {}),
      deposit: { method: depositBy, reference: f.deposit_reference || undefined, received_on: f.deposit_received_on || f.received_on }, agreement, ...(blocks ? {} : { blocks_calendar: false, blocks_calendar_reason: f.blocks_reason }),
      ...(paidBy === 'insurer' ? { insurance: { insurer_id: f.insurer_id && f.insurer_id !== 'new' ? f.insurer_id : undefined, insurer_name: f.insurer_id === 'new' ? (f.insurer_name ?? '').trim() : undefined,
        claim_number: f.claim_number || undefined, adjuster_name: f.adjuster_name || undefined, adjuster_email: f.adjuster_email || undefined, adjuster_phone: f.adjuster_phone || undefined,
        authorized_days: f.authorized_days ? Number(f.authorized_days) : undefined, authorized_daily_rate_cents: cents(f.authorized_rate ?? ''), authorized_until: f.authorized_until || undefined,
        dates_provisional: f.dates_provisional === 'yes', pays: f.insurer_pays === 'rental' ? 'split' : 'insurer' } } : {}),
      ...(draftId ? { draft_id: draftId } : {}), ...(f.odometer_out ? { odometer_out_km: Number(f.odometer_out.replace(/\D/g, '')) } : {}), ...(f.fuel_out ? { fuel_out_pct: Number(f.fuel_out) } : {}) };
    const r = await createManualRental(p);
    if (!r.ok) { setErr(r.message); return; }
    setDone(r.data);
    try { localStorage.removeItem(localKey); } catch { /* none */ }
  });

  if (done) {
    return (
      <section className="pt-card stack" aria-labelledby="mr-done" data-testid="mr-done">
        <h2 className="d3" id="mr-done">Rental {done.booking_number} added</h2>
        <p>{done.status === 'confirmed' ? 'Confirmed and on the calendar.' : done.status === 'pending_payment' ? 'The renter has the email to sign and pay online; the rental is confirmed once they pay.' : done.status === 'closed' ? 'Recorded as a completed past rental. It counts on the owner\'s or partner\'s statement and the company statement.' : done.status === 'on_rent' ? 'Recorded as on trip from the pickup you entered, and on the calendar until the return. Anything still missing (signature, licence check, coverage proof, deposit, condition report) is a task under To do.' : done.status}
          {!done.blocks_calendar && done.status === 'confirmed' ? ' It was added over a clash, so it does not block the calendar: resolve the clash before the handover.' : ''}</p>
        <p className="small" data-testid="mr-done-choice">{done.sales_sourced ? 'Marked as sourced by you: your commission is counted once the rental is completed and paid in full.' : 'Entered for CarmaCars: no commission.'}
          {done.price_flags?.length ? ' The price you typed is flagged for an Admin to review.' : ''}</p>
        {done.status === 'on_rent' && done.payment_mode === 'link' && <p className="alert alert--ok" role="status" data-testid="mr-pay-online"><span>The renter has the email to sign the agreement, then pay online from their booking.</span></p>}
        {done.charge_on_sign && <p className="alert alert--ok" role="status" data-testid="mr-charge-on-sign"><span>Awaiting signature. The saved card is charged when the renter signs the rental agreement (Accept and sign), not before.</span></p>}
        {done.card && <p className={`alert ${done.card.ok ? 'alert--ok' : 'alert--warn'}`} role="status"><span>{done.card.ok ? 'The saved card was charged.' : `The saved card was not charged: ${done.card.message ?? 'declined'}. Finance has a task; send a payment link or record a payment received another way.`}</span></p>}
        <p className="small">Total {fmt(done.total_cents)}.{done.open_cents ? ` Still to collect: ${fmt(done.open_cents)} (the booking's Money tab).` : ''} The renter signs the rental agreement in their portal, or you record a signature on paper from the booking.</p>
        <p className="row">{field ? <Link prefetch={false} className="btn btn--primary" href="/field/sales" data-testid="mr-open">Open My sales</Link>
          : <Link prefetch={false} className="btn btn--primary" href={`${base}/bookings/${done.booking_number}`} data-testid="mr-open">Open the booking</Link>}
          <button className="btn btn--ghost" type="button" onClick={() => { setDone(null); setQuote(null); setRenter(null); setChoice(isAdmin ? 'for_carmacars' : ''); }}>Add another</button></p>
      </section>
    );
  }
  const modes = (quote?.payment_modes ?? (isAdmin ? ['other_way', 'link', 'card', 'unpaid'] : field ? ['link', 'card'] : ['other_way', 'link', 'card'])).filter((m) => !past || m === 'other_way' || m === 'unpaid');
  // what this person may choose (the database says the same): a payout or the insurer is no money taken here
  const paidByOptions = RENTAL_PAID_BY.filter(([v]) => {
    const m = paymentOf(v).mode;
    if (field) return m === 'link' || m === 'card';
    if (v === 'platform_payout' || v === 'insurer') return true;
    return modes.includes(m);
  });
  const car = cars.find((x) => x.id === f.vehicle_id);
  const card = renter?.card ?? quote?.card ?? null;
  return (
    <form className="ad-form stack" noValidate data-testid="manual-rental" onSubmit={(e) => { e.preventDefault(); submit(); }}>
      <div className="row" data-testid="mr-draft-bar" role="status" aria-live="polite">
        <span className="small muted">{saveErr ? `Not saved: ${saveErr}. Kept on this device.` : savedAt ? `Saved as a draft at ${new Date(savedAt).toLocaleTimeString('en-CA', { hour: 'numeric', minute: '2-digit' })}. Finish it any time from Unfinished rentals.` : 'Saved as a draft as you type: nothing is required to save.'}</span>
        <button className="btn btn--ghost btn--sm" type="button" disabled={pending} onClick={() => start(async () => { await saveDraft(); })} data-testid="mr-save-draft">Save draft</button>
        {draftId && <button className="btn btn--quiet btn--sm" type="button" onClick={() => start(async () => { await draftClose(draftId, 'discarded'); try { localStorage.removeItem(localKey); } catch { /* none */ } window.location.href = base === '/field' ? '/field/rentals/new' : `${base}/bookings/new`; })} data-testid="mr-discard-draft">Discard</button>}
        {localDraft && !draftId && <button className="btn btn--quiet btn--sm" type="button" onClick={() => { const d = localDraft.data; if (d.f) setF((x) => ({ ...x, ...d.f })); if (d.renter) setRenter(d.renter); if (d.fees) setFees(d.fees); if (d.parts) setParts(d.parts); if (d.paid_by) setPaidBy(d.paid_by); if (d.deposit_by) setDepositBy(d.deposit_by); setDraftId(localDraft.id); setLocalDraft(null); }} data-testid="mr-restore-local">Restore what you were typing on this device</button>}
      </div>
      <section className={`pt-card ad-card stack${quick ? ' pt-card--next' : ''}`} aria-labelledby="mr-quick-h" data-testid="mr-quick">
        <div className="pt-card__head"><h2 className="d4" id="mr-quick-h">Quick start at pickup</h2>
          {!quick && <button className="btn btn--ghost btn--sm" type="button" onClick={() => { setQuick(true); const n = new Date(); n.setSeconds(0, 0); setF((x) => ({ ...x, pickup_at: local(n), return_at: local(new Date(n.getTime() + 86_400_000)), source: 'walk_in' })); setQuote(null); }} data-testid="mr-quick-open">Start at pickup</button>}</div>
        {!quick ? <p className="small muted">Standing with the renter? Take the name, phone, car, kilometres and fuel now; the car is held and you finish the rest later (you get a task).</p> : quickDone ? (
          <p className="alert alert--ok" role="status" data-testid="mr-quick-done"><span>Started and saved{f.odometer_out ? `: ${f.odometer_out} km` : ''}{f.fuel_out ? `, fuel ${FUEL.find(([v]) => v === f.fuel_out)?.[1] ?? f.fuel_out}` : ''}. The car is held for 2 hours (renewed while you work on it) and you have a task to finish it. Finish now below, or later from Unfinished rentals on any device.</span></p>
        ) : (<>
          <div className="ad-fields">
            {qtext('full_name', 'Renter\'s name')}{qtext('mobile', 'Renter\'s phone', 'tel')}
            <div className="field ad-field"><label className="label" htmlFor={id('quick-car')}>Car</label>
              <select className="select" id={id('quick-car')} value={f.vehicle_id} onChange={set('vehicle_id')} data-testid="mr-quick-car"><option value="">Choose the car</option>
                {cars.filter((c) => !c.retired).map((c) => <option key={c.id} value={c.id}>{c.name}{c.car_code ? `, ${c.car_code}` : ''}{c.plate ? `, ${c.plate}` : ''}</option>)}</select></div>
            {qtext('odometer_out', 'Kilometres on the odometer', 'numeric')}
            <div className="field ad-field"><label className="label" htmlFor={id('q-fuel_out')}>Fuel</label>
              <select className="select" id={id('q-fuel_out')} value={f.fuel_out ?? ''} onChange={set('fuel_out')} data-testid="mr-q-fuel_out">{[['', 'Choose'], ...FUEL].map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select></div>
          </div>
          <p className="small muted">The pickup is now; the return is set to tomorrow (change it when you finish).</p>
          <p><button className="btn btn--primary" type="button" disabled={pending} onClick={startQuick} data-testid="mr-quick-save">Hold the car and finish later</button></p>
        </>)}
      </section>
      <div className="row" role="group" aria-label="Quick start" data-testid="mr-presets">
        <span className="small"><b>Quick start:</b></span>
        {([['phone', 'Phone'], ['walk_in', 'Walk-in'], ['turo', 'Turo or another platform'], ['insurer', 'Insurance replacement'], ...(isAdmin ? [['owner', 'Owner using own car'], ['dummy', 'Placeholder']] : [])] as Array<[Parameters<typeof preset>[0], string]>).map(([k, l]) => (
          <button key={k} className={`btn btn--sm ${(k === f.source || (k === 'owner' && f.source_note?.startsWith('The owner')) || (k === 'dummy' && f.source_note?.startsWith('Placeholder'))) ? 'btn--primary' : 'btn--ghost'}`} type="button" onClick={() => preset(k)} data-testid={`mr-preset-${k}`}>{l}</button>))}
      </div>
      <fieldset className="stack"><legend className="d4">1. The car and the dates</legend>
        <div className="ad-fields">
          <div className="field ad-field ad-field--wide"><label className="label" htmlFor={id('vehicle_id')}>Car</label>
            <input className="input" type="search" aria-label="Find the car by its car code or plate" placeholder="Car code (CC-7F3A) or plate" data-testid="mr-car-find"
              onChange={(e) => { const k = e.target.value.toUpperCase().replace(/[^A-Z0-9]/g, ''); if (k.length < 4) return;
                const hit = cars.find((c) => { const code = (c.car_code ?? '').replace(/[^A-Z0-9]/g, ''); const plate = (c.plate ?? '').toUpperCase().replace(/[^A-Z0-9]/g, '');
                  return code === k || code === `CC${k}` || plate === k; });
                if (hit) set('vehicle_id')({ target: { value: hit.id } }); }} />
            <select className="select" id={id('vehicle_id')} value={f.vehicle_id} onChange={set('vehicle_id')} data-testid="mr-vehicle_id"><option value="">Choose the car</option>
              {cars.filter((c) => past || !c.retired || c.id === f.vehicle_id).map((c) => <option key={c.id} value={c.id}>{c.name}{c.car_code ? `, ${c.car_code}` : ''}{c.plate ? `, ${c.plate}` : ''} · {c.supply_type === 'company' ? 'CarmaCars-owned' : c.supply_type === 'partner' ? 'partner' : 'owner'}{c.daily_rate_cents ? ` · ${fmt(c.daily_rate_cents)} a day` : ' · no rates yet'}{c.retired ? ' · retired' : !c.bookable ? ' · closed to new bookings' : c.listing_finished === false ? ' · Listing not finished' : ''}</option>)}</select>
            {f.vehicle_id && <label className="check" htmlFor={id('hold')}><input id={id('hold')} type="checkbox" checked={hold} onChange={(e) => setHold(e.target.checked)} data-testid="mr-hold" /> <span>Hold the car while I finish (2 hours, renewed as I save)</span></label>}
            {car && !car.bookable && !car.retired && phase === 'upcoming' && <p className="hint" data-testid="mr-closed-car">This car is closed to new bookings: it takes a rental already underway (pickup in the past), not an upcoming one.</p>}
            {(() => { const c = cars.find((x) => x.id === f.vehicle_id); return c && c.listing_finished === false ? <p className="hint" data-testid="mr-unlisted-tag"><span className="ad-flag">Listing not finished</span> The car stays off the public site. {c.has_rates === false ? 'It has no rates yet: you type the rental charge with the reason. ' : ''}{c.needs_policy_confirm ? (isAdmin ? 'It is not on the fleet insurance policy yet: you confirm it is insured before adding the rental.' : 'It is not on the fleet insurance policy yet: only an Admin can add its rentals.') : ''}</p> : null; })()}</div>
          {text('pickup_at', 'Pickup date and time', { type: 'datetime-local', hint: 'In the past for a rental already underway' })}
          {text('return_at', 'Return date and time', { type: 'datetime-local', hint: 'Any length: longer than 30 days is priced at the monthly rate' })}
          {select('pickup_method', 'How the renter gets the car', [['collected', 'Collected from us'], ['delivered', 'We deliver it']])}
          {f.pickup_method === 'delivered' && addr('pickup_place', 'Delivery address')}
          {select('return_method', 'How the car comes back', [['returned', 'Returned to us'], ['picked_up', 'We pick it up']])}
          {f.return_method === 'picked_up' && addr('return_place', 'Pickup address')}
        </div>
        {phase && <p className={`alert ${past && !isAdmin ? 'alert--warn' : 'alert--ok'}`} role="status" aria-live="polite" data-testid="mr-phase" data-phase={phase}>
          <span>{past && !isAdmin ? 'This rental has already ended. Only an Admin can record it: check the dates, or ask an Admin to add it.' : PHASE_NOTE[phase]}</span></p>}
      </fieldset>

      <fieldset className="stack"><legend className="d4">2. The renter</legend>
        {renter ? (
          <p data-testid="mr-renter-chosen"><b>{renter.legal_name}</b> {renter.email} {renter.mobile} {renter.card ? `· card ${renter.card.brand} ending ${renter.card.last4}` : '· no saved card'} <button className="btn btn--quiet btn--sm" type="button" onClick={() => { setRenter(null); setQuote(null); }}>Change</button></p>
        ) : (<>
          {field ? <p className="small muted">Type the renter&apos;s details. A renter already on file is found by their email.</p>
            : <label className="check" htmlFor={id('new')}><input id={id('new')} type="checkbox" checked={flags.new_renter} onChange={flag('new_renter')} data-testid="mr-new-renter" /> <span>A new renter (not on file)</span></label>}
          {!flags.new_renter ? (
            <div className="stack">
              <div className="row"><label className="sr-only" htmlFor={id('q')}>Find a renter</label>
                <input className="input" id={id('q')} placeholder="Name, email or phone" value={q} onChange={(e) => setQ(e.target.value)} data-testid="mr-renter-q" onKeyDown={(e) => { if (e.key === 'Enter') { e.preventDefault(); search(); } }} />
                <button className="btn btn--ghost btn--sm" type="button" onClick={search} disabled={pending || q.trim().length < 3} data-testid="mr-renter-search">Find</button></div>
              {found.length === 0 && q.trim().length >= 3 && <p className="small">No renter found. <button className="btn btn--quiet btn--sm" type="button" data-testid="mr-new-from-search" onClick={() => { const t = q.trim();
                setFlags((x) => ({ ...x, new_renter: true })); setF((x) => ({ ...x, email: t.includes('@') ? t : x.email ?? '', mobile: /^[\d\s()+-]{7,}$/.test(t) ? t : x.mobile ?? '', full_name: !t.includes('@') && !/\d/.test(t) ? t : x.full_name ?? '' })); }}>Add them as a new renter</button></p>}
              {found.length > 0 && <ul className="stack" data-testid="mr-renter-results">{found.map((r) => (
                <li key={r.id}><button className="btn btn--quiet btn--sm" type="button" disabled={r.is_blocked} onClick={() => { setRenter(r); setQuote(null); }}>{r.legal_name}</button> <span className="small">{r.email} {r.mobile} · {r.bookings} booking(s){r.is_blocked ? ' · blocked' : ''}</span></li>))}</ul>}
            </div>
          ) : (
            <div className="ad-fields">
              {text('full_name', 'Full legal name')}{text('email', 'Email', { type: 'email', inputMode: 'email' })}{text('mobile', 'Phone', { inputMode: 'tel' })}{text('date_of_birth', 'Date of birth', { type: 'date', hint: 'Decides the young driver fee' })}
              {text('licence_number', 'Licence number')}{text('licence_expiry', 'Licence expiry', { type: 'date' })}
              <details className="ad-field ad-field--wide" data-testid="mr-renter-more"><summary className="link small">Licence class and home address (optional now: the agreement asks the renter)</summary>
                <div className="ad-fields">
                  {text('licence_class', 'Licence class', { hint: 'G unless another class' })}{text('licence_issuer', 'Licence issued by', { hint: 'ON unless another province or country' })}
                  <AddressLookup idp="mr-home" label="Find the renter's home address" onParts={(p) => setF((s) => ({ ...s, ...(p.street ? { address_line1: p.street + (p.unit ? `, Unit ${p.unit}` : '') } : {}), ...(p.city ? { city: p.city } : {}), ...(p.postal_code ? { postal_code: p.postal_code } : {}) }))} />
                  {text('address_line1', 'Home address')}{text('city', 'City')}{text('postal_code', 'Postal code')}
                </div></details>
            </div>)}
        </>)}
        <div className="stack"><p className="small"><b>Additional drivers</b></p>
          {drivers.map((d, i) => (
            <div className="ad-fields" key={i}>
              {(['full_name', 'date_of_birth', 'email'] as const).map((k) => (
                <div className="field ad-field" key={k}><label className="label" htmlFor={`mr-d${i}-${k}`}>{k === 'full_name' ? 'Name' : k === 'date_of_birth' ? 'Date of birth' : 'Email'}</label>
                  <input className="input" id={`mr-d${i}-${k}`} type={k === 'date_of_birth' ? 'date' : k === 'email' ? 'email' : 'text'} value={d[k]} onChange={(e) => setDrivers((s) => s.map((x, j) => (j === i ? { ...x, [k]: e.target.value } : x)))} /></div>))}
              <button className="btn btn--quiet btn--sm" type="button" onClick={() => setDrivers((s) => s.filter((_, j) => j !== i))}>Remove</button>
            </div>))}
          <p><button className="btn btn--ghost btn--sm" type="button" onClick={() => setDrivers((s) => [...s, { full_name: '', date_of_birth: '', email: '' }])}>Add a driver</button></p>
        </div>
      </fieldset>

      <fieldset className="stack"><legend className="d4">3. The rental</legend>
        <div className="ad-fields">
          {select('coverage_option', 'How damage to the car is covered', [['1', 'Option 1: the renter\'s own insurance'], ['2', 'Option 2: credit card coverage'], ['3', 'Option 3: the Protection Plan']])}
          {select('source', 'Where it came from', SOURCES)}
          {f.source === 'other' && text('source_note', 'Say where')}
          {text('note', 'Note (on the booking)', { wide: true })}
        </div>
        <details data-testid="mr-more"><summary className="link small">Non-refundable booking or a promo code</summary>
          <div className="ad-fields">{select('booking_type', 'Booking', [['standard', 'Standard'], ['non_refundable', 'Non-refundable (fixed discount)']])}{text('promo_code', 'Promo code')}</div></details>
        {f.vehicle_id && addonOptions.length > 0 && (
          <details className="stack" data-testid="mr-addons-block" open={addons.length > 0}><summary className="link small">Add-ons ({addons.length ? `${addons.length} chosen` : 'optional'})</summary>
            <AddonPicker idPrefix="mr" staff compact options={addonOptions} value={addons} onChange={(v) => { setAddons(v); setQuote(null); }} /></details>)}
        <p><button className="btn btn--ghost btn--sm" type="button" onClick={check} disabled={pending} data-testid="mr-check">{pending ? 'Checking' : quote ? 'Check again' : 'Check the calendar and the price'}</button></p>
        {quote && (
          <div className="stack" data-testid="mr-quote">
            {quote.free ? <p className="alert alert--ok" role="status" data-testid="mr-free"><span>{quote.vehicle.name} is free for these dates (with {quote.turnaround_minutes} minutes between trips).</span></p>
              : <div className="alert alert--warn" role="alert" data-testid="mr-clash"><span>Not free: {quote.clashes.map((c) => c.kind === 'booking' ? `${c.booking_number}${c.renter ? ` (${c.renter})` : ''}${c.overlaps ? '' : ', turnaround'}` : `calendar block (${c.reason})`).join('; ')}.
                {quote.may_override_clash ? ' You may still add it, with the reason.' : ' Choose other dates or another car.'}</span></div>}
            {!quote.free && quote.may_override_clash && text('clash_reason', 'Reason to add it over the clash', { wide: true })}
            {quote.notes?.length ? <div className="alert alert--warn" role="note" data-testid="mr-notes"><span>{quote.notes.join(' ')}</span></div> : null}
            {quote.needs_policy_confirm && !past && quote.role === 'admin' && <label className="check" htmlFor={id('policy')}><input id={id('policy')} type="checkbox" checked={flags.policy} onChange={flag('policy')} data-testid="mr-policy-confirm" /> <span>I checked that this car is insured for this rental</span></label>}
            {quote.has_rates === false && quote.price_typed_cents == null ? null : (() => {
              const days = quote.quote.billable_days || 1;
              const keys = new Set(quote.quote.lines.map((l) => lineKey(l)));
              const pending = Object.keys(fees).filter((k) => !keys.has(k) && !RENTAL_LINE.has(k));
              const edit = !!quote.may_edit_fees;
              const box = (k: string, label: string, ph: number) => <input className="input input--sm" inputMode="decimal" aria-label={`${label}: amount for the trip ($)`} placeholder={(ph / 100).toFixed(2)}
                value={fees[k] ?? ''} onChange={(e) => setFees((x) => ({ ...x, [k]: e.target.value }))} data-testid={`mr-fee-${k}`} />;
              const remove = (k: string) => <button className="btn btn--quiet btn--sm" type="button" onClick={() => setFees((x) => ({ ...x, [k]: '0' }))} data-testid={`mr-remove-${k}`} aria-label="Remove this line">Remove</button>;
              return <table className="ad-table" data-testid="mr-price"><caption className="sr-only">Price</caption>
              <thead><tr><th scope="col">Line</th><th scope="col" className="num">Amount</th>{edit && <th scope="col">Change it ($)</th>}</tr></thead><tbody>
              {quote.quote.lines.map((l, i) => { const k = lineKey(l); const rent = l.charge_type === 'rental_charge'; const editable = edit && !RENTAL_LINE.has(l.charge_type);
                return <tr key={i} data-testid={`mr-line-${k}`}><td>{rent ? `Rental charge (${days} day${days === 1 ? '' : 's'})` : l.description}<Info text={lineHelp(l.charge_type)} />
                  {l.set_by_hand || l.detail?.set_by_hand ? <span className="small muted"> (changed)</span> : null}</td><td className="num">{fmt(l.amount_cents)}</td>
                  {edit && <td>{editable ? <span className="row">{box(k, l.description, l.amount_cents)}{remove(k)}</span>
                    : rent && quote.may_override_price ? <span className="stack">
                      <span className="row"><input className="input input--sm" inputMode="decimal" aria-label={rentMode === 'day' ? 'Rental rate a day ($)' : 'Rental charge for the whole trip, before fees and tax ($)'}
                        placeholder={((rentMode === 'day' ? Math.round(l.amount_cents / days) : l.amount_cents) / 100).toFixed(2)}
                        value={rentMode === 'day' ? rentDay : f.rental_charge ?? ''} data-testid="mr-rental-inline"
                        onChange={(e) => { const v = e.target.value; if (rentMode === 'day') { setRentDay(v); const c = cents(v); setF((x) => ({ ...x, rental_charge: c === undefined ? '' : ((c * days) / 100).toFixed(2) })); } else set('rental_charge')(e); }} />
                        <select className="select select--sm" aria-label="The amount typed is" value={rentMode} onChange={(e) => { setRentMode(e.target.value as 'trip' | 'day'); setRentDay(''); setF((x) => ({ ...x, rental_charge: '' })); }} data-testid="mr-rent-mode">
                          <option value="trip">for the trip</option><option value="day">a day</option></select></span>
                      {cents(f.rental_charge ?? '') !== undefined && <span className="small muted" data-testid="mr-rent-other">{rentMode === 'day' ? `= ${fmt(cents(f.rental_charge ?? '') ?? 0)} for ${days} days` : `= ${fmt(Math.round((cents(f.rental_charge ?? '') ?? 0) / days))} a day`}</span>}</span> : null}</td>}</tr>; })}
              {edit && pending.map((k) => <tr key={k} data-testid={`mr-line-${k}`}><td>{FEE_LABEL[k] ?? k}<Info text={lineHelp(k)} /></td><td className="num">{fmt(cents(fees[k] ?? '') ?? 0)}</td><td><span className="row">{box(k, FEE_LABEL[k] ?? k, 0)}<button className="btn btn--quiet btn--sm" type="button" onClick={() => setFees((x) => { const y = { ...x }; delete y[k]; return y; })}>Remove</button></span></td></tr>)}
              {edit && customs.map((c, i) => <tr key={`c${i}`} data-testid={`mr-custom-${i}`}><td><input className="input input--sm" aria-label="What the charge is for" placeholder="What it is for" value={c.label} onChange={(e) => setCustoms((a) => a.map((y, j) => (j === i ? { ...y, label: e.target.value } : y)))} data-testid={`mr-custom-${i}-label`} /><Info text={lineHelp('custom_fee')} /></td>
                <td className="num"><label className="check small"><input type="checkbox" checked={c.hst} onChange={(e) => setCustoms((a) => a.map((y, j) => (j === i ? { ...y, hst: e.target.checked } : y)))} /> <span>+ HST</span></label></td>
                <td><span className="row"><input className="input input--sm" inputMode="decimal" aria-label="Amount before HST ($)" placeholder="0.00" value={c.amount} onChange={(e) => setCustoms((a) => a.map((y, j) => (j === i ? { ...y, amount: e.target.value } : y)))} data-testid={`mr-custom-${i}-amount`} />
                  <button className="btn btn--quiet btn--sm" type="button" onClick={() => setCustoms((a) => a.filter((_, j) => j !== i))}>Remove</button></span></td></tr>)}
              {edit && <tr><td colSpan={3}>
                <select className="select select--sm" id="mr-add-line" aria-label="Add a line to the price" value="" data-testid="mr-add-line" onChange={(e) => { const k = e.target.value; if (k === 'custom') setCustoms((a) => [...a, { label: '', amount: '', hst: true }]); else if (k) setFees((x) => ({ ...x, [k]: '' })); }}>
                  <option value="">+ Add a line (a fee from the list, or a charge of its own)</option>
                  {Object.entries(FEE_LABEL).filter(([k]) => !keys.has(k) && !(k in fees)).map(([k, l]) => <option key={k} value={k}>{l}</option>)}
                  <option value="custom">A charge of its own</option></select></td></tr>}
              <tr><td>HST<Info text={lineHelp('hst')} /></td><td className="num">{fmt(quote.quote.lines.reduce((sum, l) => sum + l.hst_cents, 0))}</td>{edit && <td><span className="small muted">worked out for you</span></td>}</tr>
              <tr><th scope="row">{quote.has_rates === false ? 'Total with the price you typed' : Object.keys(feeOverrides(fees)).length || customs.length || cents(f.rental_charge ?? '') !== undefined ? 'Total with your changes' : 'Total from the rate sheet'}</th><td className="num"><b data-testid="mr-total">{fmt(quote.quote.total_due_at_booking_cents)}</b></td>{edit && <td />}</tr>
              <tr><td>Deposit at pickup<Info text={lineHelp('deposit')} /></td><td className="num">{fmt(quote.quote.deposit_cents)}</td>{edit && <td>{isAdmin ? <input className="input input--sm" inputMode="decimal" aria-label="Deposit: change it to ($)" placeholder={(quote.quote.deposit_cents / 100).toFixed(2)} value={f.deposit ?? ''} onChange={set('deposit')} data-testid="mr-deposit-inline" /> : null}</td>}</tr>
              <tr><td>Kilometres included<Info text={lineHelp('km')} /></td><td className="num">{quote.quote.km_allowance_total} km</td>{edit && <td><span className="row"><input className="input input--sm" inputMode="numeric" aria-label="Kilometres a day" placeholder={String(Math.round(quote.quote.km_allowance_total / days))} value={f.km ?? ''} onChange={set('km')} data-testid="mr-km-inline" /><span className="small muted">a day</span></span></td>}</tr>
            </tbody></table>; })()}
            {(Object.keys(feeOverrides(fees)).length > 0 || customs.length > 0 || cents(f.rental_charge ?? '') !== undefined) && <div className="ad-fields">{text('fee_reason', 'Reason for the changes (optional)', { wide: true, hint: 'Kept on the booking. A price far under the rate sheet is flagged for an Admin, never refused.' })}</div>}
            {(quote.periods?.length ?? 0) > 1 && (() => { const ps = quote.periods!; const shares = periodShares(quote.quote.total_due_at_booking_cents, ps.map((x) => x.days));
              return <div className="stack" data-testid="mr-periods"><p className="small"><b>{ps.length} monthly periods</b> of 30 days (the last one shorter), each priced at the monthly rate. The amounts are each period&apos;s share of the total.</p>
                <table className="ad-table"><caption className="sr-only">Monthly periods</caption><thead><tr><th scope="col">Period</th><th scope="col">From</th><th scope="col">To</th><th scope="col" className="num">Days</th><th scope="col" className="num">About</th></tr></thead>
                  <tbody>{ps.map((x, i) => <tr key={x.seq}><td>{x.seq}</td><td>{new Date(x.starts_at).toLocaleDateString('en-CA', { timeZone: 'America/Toronto', month: 'short', day: 'numeric' })}</td><td>{new Date(x.ends_at).toLocaleDateString('en-CA', { timeZone: 'America/Toronto', month: 'short', day: 'numeric' })}</td><td className="num">{x.days}</td><td className="num">{fmt(shares[i])}</td></tr>)}</tbody></table></div>; })()}
            <p className="small muted">Rental charge: {quote.quote.rate_rule}; {quote.quote.km_allowance_total} km included. Type a new amount in any line to change it (amounts before HST).{quote.quote.problems.length ? ` ${quote.quote.problems.map((p) => p.message).join(' ')}` : ''}{quote.quote.promo?.problem ? ` Promo code: ${quote.quote.promo.problem}` : ''}</p>
            {quote.may_override_price && (
              <div className="stack" data-testid="mr-custom-price">
                {quote.has_rates === false && <p className="small">This car has no rates yet. Type the rental charge for the whole rental.</p>}
                {(quote.has_rates === false || !quote.may_edit_fees) && <div className="ad-fields">{text('rental_charge', quote.has_rates === false ? 'Rental charge for the whole rental ($)' : 'Rental charge typed by hand ($, empty: the rate sheet)', { inputMode: 'decimal' })}
                  {isAdmin && !quote.may_edit_fees && text('deposit', 'Deposit ($, empty: the rate sheet)', { inputMode: 'decimal' })}</div>}
                {cents(f.rental_charge ?? '') !== undefined && <div className="ad-fields">{select('price_tax', 'The rental charge typed is', PRICE_TAX_OPTIONS)}</div>}
                {split && <p className="small" data-testid="mr-price-tax">{PRICE_TAX_LABEL[split.tax]}: {fmt(split.before_tax_cents)} before tax and {fmt(split.hst_cents)} HST, {fmt(split.with_tax_cents)} in all.</p>}
                {(() => { const fl = priceFlags(typedBeforeTax, quote.rate_sheet_cents, quote.billable_days, quote.price_floor_daily_cents, quote.price_max_discount_bps);
                  return fl.length ? <p className="alert alert--warn" role="status" data-testid="mr-price-flag"><span>This price is {fl.join(' and ')}. You can still add the rental: it is flagged for an Admin to review.</span></p> : null; })()}
              </div>)}
          </div>)}
      </fieldset>

      <fieldset className="stack"><legend className="d4">4. How it was paid (rent, then deposit), the agreement</legend>
        <div className="ad-fields">
          <div className="field ad-field"><label className="label" htmlFor={id('paid_by')}>The rent is paid by</label>
            <select className="select" id={id('paid_by')} value={paidBy} onChange={(e) => setPaidBy(e.target.value as RentalPaidBy)} data-testid="mr-paid-by">
              {paidByOptions.map(([v, l]) => <option key={v} value={v} disabled={v === 'card_on_file' && !card}>{l}{v === 'card_on_file' ? (card ? ` (${card.brand} ${card.last4})` : ' (no saved card)') : ''}</option>)}</select>
            <p className="hint">{RENTAL_PAID_BY.find(([v]) => v === paidBy)?.[2]}{phase === 'in_progress' && (paidBy === 'link' || paidBy === 'card_on_file') ? ` ${LIVE_MODE[paidBy === 'link' ? 'link' : 'card']}` : ''}</p></div>
          {paidBy === 'insurer' && <fieldset className="ad-field ad-field--wide stack" data-testid="mr-insurance"><legend className="label">Insurance replacement</legend>
            <div className="ad-fields">
              <div className="field ad-field"><label className="label" htmlFor={id('insurer_id')}>Insurer</label>
                <select className="select" id={id('insurer_id')} value={f.insurer_id ?? ''} onChange={set('insurer_id')} data-testid="mr-insurer">
                  <option value="">Choose the insurer</option>{(quote?.insurers ?? []).map((x) => <option key={x.id} value={x.id}>{x.name}</option>)}<option value="new">Not listed: type its name</option></select></div>
              {f.insurer_id === 'new' && text('insurer_name', 'Insurer\'s name')}
              {text('claim_number', 'Claim number')}
              {text('adjuster_name', 'Adjuster')}{text('adjuster_email', 'Adjuster\'s email', { type: 'email', inputMode: 'email' })}{text('adjuster_phone', 'Adjuster\'s phone', { inputMode: 'tel' })}
              {text('authorized_days', 'Days authorized', { inputMode: 'numeric' })}
              {text('authorized_rate', 'Daily rate authorized ($)', { inputMode: 'decimal', hint: 'The insurer pays up to this a day; the rest is the renter\'s.' })}
              {text('authorized_until', 'Authorized until (provisional end)', { type: 'date' })}
              {select('insurer_pays', 'The insurer pays', [['all', 'The rental and the fees'], ['rental', 'The rental only (the renter pays the fees)']])}
              <label className="check ad-field--wide" htmlFor={id('dates_provisional')}><input id={id('dates_provisional')} type="checkbox" checked={f.dates_provisional === 'yes'} onChange={(e) => setF((x) => ({ ...x, dates_provisional: e.target.checked ? 'yes' : '' }))} /> <span>The return date is provisional (the repair is not finished)</span></label>
            </div></fieldset>}
          {['e_transfer', 'cash', 'cheque', 'bank_transfer', 'platform_payout'].includes(paidBy) && <>
            {needsReference(paidBy) || paidBy === 'platform_payout' ? text('reference', paidBy === 'platform_payout' ? 'Trip or payout reference (optional)' : 'Reference (e-Transfer, cheque or transfer number)') : null}
            {text('received_on', 'Date received', { type: 'date' })}
            {text('amount', parts.length ? 'Amount of this payment ($)' : 'Amount ($, empty: the total)', { inputMode: 'decimal', hint: quote?.role === 'va' && quote.single_limit_cents != null ? `Your single limit is ${fmt(quote.single_limit_cents)}.` : undefined })}
          </>}
          {offline && parts.map((x, i) => (
            <div className="field ad-field ad-field--wide" key={i} data-testid={`mr-part-${i}`}><span className="label">Payment {i + 2}</span>
              <div className="row">
                <select className="select" aria-label={`Payment ${i + 2}: how`} value={x.method} onChange={(e) => setParts((a) => a.map((y, j) => (j === i ? { ...y, method: e.target.value as PayPart['method'] } : y)))} data-testid={`mr-part-${i}-method`}>
                  {PART_METHODS.map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select>
                <input className="input" inputMode="decimal" aria-label={`Payment ${i + 2}: amount ($)`} placeholder="Amount ($)" value={x.amount} onChange={(e) => setParts((a) => a.map((y, j) => (j === i ? { ...y, amount: e.target.value } : y)))} data-testid={`mr-part-${i}-amount`} />
                {needsReference(x.method) && <input className="input" aria-label={`Payment ${i + 2}: reference`} placeholder="Reference" value={x.reference} onChange={(e) => setParts((a) => a.map((y, j) => (j === i ? { ...y, reference: e.target.value } : y)))} data-testid={`mr-part-${i}-reference`} />}
                <button className="btn btn--quiet btn--sm" type="button" onClick={() => setParts((a) => a.filter((_, j) => j !== i))}>Remove</button></div></div>))}
          {offline && <p className="ad-field--wide"><button className="btn btn--ghost btn--sm" type="button" data-testid="mr-add-payment"
            onClick={() => setParts((a) => [...a, { method: paidBy === 'cash' ? 'e_transfer' : 'cash', amount: '', reference: '' }])}>Add another payment (paid in parts)</button></p>}
          <div className="field ad-field"><label className="label" htmlFor={id('deposit_by')}>The deposit is paid by</label>
            <select className="select" id={id('deposit_by')} value={depositBy} onChange={(e) => setDepositBy(e.target.value as DepositPay)} data-testid="mr-deposit-by">
              {DEPOSIT_PAY.filter(([v]) => isAdmin || v !== 'none').map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select>
            <p className="hint">{DEPOSIT_PAY.find(([v]) => v === depositBy)?.[2]}</p></div>
          {depositBy === 'e_transfer' && text('deposit_reference', 'Deposit e-Transfer reference')}
          {(depositBy === 'e_transfer' || depositBy === 'cash') && text('deposit_received_on', 'Deposit received on', { type: 'date', hint: 'Empty: the same day as the rental payment' })}
          <div className="field ad-field"><span className="label">The rental agreement</span>
            <label className="check" htmlFor={id('agr-send')}><input type="radio" id={id('agr-send')} name="mr-agr" checked={agreement === 'send'} onChange={() => setAgreement('send')} data-testid="mr-agreement-send" /> <span>Send it to sign online</span></label>
            <label className="check" htmlFor={id('agr-paper')}><input type="radio" id={id('agr-paper')} name="mr-agr" checked={agreement === 'paper'} onChange={() => setAgreement('paper')} data-testid="mr-agreement-paper" /> <span>Already signed on paper (upload the scan on the booking)</span></label></div>
          <div className="field ad-field"><span className="label">The calendar</span>
            <label className="check" htmlFor={id('blocks')}><input type="checkbox" id={id('blocks')} checked={blocks} onChange={(e) => setBlocks(e.target.checked)} data-testid="mr-blocks" /> <span>Blocks the car&apos;s calendar</span></label>
            {!blocks && <p className="hint">For dates not known yet (an insurance replacement) or a trip another calendar holds.</p>}</div>
          {!blocks && text('blocks_reason', 'Why it does not block the calendar', { wide: true })}
        </div>
        <label className="check" htmlFor={id('dne')}><input id={id('dne')} type="checkbox" checked={flags.do_not_email} onChange={flag('do_not_email')} data-testid="mr-do-not-email" /> <span>Do not email the renter</span></label>
      </fieldset>

      <fieldset className="stack"><legend className="d4">5. Who found this client</legend>
        <SourcedChoice id="mr" value={choice} onChange={setChoice} optional={isAdmin} />
      </fieldset>

      {quote && (() => { const total = quote.quote.total_due_at_booking_cents; const first = offline ? (cents(f.amount ?? '') ?? (parts.length ? 0 : total)) : 0;
        const { paid, left } = paidSoFar(first, offline ? parts : [], total); const ps = quote.periods ?? [];
        const payWords = offline ? [`${RENTAL_PAID_BY.find(([v]) => v === paidBy)?.[1]} ${fmt(first)}`, ...parts.map((x) => `${PART_METHODS.find(([v]) => v === x.method)?.[1]} ${fmt(cents(x.amount) ?? 0)}`)].join(' + ') : RENTAL_PAID_BY.find(([v]) => v === paidBy)?.[1];
        return <section className="pt-card ad-card stack" aria-labelledby="mr-sum-h" data-testid="mr-summary"><h3 className="d4" id="mr-sum-h">Before you save</h3>
          <dl className="pt-dl small">
            <div><dt>Renter</dt><dd>{renter?.legal_name ?? (f.full_name || 'not entered yet')}</dd></div>
            <div><dt>Car</dt><dd>{quote.vehicle.name}</dd></div>
            <div><dt>Dates</dt><dd>{quote.quote.billable_days} days{phase === 'in_progress' ? ', already underway (on trip from the pickup entered)' : phase === 'past' ? ', already ended' : ''}{ps.length > 1 ? `, ${ps.length} monthly periods` : ''}</dd></div>
            <div><dt>Total</dt><dd>{fmt(total)}{Object.keys(feeOverrides(fees)).length ? ' (with the fees you changed)' : ''}</dd></div>
            <div><dt>Rental paid</dt><dd data-testid="mr-sum-paid">{payWords}{offline ? `: ${fmt(paid)} received${left > 0 ? `, ${fmt(left)} still to collect` : ''}` : ''}</dd></div>
            <div><dt>Deposit</dt><dd data-testid="mr-sum-deposit">{fmt(cents(f.deposit ?? '') ?? quote.quote.deposit_cents)} by {DEPOSIT_PAY.find(([v]) => v === depositBy)?.[1].toLowerCase()}{f.deposit_reference ? ` (${f.deposit_reference})` : ''}</dd></div>
            <div><dt>Agreement</dt><dd>{agreement === 'paper' ? 'Signed on paper' : 'Sent to sign online'}</dd></div>
          </dl></section>; })()}
      {err && <p className="alert alert--error" role="alert" data-testid="mr-error"><span>{err}</span></p>}
      <div className="row"><button className="btn btn--primary" type="submit" disabled={pending || !quote} data-testid="mr-submit">{pending ? 'Working' : past ? 'Record the past rental' : phase === 'in_progress' ? 'Add the rental already underway' : 'Add the rental'}</button>
        {!quote && <span className="small muted">{pending ? 'Checking the calendar and the price…' : 'The calendar and the price are checked once the car and the dates are in.'}</span>}</div>
    </form>
  );
}
