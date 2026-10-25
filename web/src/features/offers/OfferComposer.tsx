'use client';
import { useEffect, useMemo, useRef, useState, useTransition } from 'react';
import Link from 'next/link';
import { useRouter } from 'next/navigation';
import { money } from '@/lib/format';
import { when } from '@/features/agreement/model';
import { offersDo, offersRead } from '@/server/actions/offers';
import { deliveryDistance, draftClose, draftSave, supplyRead } from '@/server/actions/supply';
import { SourcedChoice } from '@/features/sales/SourcedChoice';
import { PRICE_TAX_OPTIONS } from '@/features/sales/priceTax';
import { AddonPicker } from '@/features/addons/AddonPicker';
import { Info } from '@/features/forms/Info';
import { AddressInput } from '@/features/forms/AddressInput';
import { lineHelp } from './help';
import { addonsPayload, type AddonChoice, type AddonOption } from '@/features/addons/model';
import { COVERAGE, DEPOSIT_PAY, PLACES, RENTAL_LINE, RENTAL_PAY, daysBetween, lineKey, missing, offerPayload, periodShares, typedRental, type OfferForm, type PlaceKind, type Role } from './model';

// Send an offer without a request (migration 0129): one screen for an Admin, customer service and sales. The customer
// found by name, phone or email (or added; one person, one record), the car with whether it is free, the dates, the
// places, the price (the rate sheet, a total or a rate per day), fees, the deposit, the Protection Plan, how the rental
// and the deposit are paid, who found the client, the message and how long the offer is open. The right side is the
// offer as the renter will see it, priced by the database (and rolled back) as you type. Send makes the same records a
// website request and its offer make; the renter gets the link by email, by text, both or neither.
type Car = { id: string; name: string; plate: string | null; car_code: string | null; daily_rate_cents: number | null; weekly_rate_cents: number | null; deposit_cents: number | null; free: boolean | null; class?: string | null; body_type?: string | null };
type Form = { role: Role; offer_hours: number; min_notice_minutes: number; km_choices: number[]; text_enabled: boolean; cars: Car[]; may_edit_fees?: boolean; period_days?: number; cycle?: string };
type Found = { id: string; legal_name: string; email: string | null; mobile: string | null; date_of_birth: string | null; is_blocked: boolean; bookings: number; card: { brand: string; last4: string } | null };
type Line = { id: string; charge_type: string; description: string | null; amount_cents: number; hst_cents: number; stage: string; charged_to_renter: boolean; booking_addon_id?: string | null; addon_code?: string | null };
type Priced = { booking_number: string; billable_days: number; rate_applied: string | null; rental_charge_cents: number; deposit_cents: number; hst_at_booking_cents: number;
  total_due_at_booking_cents: number; renter_due_at_booking_cents: number | null; km_allowance_total: number | null; overage_cents_per_km: number; pickup_place: string | null; return_place: string | null;
  rate_sheet_rental_cents: number | null; price_flags: string[]; lines: Line[]; vehicle: { name: string } | null; pickup_at: string; return_at: string };
type Sent = { booking_number: string; version: number; total_cents: number; due_cents: number; expires_at: string; renter_existing: boolean; notified: boolean; text?: { ok: boolean; to?: string; reason?: string } | null; price_flags?: string[] };

const pad = (n: number) => String(n).padStart(2, '0');
const local = (d: Date) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
const fmt = (c: number | null | undefined) => money(Number(c ?? 0), { cents: true });
const lineLabel = (l: Line) => l.description || l.charge_type.replace(/_/g, ' ');
const PLAN_TYPES = ['coverage_sold', 'coverage', 'coverage_option', 'carmacars_coverage', 'coverage_daily'];

/** What an offer draft keeps (0148). */
export interface OcDraft { f?: Partial<OfferForm>; addons?: AddonChoice[]; customs?: Array<{ label: string; amount: string; hst: boolean }>; chosen?: Found | null; renter_id?: string | null }

