'use client';
import { Info } from '@/features/forms/Info';
import { lineHelp } from '@/features/offers/help';
import { createContext, useContext, useEffect, useMemo, useRef, useState, useTransition } from 'react';
import { AddressInput } from '@/features/forms/AddressInput';
import { useRouter } from 'next/navigation';
import { money } from '@/lib/format';
import { when } from '@/features/agreement/model';
import { useDoor } from './door';
import { toLocalInput } from './Act';
import { SourcedChoice, type Choice } from '@/features/sales/SourcedChoice';
import { AddonPicker } from '@/features/addons/AddonPicker';
import { addonsPayload, type AddonChoice, type AddonOption, type BookingAddon } from '@/features/addons/model';
import { PRICE_TAX_OPTIONS } from '@/features/sales/priceTax';
import { offersDo } from '@/server/actions/offers';
import { DEPOSIT_PAY, RENTAL_PAY, describeRevision } from '@/features/offers/model';

// Review and adjust a booking request (03-admin.md section 4.2). Staff change the booking itself; every
// edit is priced by the database (adjust_booking and the pricing functions inside a rolled-back
// transaction) and shown as the renter will see the offer. Save keeps the changes; Send offer saves and
// freezes them as the next offer version.
export interface Line { id: string; charge_type: string; description: string | null; amount_cents: number; hst_cents: number; stage: string; charged_to_renter: boolean }
export interface B {
  id: string; booking_number: string; status: string; vehicle_id: string; pickup_at: string; return_at: string; booking_type: string;
  daily_rate_cents: number; weekend_rate_cents: number; weekly_rate_cents: number; monthly_rate_cents: number; rental_charge_cents: number;
  discount_cents: number; staff_discount_cents: number; staff_discount_reason: string | null; promo_discount_cents: number; deposit_cents: number;
  km_allowance_per_day: number; km_allowance_total: number | null; overage_cents_per_km: number; billable_days: number; rate_applied: string | null;
  pickup_method: string; return_method: string; pickup_place: string | null; return_place: string | null;
  pickup_location_kind: string | null; return_location_kind: string | null; pickup_distance_km: number | null; return_distance_km: number | null;
  bill_to: string; insurer_id: string | null; insurer_claim_number: string | null; insurer_adjuster_name: string | null; insurer_adjuster_email: string | null;
  insurer_adjuster_phone: string | null; insurer_authorized_daily_rate_cents: number | null; insurer_authorized_days: number | null; insurer_authorized_until: string | null;
  dates_provisional: boolean; blocks_calendar: boolean; notes: string | null; hst_at_booking_cents: number; total_due_at_booking_cents: number;
  renter_due_at_booking_cents: number | null; insurer_share_cents: number | null; promo_code: string | null;
  vehicle: { id: string; name: string; plate: string | null } | null; lines: Line[];
  /** 0058: the choice, a claim, a price typed by hand */
  /** 0066 */
  addons?: BookingAddon[];
  sales_choice?: 'sourced' | 'for_carmacars' | null; sales_claim_by?: string | null; rate_sheet_rental_cents?: number | null; custom_price_reason?: string | null; price_flags?: string[];
  /** 0112: the price typed is plus tax or tax included (then the amount typed) */
  price_tax?: 'plus' | 'included' | null; price_with_tax_cents?: number | null;
  /** 0129: how the rental and the deposit are paid */
  rental_pay_method?: string; deposit_pay_method?: string;
}
type Opt = { id: string; name: string; plate: string | null; free: boolean; daily_rate_cents: number | null };

// the Protection Plan the renter buys is one line (coverage_sold): one price on this screen (0129), never a second "coverage" field
const COVERAGE_TYPES = ['coverage_sold', 'coverage', 'coverage_option', 'carmacars_coverage', 'coverage_daily'];
const MONEY_KEYS = ['daily_rate_cents', 'weekend_rate_cents', 'weekly_rate_cents', 'monthly_rate_cents', 'staff_discount_cents', 'deposit_cents', 'overage_cents_per_km', 'insurer_authorized_daily_rate_cents'] as const;
const dollars = (c: number | null | undefined) => (c === null || c === undefined ? '' : (c / 100).toFixed(2));
const cents = (s: string) => { const n = Number(String(s).replace(/[$,\s]/g, '')); return s.trim() === '' || !Number.isFinite(n) ? null : Math.round(n * 100); };
const lineLabel = (l: Line) => l.description || l.charge_type.replace(/_/g, ' ');

