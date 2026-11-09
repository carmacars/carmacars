'use client';
import { useEffect, useMemo, useRef, useState, useTransition } from 'react';
import { playMoment } from '@/features/motion/moment';
import { PICKUP_PASSED, pickupPassed } from './pickup-passed';
import { scrollOption } from '@/lib/nav/same-page';
import Link from '@/components/Link';
import { useRouter } from 'next/navigation';
import { money } from '@/lib/format';
import { when } from '@/features/agreement/model';
import { offersDo, offersRead } from '@/server/actions/offers';
import { deliveryDistance, draftClose, draftSave, supplyRead } from '@/server/actions/supply';
import { SourcedChoice } from '@/features/sales/SourcedChoice';
import { TaxModeToggle, useTaxMode } from '@/features/sales/TaxModeToggle';
import { beforeTax, convertTyped, hstOf, linesBeforeTax, solveRental, totalDifference, type TaxMode } from '@/features/sales/taxIncluded';
import { AddonPicker } from '@/features/addons/AddonPicker';
import { Info } from '@/features/forms/Info';
import { AddressInput } from '@/features/forms/AddressInput';
import { lineHelp } from './help';
import { addonsPayload, type AddonChoice, type AddonOption } from '@/features/addons/model';
import { COVERAGE, DEPOSIT_PAY, PLACES, RENTAL_LINE, RENTAL_PAY, daysBetween, droppedByPrice, firstName, hasMobile, lineKey, liveFees, missing, missingFields, offerChannels, offerChoices, offerPayload, periodShares, typedRental, type MissingField, type OfferForm, type PlaceKind, type Role } from './model';
import { OwnerChoice, ownerChoiceInitial, ownerChoicePayload, type OwnerDefaults } from '@/features/supply/OwnerChoice';
import { TypedInput } from '@/components/DateInput';

// Send an offer without a request (migration 0129): one screen for an Admin, customer service and sales. The customer
// found by name, phone or email (or added; one person, one record), the car with whether it is free, the dates, the
// places, the price (the rate sheet, a total or a rate per day), fees, the deposit, the Protection Plan, how the rental
// and the deposit are paid, who found the client, the message and how long the offer is open. The right side is the
// offer as the renter will see it, priced by the database (and rolled back) as you type. Send makes the same records a
// website request and its offer make; the renter gets the link by email, by text, both or neither.
// Release 24 (the owner: "not cohesive, rate cards everywhere, delivery removed in one spot and its charge in another"):
// one flow (renter and dates, car, pickup and return, coverage, add-ons, price, message and send) beside a live summary
// (sticky on a desktop, a bottom sheet on a phone); the rate card folded away; and the choices drive the charges: a fee
// set by hand is kept only while the choice that makes its line is chosen (model.ts liveFees, and the database again,
// migration 0250), shown as "Set by hand" with Reset to automatic.
type Car = { id: string; name: string; plate: string | null; car_code: string | null; daily_rate_cents: number | null; weekly_rate_cents: number | null; deposit_cents: number | null; free: boolean | null; class?: string | null; body_type?: string | null;
  /** 1202: whether the Protection Plan (RentalCover) may be offered for the car, with the reason when not */
  rentalcover?: { allowed: boolean; reason: string | null; value_cents: number | null } };
type Form = { role: Role; offer_hours: number; min_notice_minutes: number; km_choices: number[]; text_enabled: boolean; cars: Car[]; may_edit_fees?: boolean; period_days?: number; cycle?: string };
type Found = { id: string; legal_name: string; email: string | null; mobile: string | null; date_of_birth: string | null; is_blocked: boolean; bookings: number; card: { brand: string; last4: string } | null };
type Line = { id: string; charge_type: string; description: string | null; amount_cents: number; hst_cents: number; hst_applies?: boolean; stage: string; charged_to_renter: boolean; booking_addon_id?: string | null; addon_code?: string | null };
type Priced = { booking_number: string; billable_days: number; hst_bps?: number; rate_applied: string | null; rental_charge_cents: number; deposit_cents: number; hst_at_booking_cents: number;
  total_due_at_booking_cents: number; renter_due_at_booking_cents: number | null; km_allowance_total: number | null; overage_cents_per_km: number; pickup_place: string | null; return_place: string | null;
  rate_sheet_rental_cents: number | null; price_flags: string[]; lines: Line[]; vehicle: { name: string } | null; pickup_at: string; return_at: string };
type Sent = { booking_number: string; version: number; total_cents: number; due_cents: number; expires_at: string; renter_existing: boolean; notified: boolean; text?: { ok: boolean; to?: string; reason?: string } | null; price_flags?: string[];
  /** 0770: Book it now: approved at once (an Admin) or waiting for an Admin (staff) */
  book_now?: { status: 'approved' | 'requested' | 'already' } | null };

const pad = (n: number) => String(n).padStart(2, '0');
const local = (d: Date) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
const fmt = (c: number | null | undefined) => money(Number(c ?? 0), { cents: true });
const lineLabel = (l: Line) => l.description || l.charge_type.replace(/_/g, ' ');
const PLAN_TYPES = ['coverage_sold', 'coverage', 'coverage_option', 'carmacars_coverage', 'coverage_daily'];

/** What an offer draft keeps (0148). */
export interface OcDraft { f?: Partial<OfferForm>; addons?: AddonChoice[]; customs?: Array<{ label: string; amount: string; hst: boolean }>; chosen?: Found | null; renter_id?: string | null;
  /** 2026-10-27: how the amounts were typed, and the total the renter pays typed */
  tax_mode?: TaxMode; total?: string }