export function OfferComposer({ base, initialCar = null, draft = null }: { base: '/admin' | '/va'; initialCar?: string | null; draft?: { id: string; data: OcDraft } | null }) {
  const start = useMemo(() => { const d = new Date(Date.now() + 86_400_000); d.setMinutes(0, 0, 0); d.setHours(10); return d; }, []);
  const [form, setForm] = useState<Form | null>(null);
  const [f, setF] = useState<OfferForm>(() => ({
    renter_id: null, full_name: '', email: '', mobile: '', date_of_birth: '',
    vehicle_id: initialCar ?? '', pickup_at: local(start), return_at: local(new Date(start.getTime() + 3 * 86_400_000)),
    pickup_kind: 'our_location', pickup_address: '', pickup_km: '', return_kind: 'our_location', return_address: '', return_km: '',
    price_mode: 'sheet', price_total: '', price_day: '', price_tax: 'plus', price_reason: '',
    deposit: '', discount: '', discount_reason: '', promo_code: '', km: '', coverage_option: '1', plan_price: '', fees: {}, fee_reason: '',
    rental_pay: 'card', deposit_pay: 'card', choice: '', message: '', note: '', hours: '24', by_email: true, by_text: false, notify: true,
    ...(draft?.data.f ?? {})
  }));
  const set = <K extends keyof OfferForm>(k: K) => (v: OfferForm[K]) => setF((s) => ({ ...s, [k]: v }));
  const [q, setQ] = useState('');
  const [found, setFound] = useState<Found[]>([]);
  const [chosen, setChosen] = useState<Found | null>(draft?.data.chosen ?? null);
  const [adding, setAdding] = useState(false);
  const [carQ, setCarQ] = useState('');
  // 0148 (sim item 9): narrow the cars to a type and to the ones free for the dates
  const [carType, setCarType] = useState('');
  const [freeOnly, setFreeOnly] = useState(false);
  const [addons, setAddons] = useState<AddonChoice[]>(draft?.data.addons ?? []);
  const [addonOptions, setAddonOptions] = useState<AddonOption[]>([]);
  const [priced, setPriced] = useState<{ booking: Priced; available: boolean } | null>(null);
  const [problem, setProblem] = useState<string | null>(null);
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

  const need = missing(f, role).filter((m) => m !== 'who found this client');
  // 0132: charges of its own on the offer (the renter sees what is typed)
  const [customs, setCustoms] = useState<Array<{ label: string; amount: string; hst: boolean }>>(draft?.data.customs ?? []);
  // 0148: saved as a draft as you type; opened again from Unfinished rentals on any device
  const [draftId, setDraftId] = useState<string | null>(draft?.id ?? null);
  const [savedAt, setSavedAt] = useState<string | null>(null);
  const snapKey = JSON.stringify({ f, addons, customs, chosen });
  const firstSnap = useRef(snapKey);
  const saveDraft = async () => {
    const data: OcDraft = { f, addons, customs, chosen, renter_id: f.renter_id };
    const r = await draftSave({ id: draftId, kind: 'offer', data: data as Record<string, unknown>, title: [chosen?.legal_name ?? f.full_name, form?.cars.find((c) => c.id === f.vehicle_id)?.name].filter(Boolean).join(', ') });
    if (r.ok) { setDraftId(r.data.id); setSavedAt(r.data.updated_at); }
  };
  useEffect(() => {
    if (sent || snapKey === firstSnap.current) return;
    if (!f.renter_id && !f.full_name.trim() && !f.email.trim()) return;
    const t = setTimeout(() => { void saveDraft(); }, 1500);
    return () => clearTimeout(t);
  }, [snapKey]); // eslint-disable-line react-hooks/exhaustive-deps
  const payload = useMemo(() => {
    const p = offerPayload(f, role, days, addonsPayload(addons), editFees);
    const c = customs.filter((x) => x.label.trim() && Number(x.amount) > 0).map((x) => ({ label: x.label.trim(), amount_cents: Math.round(Number(x.amount) * 100), hst: x.hst }));
    return editFees && c.length ? { ...p, custom_fees: c, fee_reason: p.fee_reason ?? (f.fee_reason.trim() || 'Agreed with the renter') } : p;
  }, [f, role, days, addons, editFees, customs]);
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
      setProblem(null); setPriced({ booking: r.data.booking, available: r.data.available });
    }, 450);
    return () => clearTimeout(t);
  }, [payload, form, need.length]);

  const send = (draft = false) => run(async () => {
    setErr(null);
    const m = missing(f, role);
    if (m.length) { setErr(`Still needed: ${m.join(', ')}.`); return; }
    const r = await offersDo<Sent & { booking_id: string }>('offer_create', draft ? { ...payload, draft: true } : payload, [`${base}/bookings`]);
    if (!r.ok) { setErr(r.message); return; }
    if (draftId) void draftClose(draftId, 'done');
    if (draft) { router.push(`${base}/bookings/${encodeURIComponent(r.data.booking_number)}?tab=review`); return; }
    setSent(r.data);
  });

  if (sent) return (
    <section className="pt-card stack" aria-labelledby="oc-sent" data-testid="offer-sent">
      <h2 className="d3" id="oc-sent">Offer {sent.booking_number} sent</h2>
      <p>{sent.notified ? `The renter has the link${f.by_email ? ' by email' : ''}${f.by_email && f.by_text ? ' and' : ''}${f.by_text ? ' by text' : ''}.` : 'Not sent to the renter: tell them yourself, or press Send again later from the booking.'}
        {' '}Total {fmt(sent.total_cents)}, open until {when(sent.expires_at)}. The car is reserved once they approve, sign{f.rental_pay === 'card' ? ' and pay' : ' and you record the payment'}.</p>
      {sent.text && !sent.text.ok && <p className="alert alert--warn" role="status"><span>The text was not sent: {sent.text.reason}</span></p>}
      {sent.price_flags?.length ? <p className="small">The price you typed is flagged for an Admin to review.</p> : null}
      <p className="row"><Link prefetch={false} className="btn btn--primary" href={`${base}/bookings/${encodeURIComponent(sent.booking_number)}`} data-testid="offer-open">Open the booking</Link>
        <button className="btn btn--ghost" type="button" onClick={() => { setSent(null); setChosen(null); setQ(''); setF((s) => ({ ...s, renter_id: null, full_name: '', email: '', mobile: '', date_of_birth: '', message: '', note: '', price_mode: 'sheet', price_total: '', price_day: '', price_reason: '' })); }}>Send another</button></p>
    </section>
  );

  const b = priced?.booking;
  const renterLines = (b?.lines ?? []).filter((l) => l.stage === 'booking' && l.charged_to_renter !== false && (l.amount_cents !== 0 || l.charge_type === 'rental_charge'));
  // every fee line of the offer (0132): young driver, delivery, add-ons, winter tires; the Protection Plan has its own box
  const feeLines = (b?.lines ?? []).filter((l) => l.stage === 'booking' && !RENTAL_LINE.has(l.charge_type) && !PLAN_TYPES.includes(l.charge_type));
  const keyOf = (l: Line) => (l.booking_addon_id && l.addon_code ? `addon:${l.addon_code}` : lineKey({ charge_type: l.charge_type }));
  const total = b ? (b.renter_due_at_booking_cents ?? b.total_due_at_booking_cents) : 0;
  const cars = (form?.cars ?? []).filter((c) => { const k = carQ.trim().toLowerCase(); return (!k || `${c.name} ${c.plate ?? ''} ${c.car_code ?? ''}`.toLowerCase().includes(k))
    && (!carType || c.body_type === carType || c.class === carType) && (!freeOnly || c.free !== false || c.id === f.vehicle_id); });
  const bodyTypes = [...new Set((form?.cars ?? []).map((c) => c.body_type).filter((x): x is string => !!x))].sort();
  const classes = [...new Set((form?.cars ?? []).map((c) => c.class).filter((x): x is string => !!x))].sort();
  const car = form?.cars.find((c) => c.id === f.vehicle_id);
  const id = (k: string) => `oc-${k}`;
  const text = (k: keyof OfferForm, l: string, o: { type?: string; hint?: string; inputMode?: 'decimal' | 'numeric' | 'tel' | 'email'; wide?: boolean; placeholder?: string; auto?: string } = {}) => (
    <div className={`field ad-field${o.wide ? ' ad-field--wide' : ''}`}><label className="label" htmlFor={id(k)}>{l}</label>
      <input className="input" id={id(k)} type={o.type ?? 'text'} inputMode={o.inputMode} placeholder={o.placeholder} autoComplete={o.auto ?? 'off'} value={String(f[k] ?? '')}
        onChange={(e) => set(k)(e.target.value as never)} data-testid={`oc-${k}`} aria-describedby={o.hint ? `${id(k)}-h` : undefined} />
      {o.hint && <p className="hint" id={`${id(k)}-h`}>{o.hint}</p>}</div>);
  const select = (k: keyof OfferForm, l: string, options: Array<[string, string]>) => (
    <div className="field ad-field"><label className="label" htmlFor={id(k)}>{l}</label>
      <select className="select" id={id(k)} value={String(f[k])} onChange={(e) => set(k)(e.target.value as never)} data-testid={`oc-${k}`}>{options.map(([v, x]) => <option key={v} value={v}>{x}</option>)}</select></div>);
  const placeFields = (leg: 'pickup' | 'return') => (<>
    {select(`${leg}_kind`, leg === 'pickup' ? 'Pickup' : 'Return', PLACES.map(([v, x]) => [v, leg === 'return' && v === 'delivery' ? 'We collect' : leg === 'pickup' && v === 'delivery' ? 'We deliver' : x]))}
    {(f[`${leg}_kind`] as PlaceKind) === 'delivery' && <><div className="field ad-field"><label className="label" htmlFor={id(`${leg}_address`)}>{leg === 'pickup' ? 'Delivery address' : 'Collection address'}</label>
      <AddressInput id={id(`${leg}_address`)} name={`${leg}_address`} value={{ label: String(f[`${leg}_address`] ?? ''), placeId: '' }} onChange={(x) => {
        set(`${leg}_address`)(x.label as never);
        // a suggestion chosen: the distance is measured, and prices the delivery (sim item 12); typed by hand stays as typed
        if (x.placeId) void deliveryDistance(x.placeId, x.session).then((r) => { if (r.ok && r.data.km !== null) set(`${leg}_km`)(String(r.data.km) as never); });
      }} testId={`oc-${leg}_address`} /></div>{text(`${leg}_km`, 'Distance (km)', { inputMode: 'decimal', hint: 'Measured from our location when you pick the address from the list; prices the delivery fee' })}</>}
    {(f[`${leg}_kind`] as PlaceKind) === 'airport' && text(`${leg}_address`, 'Airport code', { placeholder: 'YYZ' })}
  </>);

  return (
    <div className="ad-review" data-testid="offer-composer">
      <form className="pt-card ad-card ad-form ad-form--narrow" aria-label="The offer" noValidate onSubmit={(e) => { e.preventDefault(); send(); }}>
        <p className="small muted" role="status" aria-live="polite" data-testid="oc-draft-status">{savedAt ? `Saved as a draft at ${new Date(savedAt).toLocaleTimeString('en-CA', { hour: 'numeric', minute: '2-digit' })}: finish it later from Unfinished rentals.` : 'Saved as a draft as you type.'}
          {draftId && <> <button className="btn btn--quiet btn--sm" type="button" onClick={() => run(async () => { await draftClose(draftId, 'discarded'); router.push(`${base}/offers/new`); })} data-testid="oc-discard-draft">Discard the draft</button></>}</p>
        <fieldset className="stack"><legend className="d4">1. The customer</legend>
          {chosen ? (
            <p data-testid="oc-customer"><b>{chosen.legal_name}</b> <span className="small">{chosen.email} · {chosen.mobile} · {chosen.bookings ? `${chosen.bookings} past rental${chosen.bookings === 1 ? '' : 's'}` : 'no rental yet'}{chosen.card ? ` · card ${chosen.card.brand} ${chosen.card.last4}` : ''}</span>{' '}
              <button className="btn btn--quiet btn--sm" type="button" onClick={() => { setChosen(null); set('renter_id')(null); }}>Change</button></p>
          ) : !adding ? (<>
            <div className="field"><label className="label" htmlFor="oc-q">Find the customer</label>
              <input className="input" id="oc-q" type="search" placeholder="Name, phone or email" value={q} onChange={(e) => setQ(e.target.value)} autoComplete="off" data-testid="oc-q" aria-describedby="oc-q-h" />
              <p className="hint" id="oc-q-h">Type 3 or more characters. Not on file? Add them below.</p></div>
            {found.length > 0 && <ul className="stack" data-testid="oc-found">{found.map((r) => (
              <li key={r.id}><button className="btn btn--quiet btn--sm" type="button" disabled={r.is_blocked} onClick={() => { setChosen(r); set('renter_id')(r.id); setFound([]); }}>{r.legal_name}</button>
                <span className="small"> {r.email} · {r.mobile} · {r.bookings} rental(s){r.is_blocked ? ' · blocked' : ''}</span></li>))}</ul>}
            <p><button className="btn btn--ghost btn--sm" type="button" data-testid="oc-add-customer" onClick={() => {
              setAdding(true); const t = q.trim();
              setF((s) => ({ ...s, email: t.includes('@') ? t : s.email, mobile: /^[\d\s()+-]{7,}$/.test(t) ? t : s.mobile, full_name: !t.includes('@') && !/\d/.test(t) ? t : s.full_name }));
            }}>Add a new customer</button></p>
          </>) : (<>
            <div className="ad-fields">
              {text('full_name', 'Full legal name', { auto: 'off' })}{text('mobile', 'Mobile', { inputMode: 'tel', type: 'tel' })}
              {text('email', 'Email', { inputMode: 'email', type: 'email', hint: 'The offer link goes here' })}{text('date_of_birth', 'Date of birth', { type: 'date', hint: 'Decides the car and the young driver fee' })}
            </div>
            {dupe && <p className="alert alert--warn" role="status" data-testid="oc-dupe"><span>{dupe.legal_name} is already on file with this {f.email.includes('@') && dupe.email?.toLowerCase() === f.email.trim().toLowerCase() ? 'email' : 'phone'}.{' '}
              <button className="btn btn--quiet btn--sm" type="button" onClick={() => { setChosen(dupe); set('renter_id')(dupe.id); setAdding(false); }}>Use {dupe.legal_name}</button></span></p>}
            <p><button className="btn btn--quiet btn--sm" type="button" onClick={() => setAdding(false)}>Search instead</button></p>
          </>)}
        </fieldset>

        <fieldset className="stack"><legend className="d4">2. The car and the dates</legend>
          <div className="ad-fields">
            {text('pickup_at', 'Pickup', { type: 'datetime-local', hint: form ? `At least ${Math.round(form.min_notice_minutes / 60)} hours from now` : undefined })}
            {text('return_at', 'Return', { type: 'datetime-local' })}
            <div className="field ad-field ad-field--wide"><label className="label" htmlFor="oc-vehicle_id">Car</label>
              <input className="input" type="search" placeholder="Car code, plate or name" aria-label="Find the car" value={carQ} onChange={(e) => {
                setCarQ(e.target.value); const k = e.target.value.toUpperCase().replace(/[^A-Z0-9]/g, '');
                const hit = k.length >= 4 ? form?.cars.find((c) => (c.car_code ?? '').replace(/[^A-Z0-9]/g, '') === k || (c.car_code ?? '').replace(/[^A-Z0-9]/g, '') === `CC${k}` || (c.plate ?? '').toUpperCase().replace(/[^A-Z0-9]/g, '') === k) : undefined;
                if (hit) set('vehicle_id')(hit.id);
              }} data-testid="oc-car-q" />
              <div className="row">
                <label className="sr-only" htmlFor="oc-car-type">Type of car</label>
                <select className="select" id="oc-car-type" value={carType} onChange={(e) => setCarType(e.target.value)} data-testid="oc-car-type">
                  <option value="">Every type</option>
                  {bodyTypes.length > 0 && <optgroup label="Body">{bodyTypes.map((x) => <option key={`b-${x}`} value={x}>{x}</option>)}</optgroup>}
                  {classes.length > 0 && <optgroup label="Class">{classes.map((x) => <option key={`c-${x}`} value={x}>{x[0]!.toUpperCase() + x.slice(1)}</option>)}</optgroup>}</select>
                <label className="check" htmlFor="oc-free-only"><input id="oc-free-only" type="checkbox" checked={freeOnly} onChange={(e) => setFreeOnly(e.target.checked)} data-testid="oc-free-only" /> <span>Free for these dates only</span></label></div>
              <select className="select" id="oc-vehicle_id" value={f.vehicle_id} onChange={(e) => set('vehicle_id')(e.target.value)} data-testid="oc-vehicle_id">
                <option value="">Choose the car ({cars.length})</option>
                {cars.map((c) => <option key={c.id} value={c.id}>{c.free === false ? 'Not free · ' : c.free ? 'Free · ' : ''}{c.name}{c.car_code ? `, ${c.car_code}` : ''}{c.plate ? `, ${c.plate}` : ''}{c.daily_rate_cents ? ` · ${fmt(c.daily_rate_cents)} a day` : ' · no rates'}</option>)}
              </select>
              {car && <p className="hint" data-testid="oc-car-free">{car.free === false ? <b className="ad-late">Not free for these dates: another rental, a block or the cleaning time is in the way.</b> : car.free ? 'Free for these dates.' : ''}</p>}</div>
            {placeFields('pickup')}{placeFields('return')}
          </div>
        </fieldset>

        <fieldset className="stack"><legend className="d4">3. The price</legend>
          <p className="small"><b>Rental charge</b> (the car&apos;s rate, before fees and tax)<Info text={lineHelp('rental_charge')} /></p>
          <div className="ad-choices row" role="radiogroup" aria-label="Rental charge">
            {([['sheet', 'Rate sheet'], ['total', 'A total for the trip'], ['day', 'A rate a day']] as const).map(([v, x]) => (
              <label key={v} className="check" htmlFor={`oc-pm-${v}`}><input type="radio" id={`oc-pm-${v}`} name="oc-pm" checked={f.price_mode === v} onChange={() => set('price_mode')(v)} data-testid={`oc-pm-${v}`} /> <span>{x}</span></label>))}
          </div>
          <div className="ad-fields">
            {f.price_mode === 'total' && text('price_total', 'Rental charge for the whole trip, before fees and tax ($)', { inputMode: 'decimal', hint: b?.rate_sheet_rental_cents ? `Rate sheet: ${fmt(b.rate_sheet_rental_cents)}` : car?.daily_rate_cents ? `Rate sheet: ${fmt(car.daily_rate_cents)} a day` : undefined })}
            {f.price_mode === 'day' && text('price_day', 'Rental rate a day, before fees and tax ($)', { inputMode: 'decimal', hint: days ? `× ${days} day${days === 1 ? '' : 's'} = ${fmt(typedRental(f, days) ?? 0)}` : undefined })}
            {f.price_mode !== 'sheet' && <>{select('price_tax', 'Tax', PRICE_TAX_OPTIONS)}{text('price_reason', 'Reason for the price', { wide: true, placeholder: 'For example: weekly deal agreed on the phone' })}</>}
            {select('km', 'Kilometres a day', [['', 'The car\'s allowance'], ...(form?.km_choices ?? []).map((k) => [String(k), k === 0 ? 'Unlimited' : `${k} km`] as [string, string])])}
            {text('promo_code', 'Promo code')}
            {admin && <>{text('deposit', 'Deposit ($)', { inputMode: 'decimal', hint: car?.deposit_cents ? `The car's deposit: ${fmt(car.deposit_cents)}` : 'Empty: the car\'s deposit' })}
              {text('discount', 'Discount ($)', { inputMode: 'decimal' })}{cents0(f.discount) && text('discount_reason', 'Discount reason')}</>}
            {select('coverage_option', 'How damage to the car is covered', COVERAGE)}
            {f.coverage_option === '3' && editFees && text('plan_price', 'Protection Plan price ($, for the trip, the renter pays)', { inputMode: 'decimal', hint: b?.lines.find((l) => l.charge_type === 'coverage_sold') ? `Now ${fmt(b.lines.find((l) => l.charge_type === 'coverage_sold')!.amount_cents)}. Empty: the Protection Plan price table` : 'Empty: the Protection Plan price table' })}
            {editFees && feeLines.map((l) => { const k = keyOf(l); return (
              <div key={l.id} className="field ad-field"><label className="label" htmlFor={`oc-fee-${k}`}>{lineLabel(l)} ($, for the trip)<Info text={lineHelp(l.charge_type)} /></label>
                <input className="input" id={`oc-fee-${k}`} inputMode="decimal" placeholder={(l.amount_cents / 100).toFixed(2)} value={f.fees[k] ?? ''} data-testid={`oc-fee-${k}`}
                  onChange={(e) => setF((s) => ({ ...s, fees: { ...s.fees, [k]: e.target.value } }))} /></div>); })}
            {editFees && customs.map((c, i) => (
              <div key={i} className="field ad-field ad-field--wide" data-testid={`oc-custom-${i}`}><span className="label">A charge of its own<Info text={lineHelp('custom_fee')} /></span>
                <div className="row"><input className="input" aria-label="What the charge is for" placeholder="What it is for" value={c.label} onChange={(e) => setCustoms((a) => a.map((y, j) => (j === i ? { ...y, label: e.target.value } : y)))} />
                  <input className="input" inputMode="decimal" aria-label="Amount before HST ($)" placeholder="Amount ($)" value={c.amount} onChange={(e) => setCustoms((a) => a.map((y, j) => (j === i ? { ...y, amount: e.target.value } : y)))} />
                  <label className="check small"><input type="checkbox" checked={c.hst} onChange={(e) => setCustoms((a) => a.map((y, j) => (j === i ? { ...y, hst: e.target.checked } : y)))} /> <span>+ HST</span></label>
                  <button className="btn btn--quiet btn--sm" type="button" onClick={() => setCustoms((a) => a.filter((_, j) => j !== i))}>Remove</button></div></div>))}
            {editFees && <p className="ad-field--wide"><button className="btn btn--ghost btn--sm" type="button" onClick={() => setCustoms((a) => [...a, { label: '', amount: '', hst: true }])} data-testid="oc-add-custom">Add a charge of its own</button></p>}
            {(Object.values(f.fees).some((v) => v.trim()) || f.plan_price.trim() || customs.length > 0) && text('fee_reason', 'Reason for the changes (optional)', { wide: true })}
          </div>
          {!admin && <p className="hint">{editFees ? 'The deposit and discounts are set by an Admin. You may type the rental charge with its reason and change a fee (each change is recorded with your name); a price far under the rate sheet is flagged for an Admin, not refused.' : 'The deposit, discounts and fees are set by an Admin. You may type the rental charge with its reason; a price far under the rate sheet is flagged for an Admin, not refused.'}</p>}
          {b && form?.period_days && b.billable_days > form.period_days && (() => { const n = Math.ceil(b.billable_days / form.period_days!); const sh = periodShares(total, Array.from({ length: n }, (_, i) => (i < n - 1 ? form.period_days! : b.billable_days - form.period_days! * (n - 1))));
            return <p className="alert alert--ok small" role="status" data-testid="oc-periods"><span>{b.billable_days} days: {n} monthly periods of 30 days at the monthly rate (about {sh.map((x) => fmt(x)).join(', ')}).</span></p>; })()}
          {addonOptions.length > 0 && <details className="stack" data-testid="oc-addons"><summary className="link small">Add-ons ({addons.length ? `${addons.length} chosen` : 'optional'})</summary>
            <AddonPicker idPrefix="oc" staff compact options={addonOptions} value={addons} onChange={setAddons} /></details>}
        </fieldset>

        <fieldset className="stack"><legend className="d4">4. How it is paid</legend>
          <div className="ad-fields">
            {select('rental_pay', 'The rental', RENTAL_PAY.map(([v, x]) => [v, x]))}
            {select('deposit_pay', 'The deposit', DEPOSIT_PAY.filter(([v]) => admin || v !== 'none').map(([v, x]) => [v, x]))}
          </div>
          <p className="hint" data-testid="oc-pay-hint">{RENTAL_PAY.find(([v]) => v === f.rental_pay)?.[2]} {DEPOSIT_PAY.find(([v]) => v === f.deposit_pay)?.[2]}</p>
        </fieldset>

        <fieldset className="stack"><legend className="d4">5. Who found this client</legend>
          <SourcedChoice id="oc" value={f.choice} onChange={(v) => set('choice')(v)} optional={admin} />
        </fieldset>

        <fieldset className="stack"><legend className="d4">6. Send it</legend>
          <div className="field"><label className="label" htmlFor="oc-message">Message to the renter</label>
            <textarea className="input ad-textarea" id="oc-message" maxLength={1000} value={f.message} onChange={(e) => set('message')(e.target.value)} data-testid="oc-message" /></div>
          <div className="ad-fields">
            {select('hours', 'Offer open for', [...new Set([6, 12, 24, 48, 72, form?.offer_hours ?? 24])].filter((h) => admin || h <= 48).sort((a, z) => a - z).map((h) => [String(h), `${h} hours`]))}
            <div className="field ad-field"><span className="label">Send the link by</span>
              <label className="check" htmlFor="oc-by-email"><input id="oc-by-email" type="checkbox" checked={f.by_email} onChange={(e) => set('by_email')(e.target.checked)} data-testid="oc-by-email" /> <span>Email</span></label>
              <label className="check" htmlFor="oc-by-text"><input id="oc-by-text" type="checkbox" checked={f.by_text} disabled={form ? !form.text_enabled : false} onChange={(e) => set('by_text')(e.target.checked)} data-testid="oc-by-text" /> <span>Text{form && !form.text_enabled ? ' (texts are off in Program settings)' : ''}</span></label></div>
          </div>
          <div className="field"><label className="label" htmlFor="oc-note">Internal note (staff only)</label>
            <textarea className="input ad-textarea" id="oc-note" value={f.note} onChange={(e) => set('note')(e.target.value)} /></div>
        </fieldset>
        {err && <p className="alert alert--error" role="alert" data-testid="oc-error"><span>{err}</span></p>}
        <div className="row">
          <button className="btn btn--primary" type="submit" disabled={pending} data-testid="oc-send">{pending ? 'Sending' : f.by_email || f.by_text ? 'Send the offer' : 'Make the offer (not sent)'}</button>
          <button className="btn btn--ghost" type="button" disabled={pending} onClick={() => send(true)} data-testid="oc-draft">Save without sending</button>
        </div>
      </form>

      <div className="stack ad-sticky">
      <section className="stack" aria-label="Price">
        <div className="pt-card ad-card" data-testid="oc-price">
          <div className="pt-card__head"><h2 className="d4">Price</h2>{b && <span className="small muted">{b.billable_days} days · {b.rate_applied?.replace(/_/g, ' ')}</span>}</div>
          {b ? (<dl className="pt-dl pt-dl--money">
            {b.lines.filter((l) => l.stage === 'booking').map((l) => <div key={l.id}><dt>{lineLabel(l)}</dt><dd>{fmt(l.amount_cents)}</dd></div>)}
            <div><dt>HST</dt><dd>{fmt(b.hst_at_booking_cents)}</dd></div>
            <div><dt><b>Due at booking</b></dt><dd className="pt-total" data-testid="oc-total">{fmt(total)}</dd></div>
            <div><dt>Deposit</dt><dd>{fmt(b.deposit_cents)} ({DEPOSIT_PAY.find(([v]) => v === f.deposit_pay)?.[1].toLowerCase()})</dd></div>
          </dl>) : <p className="small muted" data-testid="oc-price-wait">{need.length ? `To price it: ${need.join(', ')}.` : 'Pricing…'}</p>}
          {b && <p className="small">{priced?.available ? 'The car is free for these dates.' : <b className="ad-late">The car is not free for these dates.</b>}</p>}
          {b?.price_flags?.length ? <p className="small"><b>Flagged for an Admin:</b> {b.price_flags.map((x) => (x === 'below_floor' ? 'under the price floor' : 'past the discount limit')).join(', ')}.</p> : null}
          {problem && <p className="alert alert--error" role="alert" data-testid="oc-problem"><span>{problem}</span></p>}
        </div>
      </section>

      <aside className="ad-renter-view" aria-label="The offer as the renter sees it" data-testid="oc-renter-view">
        <p className="pt-kicker">The offer as the renter sees it</p>
        <h3 className="d4">Your offer for the {b?.vehicle?.name ?? car?.name ?? 'car'}</h3>
        <p className="pt-note small"><b>This offer does not hold the car.</b> The car is reserved once you approve, sign and {f.rental_pay === 'card' ? 'pay' : 'we receive your payment'}.</p>
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
      </aside>
      </div>
    </div>
  );
}
const cents0 = (s: string) => Number(String(s).replace(/[$,\s]/g, '')) > 0;