type CtxT = { v: Record<string, string | boolean>; set: (k: string) => (x: string | boolean) => void; changed: (k: string) => boolean; editable: boolean };
const Ctx = createContext<CtxT>({ v: {}, set: () => () => {}, changed: () => false, editable: false });
const F = ({ k, l, type = 'text', hint, money: m }: { k: string; l: string; type?: string; hint?: string; money?: boolean }) => { const { v, set, changed, editable } = useContext(Ctx); return (
  <div className={`field ad-field${changed(k) ? ' ad-diff' : ''}`}>
    <label className="label" htmlFor={`rv-${k}`}>{l}{m ? ' ($)' : ''}</label>
    <input className="input" id={`rv-${k}`} type={type} value={String(v[k] ?? '')} disabled={!editable} inputMode={m ? 'decimal' : undefined}
      onChange={(e) => set(k)(e.target.value)} aria-describedby={hint ? `rv-${k}-h` : undefined} />
    {hint && <p className="hint" id={`rv-${k}-h`}>{hint}</p>}
  </div>
); };
// an address with the lookup (0130); disabled when the booking cannot be edited
const A = ({ k, l }: { k: string; l: string }) => { const { v, set, changed, editable } = useContext(Ctx); return (
  <div className={`field ad-field${changed(k) ? ' ad-diff' : ''}`}>
    <label className="label" htmlFor={`rv-${k}`}>{l}</label>
    {editable ? <AddressInput id={`rv-${k}`} name={k} value={{ label: String(v[k] ?? ''), placeId: '' }} onChange={(x) => set(k)(x.label)} />
      : <input className="input" id={`rv-${k}`} value={String(v[k] ?? '')} disabled />}
  </div>
); };
const S = ({ k, l, options }: { k: string; l: string; options: Array<[string, string]> }) => { const { v, set, changed, editable } = useContext(Ctx); return (
  <div className={`field ad-field${changed(k) ? ' ad-diff' : ''}`}>
    <label className="label" htmlFor={`rv-${k}`}>{l}</label>
    <select className="select" id={`rv-${k}`} value={String(v[k] ?? '')} disabled={!editable} onChange={(e) => set(k)(e.target.value)}>{options.map(([a, c]) => <option key={a} value={a}>{c}</option>)}</select>
  </div>
); };
const Place = ({ leg }: { leg: 'pickup' | 'return' }) => { const { v } = useContext(Ctx); return (
  <>
    <S k={`${leg}_kind`} l={leg === 'pickup' ? 'Pickup place' : 'Return place'} options={[['our_location', 'Our location'], ['delivery', leg === 'pickup' ? 'We deliver' : 'We collect'], ['airport', 'Airport'], ['owner_location', 'Owner\'s location']]} />
    {v[`${leg}_kind`] === 'airport' && <F k={`${leg}_address`} l="Airport code (YYZ, YTZ)" />}
    {v[`${leg}_kind`] === 'delivery' && <A k={`${leg}_address`} l="Address" />}
    {v[`${leg}_kind`] === 'delivery' && <F k={`${leg}_km`} l="Distance (km)" hint="From the delivery origin; prices the delivery fee" />}
  </>
); };