export function OfferComposer({ base, initialCar = null, draft = null, owner = null }: { base: '/admin' | '/staff'; initialCar?: string | null; draft?: { id: string; data: OcDraft } | null; owner?: OwnerDefaults | null }) {
  // 0156: what the car's owner sees of the booking
  const [ownerChoice, setOwnerChoice] = useState(() => ownerChoiceInitial(owner));
  const start = useMemo(() => { const d = new Date(Date.now() + 86_400_000); d.setMinutes(0, 0, 0); d.setHours(10); return d; }, []);
  const [form, setForm] = useState<Form | null>(null);
  const [f, setF] = useState<OfferForm>(() => ({
    renter_id: null, full_name: '', email: '', mobile: '', date_of_birth: '',
    vehicle_id: initialCar ?? '', pickup_at: local(start), return_at: local(new Date(start.getTime() + 3 * 86_400_000)),
    pickup_kind: 'our_location', pickup_address: '', pickup_km: '', return_kind: 'our_location', return_address: '', return_km: '',
    price_mode: 'sheet', price_total: '', price_day: '', price_tax: 'plus', price_reason: '',
    deposit: '', discount: '', discount_reason: '', promo_code: '', km: '', coverage_option: '1', plan_price: '', fees: {}, fee_reason: '',
    rental_pay: 'card', deposit_pay: 'card', choice: '', message: '', note: '', hours: '24', by_email: false, by_text: true, notify: true,
    ...(draft?.data.f ?? {})
  }));
  const set = <K extends keyof OfferForm>(k: K) => (v: OfferForm[K]) => setF((s) => ({ ...s, [k]: v }));
  // Release 24: a choice that makes a fee line (where the car is handed over and taken back, the coverage): a fee set by
  // hand whose choice is no longer chosen goes with it, and the place typed for another kind of place is cleared
  const choose = (patch: Partial<OfferForm>) => setF((s) => {
    const n = { ...s, ...patch };
    if (patch.pickup_kind && patch.pickup_kind !== s.pickup_kind) { n.pickup_address = ''; n.pickup_km = ''; }
    if (patch.return_kind && patch.return_kind !== s.return_kind) { n.return_address = ''; n.return_km = ''; }
    return { ...n, fees: liveFees(n.fees, offerChoices(n)), plan_price: n.coverage_option === '3' ? n.plan_price : '' };
  });
  const [q, setQ] = useState('');
  const [found, setFound] = useState<Found[]>([]);
  const [chosen, setChosen] = useState<Found | null>(draft?.data.chosen ?? null);
  const [adding, setAdding] = useState(false);
  const [carQ, setCarQ] = useState('');
  // 0148 (sim item 9): narrow the cars to a type and to the ones free for the dates
  const [carType, setCarType] = useState('');
  const [freeOnly, setFreeOnly] = useState(false);
  const [addons, setAddons] = useState<AddonChoice[]>(draft?.data.addons ?? []);
  // an add-on taken off: its price set by hand goes with it
  const changeAddons = (v: AddonChoice[]) => { setAddons(v); setF((s) => ({ ...s, fees: liveFees(s.fees, { addons: v.map((a) => a.code) }) })); };
  const [addonOptions, setAddonOptions] = useState<AddonOption[]>([]);
  const [priced, setPriced] = useState<{ booking: Priced; available: boolean } | null>(null);
  // the payload the price on screen was worked out for (an older one shows as updating)
  const [pricedKey, setPricedKey] = useState('');
  // 2026-10-27: amounts typed before or after tax (remembered on this device), and the total the renter pays (after tax)
  const [taxMode, setTaxMode] = useTaxMode();
  const [totalTyped, setTotalTyped] = useState(draft?.data.total ?? '');
  const [solvedW, setSolvedW] = useState<number | null>(null);
  const restoredTax = useRef(false);
  useEffect(() => {
    if (restoredTax.current || !draft) return;
    restoredTax.current = true;
    // the boxes of the draft are in the draft's mode: the device's saved mode never reinterprets them
    setTaxMode(draft.data.tax_mode ?? (draft.data.f?.price_tax === 'included' ? 'after' : 'before'));
  }, [draft, setTaxMode]);
  const [problem, setProblem] = useState<string | null>(null);
  // 0770: Book it now (no renter approval): an Admin's offer is approved at once; staff's waits for an Admin
  const [bookNow, setBookNow] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [sent, setSent] = useState<Sent | null>(null);
  const [pending, run] = useTransition();
  const router = useRouter();
  const role: Role = form?.role ?? 'sales';
  const admin = role === 'admin';
  // 0132: fee lines set by hand by an Admin, and by customer service and sales while Program settings allow it
  const editFees = form?.may_edit_fees ?? admin;
  const days = priced?.booking.billable_days ?? daysBetween(f.pickup_at, f.return_at);

  // the cars, with whether each is free for the dates (again when the dates change)
  useEffect(() => {
    const t = setTimeout(async () => {
      const r = await offersRead<Form>('offer_form', { pickup_at: f.pickup_at ? new Date(f.pickup_at).toISOString() : null, return_at: f.return_at ? new Date(f.return_at).toISOString() : null });
      if (r.ok) { setForm(r.data); setF((s) => (s.hours === '24' && r.data.offer_hours ? { ...s, hours: String(r.data.role === 'admin' ? r.data.offer_hours : Math.min(r.data.offer_hours, 48)) } : s)); }
      else setErr(r.message);
    }, 250);
    return () => clearTimeout(t);
  }, [f.pickup_at, f.return_at]);

  // the customer search, as you type (name, email or phone)
  useEffect(() => {
    if (chosen || q.trim().length < 3) { setFound([]); return; }
    const t = setTimeout(async () => { const r = await offersRead<Found[]>('find_customers', { q }); if (r.ok) setFound(r.data); }, 300);
    return () => clearTimeout(t);
  }, [q, chosen]);
  // a new customer whose email or phone is already on file: say so, offer to use them (never a second record)
  const [dupe, setDupe] = useState<Found | null>(null);
  useEffect(() => {
    if (!adding) { setDupe(null); return; }
    const key = f.email.includes('@') ? f.email.trim() : f.mobile.replace(/\D/g, '').length >= 10 ? f.mobile.replace(/\D/g, '').slice(-10) : '';
    if (!key) { setDupe(null); return; }
    const t = setTimeout(async () => { const r = await offersRead<Found[]>('find_customers', { q: key }); setDupe(r.ok && r.data.length ? r.data[0]! : null); }, 400);
    return () => clearTimeout(t);
  }, [adding, f.email, f.mobile]);

  // add-ons of the car for the dates
  useEffect(() => {
    if (!f.vehicle_id) { setAddonOptions([]); return; }
    let live = true;
    supplyRead<AddonOption[]>('addons_for_car', { vehicle_id: f.vehicle_id, pickup_at: f.pickup_at ? new Date(f.pickup_at).toISOString() : null, return_at: f.return_at ? new Date(f.return_at).toISOString() : null })
      .then((r) => { if (live && r.ok) setAddonOptions(r.data ?? []); });
    return () => { live = false; };
  }, [f.vehicle_id, f.pickup_at, f.return_at]);

  // the total the renter pays typed (after tax): the rental charge is worked out from it, so no price or reason to type
  const totalCents = /^\s*\$?[\d,]+(\.\d{0,2})?\s*$/.test(totalTyped) ? Math.round(Number(totalTyped.replace(/[$,\s]/g, '')) * 100) : null;
  const missingNow = () => missing(f, role).filter((m) => totalCents === null || (m !== 'the price' && m !== 'the reason for the price'));
  const need = missingNow().filter((m) => m !== 'who found this client');
  // 0132: charges of its own on the offer (the renter sees what is typed)
  const [customs, setCustoms] = useState<Array<{ label: string; amount: string; hst: boolean }>>(draft?.data.customs ?? []);
  // 0148: saved as a draft as you type; opened again from Unfinished rentals on any device
  const [draftId, setDraftId] = useState<string | null>(draft?.id ?? null);
  const [savedAt, setSavedAt] = useState<string | null>(null);
  const snapKey = JSON.stringify({ f, addons, customs, chosen, taxMode, totalTyped });
  const firstSnap = useRef(snapKey);
  const saveDraft = async () => {
    const data: OcDraft = { f, addons, customs, chosen, renter_id: f.renter_id, tax_mode: taxMode, total: totalTyped };
    const r = await draftSave({ id: draftId, kind: 'offer', data: data as Record<string, unknown>, title: [chosen?.legal_name ?? f.full_name, form?.cars.find((c) => c.id === f.vehicle_id)?.name].filter(Boolean).join(', ') });
    if (r.ok) { setDraftId(r.data.id); setSavedAt(r.data.updated_at); }
  };
  useEffect(() => {
    if (sent || snapKey === firstSnap.current) return;
    if (!f.renter_id && !f.full_name.trim() && !f.email.trim()) return;
    const t = setTimeout(() => { void saveDraft(); }, 1500);
    return () => clearTimeout(t);
  }, [snapKey]); // eslint-disable-line react-hooks/exhaustive-deps
  // 2026-10-27: the settings' HST rate and each line's own HST flag, from the offer as priced
  const bps = priced?.booking.hst_bps ?? null;
  const pricedLines = priced?.booking.lines;
  // each line's HST flag, as a string so a new price with the same lines does not make a new payload (and a new price)
  const hstSig = JSON.stringify((pricedLines ?? []).filter((x) => x.stage === 'booking').map((x) => [x.booking_addon_id && x.addon_code ? `addon:${x.addon_code}` : lineKey({ charge_type: x.charge_type }), x.hst_applies ?? x.hst_cents !== 0]));
  const payload = useMemo(() => {
    const after = taxMode === 'after';
    const flags = new Map(JSON.parse(hstSig) as Array<[string, boolean]>);
    const hstFor = (k: string) => flags.get(k) ?? true;
    const typedC = customs.filter((x) => x.label.trim() && Number(x.amount) > 0);
    const cc = linesBeforeTax(typedC.map((x, i) => ({ key: String(i), typed: Math.round(Number(x.amount) * 100), hst: x.hst })), after && bps !== null ? 'after' : 'before', bps ?? 0);
    const p = offerPayload(f, role, days, addonsPayload(addons), editFees, { after, bps, hstFor, rentalWithTax: totalCents !== null ? solvedW : null, extraResidual: editFees ? cc.residual : 0 });
    const c = typedC.map((x, i) => ({ label: x.label.trim(), amount_cents: cc.cents[String(i)], hst: x.hst }));
    return editFees && c.length ? { ...p, custom_fees: c, fee_reason: p.fee_reason ?? (f.fee_reason.trim() || 'Agreed with the renter') } : p;
  }, [f, role, days, addons, editFees, customs, taxMode, bps, hstSig, totalCents, solvedW]);
  const payloadKey = JSON.stringify({ ...payload, expires_at: null });
  // the price and the renter's view, from the database, as you type
  const seq = useRef(0);
  useEffect(() => {
    const n = ++seq.current;
    if (!form || need.length) { setPriced(null); setProblem(null); return; }
    const t = setTimeout(async () => {
      const r = await offersRead<{ ok: boolean; error?: string; booking: Priced; available: boolean }>('offer_preview', payload);
      if (n !== seq.current) return;
      if (!r.ok) { setProblem(r.message); setPriced(null); return; }
      if (!r.data.ok) { setProblem((r.data.error ?? 'The database refused this offer.').replace(/^.*?ERROR:\s*/, '')); setPriced(null); return; }
      setProblem(null); setPriced({ booking: r.data.booking, available: r.data.available }); setPricedKey(JSON.stringify({ ...payload, expires_at: null }));
    }, 450);
    return () => clearTimeout(t);
  }, [payload, form, need.length]);

  // 2026-10-27: the total the renter pays, typed: the rental charge (tax included) is worked out so the total priced is it
  const fresh = !!priced && pricedKey === payloadKey;
  // Release 24: a fee set by hand the database priced away (its choice is gone: a young driver fee once the date of
  // birth is not young) is dropped here too, so it never comes back with the choice
  useEffect(() => {
    if (!fresh || !priced) return;
    const gone = droppedByPrice((payload.line_overrides ?? {}) as Record<string, unknown>, priced.booking.lines);
    if (!gone.length) return;
    setF((s) => { const fees = { ...s.fees }; for (const k of gone) delete fees[k]; return { ...s, fees, plan_price: gone.includes('coverage_sold') ? '' : s.plan_price }; });
  }, [fresh, priced]); // eslint-disable-line react-hooks/exhaustive-deps
  const solveSteps = useRef(0);
  const othersKey = JSON.stringify({ ...payload, rental_charge_cents: null, price_tax: null, price_reason: null, expires_at: null });
  useEffect(() => { solveSteps.current = 0; if (totalCents === null) setSolvedW(null); }, [totalTyped, othersKey]); // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => {
    if (totalCents === null || !priced || !fresh) return;
    const t = priced.booking.total_due_at_booking_cents;
    if (t === totalCents || solveSteps.current >= 6) return;
    const rl = priced.booking.lines.find((l) => l.stage === 'booking' && l.charge_type === 'rental_charge');
    const w = solveRental(totalCents, t, rl ? rl.amount_cents + rl.hst_cents : 0);
    if (w === null || w === solvedW) return;
    solveSteps.current += 1;
    setSolvedW(w);
  }, [priced, fresh, totalTyped]); // eslint-disable-line react-hooks/exhaustive-deps
  // the toggle: every box typed keeps meaning the same money (a line without HST is left as it is)
  const changeTaxMode = (m: TaxMode) => {
    if (m === taxMode) return;
    const lineHst = (k: string) => { const l = (pricedLines ?? []).find((x) => (x.booking_addon_id && x.addon_code ? `addon:${x.addon_code}` : lineKey({ charge_type: x.charge_type })) === k); return l ? (l.hst_applies ?? l.hst_cents !== 0) : true; };
    const conv1 = (v: string, hst: boolean) => { const c = Number(v.replace(/[$,\s]/g, '')); return !v.trim() || !Number.isFinite(c) || bps === null ? v : (convertTyped(Math.round(c * 100), taxMode, m, hst, bps) / 100).toFixed(2); };
    setF((s) => ({ ...s, price_tax: m === 'after' ? 'included' : 'plus', price_total: conv1(s.price_total, true), price_day: conv1(s.price_day, true), plan_price: conv1(s.plan_price, true),
      fees: Object.fromEntries(Object.entries(s.fees).map(([k, v]) => [k, conv1(v, lineHst(k))])) }));
    setCustoms((a) => a.map((c) => (c.hst ? { ...c, amount: conv1(c.amount, true) } : c)));
    setTaxMode(m);
  };

  // the price summary as a bottom sheet on a phone (open or folded), and the charges being changed by hand
  const [sheet, setSheet] = useState(false);
  const [editing, setEditing] = useState<string[]>([]);
  // Send pressed with something missing: each missing field then says so beside it
  const [tried, setTried] = useState(false);
  const send = (draft = false) => run(async () => {
    setErr(null); setTried(true);
    const m = missingNow();
    if (m.length) { setErr(`Still needed: ${m.join(', ')}.`); return; }
    const o = ownerChoicePayload(ownerChoice, owner);
    const r = await offersDo<Sent & { booking_id: string }>('offer_create', draft ? { ...payload, ...o, draft: true } : { ...payload, ...o, ...(bookNow ? { book_now: true } : {}) }, [`${base}/bookings`]);
    if (!r.ok) { setErr(r.message); return; }
    if (draftId) void draftClose(draftId, 'done');
    if (draft) { router.push(`${base}/bookings/${encodeURIComponent(r.data.booking_number)}?tab=review`, scrollOption(`${base}/bookings/${encodeURIComponent(r.data.booking_number)}?tab=review`)); return; }
    setSent(r.data);
    playMoment('offer');
  });

  if (sent) return (
    <section className="pt-card stack" aria-labelledby="oc-sent" data-testid="offer-sent">
      <h2 className="d3" id="oc-sent">{sent.book_now?.status === 'approved' ? `Booking ${sent.booking_number} booked` : `Offer ${sent.booking_number} sent`}</h2>
      {sent.book_now?.status === 'approved' && <p className="alert alert--ok" role="status" data-testid="oc-booked-now"><span>Booked without the renter&apos;s approval: the car is held and the booking waits for payment. The renter gets one link to sign and pay; or open the booking to have them sign and pay on this device (Sign now on this device, Take the card).</span></p>}
      {sent.book_now?.status === 'requested' && <p className="alert alert--warn" role="status" data-testid="oc-book-now-asked"><span>Book it now is waiting for an Admin: once they approve, the booking waits for payment and the renter gets the Sign and pay link. Until then the offer is out as usual.</span></p>}
      <p>{sent.notified ? `The renter has the link${offerChannels(f).email ? ' by email' : ''}${offerChannels(f).email && offerChannels(f).text ? ' and' : ''}${offerChannels(f).text ? ' by text' : ''}.` : 'Not sent to the renter: tell them yourself, or press Send again later from the booking.'}
        {' '}Total {fmt(sent.total_cents)}, open until {when(sent.expires_at)}. The car is reserved once they approve, sign{f.rental_pay === 'card' ? ' and pay' : ' and you record the payment'}.</p>
      {sent.text && !sent.text.ok && <p className="alert alert--warn" role="status"><span>The text was not sent: {sent.text.reason}</span></p>}
      {sent.price_flags?.length ? <p className="small">The price you typed is flagged for an Admin to review.</p> : null}
      <p className="row"><Link prefetch={false} className="btn btn--primary" href={`${base}/bookings/${encodeURIComponent(sent.booking_number)}`} data-testid="offer-open">Open the booking</Link>
        <button className="btn btn--ghost" type="button" onClick={() => { setSent(null); setChosen(null); setQ(''); setF((s) => ({ ...s, renter_id: null, full_name: '', email: '', mobile: '', date_of_birth: '', message: '', note: '', price_mode: 'sheet', price_total: '', price_day: '', price_reason: '' })); }}>Send another</button></p>
    </section>
  );


  const b = priced?.booking;
  // the rental charge and what comes off it first, then the charges, in the database's order
  const bookingLines = (b?.lines ?? []).filter((l) => l.stage === 'booking').map((l, i) => ({ l, i })).sort((x, y) => (RENTAL_LINE.has(y.l.charge_type) ? 1 : 0) - (RENTAL_LINE.has(x.l.charge_type) ? 1 : 0) || x.i - y.i).map((x) => x.l);
  const renterLines = bookingLines.filter((l) => l.charged_to_renter !== false && (l.amount_cents !== 0 || l.charge_type === 'rental_charge'));
  // every fee line of the offer (0132): young driver, delivery, collection, add-ons; the Protection Plan is with the coverage
  const feeLines = bookingLines.filter((l) => !RENTAL_LINE.has(l.charge_type) && !PLAN_TYPES.includes(l.charge_type));
  const keyOf = (l: Line) => (l.booking_addon_id && l.addon_code ? `addon:${l.addon_code}` : lineKey({ charge_type: l.charge_type }));
  // the lines set by hand, as sent (a fee whose choice is gone is never sent: model.ts liveFees)
  const handKeys = new Set(Object.keys((payload.line_overrides ?? {}) as Record<string, number>));
  const isHand = (l: Line) => handKeys.has(keyOf(l)) || (PLAN_TYPES.includes(l.charge_type) && handKeys.has('coverage_sold'));
  const reset = (k: string) => { setEditing((e) => e.filter((x) => x !== k)); if (k === 'coverage_sold') set('plan_price')(''); else setF((s) => { const fees = { ...s.fees }; delete fees[k]; return { ...s, fees }; }); };
  const priced0 = b ? (b.renter_due_at_booking_cents ?? b.total_due_at_booking_cents) : 0;
  // a fee typed shows at once (its amount before tax, and the total moved by it and its HST); the database checks it a
  // moment later (the debounced preview) and its answer replaces this
  const typedOver = (payload.line_overrides ?? {}) as Record<string, number>;
  const shownCents = (l: Line) => { const k = PLAN_TYPES.includes(l.charge_type) ? 'coverage_sold' : keyOf(l); return !fresh && k in typedOver && !RENTAL_LINE.has(l.charge_type) ? typedOver[k]! : l.amount_cents; };
  const lineDelta = (l: Line) => { const c = shownCents(l); if (c === l.amount_cents) return 0; const hst = l.hst_applies ?? l.hst_cents !== 0; return c - l.amount_cents + (hst && bps !== null ? hstOf(c, bps) - l.hst_cents : 0); };
  const hstDelta = (l: Line) => { const c = shownCents(l); return c === l.amount_cents || !(l.hst_applies ?? l.hst_cents !== 0) || bps === null ? 0 : hstOf(c, bps) - l.hst_cents; };
  const total = priced0 + (b ? b.lines.filter((l) => l.stage === 'booking').reduce((x, l) => x + lineDelta(l), 0) : 0);
  const hstShown = b ? b.hst_at_booking_cents + b.lines.filter((l) => l.stage === 'booking').reduce((x, l) => x + hstDelta(l), 0) : 0;
  const difference = b && fresh ? totalDifference(b.total_due_at_booking_cents, totalCents, fmt) : '';
  const tw = taxMode === 'after' ? 'HST included' : 'before tax';
  const cars = (form?.cars ?? []).filter((c) => { const k = carQ.trim().toLowerCase(); return (!k || `${c.name} ${c.plate ?? ''} ${c.car_code ?? ''}`.toLowerCase().includes(k))
    && (!carType || c.body_type === carType || c.class === carType) && (!freeOnly || c.free !== false || c.id === f.vehicle_id); });
  const bodyTypes = [...new Set((form?.cars ?? []).map((c) => c.body_type).filter((x): x is string => !!x))].sort();
  const classes = [...new Set((form?.cars ?? []).map((c) => c.class).filter((x): x is string => !!x))].sort();
  const car = form?.cars.find((c) => c.id === f.vehicle_id);
  // the simplicity pass: what is missing, beside its field once Send was pressed, and in one checklist above Send
  const missingList = missingFields(f, role, { adding }).filter((m) => totalCents === null || (m.field !== 'price' && m.field !== 'price_reason'));
  const needOf = (field: MissingField['field']) => missingList.find((m) => m.field === field);
  const needMsg = (field: MissingField['field']) => { const m = tried ? needOf(field) : undefined; return m ? <p className="oc-need" data-testid={`oc-need-${field}`}>{m.say}</p> : null; };
  const who = firstName(chosen?.legal_name ?? f.full_name);
  // each line of the summary in plain words ("Delivery to 78 Main St")
  const place = (leg: 'pickup' | 'return') => { const k = f[`${leg}_kind`]; const a = String(f[`${leg}_address`] ?? '').trim();
    return k === 'airport' ? `the airport${a ? ` (${a.toUpperCase()})` : ''}` : a ? a.split(',')[0]! : 'the renter'; };
  const plain = (l: Line) => l.charge_type === 'rental_charge' && b ? `Car rental, ${b.billable_days} day${b.billable_days === 1 ? '' : 's'}`
    : l.charge_type === 'delivery' ? `Delivery to ${place('pickup')}` : l.charge_type === 'pickup' ? `Collection from ${place('return')}`
    : PLAN_TYPES.includes(l.charge_type) ? 'Protection Plan' : lineLabel(l);
  const id = (k: string) => `oc-${k}`;
  const text = (k: keyof OfferForm, l: string, o: { type?: string; hint?: string; inputMode?: 'decimal' | 'numeric' | 'tel' | 'email'; wide?: boolean; placeholder?: string; auto?: string; need?: MissingField['field']; info?: string } = {}) => (
    <div className={`field ad-field${o.wide ? ' ad-field--wide' : ''}`}><span className="label-line"><label className="label" htmlFor={id(k)}>{l}</label>{o.info && <Info text={o.info} label={`About ${l}`} />}</span>
      <TypedInput className={`input${o.need && tried && needOf(o.need) ? ' is-invalid' : ''}`} id={id(k)} type={o.type ?? 'text'} inputMode={o.inputMode} placeholder={o.placeholder} autoComplete={o.auto ?? 'off'} value={String(f[k] ?? '')}
        onChange={(e) => set(k)(e.target.value as never)} data-testid={`oc-${k}`} aria-describedby={o.hint ? `${id(k)}-h` : undefined} aria-invalid={o.need && tried && needOf(o.need) ? true : undefined} />
      {o.hint && <p className="hint" id={`${id(k)}-h`}>{o.hint}</p>}{o.need && needMsg(o.need)}</div>);
  const select = (k: keyof OfferForm, l: string, options: Array<[string, string]>, onPick?: (v: string) => void, info?: string) => (
    <div className="field ad-field"><span className="label-line"><label className="label" htmlFor={id(k)}>{l}</label>{info && <Info text={info} label={`About ${l}`} />}</span>
      <select className="select" id={id(k)} value={String(f[k])} onChange={(e) => (onPick ? onPick(e.target.value) : set(k)(e.target.value as never))} data-testid={`oc-${k}`}>{options.map(([v, x]) => <option key={v} value={v}>{x}</option>)}</select></div>);
  // the fee a choice makes, beside the choice: its amount, and whether it is the automatic one or set by hand
  const feeNote = (key: string, what: string) => {
    const l = bookingLines.find((x) => keyOf(x) === key || (key === 'coverage_sold' && PLAN_TYPES.includes(x.charge_type)));
    if (!l) return null;
    const hand = isHand(l);
    return <p className="small oc-feenote" data-testid={`oc-feenote-${key}`}>{what}: <b className="num">{fmt(shownCents(l))}</b> {hand
      ? <><span className="ad-b ad-b--amber">Set by hand</span> <button className="btn btn--quiet btn--sm" type="button" onClick={() => reset(key)}>Reset to automatic</button></>
      : <span className="ad-b ad-b--light">Automatic</span>}</p>;
  };
  const placeFields = (leg: 'pickup' | 'return') => (<div className="stack oc-leg" data-testid={`oc-leg-${leg}`}>
    {select(`${leg}_kind`, leg === 'pickup' ? 'They pick up the car' : 'They return the car', PLACES.map(([v]) => [v, leg === 'return' && v === 'delivery' ? 'We collect it from them' : leg === 'pickup' && v === 'delivery' ? 'We deliver it to them' : v === 'our_location' ? 'At our location' : v === 'airport' ? 'At an airport' : 'At the owner\'s location']),
      (v) => choose({ [`${leg}_kind`]: v as PlaceKind }))}
    {(f[`${leg}_kind`] as PlaceKind) === 'delivery' && <><div className="field ad-field"><label className="label" htmlFor={id(`${leg}_address`)}>{leg === 'pickup' ? 'Delivery address' : 'Collection address'}</label>
      <AddressInput id={id(`${leg}_address`)} name={`${leg}_address`} value={{ label: String(f[`${leg}_address`] ?? ''), placeId: '' }} onChange={(x) => {
        set(`${leg}_address`)(x.label as never);
        // a suggestion chosen: the distance is measured, and prices the delivery (sim item 12); typed by hand stays as typed
        if (x.placeId) void deliveryDistance(x.placeId, x.session).then((r) => { if (r.ok && r.data.km !== null) set(`${leg}_km`)(String(r.data.km) as never); });
      }} testId={`oc-${leg}_address`} /></div>{text(`${leg}_km`, 'Distance (km)', { inputMode: 'decimal', hint: 'Filled when you pick the address from the list. It sets the fee.' })}</>}
    {(f[`${leg}_kind`] as PlaceKind) === 'airport' && text(`${leg}_address`, 'Airport code', { placeholder: 'YYZ' })}
    {feeNote(leg === 'pickup' ? 'delivery' : 'pickup', leg === 'pickup' ? 'Delivery fee' : 'Collection fee')}
  </div>);
  const step = (n: number, title: string, lead: string, body: React.ReactNode, o: { testId?: string } = {}) => (
    <fieldset className="oc-step" data-testid={o.testId}><legend className="oc-step__head"><span className="oc-step__n" aria-hidden="true">{n}</span><span className="d4">{title}</span></legend>
      <p className="small muted oc-step__lead">{lead}</p>{body}</fieldset>);
  // "More options" of a step: closed unless something in it is in use
  const more = (testId: string, label: string, inUse: boolean, body: React.ReactNode) => (
    <details className="oc-disclose oc-more" open={inUse || undefined} data-testid={testId}><summary>{label}{inUse ? ' (in use)' : ''}</summary><div className="stack">{body}</div></details>);
  const periods = b && form?.period_days && b.billable_days > form.period_days ? (() => { const n = Math.ceil(b.billable_days / form.period_days!); const sh = periodShares(total, Array.from({ length: n }, (_, i) => (i < n - 1 ? form.period_days! : b.billable_days - form.period_days! * (n - 1))));
    return <p className="alert alert--ok small" role="status" data-testid="oc-periods"><span>{b.billable_days} days: {n} monthly periods of 30 days at the monthly rate (about {sh.map((x) => fmt(x)).join(', ')}).</span></p>; })() : null;
  const rentalLine = bookingLines.find((l) => l.charge_type === 'rental_charge');
  const priceInUse = f.price_mode !== 'sheet' || !!totalTyped.trim() || handKeys.size > 0 || customs.length > 0 || !!f.km || !!f.promo_code.trim() || !!f.deposit.trim() || cents0(f.discount) || editing.length > 0;
  const payInUse = f.rental_pay !== 'card' || f.deposit_pay !== 'card';
  const payWords = `${RENTAL_PAY.find(([v]) => v === f.rental_pay)?.[1]}; deposit: ${DEPOSIT_PAY.find(([v]) => v === f.deposit_pay)?.[1].toLowerCase()}`;
  let n = 0;

  return (
    <div className="oc-flow" data-testid="offer-composer">
      <form className="pt-card ad-card ad-form ad-form--narrow oc-form" aria-label="The offer" noValidate onSubmit={(e) => { e.preventDefault(); if (!pickupPassed(f.pickup_at)) send(); }}>
        <p className="small muted" role="status" aria-live="polite" data-testid="oc-draft-status">{savedAt ? `Saved as a draft at ${new Date(savedAt).toLocaleTimeString('en-CA', { hour: 'numeric', minute: '2-digit' })}: finish it later from Unfinished rentals.` : 'Saved as a draft as you type.'}
          {draftId && <> <button className="btn btn--quiet btn--sm" type="button" onClick={() => run(async () => { await draftClose(draftId, 'discarded'); router.push(`${base}/offers/new`, scrollOption(`${base}/offers/new`)); })} data-testid="oc-discard-draft">Discard the draft</button></>}</p>

        {step(++n, 'Who is renting and when', 'Find the renter (or add them), then set when they pick up and return the car.', <>
          {chosen ? (
            <p data-testid="oc-customer"><b>{chosen.legal_name}</b> <span className="small">{chosen.email} · {chosen.mobile} · {chosen.bookings ? `${chosen.bookings} past rental${chosen.bookings === 1 ? '' : 's'}` : 'no rental yet'}{chosen.card ? ` · card ${chosen.card.brand} ${chosen.card.last4}` : ''}</span>{' '}
              <button className="btn btn--quiet btn--sm" type="button" onClick={() => { setChosen(null); set('renter_id')(null); }}>Change</button></p>
          ) : !adding ? (<>
            <div className="field"><label className="label" htmlFor="oc-q">Find the renter</label>
              <input className={`input${tried && needOf('renter') ? ' is-invalid' : ''}`} id="oc-q" type="search" placeholder="Name, phone or email" value={q} onChange={(e) => setQ(e.target.value)} autoComplete="off" data-testid="oc-q" aria-describedby="oc-q-h" />
              <p className="hint" id="oc-q-h">Type 3 or more letters or digits.</p>{needMsg('renter')}</div>
            {found.length > 0 && <ul className="stack" data-testid="oc-found">{found.map((r) => (
              <li key={r.id}><button className="btn btn--quiet btn--sm" type="button" disabled={r.is_blocked} onClick={() => { setChosen(r); setF((x) => ({ ...x, renter_id: r.id, mobile: r.mobile ?? '' })); setFound([]); }}>{r.legal_name}</button>
                <span className="small"> {r.email} · {r.mobile} · {r.bookings} rental(s){r.is_blocked ? ' · blocked' : ''}</span></li>))}</ul>}
            <p><button className="btn btn--ghost btn--sm" type="button" data-testid="oc-add-customer" onClick={() => {
              setAdding(true); const t = q.trim();
              setF((s) => ({ ...s, email: t.includes('@') ? t : s.email, mobile: /^[\d\s()+-]{7,}$/.test(t) ? t : s.mobile, full_name: !t.includes('@') && !/\d/.test(t) ? t : s.full_name }));
            }}>Not on file? Add a new customer</button></p>
          </>) : (<>
            <div className="ad-fields">
              {text('full_name', 'Full legal name', { auto: 'off', need: 'full_name' })}{text('mobile', 'Mobile', { inputMode: 'tel', type: 'tel', need: 'mobile' })}
              {text('email', 'Email', { inputMode: 'email', type: 'email', hint: 'The offer link goes here', need: 'email' })}{text('date_of_birth', 'Date of birth', { type: 'date', need: 'date_of_birth', info: 'The renter\'s age decides which cars they may rent and whether a young driver fee applies.' })}
            </div>
            {dupe && <p className="alert alert--warn" role="status" data-testid="oc-dupe"><span>{dupe.legal_name} is already on file with this {f.email.includes('@') && dupe.email?.toLowerCase() === f.email.trim().toLowerCase() ? 'email' : 'phone'}.{' '}
              <button className="btn btn--quiet btn--sm" type="button" onClick={() => { setChosen(dupe); setF((x) => ({ ...x, renter_id: dupe.id, mobile: dupe.mobile ?? '' })); setAdding(false); }}>Use {dupe.legal_name}</button></span></p>}
            <p><button className="btn btn--quiet btn--sm" type="button" onClick={() => setAdding(false)}>Search instead</button></p>
          </>)}
          <div className="ad-fields">
            {text('pickup_at', 'Pickup', { type: 'datetime-local', hint: form ? `At least ${Math.round(form.min_notice_minutes / 60)} hours from now` : undefined })}
            {text('return_at', 'Return', { type: 'datetime-local', need: 'return_at', hint: days ? `${days} day${days === 1 ? '' : 's'}` : undefined })}
          </div>
        </>, { testId: 'oc-step-renter' })}

        {step(++n, 'Which car', 'Search by car code, plate or name. Each car says whether it is free for these dates.', <>
          <div className="ad-fields">
            <div className="field ad-field ad-field--wide"><label className="label" htmlFor="oc-car-q">Find the car</label>
              <input className="input" id="oc-car-q" type="search" placeholder="Car code, plate or name" value={carQ} onChange={(e) => {
                setCarQ(e.target.value); const k = e.target.value.toUpperCase().replace(/[^A-Z0-9]/g, '');
                const hit = k.length >= 4 ? form?.cars.find((c) => (c.car_code ?? '').replace(/[^A-Z0-9]/g, '') === k || (c.car_code ?? '').replace(/[^A-Z0-9]/g, '') === `CC${k}` || (c.plate ?? '').toUpperCase().replace(/[^A-Z0-9]/g, '') === k) : undefined;
                if (hit) set('vehicle_id')(hit.id);
              }} data-testid="oc-car-q" /></div>
            <div className="field ad-field ad-field--wide"><label className="label" htmlFor="oc-vehicle_id">Car</label>
              <select className={`select${tried && needOf('vehicle_id') ? ' is-invalid' : ''}`} id="oc-vehicle_id" value={f.vehicle_id} onChange={(e) => set('vehicle_id')(e.target.value)} data-testid="oc-vehicle_id">
                <option value="">Choose the car ({cars.length})</option>
                {cars.map((c) => <option key={c.id} value={c.id}>{c.free === false ? 'Not free · ' : c.free ? 'Free · ' : ''}{c.name}{c.car_code ? `, ${c.car_code}` : ''}{c.plate ? `, ${c.plate}` : ''}</option>)}
              </select>
              {car && <p className="hint" data-testid="oc-car-free">{car.free === false ? <b className="ad-late">Not free for these dates: another rental, a block or the cleaning time is in the way.</b> : car.free ? 'Free for these dates.' : ''}</p>}
              {needMsg('vehicle_id')}</div>
          </div>
          <details className="oc-disclose oc-more" open={!!carType || freeOnly || undefined} data-testid="oc-rate-card"><summary>More options: rate card and filters</summary>
            <div className="stack">
              {car && <dl className="pt-dl pt-dl--money small">
                <div><dt>Daily rate</dt><dd>{car.daily_rate_cents ? fmt(car.daily_rate_cents) : 'none'}</dd></div>
                <div><dt>Weekly rate (a day)</dt><dd>{car.weekly_rate_cents ? fmt(car.weekly_rate_cents) : 'none'}</dd></div>
                <div><dt>Deposit</dt><dd>{car.deposit_cents ? fmt(car.deposit_cents) : 'none'}</dd></div>
                {b?.rate_sheet_rental_cents != null && <div><dt>Rate sheet for these dates</dt><dd>{fmt(b.rate_sheet_rental_cents)}</dd></div>}
                {b?.rate_applied && <div><dt>Rate used</dt><dd>{b.rate_applied.replace(/_/g, ' ')}, {b.billable_days} day{b.billable_days === 1 ? '' : 's'}</dd></div>}
                {b?.km_allowance_total ? <div><dt>Kilometres</dt><dd>{b.km_allowance_total} km, then {fmt(b.overage_cents_per_km)} a km</dd></div> : null}
              </dl>}
              <div className="ad-fields">
                <div className="field ad-field"><label className="label" htmlFor="oc-car-type">Type of car</label>
                  <select className="select" id="oc-car-type" value={carType} onChange={(e) => setCarType(e.target.value)} data-testid="oc-car-type">
                    <option value="">Every type</option>
                    {bodyTypes.length > 0 && <optgroup label="Body">{bodyTypes.map((x) => <option key={`b-${x}`} value={x}>{x}</option>)}</optgroup>}
                    {classes.length > 0 && <optgroup label="Class">{classes.map((x) => <option key={`c-${x}`} value={x}>{x[0]!.toUpperCase() + x.slice(1)}</option>)}</optgroup>}</select></div>
                <div className="field ad-field oc-check"><label className="check" htmlFor="oc-free-only"><input id="oc-free-only" type="checkbox" checked={freeOnly} onChange={(e) => setFreeOnly(e.target.checked)} data-testid="oc-free-only" /> <span>Only cars free for these dates</span></label></div>
              </div>
            </div></details>
          {periods}
        </>, { testId: 'oc-step-car' })}

        {step(++n, 'Where they pick up and return', 'At our location unless you deliver or collect the car. A delivery fee is added for you.', <div className="oc-legs">{placeFields('pickup')}{placeFields('return')}</div>, { testId: 'oc-step-places' })}

        {step(++n, 'How damage is covered', 'Ask the renter: their own insurance, their credit card, or our Protection Plan.', <>
          <div className="field"><span className="label-line"><label className="label" htmlFor="oc-coverage_option">Coverage</label><Info text={lineHelp('coverage_sold')} label="About coverage" /></span>
            <select className="select" id="oc-coverage_option" value={f.coverage_option} onChange={(e) => choose({ coverage_option: e.target.value })} data-testid="oc-coverage_option" aria-describedby="oc-coverage-h">
              {COVERAGE.filter(([v]) => v !== '3' || car?.rentalcover?.allowed !== false || f.coverage_option === '3').map(([v]) => <option key={v} value={v}>{COVER_SHORT[v] ?? v}</option>)}</select>
            <p className="hint" id="oc-coverage-h">{COVER_HELP[f.coverage_option] ?? ''}</p>
            {car?.rentalcover?.allowed === false && <p className="hint" data-testid="oc-plan-not-offered">{car.rentalcover.reason ?? 'The Protection Plan is not offered for this car.'}</p>}</div>
          {f.coverage_option === '3' && feeNote('coverage_sold', 'Protection Plan')}
          {f.coverage_option === '3' && editFees && more('oc-coverage-more', 'More options: another Protection Plan price', !!f.plan_price.trim(),
            <div className="ad-fields">{text('plan_price', `Protection Plan price for the trip, ${tw} ($)`, { inputMode: 'decimal', hint: 'Empty: the price from the Protection Plan table' })}</div>)}
        </>, { testId: 'oc-step-coverage' })}

        {addonOptions.length > 0 && step(++n, 'Extras', 'Optional: add-ons the renter asked for. Their price is added for you.', <details className="oc-disclose" open={addons.length > 0 || undefined} data-testid="oc-addons"><summary>{addons.length ? `${addons.length} chosen: change` : 'Choose add-ons'}</summary>
          <AddonPicker idPrefix="oc" staff compact options={addonOptions} value={addons} onChange={changeAddons} /></details>, { testId: 'oc-step-addons' })}

        {step(++n, 'The price', 'The rate sheet price is filled in for you. Change it only if you agreed another price with the renter.', <>
          <p className="oc-pricenow" data-testid="oc-price-now">{!b ? 'The price shows once the renter, the dates and the car are in.'
            : totalCents !== null ? `Worked out from the total you typed: ${fmt(total)}.`
            : f.price_mode === 'sheet' ? <>Rate sheet price: <b className="num">{fmt(rentalLine?.amount_cents ?? b.rate_sheet_rental_cents ?? 0)}</b> for {b.billable_days} day{b.billable_days === 1 ? '' : 's'}, before tax.</>
            : <>Price you typed: <b className="num">{fmt(rentalLine?.amount_cents ?? 0)}</b> before tax (rate sheet {fmt(b.rate_sheet_rental_cents ?? 0)}).</>}</p>
          {needMsg('price')}{needMsg('price_reason')}
          {more('oc-price-more', 'More options: another price, fees, deposit, discount', priceInUse, <>
            <TaxModeToggle value={taxMode} onChange={changeTaxMode} idPrefix="oc" bps={bps}>
              <details className="oc-disclose" open={!!totalTyped.trim() || undefined} data-testid="oc-total-typed-d"><summary>Type the total the renter pays</summary>
                <div className="ad-taxtotal">
                  <div className="field"><label className="label" htmlFor="oc-total-typed">Total the renter pays (after tax, $)</label>
                    <input className="input input--sm" id="oc-total-typed" inputMode="decimal" placeholder={b ? (b.total_due_at_booking_cents / 100).toFixed(2) : ''} value={totalTyped} onChange={(e) => setTotalTyped(e.target.value)} data-testid="oc-total-typed" aria-describedby="oc-total-typed-h" /></div>
                  {totalTyped.trim() && <button className="btn btn--quiet btn--sm" type="button" onClick={() => setTotalTyped('')} data-testid="oc-total-clear">Clear the total</button>}
                </div>
                <p className="hint" id="oc-total-typed-h" data-testid="oc-total-breakdown" aria-live="polite">{totalCents === null ? 'The car rental is worked out so the total comes to exactly this; the other lines stay as they are.'
                  : !b || !fresh || b.total_due_at_booking_cents !== totalCents ? (b && fresh && (() => { const rl = b.lines.find((l) => l.stage === 'booking' && l.charge_type === 'rental_charge'); return solveRental(totalCents, b.total_due_at_booking_cents, rl ? rl.amount_cents + rl.hst_cents : 0) === null; })() ? 'The other lines already come to more than this total: lower a fee or type a higher total.' : 'Working out the car rental…')
                  : `Before tax: ${b.lines.filter((l) => l.stage === 'booking' && l.amount_cents !== 0).map((l) => `${plain(l)} ${fmt(l.amount_cents)}`).join(' + ')}; HST ${fmt(b.hst_at_booking_cents)}; total ${fmt(b.total_due_at_booking_cents)}.`}</p>
              </details>
            </TaxModeToggle>
            <div className="stack oc-sub"><p className="label-line"><span className="label">Car rental price</span><Info text={lineHelp('rental_charge')} label="About the car rental price" /></p>
              {totalCents !== null && <p className="small" data-testid="oc-rent-from-total">{solvedW !== null ? `From the total: ${fmt(solvedW)} with HST${bps !== null ? ` (${fmt(beforeTax(solvedW, bps))} before tax)` : ''}.` : 'Worked out from the total.'}</p>}
              {totalCents === null && <div className="ad-taxmode__opts oc-seg" role="radiogroup" aria-label="Car rental price">
                {([['sheet', 'Rate sheet'], ['total', 'A total for the trip'], ['day', 'A rate a day']] as const).map(([v, x]) => (
                  <label key={v} className="ad-taxmode__opt" htmlFor={`oc-pm-${v}`}><input type="radio" id={`oc-pm-${v}`} name="oc-pm" value={v} checked={f.price_mode === v} onChange={() => set('price_mode')(v)} data-testid={`oc-pm-${v}`} /> <span>{x}</span></label>))}
              </div>}
              {(f.price_mode !== 'sheet' || totalCents !== null) && <div className="ad-fields">
                {f.price_mode === 'total' && totalCents === null && text('price_total', `For the whole trip, ${tw} ($)`, { inputMode: 'decimal', need: 'price', hint: b?.rate_sheet_rental_cents ? `Rate sheet: ${fmt(b.rate_sheet_rental_cents)}` : car?.daily_rate_cents ? `Rate sheet: ${fmt(car.daily_rate_cents)} a day` : undefined })}
                {f.price_mode === 'day' && totalCents === null && text('price_day', `A day, ${tw} ($)`, { inputMode: 'decimal', need: 'price', hint: days ? `× ${days} day${days === 1 ? '' : 's'} = ${fmt(typedRental(f, days) ?? 0)}` : undefined })}
                {text('price_reason', 'Why this price', { wide: true, need: 'price_reason', placeholder: 'For example: weekly deal agreed on the phone' })}
              </div>}</div>
            <div className="ad-fields">
              {select('km', 'Kilometres a day', [['', 'The car\'s allowance'], ...(form?.km_choices ?? []).map((k) => [String(k), k === 0 ? 'Unlimited' : `${k} km`] as [string, string])], undefined, lineHelp('km'))}
              {text('promo_code', 'Promo code')}
              {admin && <>{text('deposit', 'Deposit ($)', { inputMode: 'decimal', info: lineHelp('deposit'), hint: car?.deposit_cents ? `Empty: the car's ${fmt(car.deposit_cents)}` : 'Empty: the car\'s deposit' })}
                {text('discount', 'Discount ($)', { inputMode: 'decimal', info: 'Taken off the car rental before tax. Recorded with your name and the reason.' })}{cents0(f.discount) && text('discount_reason', 'Why the discount', { wide: true })}</>}
            </div>
            {(feeLines.length > 0 || (editFees && customs.length > 0)) && <div className="stack oc-sub"><p className="label">Fees</p>
              <ul className="oc-charges" data-testid="oc-charges">
                {feeLines.map((l) => { const k = keyOf(l); const hand = isHand(l); const open = hand || editing.includes(k); return (
                  <li key={l.id} className={`oc-charge${editFees && open ? ' is-editing' : ''}`} data-testid={`oc-charge-${k}`}>
                    <span className="oc-charge__label">{plain(l)}<Info text={lineHelp(l.charge_type)} /></span>
                    <span className="oc-charge__amt num">{fmt(shownCents(l))}</span>
                    <span className="oc-charge__state">{hand ? <span className="ad-b ad-b--amber">Set by hand</span> : <span className="ad-b ad-b--light">Automatic</span>}</span>
                    {editFees && <span className="oc-charge__do">{open ? <>
                      <label className="vh" htmlFor={`oc-fee-${k}`}>{plain(l)}: amount for the trip, {taxMode === 'after' && (l.hst_applies ?? l.hst_cents !== 0) ? 'HST included' : 'before tax'} ($)</label>
                      <input className="input input--sm" id={`oc-fee-${k}`} inputMode="decimal" placeholder={(l.amount_cents / 100).toFixed(2)} value={f.fees[k] ?? ''} data-testid={`oc-fee-${k}`}
                        onChange={(e) => setF((s) => ({ ...s, fees: { ...s.fees, [k]: e.target.value } }))} />
                      <button className="btn btn--quiet btn--sm" type="button" onClick={() => reset(k)} data-testid={`oc-reset-${k}`}>{hand ? 'Reset to automatic' : 'Cancel'}</button></>
                      : <button className="btn btn--quiet btn--sm" type="button" onClick={() => setEditing((e) => [...e, k])} data-testid={`oc-change-${k}`}>Change</button>}</span>}
                  </li>); })}
                {editFees && customs.map((c, i) => (
                  <li key={`c${i}`} className="oc-charge oc-charge--own" data-testid={`oc-custom-${i}`}>
                    <span className="oc-charge__label"><input className="input input--sm" aria-label="What the charge is for" placeholder="What it is for" value={c.label} onChange={(e) => setCustoms((a) => a.map((y, j) => (j === i ? { ...y, label: e.target.value } : y)))} /><Info text={lineHelp('custom_fee')} /></span>
                    <span className="oc-charge__do"><input className="input input--sm" inputMode="decimal" aria-label={`Amount ${c.hst && taxMode === 'after' ? 'with HST' : 'before HST'} ($)`} placeholder="Amount ($)" value={c.amount} onChange={(e) => setCustoms((a) => a.map((y, j) => (j === i ? { ...y, amount: e.target.value } : y)))} />
                      <label className="check small"><input type="checkbox" checked={c.hst} onChange={(e) => setCustoms((a) => a.map((y, j) => (j === i ? { ...y, hst: e.target.checked } : y)))} /> <span>+ HST</span></label>
                      <button className="btn btn--quiet btn--sm" type="button" onClick={() => setCustoms((a) => a.filter((_, j) => j !== i))}>Remove</button></span>
                  </li>))}
              </ul></div>}
            {editFees && <p><button className="btn btn--quiet btn--sm" type="button" onClick={() => setCustoms((a) => [...a, { label: '', amount: '', hst: true }])} data-testid="oc-add-custom">+ Add another charge</button></p>}
            {(handKeys.size > 0 || customs.length > 0) && <div className="ad-fields">{text('fee_reason', 'Why the fees changed (optional)', { wide: true })}</div>}
            {!admin && <p className="hint">{editFees ? 'The deposit and discounts are set by an Admin. You may type another price with its reason and change a fee (recorded with your name). A price far under the rate sheet is flagged for an Admin, not refused.' : 'The deposit, discounts and fees are set by an Admin. You may type another price with its reason; a price far under the rate sheet is flagged for an Admin, not refused.'}</p>}
          </>)}
          <p className="small" data-testid="oc-pay-now">Paid by: {payWords}.</p>
          {more('oc-pay-more', 'More options: how it is paid', payInUse, <>
            <div className="ad-fields">
              {select('rental_pay', 'The rental', RENTAL_PAY.map(([v, x]) => [v, x]))}
              {select('deposit_pay', 'The deposit', DEPOSIT_PAY.filter(([v]) => admin || v !== 'none').map(([v, x]) => [v, x]))}
            </div>
            <p className="hint" data-testid="oc-pay-hint">{RENTAL_PAY.find(([v]) => v === f.rental_pay)?.[2]} {DEPOSIT_PAY.find(([v]) => v === f.deposit_pay)?.[2]}</p></>)}
        </>, { testId: 'oc-step-price' })}

        {step(++n, 'Send it', 'Add a short message if you like, choose how the link goes, then send.', <>
          {!admin && <div>{needMsg('choice')}<SourcedChoice id="oc" value={f.choice} onChange={(v) => set('choice')(v)} optional={admin} /></div>}
          <div className="field"><label className="label" htmlFor="oc-message">Message to the renter (optional)</label>
            <textarea className="input ad-textarea" id="oc-message" maxLength={1000} value={f.message} onChange={(e) => set('message')(e.target.value)} data-testid="oc-message" /></div>
          <div className="field"><span className="label">Send the link by</span>
            <div className="oc-chips">
              <label className="oc-chip" htmlFor="oc-by-text"><input id="oc-by-text" type="checkbox" checked={f.by_text} disabled={form ? !form.text_enabled : false} onChange={(e) => set('by_text')(e.target.checked)} data-testid="oc-by-text" /> <span>Text{form && !form.text_enabled ? ' (off in Program settings)' : ''}</span></label>
              <label className="oc-chip" htmlFor="oc-by-email"><input id="oc-by-email" type="checkbox" checked={f.by_email} onChange={(e) => set('by_email')(e.target.checked)} data-testid="oc-by-email" /> <span>Email</span></label></div>
            {f.by_text && !hasMobile(f.mobile) && <p className="small ad-flag" role="note" data-testid="oc-no-mobile">No mobile number for this renter: the link goes by email instead.</p>}</div>
          {more('oc-send-more', 'More options: how long it is open, owner, internal note', !!f.note.trim() || (admin && !!f.choice) || f.hours !== String(form ? (admin ? form.offer_hours : Math.min(form.offer_hours, 48)) : 24), <>
            <div className="ad-fields">{select('hours', 'Offer open for', [...new Set([6, 12, 24, 48, 72, form?.offer_hours ?? 24])].filter((h) => admin || h <= 48).sort((a, z) => a - z).map((h) => [String(h), `${h} hours`]))}</div>
            {admin && <SourcedChoice id="oc" value={f.choice} onChange={(v) => set('choice')(v)} optional={admin} />}
            {owner?.may && <OwnerChoice d={owner} value={ownerChoice} onChange={setOwnerChoice} testPrefix="oc" />}
            <div className="field"><label className="label" htmlFor="oc-note">Internal note (staff only)</label>
              <textarea className="input ad-textarea" id="oc-note" value={f.note} onChange={(e) => set('note')(e.target.value)} /></div></>)}
          <div className="field" data-testid="oc-book-now-field"><label className="check" htmlFor="oc-book-now"><input id="oc-book-now" type="checkbox" checked={bookNow} onChange={(e) => setBookNow(e.target.checked)} data-testid="oc-book-now" /> <span>Book it now (no renter approval)</span></label>
            <p className="hint">{admin ? 'The offer becomes the booking at once: the car is held, and the renter gets one link to sign and pay (or signs and pays on this device).' : 'An Admin approves it in one tap; then the booking waits for payment and the renter gets the link to sign and pay.'}</p></div>
          <p className={`oc-ready${missingList.length ? ' is-missing' : ' is-ready'}`} role="status" aria-live="polite" data-testid="oc-ready">{missingList.length ? <>Missing: {missingList.map((m) => m.short).join(', ')}</> : <>Ready to send</>}</p>
          {err && <p className="alert alert--error" role="alert" data-testid="oc-error"><span>{err}</span></p>}
          {pickupPassed(f.pickup_at) && <p className="alert alert--error" role="alert" data-testid="oc-pickup-passed"><span>{PICKUP_PASSED}</span></p>}
          <div className="oc-actions">
            <button className="btn btn--primary" type="submit" disabled={pending || pickupPassed(f.pickup_at)} data-testid="oc-send">{pending ? 'Sending' : f.by_email || f.by_text ? `Send the offer${who ? ` to ${who}` : ''}` : 'Make the offer (not sent)'}</button>
            <button className="btn btn--quiet" type="button" disabled={pending} onClick={() => send(true)} data-testid="oc-draft">Save without sending</button>
          </div>
          <section className="oc-renter-below" data-testid="oc-renter-view-d"><p className="pt-kicker">The offer as the renter sees it</p>
            <div className="ad-renter-view" aria-label="The offer as the renter sees it" data-testid="oc-renter-view">
              <h3 className="d4">Your offer for the {b?.vehicle?.name ?? car?.name ?? 'car'}</h3>
              <p className="pt-note small"><b>This offer does not hold the car until you approve it.</b> Once you approve, the car is booked for you; sign the agreement and {f.rental_pay === 'card' ? 'pay' : 'send your payment'} before pickup.</p>
              {f.message.trim() && <div><b className="small">Message from our team</b><p className="small">{f.message}</p></div>}
              {b && <><dl className="pt-dl small">
                <div><dt>Pickup</dt><dd>{when(b.pickup_at)}, {b.pickup_place ?? 'our location'}</dd></div>
                <div><dt>Return</dt><dd>{when(b.return_at)}, {b.return_place ?? 'our location'}</dd></div>
                <div><dt>Deposit at pickup</dt><dd>{money(b.deposit_cents)}</dd></div>
                {b.km_allowance_total ? <div><dt>Kilometres</dt><dd>{b.km_allowance_total} km included, then {fmt(b.overage_cents_per_km)} per km</dd></div> : null}
                <div><dt>You pay by</dt><dd>{RENTAL_PAY.find(([v]) => v === f.rental_pay)?.[1]}</dd></div>
              </dl>
              <dl className="pt-dl pt-dl--money small">
                {renterLines.map((l) => <div key={l.id}><dt>{lineLabel(l)}</dt><dd>{fmt(l.amount_cents)}</dd></div>)}
                <div><dt>HST</dt><dd>{fmt(b.hst_at_booking_cents)}</dd></div>
                <div><dt><b>Total due at booking</b></dt><dd><b>{fmt(total)}</b></dd></div>
              </dl></>}
              <p className="small muted" suppressHydrationWarning>Open for {f.hours} hours after it is sent</p>
            </div></section>
        </>, { testId: 'oc-step-send' })}
      </form>

      <aside className={`pt-card ad-card oc-summary${sheet ? ' is-open' : ''}`} aria-label="Price" data-testid="oc-price">
        <div className="oc-summary__body" id="oc-summary-body">
          <div className="pt-card__head"><h2 className="d4">The price</h2>{b && <span className="small muted">{b.billable_days} day{b.billable_days === 1 ? '' : 's'}</span>}</div>
          {b ? (<dl className="pt-dl pt-dl--money oc-lines">
            {bookingLines.map((l) => { const hand = isHand(l) && !RENTAL_LINE.has(l.charge_type); return (
              <div key={l.id} data-testid={`oc-line-${keyOf(l)}`}><dt>{plain(l)}{hand && <> <span className="ad-b ad-b--amber">Set by hand</span> <button className="btn btn--quiet btn--sm" type="button" onClick={() => reset(PLAN_TYPES.includes(l.charge_type) ? 'coverage_sold' : keyOf(l))} aria-label={`${plain(l)}: reset to automatic`}>Reset</button></>}</dt><dd>{fmt(shownCents(l))}</dd></div>); })}
            <div><dt>HST</dt><dd>{fmt(hstShown)}</dd></div>
            <div><dt><span className="oc-dt">Deposit<Info text={lineHelp('deposit')} label="About the deposit" /></span></dt><dd data-testid="oc-sum-deposit">{f.deposit_pay === 'none' ? 'No deposit' : `${fmt(b.deposit_cents)} (${DEPOSIT_PAY.find(([v]) => v === f.deposit_pay)?.[1].toLowerCase()})`}</dd></div>
          </dl>) : <p className="small muted" data-testid="oc-price-wait">{need.length ? `To work out the price: ${missingList.filter((m) => m.field !== 'choice').map((m) => m.short).join(', ') || need.join(', ')}.` : 'Working out the price…'}</p>}
          {b && <p className="small">{priced?.available ? 'The car is free for these dates.' : <b className="ad-late">The car is not free for these dates.</b>}</p>}
          {b?.price_flags?.length ? <p className="small"><b>Flagged for an Admin:</b> {b.price_flags.map((x) => (x === 'below_floor' ? 'under the price floor' : 'past the discount limit')).join(', ')}.</p> : null}
          {difference && <p className="alert alert--warn" role="alert" data-testid="oc-total-diff"><span>{difference} Check the amounts before you send.</span></p>}
        </div>
        {problem && <p className="alert alert--error" role="alert" data-testid="oc-problem"><span>{problem}</span></p>}
        <div className="oc-summary__foot">
          <span className="oc-summary__due"><span className="small muted">Total to pay now</span>
            <span className="oc-total-row">{b ? <b className="pt-total" data-testid="oc-total" data-fresh={fresh ? 'yes' : 'no'}>{fmt(total)}</b> : <b className="pt-total muted">not priced yet</b>}{b && !fresh && <span className="oc-spin" role="status" aria-label="Checking the price" data-testid="oc-updating" />}</span></span>
          <button className="btn btn--ghost btn--sm oc-summary__toggle" type="button" aria-expanded={sheet} aria-controls="oc-summary-body" onClick={() => setSheet((x) => !x)} data-testid="oc-sheet-toggle">{sheet ? 'Hide the details' : 'See every line'}</button>
        </div>
      </aside>
    </div>
  );
}
// the coverage in a few words, the detail under it
const COVER_SHORT: Record<string, string> = { '1': 'Their own car insurance', '2': 'Their credit card', '3': 'Our Protection Plan' };
const COVER_HELP: Record<string, string> = { '1': 'Option 1: the renter\'s own car insurance covers the rental (OPCF 27 on their policy).', '2': 'Option 2: the rental coverage of the credit card they pay with.', '3': 'Option 3: they buy our Protection Plan; its price is added to the offer.' };
const cents0 = (s: string) => Number(String(s).replace(/[$,\s]/g, '')) > 0;