export function BookingReview({ b, insurers, kmChoices, offerHours, editable }: { b: B; insurers: Array<{ id: string; name: string }>; kmChoices: number[]; offerHours: number; editable: boolean }) {
  const { act: adminAct, preview: adminPreview, kind } = useDoor();
  const va = kind === 'va';
  const router = useRouter();
  const coverageLine = b.lines.find((l) => COVERAGE_TYPES.includes(l.charge_type));
  const feeLines = b.lines.filter((l) => l.stage === 'booking' && !['rental_charge', 'non_refundable_discount', 'staff_discount', 'promo_discount', 'discount'].includes(l.charge_type) && !COVERAGE_TYPES.includes(l.charge_type));
  const start = useMemo(() => ({
    vehicle_id: b.vehicle_id, pickup_at: toLocalInput(b.pickup_at), return_at: toLocalInput(b.return_at), booking_type: b.booking_type,
    ...Object.fromEntries(MONEY_KEYS.map((k) => [k, dollars(b[k] as number | null)])),
    rental_charge_cents: '', price_tax: b.price_tax === 'included' ? 'included' : 'plus', price_reason: '', staff_discount_reason: b.staff_discount_reason ?? '', km_allowance_per_day: String(b.km_allowance_per_day ?? ''),
    pickup_kind: b.pickup_location_kind ?? (b.pickup_method === 'delivered' ? 'delivery' : 'our_location'), pickup_address: b.pickup_place ?? '', pickup_km: b.pickup_distance_km?.toString() ?? '',
    return_kind: b.return_location_kind ?? (b.return_method === 'picked_up' ? 'delivery' : 'our_location'), return_address: b.return_place ?? '', return_km: b.return_distance_km?.toString() ?? '',
    coverage: dollars(coverageLine?.amount_cents ?? null), promo_code: b.promo_code ?? '',
    bill_to: b.bill_to, insurer_id: b.insurer_id ?? '', insurer_claim_number: b.insurer_claim_number ?? '', insurer_adjuster_name: b.insurer_adjuster_name ?? '',
    insurer_adjuster_email: b.insurer_adjuster_email ?? '', insurer_adjuster_phone: b.insurer_adjuster_phone ?? '', insurer_authorized_days: b.insurer_authorized_days?.toString() ?? '',
    insurer_authorized_until: b.insurer_authorized_until ?? '', dates_provisional: b.dates_provisional, blocks_calendar: b.blocks_calendar, blocks_reason: '',
    ...Object.fromEntries(feeLines.map((l) => [`fee:${l.charge_type}`, dollars(l.amount_cents)])), fee_reason: '',
    message: '', expires_hours: String(offerHours), note: b.notes ?? '',
    rental_pay: b.rental_pay_method ?? 'card', deposit_pay: b.deposit_pay_method ?? 'card', notify: true, by_email: true, by_text: false
  }) as Record<string, string | boolean>, [b, offerHours]); // eslint-disable-line react-hooks/exhaustive-deps
  const [v, setV] = useState(() => (va && Number(start.expires_hours) > 48 ? { ...start, expires_hours: '48' } : start));
  const [preview, setPreview] = useState<{ booking: B; available: boolean } | null>(null);
  // the choice once per booking (0058): a request a staff member entered already carries it
  const needChoice = !b.sales_choice && !b.sales_claim_by;
  const [choice, setChoice] = useState<Choice>('');
  const [problem, setProblem] = useState<string | null>(null);
  const [done, setDone] = useState<string | null>(null);
  const [pending, run] = useTransition();
  const [opts, setOpts] = useState<Opt[]>([]);
  // add-ons (0066): staff add, remove and confirm them here; the price below follows
  const addons0 = useMemo<AddonChoice[]>(() => (b.addons ?? []).filter((a) => !a.after_booking).map((a) => ({ code: a.code, quantity: a.quantity, hours: a.hours })), [b]);
  const [addons, setAddons] = useState<AddonChoice[]>(addons0);
  const [addonOptions, setAddonOptions] = useState<AddonOption[]>([]);
  const norm = (l: AddonChoice[]) => JSON.stringify(addonsPayload(l).sort((x, y) => x.code.localeCompare(y.code)));
  const addonsChanged = norm(addons) !== norm(addons0);
  const set = (k: string) => (x: string | boolean) => { setDone(null); setV((s) => ({ ...s, [k]: x })); };
  const changed = (k: string) => v[k] !== start[k];

  // what differs from the booking as stored, in the database's words
  const payload = useMemo(() => {
    const ch: Record<string, unknown> = {};
    if (changed('vehicle_id')) ch.vehicle_id = v.vehicle_id;
    if (changed('pickup_at') && v.pickup_at) ch.pickup_at = new Date(String(v.pickup_at)).toISOString();
    if (changed('return_at') && v.return_at) ch.return_at = new Date(String(v.return_at)).toISOString();
    if (changed('booking_type')) ch.booking_type = v.booking_type;
    for (const k of MONEY_KEYS) if (changed(k)) ch[k] = cents(String(v[k])) ?? 0;
    if (String(v.rental_charge_cents).trim()) { ch.rental_charge_cents = cents(String(v.rental_charge_cents)); ch.price_tax = v.price_tax; ch.price_reason = String(v.price_reason).trim() || null; }
    if (changed('staff_discount_reason') || changed('staff_discount_cents')) ch.staff_discount_reason = String(v.staff_discount_reason).trim() || null;
    if (changed('km_allowance_per_day')) ch.km_allowance_per_day = Number(v.km_allowance_per_day);
    for (const k of ['bill_to', 'insurer_id', 'insurer_claim_number', 'insurer_adjuster_name', 'insurer_adjuster_email', 'insurer_adjuster_phone', 'insurer_authorized_until']) if (changed(k)) ch[k] = String(v[k]).trim() || null;
    if (changed('insurer_authorized_days')) ch.insurer_authorized_days = v.insurer_authorized_days ? Number(v.insurer_authorized_days) : null;
    if (changed('dates_provisional')) ch.dates_provisional = v.dates_provisional;
    const p: Record<string, unknown> = { booking: b.id, changes: ch };
    const placeChanged = ['pickup_kind', 'pickup_address', 'pickup_km', 'return_kind', 'return_address', 'return_km'].some(changed);
    if (placeChanged) p.places = {
      pickup_location: { kind: v.pickup_kind, address: String(v.pickup_address).trim() || null, distance_km: v.pickup_km ? Number(v.pickup_km) : null, airport_code: v.pickup_kind === 'airport' ? String(v.pickup_address).trim() : null },
      return_location: { kind: v.return_kind, address: String(v.return_address).trim() || null, distance_km: v.return_km ? Number(v.return_km) : null, airport_code: v.return_kind === 'airport' ? String(v.return_address).trim() : null } };
    // 0132: each fee as its amount for the trip (it was a rate a day before: typing $50 for 3 days gave $150), the Protection Plan too
    const lines: Record<string, number> = {};
    if (changed('coverage') && String(v.coverage).trim()) lines.coverage_sold = cents(String(v.coverage)) ?? 0;
    if (changed('promo_code')) p.promo_code = String(v.promo_code).trim();
    for (const l of feeLines.filter((x) => changed(`fee:${x.charge_type}`))) lines[l.charge_type] = cents(String(v[`fee:${l.charge_type}`])) ?? 0;
    if (Object.keys(lines).length) { p.line_overrides = lines; p.fee_reason = String(v.fee_reason).trim() || 'Changed on the review screen'; }
    if (changed('blocks_calendar')) { p.blocks_calendar = v.blocks_calendar; p.blocks_calendar_reason = String(v.blocks_reason).trim() || null; }
    if (addonsChanged) p.addons = addonsPayload(addons);
    return p;
  }, [v, addons]); // eslint-disable-line react-hooks/exhaustive-deps
  const payChanged = changed('rental_pay') || changed('deposit_pay');
  const dirty = Object.keys(payload.changes as object).length > 0 || Object.keys(payload).some((k) => !['booking', 'changes'].includes(k));
  // an offer that is out (offered, or approved and not paid): edited in place and sent again in one step (0129)
  const out = ['offered', 'pending_payment'].includes(b.status);
  const [revised, setRevised] = useState<string[] | null>(null);

  // live re-pricing, debounced
  const seq = useRef(0);
  useEffect(() => {
    const n = ++seq.current;
    const t = setTimeout(async () => {
      if (!dirty) { setPreview(null); setProblem(null); return; }
      const r = await adminPreview<{ ok: boolean; error?: string; booking: B; available: boolean }>('booking_preview', payload);
      if (n !== seq.current) return;
      if (!r.ok) { setProblem(r.message); return; }
      if (!r.data.ok) { setProblem(r.data.error ?? 'The database refused this change.'); setPreview(null); return; }
      setProblem(null); setPreview({ booking: r.data.booking, available: r.data.available });
    }, 350);
    return () => clearTimeout(t);
  }, [payload, dirty, adminPreview]);

  // the add-ons offered for the car and dates (staff see every one; notice is theirs to judge)
  useEffect(() => {
    const t = setTimeout(async () => {
      if (!v.vehicle_id) return;
      const r = await adminPreview<AddonOption[]>('addons_for_car', { vehicle_id: v.vehicle_id, booking: b.id,
        pickup_at: v.pickup_at ? new Date(String(v.pickup_at)).toISOString() : null, return_at: v.return_at ? new Date(String(v.return_at)).toISOString() : null });
      if (r.ok) setAddonOptions(r.data ?? []);
    }, 300);
    return () => clearTimeout(t);
  }, [v.vehicle_id, v.pickup_at, v.return_at, b.id, adminPreview]);

  // the car picker: bookable cars with whether each is free for the dates
  useEffect(() => {
    const t = setTimeout(async () => {
      if (!v.pickup_at || !v.return_at) return;
      const r = await adminPreview<Opt[]>('quote_vehicles', { booking: b.id, pickup_at: new Date(String(v.pickup_at)).toISOString(), return_at: new Date(String(v.return_at)).toISOString() });
      if (r.ok) setOpts(r.data);
    }, 300);
    return () => clearTimeout(t);
  }, [v.pickup_at, v.return_at, b.id, adminPreview]);

  const shown = preview?.booking ?? b;
  const lines = shown.lines.filter((l) => l.stage === 'booking' && l.charged_to_renter !== false && (l.amount_cents !== 0 || l.charge_type === 'rental_charge'));
  const total = shown.bill_to !== 'renter' && shown.renter_due_at_booking_cents !== null ? shown.renter_due_at_booking_cents : shown.total_due_at_booking_cents;
  const diffs: Array<[string, string, string]> = [];
  if (shown.pickup_at !== b.pickup_at) diffs.push(['Pickup', when(b.pickup_at), when(shown.pickup_at)]);
  if (shown.return_at !== b.return_at) diffs.push(['Return', when(b.return_at), when(shown.return_at)]);
  if (shown.vehicle_id !== b.vehicle_id) diffs.push(['Car', b.vehicle?.name ?? '', shown.vehicle?.name ?? '']);
  if (shown.total_due_at_booking_cents !== b.total_due_at_booking_cents) diffs.push(['Total', money(b.total_due_at_booking_cents, { cents: true }), money(shown.total_due_at_booking_cents, { cents: true })]);
  if (shown.deposit_cents !== b.deposit_cents) diffs.push(['Deposit', money(b.deposit_cents), money(shown.deposit_cents)]);
  const expiresAt = () => new Date(Date.now() + Number(v.expires_hours || offerHours) * 3600_000).toISOString();

  const pays = () => ({ rental_pay_method: v.rental_pay, deposit_pay_method: v.deposit_pay });
  const revise = (notify: boolean) => run(async () => {
    setProblem(null);
    if (!dirty && !payChanged && !String(v.message).trim()) { setProblem('Nothing changed yet: change the offer first.'); return; }
    const r = await offersDo<{ version: number | null; before: Record<string, unknown>; after: Record<string, unknown>; text?: { ok: boolean; reason?: string } | null }>('offer_revise', {
      ...payload, ...pays(), internal_note: v.note, message: v.message, expires_at: expiresAt(), notify, channels: { email: Boolean(v.by_email), text: Boolean(v.by_text) } },
      [`/admin/bookings/${b.booking_number}`, `/va/bookings/${b.booking_number}`]);
    if (!r.ok) { setProblem(r.message); return; }
    setRevised(describeRevision(r.data.before as never, r.data.after as never, (c) => money(c, { cents: true }), when));
    setDone(r.data.version ? `Offer version ${r.data.version} ${notify ? 'sent to the renter' : 'saved; the renter was not told'}.${r.data.text && !r.data.text.ok ? ` The text was not sent: ${r.data.text.reason}` : ''}` : 'Saved.');
    router.refresh();
  });

  const act = (action: 'booking_save' | 'send_offer') => run(async () => {
    setProblem(null);
    // how it is paid, kept before the save or the offer (the review screen's own action knows nothing of it)
    if (payChanged) {
      const p = await offersDo('offer_revise', { booking: b.id, changes: {}, ...pays() });
      if (!p.ok) { setProblem(p.message); return; }
    }
    const body: Record<string, unknown> = { ...payload, internal_note: v.note };
    if (action === 'send_offer') {
      if (needChoice && !choice && va) { setProblem('Choose "I sourced this client" or "Entered for CarmaCars".'); return; }
      body.message = v.message; body.expires_at = expiresAt(); if (needChoice && choice) body.sales_choice = choice;
    }
    const r = await adminAct(action, body, va ? [] : [`/admin/bookings/${b.booking_number}`, '/admin/requests']);
    if (!r.ok) { setProblem(r.message); return; }
    setDone(action === 'send_offer' ? 'Offer sent. The renter has it by email and in their account.' : 'Saved.');
    router.refresh();
  });

  return (
    <Ctx.Provider value={{ v, set, changed, editable }}>
    <div className="ad-review" data-testid="booking-review">
      <form className="pt-card ad-card ad-form ad-form--narrow" aria-label="Adjust the booking" onSubmit={(e) => { e.preventDefault(); if (out) revise(Boolean(v.notify)); else act('booking_save'); }}>
        <h2 className="d4">{out ? 'Edit the offer' : 'Adjust'}</h2>
        {out && editable && <p className="pt-note small" data-testid="review-edit-in-place">{b.status === 'pending_payment' ? 'The renter approved this offer and has not paid yet.' : 'This offer is out with the renter.'} Change anything here: the changes are highlighted, and Save sends the updated offer as a new version (or saves it without telling the renter). No need to withdraw it first.</p>}
        {!editable && <p className="pt-note small">You cannot change this offer. Ask customer service or an Admin.</p>}
        <fieldset className="ad-fields" disabled={!editable}>
          <legend className="vh">Car and dates</legend>
          <div className={`field ad-field ad-field--wide${changed('vehicle_id') ? ' ad-diff' : ''}`}>
            <label className="label" htmlFor="rv-vehicle_id">Car</label>
            <select className="select" id="rv-vehicle_id" value={String(v.vehicle_id)} onChange={(e) => set('vehicle_id')(e.target.value)}>
              {!opts.some((o) => o.id === b.vehicle_id) && <option value={b.vehicle_id}>{b.vehicle?.name} {b.vehicle?.plate}</option>}
              {opts.map((o) => <option key={o.id} value={o.id}>{o.name} {o.plate ?? ''}{o.free ? '' : ' (not free)'}{o.daily_rate_cents ? `, ${money(o.daily_rate_cents)} a day` : ''}</option>)}
            </select>
          </div>
          <F k="pickup_at" l="Pickup" type="datetime-local" />
          <F k="return_at" l="Return" type="datetime-local" />
          <S k="booking_type" l="Rate type" options={[['standard', 'Standard'], ['non_refundable', 'Non-refundable']]} />
          <Place leg="pickup" />
          <Place leg="return" />
        </fieldset>
        <fieldset className="ad-fields" disabled={!editable}>
          <legend className="pt-kicker">Rates and fees</legend>
          {va && <p className="hint ad-field--wide">Rates, fees, discounts and the Deposit are set by an Admin. You may type the rental charge with its reason: the rate sheet stays beside it, and a price far under it is flagged for an Admin.</p>}
          {va && <><F k="rental_charge_cents" l="Rental charge typed by hand" money hint="Leave empty to use the rate sheet" /><S k="price_tax" l="Tax" options={PRICE_TAX_OPTIONS} /><F k="price_reason" l="Reason for the price" /></>}
          {b.custom_price_reason && <p className="small ad-field--wide" data-testid="review-custom-price">Price typed by hand: {b.price_tax === 'included'
            ? <>{money(b.price_with_tax_cents ?? 0, { cents: true })} tax included ({money(b.rental_charge_cents, { cents: true })} before tax; rate sheet {money(b.rate_sheet_rental_cents ?? 0, { cents: true })})</>
            : <>{money(b.rental_charge_cents, { cents: true })} plus tax (rate sheet {money(b.rate_sheet_rental_cents ?? 0, { cents: true })})</>}. {b.custom_price_reason}{b.price_flags?.length ? ' Flagged for an Admin.' : ''}</p>}
          {!va && <><F k="daily_rate_cents" l="Daily" money /><F k="weekend_rate_cents" l="Weekend" money />
          <F k="weekly_rate_cents" l="Weekly" money /><F k="monthly_rate_cents" l="Monthly" money />
          <F k="rental_charge_cents" l="Rental charge typed by hand" money hint="Leave empty to use the rates" />
          <S k="price_tax" l="Tax" options={PRICE_TAX_OPTIONS} />
          <F k="price_reason" l="Reason for the price" />
          <F k="deposit_cents" l="Deposit" money /></>}
          <S k="km_allowance_per_day" l="Kilometres a day" options={[...new Set([...kmChoices, b.km_allowance_per_day])].sort((a, z) => a - z).map((k) => [String(k), k === 0 ? 'Unlimited' : `${k} km`])} />
          {!va && <><F k="overage_cents_per_km" l="Overage per km" money />
          <F k="staff_discount_cents" l="Discount" money />
          <F k="staff_discount_reason" l="Discount reason" /></>}
          <F k="coverage" l="Protection Plan price" money hint={coverageLine ? 'What the renter pays for the Protection Plan' : 'Only when the renter chose the Protection Plan (option 3)'} />
          <F k="promo_code" l="Promo code" />
          {feeLines.map((l) => <F key={l.id} k={`fee:${l.charge_type}`} l={`${lineLabel(l)} (for the trip)`} money />)}
          {(feeLines.some((l) => changed(`fee:${l.charge_type}`)) || changed('coverage')) && <F k="fee_reason" l="Reason for the fee change (optional)" />}
        </fieldset>
        <fieldset className="ad-fields" disabled={!editable}>
          <legend className="pt-kicker">Billing and calendar</legend>
          <S k="bill_to" l="Bill to" options={[['renter', 'Renter'], ['insurer', 'Insurer pays rental and fees'], ['split', 'Insurer pays the rental only']]} />
          {v.bill_to !== 'renter' && <>
            <S k="insurer_id" l="Insurer" options={[['', 'Choose'], ...insurers.map((i) => [i.id, i.name] as [string, string])]} />
            <F k="insurer_claim_number" l="Claim number" /><F k="insurer_adjuster_name" l="Adjuster" />
            <F k="insurer_adjuster_email" l="Adjuster email" type="email" /><F k="insurer_adjuster_phone" l="Adjuster phone" type="tel" />
            <F k="insurer_authorized_daily_rate_cents" l="Authorized daily rate" money /><F k="insurer_authorized_days" l="Authorized days" />
            <F k="insurer_authorized_until" l="Authorized until" type="date" />
            <div className="field ad-field"><label className="check"><input type="checkbox" checked={Boolean(v.dates_provisional)} onChange={(e) => set('dates_provisional')(e.target.checked)} /> <span>Dates are provisional</span></label></div>
          </>}
          {!va && <div className={`field ad-field${changed('blocks_calendar') ? ' ad-diff' : ''}`}><label className="check"><input type="checkbox" checked={Boolean(v.blocks_calendar)} onChange={(e) => set('blocks_calendar')(e.target.checked)} /> <span>Blocks the calendar</span></label></div>}
          {changed('blocks_calendar') && <F k="blocks_reason" l="Reason for the calendar switch" />}
          <S k="rental_pay" l="The rental is paid by" options={RENTAL_PAY.map(([a, c]) => [a, c])} />
          <S k="deposit_pay" l="The deposit is taken by" options={DEPOSIT_PAY.filter(([a]) => !va || a !== 'none').map(([a, c]) => [a, c])} />
        </fieldset>
        <fieldset className="ad-fields" disabled={!editable} data-testid="review-addons">
          <legend className="pt-kicker">Add-ons</legend>
          <div className={`ad-field--wide${addonsChanged ? ' ad-diff' : ''}`}>
            {(b.addons ?? []).some((a) => a.status === 'pending') && <p className="small"><b>Waiting for confirmation:</b> {(b.addons ?? []).filter((a) => a.status === 'pending').map((a) => a.name).join(', ')}. Keep it to confirm it with the offer, or remove it.</p>}
            <AddonPicker idPrefix="rv" staff compact options={addonOptions} value={addons} onChange={(x) => { setDone(null); setAddons(x); }} />
          </div>
        </fieldset>
        <div className="field ad-field"><label className="label" htmlFor="rv-note">Internal note</label><textarea className="input ad-textarea" id="rv-note" value={String(v.note)} onChange={(e) => set('note')(e.target.value)} /></div>
        {editable && !out && <button className="btn btn--ghost btn--sm" type="submit" disabled={pending} data-testid="review-save">{pending ? 'Saving' : 'Save changes'}</button>}
        {editable && out && (
          <div className="stack" data-testid="review-revise">
            {diffs.length > 0 && <ul className="pt-changes small" aria-label="What changes">{diffs.map(([k, a, z]) => <li key={k}><span className="small muted">{k}</span><span><del>{a}</del> <span className="vh">changed to</span> <ins>{z}</ins></span></li>)}</ul>}
            <div className="field ad-field"><label className="label" htmlFor="rv-rmsg">Message to the renter</label>
              <textarea className="input ad-textarea" id="rv-rmsg" maxLength={1000} value={String(v.message)} onChange={(e) => set('message')(e.target.value)} placeholder="What changed and why" data-testid="review-revise-message" /></div>
            <div className="field ad-field"><label className="label" htmlFor="rv-rexp">Open for</label>
              <select className="select" id="rv-rexp" value={String(v.expires_hours)} onChange={(e) => set('expires_hours')(e.target.value)}>
                {[...new Set([6, 12, 24, 48, 72, offerHours])].filter((h) => !va || h <= 48).sort((a, z) => a - z).map((h) => <option key={h} value={h}>{h} hours</option>)}</select></div>
            <div className="field ad-field"><span className="label">Send the update by</span>
              <label className="check" htmlFor="rv-by-email"><input id="rv-by-email" type="checkbox" checked={Boolean(v.by_email)} onChange={(e) => set('by_email')(e.target.checked)} /> <span>Email</span></label>
              <label className="check" htmlFor="rv-by-text"><input id="rv-by-text" type="checkbox" checked={Boolean(v.by_text)} onChange={(e) => set('by_text')(e.target.checked)} /> <span>Text</span></label></div>
            <div className="row">
              <button className="btn btn--primary" type="button" disabled={pending} onClick={() => revise(Boolean(v.by_email) || Boolean(v.by_text))} data-testid="review-revise-send">{pending ? 'Saving' : 'Save and send the update'}</button>
              <button className="btn btn--ghost btn--sm" type="button" disabled={pending} onClick={() => revise(false)} data-testid="review-revise-quiet">Save without telling the renter</button>
            </div>
            {revised && revised.length > 0 && <ul className="small" data-testid="review-revised">{revised.map((x) => <li key={x}>{x}</li>)}</ul>}
          </div>)}
      </form>

      <section className="stack" aria-label="Price">
        <div className="pt-card ad-card" data-testid="review-price">
          <div className="pt-card__head"><h2 className="d4">Price {preview ? <span className="ad-b ad-b--amber">Re-priced, not saved</span> : null}</h2><span className="small muted">{shown.billable_days} days · {shown.rate_applied?.replace(/_/g, ' ')}</span></div>
          <dl className="pt-dl pt-dl--money">
            {shown.lines.filter((l) => l.stage === 'booking').map((l) => <div key={l.id}><dt>{lineLabel(l)}</dt><dd>{money(l.amount_cents, { cents: true })}</dd></div>)}
            <div><dt>HST <Info text={lineHelp('hst')} label="What is HST?" /></dt><dd>{money(shown.hst_at_booking_cents, { cents: true })}</dd></div>
            {shown.bill_to !== 'renter' && shown.insurer_share_cents ? <div><dt>Insurer pays</dt><dd>{money(shown.insurer_share_cents, { cents: true })}</dd></div> : null}
            <div><dt><b>Due at booking</b></dt><dd className="pt-total" data-testid="review-total">{money(total, { cents: true })}</dd></div>
          </dl>
          <p className="small">{(preview?.available ?? true) ? 'The car is free for these dates.' : <b className="ad-late">The car is not free for these dates.</b>}</p>
          {problem && <p className="alert alert--error" role="alert"><span>{problem}</span></p>}
        </div>
        {(b.status === 'requested') && (
          <form className="pt-card ad-card ad-form ad-form--narrow" aria-label="Send the offer" onSubmit={(e) => { e.preventDefault(); act('send_offer'); }}>
            <h2 className="d4">Send the offer</h2>
            <div className="field ad-field"><label className="label" htmlFor="rv-msg">Message to the renter</label>
              <textarea className="input ad-textarea" id="rv-msg" maxLength={1000} value={String(v.message)} onChange={(e) => set('message')(e.target.value)} aria-describedby="rv-msg-h" />
              <p className="hint" id="rv-msg-h">{diffs.length ? 'Say what changed from the request and why.' : 'Optional.'}</p></div>
            <div className="field ad-field"><label className="label" htmlFor="rv-exp">Offer open for</label>
              <select className="select" id="rv-exp" value={String(v.expires_hours)} onChange={(e) => set('expires_hours')(e.target.value)}>
                {[...new Set([6, 12, 24, 48, 72, offerHours])].filter((h) => !va || h <= 48).sort((a, z) => a - z).map((h) => <option key={h} value={h}>{h} hours</option>)}</select></div>
            {needChoice && <SourcedChoice id="rv" value={choice} onChange={setChoice} optional={!va} />}
            {!needChoice && <p className="small muted" data-testid="review-choice">{b.sales_claim_by ? 'Someone said they sourced this client: an Admin decides.' : b.sales_choice === 'sourced' ? 'Marked "I sourced this client".' : 'Entered for CarmaCars.'}</p>}
            <button className="btn btn--primary" type="submit" disabled={pending} data-testid="review-send">{pending ? 'Sending' : dirty ? 'Save and send the offer' : 'Send the offer'}</button>
          </form>
        )}
        {done && <p className="alert alert--ok" role="status"><span>{done}</span></p>}
      </section>

      <aside className="ad-renter-view" aria-label="The offer as the renter sees it" data-testid="renter-preview">
        <p className="pt-kicker">The offer as the renter sees it</p>
        <h3 className="d4">Your offer for the {shown.vehicle?.name}</h3>
        <p className="pt-note small"><b>This offer does not hold the car.</b> The car is reserved once you approve, sign and pay.</p>
        {String(v.message).trim() && <div><b className="small">Message from our team</b><p className="small">{String(v.message)}</p></div>}
        {diffs.length > 0 && <ul className="pt-changes">{diffs.map(([k, a, z]) => <li key={k}><span className="small muted">{k}</span><span><del>{a}</del> <span className="vh">changed to</span> <ins>{z}</ins></span></li>)}</ul>}
        <dl className="pt-dl small">
          <div><dt>Pickup</dt><dd>{when(shown.pickup_at)}, {shown.pickup_place ?? 'our location'}</dd></div>
          <div><dt>Return</dt><dd>{when(shown.return_at)}, {shown.return_place ?? 'our location'}</dd></div>
          <div><dt>Deposit at pickup</dt><dd>{money(shown.deposit_cents)}</dd></div>
          {shown.km_allowance_total ? <div><dt>Kilometres</dt><dd>{shown.km_allowance_total} km included, then {money(shown.overage_cents_per_km, { cents: true })} per km</dd></div> : null}
        </dl>
        <dl className="pt-dl pt-dl--money small">
          {lines.map((l) => <div key={l.id}><dt>{lineLabel(l)} <Info text={lineHelp(l.charge_type)} label={`What is ${lineLabel(l)}?`} /></dt><dd>{money(l.amount_cents, { cents: true })}</dd></div>)}
          <div><dt>HST</dt><dd>{money(shown.hst_at_booking_cents, { cents: true })}</dd></div>
          <div><dt><b>Total due at booking</b></dt><dd><b>{money(total, { cents: true })}</b></dd></div>
        </dl>
        {/* from the clock: the server and the browser can be a minute apart, so the text may differ on hydration */}
        <p className="small muted" suppressHydrationWarning>Open until {when(expiresAt())}</p>
      </aside>
    </div>
    </Ctx.Provider>
  );
}
